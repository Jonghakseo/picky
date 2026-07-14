import { logAgentd } from "../local-log.js";
import type { PickyAgentSession, PickySessionMessage } from "../protocol.js";
import type { RewindBranchMessage, RewindTarget, RuntimeSessionHandle } from "../runtime/types.js";

/**
 * Collaborators the rewind orchestration needs from the supervisor. Passed as closures so the
 * feature lives outside the `session-supervisor.ts` facade without exposing its private surface.
 */
export interface RewindDeps {
  handle(sessionId: string, action: string): Promise<RuntimeSessionHandle>;
  session(sessionId: string): PickyAgentSession;
  removeMessages(sessionId: string, ids: readonly string[]): Promise<void>;
  drainQueue(sessionId: string, handle: RuntimeSessionHandle): Promise<void>;
  patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  updateTodoState(sessionId: string, todoState: PickyAgentSession["todoState"]): Promise<void>;
  emitRewound(sessionId: string, editorText: string | undefined, removedIds: string[]): void;
  waitSettled(sessionId: string): Promise<void>;
}

export async function listRewindTargets(deps: RewindDeps, sessionId: string): Promise<RewindTarget[]> {
  const handle = await deps.handle(sessionId, "list rewind targets");
  return handle.listRewindTargets?.() ?? [];
}

export async function rewindToEntry(deps: RewindDeps, sessionId: string, entryId: string): Promise<PickyAgentSession> {
  const handle = await deps.handle(sessionId, "rewind session");
  if (!handle.rewindToEntry) throw new Error("Runtime session does not support rewind");
  logAgentd("session rewind requested", { sessionId, entryId, streaming: handle.isStreaming });

  if (handle.isStreaming) {
    await handle.abort();
    await deps.waitSettled(sessionId);
  }
  await deps.drainQueue(sessionId, handle);

  const result = await handle.rewindToEntry(entryId);
  const newBranch = handle.getActiveBranchTranscript?.() ?? [];
  const todoResolution = handle.getTodoStateResolution?.();
  if (todoResolution?.resolved) await deps.updateTodoState(sessionId, todoResolution.todoState);
  const removedIds = rewindRemovedMessageIds(deps.session(sessionId).messages ?? [], newBranch);
  await deps.removeMessages(sessionId, removedIds);

  const latestAssistantText = [...newBranch].reverse().find((message) => message.role === "assistant")?.text.trim();
  const current = deps.session(sessionId);
  const patch: Partial<PickyAgentSession> = {
    thinkingPreview: undefined,
    lastSummary: latestAssistantText || undefined,
    finalAnswer: latestAssistantText || undefined,
  };
  if ((current.status === "failed" || current.status === "cancelled") && latestAssistantText) patch.status = "completed";
  await deps.patch(sessionId, patch);
  deps.emitRewound(sessionId, result.editorText, removedIds);
  logAgentd("session rewound", { sessionId, entryId, removedCount: removedIds.length, branchMessages: newBranch.length });
  return deps.session(sessionId);
}

export function rewindRemovedMessageIds(messages: readonly PickySessionMessage[], branch: readonly RewindBranchMessage[]): string[] {
  // Rewinding to user message U moves the live Pi leaf to U's parent, so the HUD journal must drop U
  // and every message after it. The Pi branch and the HUD journal are NOT 1:1: the branch also carries
  // entries the journal never recorded (the kickoff prompt, handoff/source-context messages, tool-only
  // turns). So we anchor ONLY on the last branch message (the newest message that must remain) and cut
  // the journal after its most recent occurrence. An empty branch means we rewound past the first
  // message (leaf reset to null), so the whole journal is dropped. If the anchor text cannot be found
  // in the journal we return [] (no removal) rather than risk dropping messages that must remain.
  if (branch.length === 0) return messages.map((message) => message.id);
  const anchor = branch[branch.length - 1];
  if (!anchor) return [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message && journalMessageMatchesBranch(message, anchor)) {
      return messages.slice(index + 1).map((entry) => entry.id);
    }
  }
  return [];
}

function journalMessageMatchesBranch(message: PickySessionMessage, branchMessage: RewindBranchMessage): boolean {
  const text = message.text?.trim();
  if (!text || text !== branchMessage.text.trim()) return false;
  if (branchMessage.role === "user") {
    // Accept HUD-originated user turns and Pi-derived user turns (terminal sync imports them as
    // originatedBy "pi_extension"; legacy entries may omit the field).
    return message.kind === "user_text"
      && (message.originatedBy === "user" || message.originatedBy === "pi_extension" || message.originatedBy === undefined);
  }
  return message.kind === "agent_text";
}
