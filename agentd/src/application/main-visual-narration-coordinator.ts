import { randomUUID } from "node:crypto";
import { makeAnnotationOverlayRequestForContext, type MainTurnOverlayContext } from "./overlay-context-resolver.js";
import { AnnotationDslParser, type AnnotationDslTag } from "../domain/annotation-dsl.js";
import { NarrationSentenceChunker } from "../domain/narration-sentence-chunker.js";
import { VisualNarrationSegmentAssembler, type VisualNarrationSegmentAction } from "../domain/visual-narration-segment.js";
import type { PickyContextPacket, PickyPreparedVisualNarrationVisual, PickyVisualNarrationSegmentIdentity } from "../protocol.js";

type MainVisualNarrationSegment = {
  identity: PickyVisualNarrationSegmentIdentity;
  visual: PickyPreparedVisualNarrationVisual;
};

export type MainNarrationMetadata = {
  originSource?: "voice" | "text" | "voiceFollowUp" | "textFollowUp" | "system" | "cli" | "unknown";
  replyKind: "pickleCompletion" | "main";
  sessionId?: string;
};

export interface MainVisualNarrationCoordinatorDeps {
  currentTurn(): {
    contextId: string;
    turnId: number;
    turnToken: string;
    context?: PickyContextPacket;
    overlayContext?: MainTurnOverlayContext;
    screenOverlayDisabled: boolean;
  };
  narrationMetadata(): MainNarrationMetadata;
  emit(event: string, payload: unknown): void;
  log(message: string, data: Record<string, string | number | boolean | null | undefined>): void;
}

/**
 * Translates streamed main-agent visual DSL into source-ordered narration and
 * overlay events. SessionSupervisor remains the owner of turn identity and
 * session state; this coordinator owns only parser, sentence, and segment
 * buffers for the active main turn.
 */
export class MainVisualNarrationCoordinator {
  private annotationDslTagSeen = false;
  private narrationChunkCount = 0;
  private visualNarrationOrdinal = 0;
  private readonly annotationDslParser = new AnnotationDslParser();
  private readonly narrationSentenceChunker = new NarrationSentenceChunker();
  private readonly visualNarrationSegments = new VisualNarrationSegmentAssembler<MainVisualNarrationSegment>();

  constructor(private readonly deps: MainVisualNarrationCoordinatorDeps) {}

  get hasAnnotationDslTag(): boolean {
    return this.annotationDslTagSeen;
  }

  get didStreamNarration(): boolean {
    return this.narrationChunkCount > 0;
  }

  beginTurn(): void {
    this.reset();
  }

  reset(): void {
    this.annotationDslTagSeen = false;
    this.narrationChunkCount = 0;
    this.visualNarrationOrdinal = 0;
    this.annotationDslParser.reset();
    this.narrationSentenceChunker.reset();
    this.visualNarrationSegments.reset();
  }

  consume(text: string): string {
    const result = this.annotationDslParser.feed(text);
    this.annotationDslTagSeen ||= result.completedTags.length > 0 || result.droppedTags.length > 0;
    const turn = this.deps.currentTurn();
    for (const summary of result.healedTags) {
      this.deps.log("main annotation DSL tag healed", { contextId: turn.contextId, turnId: turn.turnId, summary });
    }
    for (const reason of result.droppedTags) {
      this.deps.log("main annotation DSL tag dropped", { contextId: turn.contextId, turnId: turn.turnId, reason });
    }
    for (const item of result.streamItems) {
      if (item.kind === "text") {
        this.applyActions(this.visualNarrationSegments.appendText(item.text));
      } else if (item.kind === "visualBoundary") {
        this.flushNarrationSentences();
        this.applyActions(this.visualNarrationSegments.boundary());
      } else {
        this.prepareSegment(item.tag);
      }
    }
    return result.cleanText;
  }

  finishAssistantDsl(): void {
    const result = this.annotationDslParser.finish();
    this.annotationDslTagSeen ||= result.droppedTags.length > 0;
    const turn = this.deps.currentTurn();
    for (const summary of result.healedTags) {
      this.deps.log("main annotation DSL tag healed", { contextId: turn.contextId, turnId: turn.turnId, summary });
    }
    for (const reason of result.droppedTags) {
      this.deps.log("main annotation DSL tag dropped", { contextId: turn.contextId, turnId: turn.turnId, reason });
    }
    this.applyActions(this.visualNarrationSegments.finish());
  }

  flushNarrationSentences(): void {
    for (const text of this.narrationSentenceChunker.finish()) {
      this.emitNarrationChunk(text);
    }
  }

  private prepareSegment(tag: AnnotationDslTag): void {
    if (tag.kind === "screen") return;
    const turn = this.deps.currentTurn();
    if (turn.screenOverlayDisabled) return;
    const captured = turn.overlayContext;
    if (!captured || turn.context?.id !== captured.context.id) {
      this.deps.log("stale DSL overlay dropped", {
        contextId: turn.contextId,
        turnId: turn.turnId,
        capturedContextId: captured?.context.id,
        currentContextId: turn.context?.id,
        kind: tag.kind,
      });
      return;
    }

    try {
      const visual: PickyPreparedVisualNarrationVisual = {
        kind: "annotations",
        request: makeAnnotationOverlayRequestForContext(captured.context, {
          mode: "append",
          annotations: [tag.annotation],
          ...(tag.screenId === undefined ? {} : { screenId: tag.screenId }),
        }, captured.generation),
      };
      const segment: MainVisualNarrationSegment = {
        identity: {
          contextId: captured.context.id,
          contextGeneration: captured.generation,
          turnToken: turn.turnToken,
          segmentId: `segment-${randomUUID()}`,
          ordinal: this.visualNarrationOrdinal,
        },
        visual,
      };
      this.visualNarrationOrdinal += 1;
      this.applyActions(this.visualNarrationSegments.prepare(segment));
    } catch (error) {
      this.deps.log("main annotation DSL overlay unavailable", {
        contextId: turn.contextId,
        turnId: turn.turnId,
        kind: tag.kind,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private applyActions(actions: VisualNarrationSegmentAction<MainVisualNarrationSegment>[]): void {
    for (const action of actions) {
      if (action.kind === "orphanText") {
        for (const text of this.narrationSentenceChunker.feed(action.text)) {
          this.emitNarrationChunk(text);
        }
      } else if (action.kind === "prepared") {
        this.deps.emit("mainVisualNarrationSegmentPrepared", action.segment);
        this.deps.log("visual narration segment prepared", {
          contextId: action.segment.identity.contextId,
          turnToken: action.segment.identity.turnToken,
          ordinal: action.segment.identity.ordinal,
          kind: action.segment.visual.kind,
        });
      } else if (action.kind === "sentence") {
        this.narrationChunkCount += 1;
        this.deps.emit("mainVisualNarrationSegmentSentence", {
          identity: action.segment.identity,
          index: action.index,
          text: action.text,
          ...this.deps.narrationMetadata(),
        });
        this.deps.log("visual narration segment sentence", {
          contextId: action.segment.identity.contextId,
          turnToken: action.segment.identity.turnToken,
          ordinal: action.segment.identity.ordinal,
          index: action.index,
          textChars: action.text.length,
        });
      } else {
        this.deps.emit("mainVisualNarrationSegmentCommitted", {
          identity: action.segment.identity,
          ...(action.text ? { text: action.text } : {}),
          sentenceCount: action.sentenceCount,
          ...this.deps.narrationMetadata(),
        });
        this.deps.log("visual narration segment committed", {
          contextId: action.segment.identity.contextId,
          turnToken: action.segment.identity.turnToken,
          ordinal: action.segment.identity.ordinal,
          sentenceCount: action.sentenceCount,
          textChars: action.text?.length ?? 0,
        });
      }
    }
  }

  private emitNarrationChunk(text: string): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    const { contextId } = this.deps.currentTurn();
    this.narrationChunkCount += 1;
    this.deps.emit("mainNarrationChunk", {
      contextId,
      text: trimmed,
      ...this.deps.narrationMetadata(),
    });
  }
}
