import { isTerminalStatus } from "../domain/session-status.js";
import { isTransientAgentBusyError } from "../domain/transient-runtime-error.js";
import { logAgentd, logLifecycleEvent, type LogField } from "../local-log.js";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { PickyAgentSession, PickyContextPacket, PickyQueueItem } from "../protocol.js";
import { queueTextMatchesUserText, type PendingQueueDelivery } from "../domain/queue-policy.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

export interface FollowUpLifecycleDiagnosticsDeps {
  getSession(sessionId: string): PickyAgentSession | undefined;
  getSessionOrThrow(sessionId: string): PickyAgentSession;
  getRuntimeHandle(sessionId: string): RuntimeSessionHandle | undefined;
  getPendingQueueDeliveries(sessionId: string): readonly PendingQueueDelivery[] | undefined;
  waitForRuntimeEvents(sessionId: string): Promise<void>;
  waitForQueuedStateToSettle(sessionId: string): Promise<void>;
  drainPendingTextOnce(sessionId: string, text: string): Promise<void>;
  discardPendingTextOnce(sessionId: string, text: string): void;
  markCommandReceiptFailed(sessionId: string, commandReceiptId: string | undefined, message: string): Promise<void>;
  appendLog(sessionId: string, line: string): Promise<void>;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  lifecycleEventLogger?: (event: string, fields: Record<string, LogField>) => void;
  followUpStallDelayMs?: number;
  scheduleFollowUpStall?: (callback: () => void, delayMs: number) => unknown;
  clearFollowUpStall?: (timer: unknown) => void;
}

type FollowUpStall = {
  sessionId: string;
  text: string;
  enqueuedAt: number;
  timer: unknown;
};

/**
 * Owns follow-up dispatch lifecycle evidence and terminal/runtime mismatch stall
 * timers. SessionSupervisor remains the owner of session and queue state; this
 * coordinator accesses and mutates that state only through injected boundaries.
 */
export class FollowUpLifecycleDiagnostics {
  private readonly lifecycleEventLogger: (event: string, fields: Record<string, LogField>) => void;
  private readonly followUpStalls = new Map<string, FollowUpStall>();

  constructor(private readonly deps: FollowUpLifecycleDiagnosticsDeps) {
    this.lifecycleEventLogger = deps.lifecycleEventLogger ?? logLifecycleEvent;
  }

  logLifecycle(event: string, sessionId: string, handle?: RuntimeSessionHandle, fields: Record<string, LogField> = {}): void {
    this.lifecycleEventLogger(event, { sessionId, ...this.lifecycleFields(sessionId, handle), ...fields });
  }

  logFollowUpRouting(
    sessionId: string,
    handle: RuntimeSessionHandle,
    textChars: number,
    imageCount: number,
    source?: PickyContextPacket["source"],
  ): boolean {
    const statusAtRequest = this.deps.getSessionOrThrow(sessionId).status;
    const runtimeActiveWhileTerminal = isTerminalStatus(statusAtRequest) && handle.isStreaming;
    this.logLifecycle("followUpRequested", sessionId, handle, {
      source: source ?? "none",
      textChars,
      imageCount,
      runtimeActiveWhileTerminal,
    });
    if (runtimeActiveWhileTerminal) {
      this.logLifecycle("followUpTerminalRuntimeMismatch", sessionId, handle, { statusAtRequest });
    }
    return runtimeActiveWhileTerminal;
  }

  queueDelivery(
    sessionId: string,
    handle: RuntimeSessionHandle,
    prompt: BuiltPrompt,
    rawText: string,
    commandReceiptId: string | undefined,
    runtimeActiveWhileTerminal: boolean,
  ): void {
    // Pi SDK followUp may resolve only after an idle session finishes its whole next turn.
    // Picky follow-ups are enqueue semantics, so do not hold the caller/Picky tool open.
    //
    // `rawText` is the unwrapped user text we pushed into the pending queue and the value the
    // runtime adapter translates Pi's queue entries back to (see `isPromptInRuntimeQueue`).
    // `prompt.text` may be wrapped (e.g. visual follow-up adds a "# Picky follow-up" header), so
    // the pending lookup must use the raw text or the entry will never drain.
    void handle.followUp(prompt)
      .then(async () => {
        logAgentd("follow-up delivery finished", { sessionId });
        this.logLifecycle("followUpAccepted", sessionId, handle, { accepted: true });
        // Pi only fires queue_update when the prompt traverses the queue. For idle (non-streaming)
        // sessions Pi runs the prompt inline and never enqueues, so our deferred pending entry would
        // never get drained. Detect that by checking Pi's queue snapshot once the prompt is
        // accepted and drain explicitly when the prompt is not waiting in either queue.
        await this.deps.waitForRuntimeEvents(sessionId);
        await this.deps.waitForQueuedStateToSettle(sessionId);
        const stillQueued = this.isPromptInRuntimeQueue(handle, rawText);
        this.logLifecycle(stillQueued ? "followUpQueued" : "followUpDelivered", sessionId, handle, {
          accepted: true,
          runtimeActiveWhileTerminal,
        });
        if (!stillQueued) {
          await this.deps.drainPendingTextOnce(sessionId, rawText);
          return;
        }
        this.armFollowUpStall(sessionId, rawText, runtimeActiveWhileTerminal);
      })
      .catch((error) => void this.handleDeliveryError(sessionId, rawText, error, commandReceiptId));
  }

  armFollowUpStall(sessionId: string, text: string, runtimeActiveWhileTerminal: boolean): void {
    if (!runtimeActiveWhileTerminal) return;
    const delivery = this.deps.getPendingQueueDeliveries(sessionId)?.find((entry) => entry.kind === "followUp" && entry.text === text);
    if (!delivery || this.followUpStalls.has(delivery.id)) return;
    const enqueuedAt = Date.now();
    const delayMs = this.deps.followUpStallDelayMs ?? 30_000;
    const timer = (this.deps.scheduleFollowUpStall ?? ((callback, delay) => setTimeout(callback, delay)))(() => {
      const active = this.followUpStalls.get(delivery.id);
      const handle = this.deps.getRuntimeHandle(sessionId);
      if (!active || !handle || !this.isPromptInRuntimeQueue(handle, active.text)) {
        this.clearFollowUpStall(delivery.id);
        return;
      }
      this.logLifecycle("followUpQueueStalled", sessionId, handle, {
        ageMs: Date.now() - active.enqueuedAt,
        runtimeActiveWhileTerminal: true,
      });
      this.clearFollowUpStall(delivery.id);
    }, delayMs);
    this.followUpStalls.set(delivery.id, { sessionId, text, enqueuedAt, timer });
  }

  clearFollowUpStall(deliveryId: string): void {
    const stall = this.followUpStalls.get(deliveryId);
    if (!stall) return;
    (this.deps.clearFollowUpStall ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>)))(stall.timer);
    this.followUpStalls.delete(deliveryId);
  }

  clearFollowUpStallForText(sessionId: string, text: string): void {
    for (const [deliveryId, stall] of this.followUpStalls) {
      if (stall.sessionId === sessionId && stall.text === text) this.clearFollowUpStall(deliveryId);
    }
  }

  clearFollowUpStallForQueueItem(sessionId: string, item: PickyQueueItem): void {
    if (item.id && this.followUpStalls.has(item.id)) {
      this.clearFollowUpStall(item.id);
      return;
    }
    // Older persisted queue items may lack an id. In that compatibility path, text is the
    // only available correlation key, so clear matching stall candidates conservatively.
    this.clearFollowUpStallForText(sessionId, item.text);
  }

  clearFollowUpStalls(sessionId: string): void {
    for (const [deliveryId, stall] of this.followUpStalls) {
      if (stall.sessionId === sessionId) this.clearFollowUpStall(deliveryId);
    }
  }

  isPromptInRuntimeQueue(handle: RuntimeSessionHandle, text: string): boolean {
    // Runtime adapters reverse Pi's slash-command and subagent expansion before exposing queue
    // entries, so this raw-text match preserves the pending delivery's identity.
    const matches = (entry: string) => queueTextMatchesUserText(entry, text);
    return handle.getFollowUpMessages().some(matches) || handle.getSteeringMessages().some(matches);
  }

  private async handleDeliveryError(sessionId: string, text: string, error: unknown, commandReceiptId?: string): Promise<void> {
    this.clearFollowUpStallForText(sessionId, text);
    this.logLifecycle("followUpRejected", sessionId, undefined, { accepted: false });
    this.deps.discardPendingTextOnce(sessionId, text);
    const message = error instanceof Error ? error.message : String(error);
    logAgentd("follow-up delivery failed", { sessionId, error: message });
    await this.deps.markCommandReceiptFailed(sessionId, commandReceiptId, message);
    await this.deps.appendLog(sessionId, `follow-up failed: ${message}`);
    if (isTransientAgentBusyError(message)) {
      logAgentd("follow-up transient busy failure ignored", { sessionId, error: message });
      return;
    }
    const current = this.deps.getSession(sessionId);
    if (!current || ["completed", "cancelled"].includes(current.status)) return;
    await this.deps.patchSession(sessionId, { status: "failed", lastSummary: `Follow-up failed: ${message}` });
  }

  private lifecycleFields(sessionId: string, handle = this.deps.getRuntimeHandle(sessionId)): Record<string, LogField> {
    const session = this.deps.getSession(sessionId);
    return {
      sessionStatus: session?.status,
      isStreaming: handle?.isStreaming,
      isCompacting: handle?.isCompacting ?? false,
      queuedSteeringCount: handle?.getSteeringMessages().length ?? session?.queuedSteers?.length ?? 0,
      queuedFollowUpCount: handle?.getFollowUpMessages().length ?? session?.queuedFollowUps?.length ?? 0,
      pendingDeliveryCount: this.deps.getPendingQueueDeliveries(sessionId)?.length ?? 0,
    };
  }
}
