import { randomUUID } from "node:crypto";
import { AnnotationDslParser, type AnnotationDslTag } from "../domain/annotation-dsl.js";
import { normalizeDslWhitespace } from "../domain/session-text-policy.js";
import { logAgentd } from "../local-log.js";
import type { PickyAnnotationOverlayRequest, PickyContextPacket } from "../protocol.js";
import { makeAnnotationOverlayRequestForContext } from "./overlay-context-resolver.js";

export interface PickleVisualDslLease {
  id: string;
  sessionId: string;
  context: PickyContextPacket;
  generation: number;
}

interface ActivePickleVisualDslLease {
  lease: PickleVisualDslLease;
  parser: AnnotationDslParser;
}

export class PickleVisualDslCoordinator {
  private readonly activeBySession = new Map<string, ActivePickleVisualDslLease>();

  constructor(private readonly emitAnnotationOverlay: (request: PickyAnnotationOverlayRequest) => void) {}

  createLease(sessionId: string, context: PickyContextPacket): PickleVisualDslLease {
    return {
      id: `pickle-visual-${randomUUID()}`,
      sessionId,
      context,
      generation: 0,
    };
  }

  activate(lease: PickleVisualDslLease): void {
    this.activeBySession.set(lease.sessionId, { lease, parser: new AnnotationDslParser() });
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
    this.logDiagnostics(active.lease, result.healedTags, result.droppedTags);
    for (const tag of result.completedTags) this.emitTag(active.lease, tag);
    return result.cleanText;
  }

  finishAssistantMessage(sessionId: string): void {
    const active = this.activeBySession.get(sessionId);
    if (active) this.finishParser(active);
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
  }

  private emitTag(lease: PickleVisualDslLease, tag: AnnotationDslTag): void {
    if (tag.kind === "screen") return;
    try {
      const annotation = {
        ...tag.annotation,
        id: `${lease.id}-${tag.annotation.id}`,
      };
      const request = makeAnnotationOverlayRequestForContext(lease.context, {
        mode: "append",
        annotations: [annotation],
        ...(tag.screenId === undefined ? {} : { screenId: tag.screenId }),
      }, lease.generation);
      this.emitAnnotationOverlay({ ...request, revealImmediately: true });
    } catch (error) {
      logAgentd("pickle visual DSL overlay dropped", {
        sessionId: lease.sessionId,
        leaseId: lease.id,
        contextId: lease.context.id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
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
