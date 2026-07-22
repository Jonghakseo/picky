import { isCompactSlashCommand } from "../domain/slash-commands.js";
import { logAgentd, type LogField } from "../local-log.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

type TerminalStatus = "cancelled" | "failed";

interface TerminalManualCompactionDependencies {
  sessionStatus(sessionId: string): string;
  cancelPendingExtensionUi(sessionId: string, handle: RuntimeSessionHandle): Promise<void>;
  resetAssistantDraft(sessionId: string): void;
  beginTerminalManualCompaction(sessionId: string, status: TerminalStatus): void;
  clearTerminalManualCompaction(sessionId: string): void;
  finishTerminalManualCompaction(sessionId: string): void;
  waitForRuntimeEvents(sessionId: string): Promise<void>;
  logLifecycle(event: string, sessionId: string, handle: RuntimeSessionHandle, fields?: Record<string, LogField>): void;
}

/** Serializes manual compaction requested from an already terminal Pickle. */
export class TerminalManualCompactionCoordinator {
  private readonly pending = new Map<string, Promise<void>>();

  constructor(private readonly dependencies: TerminalManualCompactionDependencies) {}

  hasPending(sessionId: string): boolean {
    return this.pending.has(sessionId);
  }

  async execute(sessionId: string, text: string, handle: RuntimeSessionHandle): Promise<boolean> {
    if (!isCompactSlashCommand(text) || !handle.compact) return false;
    if (this.pending.has(sessionId)) throw new Error("Manual compaction is already in progress");

    const status = this.dependencies.sessionStatus(sessionId);
    const terminalStatus = status === "cancelled" || status === "failed" ? status : undefined;
    // Reserve before the first await so concurrent WebSocket commands cannot both begin.
    const reservation = terminalStatus ? Promise.resolve() : undefined;
    if (reservation) this.pending.set(sessionId, reservation);

    const startedAt = Date.now();
    let compactFinished = false;
    try {
      await this.dependencies.cancelPendingExtensionUi(sessionId, handle);
      this.dependencies.resetAssistantDraft(sessionId);
      const customInstructions = text.trim().replace(/^\/compact\s*/, "").trim() || undefined;
      if (terminalStatus) this.dependencies.beginTerminalManualCompaction(sessionId, terminalStatus);
      logAgentd("compact requested", { sessionId, wasStreaming: handle.isStreaming, instructionChars: customInstructions?.length ?? 0 });
      this.logCompactStarted(sessionId, handle, terminalStatus, customInstructions);
      await handle.compact(customInstructions);
      compactFinished = true;
      this.logCompactOutcome("manualCompactFinished", sessionId, handle, startedAt, "resolved");
      await this.dependencies.waitForRuntimeEvents(sessionId);
      this.logCompactOutcome("manualCompactSettled", sessionId, handle, startedAt, "settled");
    } catch (error) {
      this.logCompactRejection(sessionId, handle, startedAt, compactFinished);
      if (terminalStatus) this.dependencies.clearTerminalManualCompaction(sessionId);
      throw error;
    } finally {
      if (reservation && this.pending.get(sessionId) === reservation) {
        this.pending.delete(sessionId);
        this.dependencies.finishTerminalManualCompaction(sessionId);
      }
    }
    return true;
  }

  private logCompactStarted(
    sessionId: string,
    handle: RuntimeSessionHandle,
    terminalStatus: TerminalStatus | undefined,
    customInstructions: string | undefined,
  ): void {
    this.dependencies.logLifecycle("manualCompactStarted", sessionId, handle, {
      terminalStatus: terminalStatus ?? "none",
      instructionChars: customInstructions?.length ?? 0,
    });
  }

  private logCompactOutcome(
    event: "manualCompactFinished" | "manualCompactSettled",
    sessionId: string,
    handle: RuntimeSessionHandle,
    startedAt: number,
    outcome: "resolved" | "settled" | "rejected",
  ): void {
    this.dependencies.logLifecycle(event, sessionId, handle, {
      elapsedMs: Date.now() - startedAt,
      outcome,
    });
  }

  private logCompactRejection(sessionId: string, handle: RuntimeSessionHandle, startedAt: number, compactFinished: boolean): void {
    this.logCompactOutcome(compactFinished ? "manualCompactSettled" : "manualCompactFinished", sessionId, handle, startedAt, "rejected");
  }
}
