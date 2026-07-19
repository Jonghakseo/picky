import { randomUUID } from "node:crypto";
import { AnnotationDslParser, type AnnotationDslTag } from "../domain/annotation-dsl.js";
import { quickReplyOriginFromContextSource } from "../domain/main-agent-policy.js";
import { NarrationSentenceChunker } from "../domain/narration-sentence-chunker.js";
import { normalizeDslWhitespace } from "../domain/session-text-policy.js";
import { VisualNarrationSegmentAssembler, type VisualNarrationSegmentAction } from "../domain/visual-narration-segment.js";
import { logAgentd } from "../local-log.js";
import type { EventEnvelope, PickyContextPacket, PickyPreparedVisualNarrationVisual, PickyVisualNarrationSegmentIdentity } from "../protocol.js";
import { makeAnnotationOverlayRequestForContext } from "./overlay-context-resolver.js";

export interface PickleVisualDslLease {
  id: string;
  sessionId: string;
  context: PickyContextPacket;
  generation: number;
}

type VisualNarrationEventType =
  | "mainNarrationChunk"
  | "mainVisualNarrationSegmentPrepared"
  | "mainVisualNarrationSegmentSentence"
  | "mainVisualNarrationSegmentCommitted"
  | "quickReply";

type EventPayload<Type extends VisualNarrationEventType> = Omit<
  Extract<EventEnvelope, { type: Type }>,
  "id" | "protocolVersion" | "timestamp"
>;

export type PickleVisualDslEvent = {
  [Type in VisualNarrationEventType]: EventPayload<Type>
}[VisualNarrationEventType];

interface PickleVisualNarrationSegment {
  identity: PickyVisualNarrationSegmentIdentity;
  visual: PickyPreparedVisualNarrationVisual;
}

interface ActivePickleVisualDslLease {
  lease: PickleVisualDslLease;
  parser: AnnotationDslParser;
  narrationSentenceChunker: NarrationSentenceChunker;
  visualSegments: VisualNarrationSegmentAssembler<PickleVisualNarrationSegment>;
  cleanDraft: string;
  narrationChunkCount: number;
  visualOrdinal: number;
}

export class PickleVisualDslCoordinator {
  private readonly activeBySession = new Map<string, ActivePickleVisualDslLease>();

  constructor(private readonly emitEvent: (event: PickleVisualDslEvent) => void) {}

  createLease(sessionId: string, context: PickyContextPacket): PickleVisualDslLease {
    return {
      id: `pickle-visual-${randomUUID()}`,
      sessionId,
      context,
      generation: 0,
    };
  }

  activate(lease: PickleVisualDslLease): void {
    this.activeBySession.set(lease.sessionId, {
      lease,
      parser: new AnnotationDslParser(),
      narrationSentenceChunker: new NarrationSentenceChunker(),
      visualSegments: new VisualNarrationSegmentAssembler<PickleVisualNarrationSegment>(),
      cleanDraft: "",
      narrationChunkCount: 0,
      visualOrdinal: 0,
    });
    logAgentd("pickle visual DSL activated", {
      sessionId: lease.sessionId,
      leaseId: lease.id,
      contextId: lease.context.id,
      screenshots: lease.context.screenshots.length,
    });
  }

  deactivate(sessionId: string, reason: string, leaseId?: string): void {
    const active = this.activeBySession.get(sessionId);
    if (!active || (leaseId !== undefined && active.lease.id !== leaseId)) return;
    this.finishParser(active);
    this.activeBySession.delete(sessionId);
    logAgentd("pickle visual DSL deactivated", { sessionId, leaseId: active.lease.id, reason });
  }

  consumeAssistantDelta(sessionId: string, delta: string): string {
    const active = this.activeBySession.get(sessionId);
    if (!active) return delta;
    const result = active.parser.feed(delta);
    active.cleanDraft += result.cleanText;
    this.logDiagnostics(active.lease, result.healedTags, result.droppedTags);
    for (const item of result.streamItems) {
      if (item.kind === "text") {
        this.applyVisualNarrationActions(active, active.visualSegments.appendText(item.text));
      } else if (item.kind === "visualBoundary") {
        this.flushNarrationSentences(active);
        this.applyVisualNarrationActions(active, active.visualSegments.boundary());
      } else {
        this.prepareVisualNarrationSegment(active, item.tag);
      }
    }
    return result.cleanText;
  }

  finishAssistantMessage(sessionId: string): void {
    const active = this.activeBySession.get(sessionId);
    if (active) this.finishParser(active);
  }

  completeAssistantRun(sessionId: string, finalAnswer?: string): void {
    const active = this.activeBySession.get(sessionId);
    if (!active) return;
    const text = normalizeDslWhitespace(
      finalAnswer === undefined
        ? active.cleanDraft
        : this.sanitizeCompleteText(sessionId, finalAnswer),
    ).trim();
    if (!text) return;
    this.emitEvent({
      type: "quickReply",
      contextId: active.lease.context.id,
      text,
      ...this.narrationMetadata(active.lease),
      ...(active.narrationChunkCount > 0 ? { didStreamNarration: true } : {}),
    });
  }

  sanitizeCompleteText(sessionId: string, text: string): string {
    if (!this.activeBySession.has(sessionId)) return text;
    const parser = new AnnotationDslParser();
    const result = parser.feed(text);
    const finished = parser.finish();
    const hadDsl = result.completedTags.length > 0 || result.droppedTags.length > 0 || finished.droppedTags.length > 0;
    return hadDsl ? normalizeDslWhitespace(result.cleanText) : result.cleanText;
  }

  hasActiveLease(sessionId: string): boolean {
    return this.activeBySession.has(sessionId);
  }

  private finishParser(active: ActivePickleVisualDslLease): void {
    const result = active.parser.finish();
    this.logDiagnostics(active.lease, result.healedTags, result.droppedTags);
    this.applyVisualNarrationActions(active, active.visualSegments.finish());
    this.flushNarrationSentences(active);
  }

  private prepareVisualNarrationSegment(active: ActivePickleVisualDslLease, tag: AnnotationDslTag): void {
    if (tag.kind === "screen") return;
    try {
      const annotation = {
        ...tag.annotation,
        id: `${active.lease.id}-${tag.annotation.id}`,
      };
      const visual: PickyPreparedVisualNarrationVisual = {
        kind: "annotations",
        request: makeAnnotationOverlayRequestForContext(active.lease.context, {
          mode: "append",
          annotations: [annotation],
          ...(tag.screenId === undefined ? {} : { screenId: tag.screenId }),
        }, active.lease.generation),
      };
      const segment: PickleVisualNarrationSegment = {
        identity: {
          contextId: active.lease.context.id,
          contextGeneration: active.lease.generation,
          turnToken: active.lease.id,
          segmentId: `segment-${randomUUID()}`,
          ordinal: active.visualOrdinal,
        },
        visual,
      };
      active.visualOrdinal += 1;
      this.applyVisualNarrationActions(active, active.visualSegments.prepare(segment));
    } catch (error) {
      logAgentd("pickle visual DSL overlay dropped", {
        sessionId: active.lease.sessionId,
        leaseId: active.lease.id,
        contextId: active.lease.context.id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private applyVisualNarrationActions(
    active: ActivePickleVisualDslLease,
    actions: VisualNarrationSegmentAction<PickleVisualNarrationSegment>[],
  ): void {
    for (const action of actions) {
      if (action.kind === "orphanText") {
        this.emitNarrationSentences(active, action.text);
      } else if (action.kind === "prepared") {
        this.emitEvent({
          type: "mainVisualNarrationSegmentPrepared",
          identity: action.segment.identity,
          visual: action.segment.visual,
        });
        this.logSegmentAction(active.lease, action.segment.identity, "prepared");
      } else if (action.kind === "sentence") {
        active.narrationChunkCount += 1;
        this.emitEvent({
          type: "mainVisualNarrationSegmentSentence",
          identity: action.segment.identity,
          index: action.index,
          text: action.text,
          ...this.narrationMetadata(active.lease),
        });
        this.logSegmentAction(active.lease, action.segment.identity, "sentence", {
          index: action.index,
          textChars: action.text.length,
        });
      } else {
        this.emitEvent({
          type: "mainVisualNarrationSegmentCommitted",
          identity: action.segment.identity,
          ...(action.text ? { text: action.text } : {}),
          sentenceCount: action.sentenceCount,
          ...this.narrationMetadata(active.lease),
        });
        this.logSegmentAction(active.lease, action.segment.identity, "committed", {
          sentenceCount: action.sentenceCount,
          textChars: action.text?.length ?? 0,
        });
      }
    }
  }

  private emitNarrationSentences(active: ActivePickleVisualDslLease, text: string): void {
    for (const sentence of active.narrationSentenceChunker.feed(text)) {
      this.emitNarrationChunk(active, sentence);
    }
  }

  private flushNarrationSentences(active: ActivePickleVisualDslLease): void {
    for (const sentence of active.narrationSentenceChunker.finish()) {
      this.emitNarrationChunk(active, sentence);
    }
  }

  private emitNarrationChunk(active: ActivePickleVisualDslLease, text: string): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    active.narrationChunkCount += 1;
    this.emitEvent({
      type: "mainNarrationChunk",
      contextId: active.lease.context.id,
      text: trimmed,
      ...this.narrationMetadata(active.lease),
    });
  }

  private narrationMetadata(lease: PickleVisualDslLease): {
    originSource: ReturnType<typeof quickReplyOriginFromContextSource>;
    replyKind: "main";
    sessionId: string;
  } {
    return {
      originSource: quickReplyOriginFromContextSource(lease.context.source),
      replyKind: "main",
      sessionId: lease.sessionId,
    };
  }

  private logSegmentAction(
    lease: PickleVisualDslLease,
    identity: PickyVisualNarrationSegmentIdentity,
    action: "prepared" | "sentence" | "committed",
    fields: Record<string, string | number> = {},
  ): void {
    logAgentd(`pickle visual narration segment ${action}`, {
      sessionId: lease.sessionId,
      contextId: identity.contextId,
      turnToken: identity.turnToken,
      ordinal: identity.ordinal,
      ...fields,
    });
  }

  private logDiagnostics(lease: PickleVisualDslLease, healedTags: readonly string[], droppedTags: readonly string[]): void {
    for (const summary of healedTags) {
      logAgentd("pickle visual DSL tag healed", { sessionId: lease.sessionId, leaseId: lease.id, summary });
    }
    for (const reason of droppedTags) {
      logAgentd("pickle visual DSL tag dropped", { sessionId: lease.sessionId, leaseId: lease.id, reason });
    }
  }
}
