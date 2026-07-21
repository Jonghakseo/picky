import { isCompactSlashCommand } from "../domain/slash-commands.js";
import { logAgentd } from "../local-log.js";
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

    try {
      await this.dependencies.cancelPendingExtensionUi(sessionId, handle);
      this.dependencies.resetAssistantDraft(sessionId);
      const customInstructions = text.trim().replace(/^\/compact\s*/, "").trim() || undefined;
      if (terminalStatus) this.dependencies.beginTerminalManualCompaction(sessionId, terminalStatus);
      logAgentd("compact requested", { sessionId, wasStreaming: handle.isStreaming, instructionChars: customInstructions?.length ?? 0 });
      await handle.compact(customInstructions);
      await this.dependencies.waitForRuntimeEvents(sessionId);
    } catch (error) {
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
}
