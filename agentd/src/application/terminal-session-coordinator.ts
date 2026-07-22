import { PiSessionTailWatcher, type PiSessionTailEntry } from "./pi-session-tail-watcher.js";
import { readPiTerminalSessionMessages } from "./pi-session-syncer.js";
import { inferTerminalStatusFromEntries } from "./terminal-tail-status.js";
import { appendUniqueLog, piSessionFilePathForSession } from "../domain/pi-session-files.js";
import { canonicalizeSubagentMentions } from "../domain/subagent-mention.js";
import { FOLLOWUP_PREFIX } from "../domain/log-prefixes.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession, PickySessionMessage } from "../protocol.js";

export interface TerminalSessionSyncOutcome {
  baselineFound: boolean;
  importedMessageCount: number;
  activeLastMessageId?: string;
  baselinePiMessageId?: string;
}

interface TerminalSessionMessageRecorder {
  recordTerminalSessionMessages(sessionId: string, messages: readonly PickySessionMessage[]): Promise<void>;
}

interface TerminalSessionCoordinatorDeps {
  getSession(sessionId: string): PickyAgentSession | undefined;
  getSessionOrThrow(sessionId: string): PickyAgentSession;
  hasRuntimeHandle(sessionId: string): boolean;
  detachRuntimeHandle(sessionId: string): Promise<void>;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  updateTodoState(sessionId: string, todoState: PickyAgentSession["todoState"]): Promise<void>;
  messageRecorder: TerminalSessionMessageRecorder;
  emitSyncOutcome(sessionId: string, outcome: TerminalSessionSyncOutcome): void;
}

/**
 * Owns terminal-overlay JSONL watching and reconciliation. SessionSupervisor keeps the
 * public command surface, while this coordinator owns watcher lifecycle and sync rules.
 */
export class TerminalSessionCoordinator {
  private readonly tailWatchers = new Map<string, PiSessionTailWatcher>();

  constructor(private readonly deps: TerminalSessionCoordinatorDeps) {}

  async setTailEnabled(sessionId: string, enabled: boolean): Promise<void> {
    if (enabled) {
      if (this.tailWatchers.has(sessionId)) return;
      const session = this.deps.getSession(sessionId);
      if (!session) {
        logAgentd("terminal tail skipped", { sessionId, reason: "unknown session" });
        return;
      }
      const sessionFilePath = piSessionFilePathForSession(session);
      if (!sessionFilePath) {
        logAgentd("terminal tail skipped", { sessionId, reason: "no pi session file" });
        return;
      }
      const watcher = new PiSessionTailWatcher(
        sessionFilePath,
        (entries) => this.handleTailEntries(sessionId, entries),
        (error) => logAgentd("terminal tail error", { sessionId, error: error instanceof Error ? error.message : String(error) }),
        { onTruncate: () => this.handleTailTruncation(sessionId, sessionFilePath) },
      );
      try {
        await watcher.start();
        this.tailWatchers.set(sessionId, watcher);
        logAgentd("terminal tail started", { sessionId, sessionFilePath });
      } catch (error) {
        logAgentd("terminal tail start failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
      }
      return;
    }
    const watcher = this.tailWatchers.get(sessionId);
    if (!watcher) return;
    this.tailWatchers.delete(sessionId);
    await watcher.stop().catch(() => undefined);
    logAgentd("terminal tail stopped", { sessionId });
  }

  invalidateRuntimeHandleAfterSync(
    sessionId: string,
    outcome: { activeLastMessageId?: string; baselinePiMessageId?: string; importedMessageCount: number },
  ): void {
    const activeLastMessageId = outcome.activeLastMessageId?.trim();
    if (!activeLastMessageId) return;
    const baselinePiMessageId = outcome.baselinePiMessageId?.trim();
    const activePathAdvanced = baselinePiMessageId
      ? activeLastMessageId !== baselinePiMessageId
      : outcome.importedMessageCount > 0;
    if (!activePathAdvanced || !this.deps.hasRuntimeHandle(sessionId)) return;
    void this.deps.detachRuntimeHandle(sessionId);
    logAgentd("terminal session sync invalidated runtime handle after pi session advanced", {
      sessionId,
      activeLastMessageId,
      ...(baselinePiMessageId ? { baselinePiMessageId } : {}),
      importedMessageCount: outcome.importedMessageCount,
    });
  }

  async sync(sessionId: string, baselinePiMessageId?: string): Promise<PickyAgentSession> {
    const session = this.deps.getSessionOrThrow(sessionId);
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) throw new Error(`Session has no Pi session file to sync: ${sessionId}`);
    logAgentd("terminal session sync requested", { sessionId, sessionFilePath, baselinePiMessageId });
    const result = await readPiTerminalSessionMessages(sessionFilePath, baselinePiMessageId);
    if (result.todoStateResolved) await this.deps.updateTodoState(sessionId, result.todoState);
    if (!result.baselineFound) {
      logAgentd("terminal session sync skipped", { sessionId, reason: "baseline pi message not found", baselinePiMessageId, activeLastMessageId: result.activeLastMessageId });
      this.emitSyncOutcome(sessionId, false, 0, result.activeLastMessageId, baselinePiMessageId);
      return this.deps.getSessionOrThrow(sessionId);
    }

    const existingMessages = this.deps.getSessionOrThrow(sessionId).messages ?? [];
    const existingIds = new Set(existingMessages.map((message) => message.id));
    const baselineCreatedAt = result.baselineCreatedAt;
    const hudUserTextsInWindow = existingMessages
      .filter((message) => message.kind === "user_text" && message.originatedBy === "user" && typeof message.text === "string" && message.text.trim().length > 0)
      .filter((message) => !baselineCreatedAt || message.createdAt >= baselineCreatedAt)
      .map((message) => canonicalizeSubagentMentions((message.text ?? "").trim()));
    const hudAgentTextsInWindow = existingMessages
      .filter((message) => message.kind === "agent_text" && typeof message.text === "string" && message.text.trim().length > 0)
      .filter((message) => !baselineCreatedAt || message.createdAt >= baselineCreatedAt)
      .map((message) => canonicalizeSubagentMentions((message.text ?? "").trim()));
    const messagesToImport = result.messages.filter((message) => {
      if (existingIds.has(message.id)) return false;
      const text = (message.text ?? "").trim();
      if (!text) return true;
      const candidates = message.kind === "user_text"
        ? hudUserTextsInWindow
        : message.kind === "agent_text"
          ? hudAgentTextsInWindow
          : undefined;
      if (!candidates) return true;
      // Pi rewrites `>name` subagent mentions to `subagent:name` in its JSONL, so compare on the
      // canonicalized form to keep the expanded Pi copy from surviving as a duplicate bubble.
      const index = candidates.indexOf(canonicalizeSubagentMentions(text));
      if (index < 0) return true;
      candidates.splice(index, 1);
      return false;
    });
    this.invalidateRuntimeHandleAfterSync(sessionId, {
      activeLastMessageId: result.activeLastMessageId,
      baselinePiMessageId,
      importedMessageCount: messagesToImport.length,
    });
    if (messagesToImport.length === 0) {
      logAgentd("terminal session sync noop", { sessionId, activeLastMessageId: result.activeLastMessageId });
      this.emitSyncOutcome(sessionId, true, 0, result.activeLastMessageId, baselinePiMessageId);
      return this.deps.getSessionOrThrow(sessionId);
    }

    await this.deps.messageRecorder.recordTerminalSessionMessages(sessionId, messagesToImport);
    const latestAssistantText = [...messagesToImport].reverse().find((message) => message.kind === "agent_text")?.text?.trim();
    const latestUserText = [...messagesToImport].reverse().find((message) => message.kind === "user_text")?.text?.trim();
    const patch: Partial<PickyAgentSession> = {
      thinkingPreview: undefined,
      ...(latestAssistantText ? { lastSummary: latestAssistantText, finalAnswer: latestAssistantText } : {}),
      ...(latestUserText ? { logs: appendUniqueLog(this.deps.getSessionOrThrow(sessionId).logs, `${FOLLOWUP_PREFIX}${latestUserText}`) } : {}),
    };
    if (latestAssistantText) patch.status = "completed";
    await this.deps.patchSession(sessionId, patch);
    logAgentd("terminal session synced", { sessionId, importedMessages: messagesToImport.length, activeLastMessageId: result.activeLastMessageId });
    this.emitSyncOutcome(sessionId, true, messagesToImport.length, result.activeLastMessageId, baselinePiMessageId);
    return this.deps.getSessionOrThrow(sessionId);
  }

  private handleTailTruncation(sessionId: string, sessionFilePath: string): void {
    if (!this.deps.hasRuntimeHandle(sessionId)) return;
    void this.deps.detachRuntimeHandle(sessionId);
    logAgentd("terminal tail invalidated runtime handle after pi session rewrite", { sessionId, sessionFilePath });
  }

  private async handleTailEntries(sessionId: string, entries: PiSessionTailEntry[]): Promise<void> {
    const session = this.deps.getSession(sessionId);
    if (!session) return;
    const inferred = inferTerminalStatusFromEntries(entries);
    if (!inferred || session.status === inferred) return;
    if (session.status === "cancelled" && inferred !== "completed") return;
    logAgentd("terminal tail status patch", { sessionId, from: session.status, to: inferred });
    await this.deps.patchSession(sessionId, { status: inferred });
  }

  private emitSyncOutcome(
    sessionId: string,
    baselineFound: boolean,
    importedMessageCount: number,
    activeLastMessageId?: string,
    baselinePiMessageId?: string,
  ): void {
    this.deps.emitSyncOutcome(sessionId, {
      baselineFound,
      importedMessageCount,
      activeLastMessageId,
      baselinePiMessageId,
    });
  }
}
