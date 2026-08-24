import type { PickyActivitySummary, PickyAgentSession, PickyArtifact, PickySessionMessage, PickySessionProjectionMutation } from "../protocol.js";
import { finalizeTerminalSession, type TerminalRuntimeStatusEvent, type TerminalTransientReset } from "../domain/terminal-session-finalization.js";
import { cleanFinalAnswer } from "../domain/session-summary.js";
import { hasActivity, zeroActivitySummary } from "../domain/activity-summary.js";
import { nextRevision } from "../domain/session-revision-policy.js";
import type { RuntimeEvent } from "../runtime/types.js";
import type { RuntimeTerminalSnapshot } from "./runtime-event-handler.js";
import type { SessionMessageTerminalSnapshot } from "../session-message-builder.js";
import { randomUUID } from "node:crypto";

export interface TerminalDurableCommitDependencies {
  runExclusiveMessageOperation(sessionId: string, work: () => Promise<void>): Promise<void>;
  runSessionWrite(sessionId: string, work: () => Promise<void>): Promise<void>;
  getSession(sessionId: string): PickyAgentSession;
  messageSnapshot(sessionId: string): SessionMessageTerminalSnapshot;
  runtimeSnapshot(sessionId: string): RuntimeTerminalSnapshot;
  turnActivity(sessionId: string): PickyActivitySummary | undefined;
  materialize(session: PickyAgentSession): Promise<{ artifacts: PickyArtifact[]; emittedArtifacts: PickyArtifact[] } | undefined>;
  save(session: PickyAgentSession): Promise<void>;
  setSession(sessionId: string, session: PickyAgentSession): void;
  rehydrateMessageSession(sessionId: string, messages: readonly PickySessionMessage[]): void;
  resetTerminalAssistantDraft(sessionId: string): void;
  resetTerminalThinkingDraft(sessionId: string): void;
  resetTerminalThinkingActive(sessionId: string): void;
  clearTerminalPendingThinkingFlush(sessionId: string): void;
  markTerminalRunProcessed(sessionId: string): void;
  clearTurnActivity(sessionId: string): void;
  publish(sessionId: string, publication: TerminalCommitPublication, committedActivity: boolean, emittedArtifacts: readonly PickyArtifact[]): Promise<void>;
  isPickleSession(sessionId: string): boolean;
  notifyPickleCompletion(sessionId: string): Promise<void>;
  logNotificationFailure(sessionId: string, error: unknown): void;
}

export interface TerminalCommitPublication {
  readonly before: PickyAgentSession;
  readonly after: PickyAgentSession;
  readonly mutations: readonly PickySessionProjectionMutation[];
  readonly revision: number;
}

/**
 * Runs the terminal transaction in the same journal chain as every message operation, then in
 * the supervisor write chain. The nested order ensures new journal work queues behind terminal
 * persistence instead of retaining a stale pre-terminal journal while its save is in flight.
 */
export async function finalizeTerminalOperation(
  dependencies: TerminalDurableCommitDependencies,
  sessionId: string,
  event: Extract<RuntimeEvent, { type: "status" }>,
): Promise<void> {
  await dependencies.runExclusiveMessageOperation(sessionId, async () => {
    await dependencies.runSessionWrite(sessionId, async () => {
      const before = dependencies.getSession(sessionId);
      const messageSnapshot = dependencies.messageSnapshot(sessionId);
      const runtimeSnapshot = dependencies.runtimeSnapshot(sessionId);
      const now = new Date().toISOString();
      const activitySnapshot = dependencies.turnActivity(sessionId);
      const messages = stageTerminalMessages(
        before,
        messageSnapshot.journal,
        messageSnapshot.assistantDraft || runtimeSnapshot.assistantDraft || cleanFinalAnswer(event.finalAnswer) || "",
        activitySnapshot,
        event,
        now,
      );
      const prepared = {
        messages,
        artifacts: before.artifacts,
        activitySummary: activitySnapshot ? zeroActivitySummary() : before.activitySummary,
      };
      const provisional = finalizeTerminalSession({
        currentSession: before,
        messageSnapshot,
        runtimeSnapshot,
        event: event as TerminalRuntimeStatusEvent,
        prepared,
        now,
      });
      const materialized = await dependencies.materialize(provisional.nextSession);
      const finalization = materialized
        ? finalizeTerminalSession({
          currentSession: before,
          messageSnapshot,
          runtimeSnapshot,
          event: event as TerminalRuntimeStatusEvent,
          prepared: { ...prepared, artifacts: materialized.artifacts },
          now,
        })
        : provisional;
      const after = { ...finalization.nextSession, revision: nextRevision(before.revision ?? 0, true) };

      // The one terminal persistence effect. No reset, projection event, or notification precedes it.
      await dependencies.save(after);
      dependencies.setSession(sessionId, after);
      applyTransientResets(dependencies, sessionId, finalization.transientResets, after.messages ?? []);
      dependencies.markTerminalRunProcessed(sessionId);
      dependencies.clearTurnActivity(sessionId);
      await dependencies.publish(sessionId, {
        before,
        after,
        mutations: finalization.mutations,
        revision: after.revision ?? 0,
      }, Boolean(activitySnapshot), materialized?.emittedArtifacts ?? []);
      if (!dependencies.isPickleSession(sessionId)) return;
      try {
        await dependencies.notifyPickleCompletion(sessionId);
      } catch (error) {
        dependencies.logNotificationFailure(sessionId, error);
      }
    });
  });
}

function applyTransientResets(
  dependencies: TerminalDurableCommitDependencies,
  sessionId: string,
  resets: readonly TerminalTransientReset[],
  messages: readonly PickySessionMessage[],
): void {
  for (const reset of resets) {
    switch (reset) {
      case "SessionMessageBuilder.states":
        dependencies.rehydrateMessageSession(sessionId, messages);
        break;
      case "RuntimeEventHandler.assistantDrafts":
        dependencies.resetTerminalAssistantDraft(sessionId);
        break;
      case "RuntimeEventHandler.thinkingDrafts":
        dependencies.resetTerminalThinkingDraft(sessionId);
        break;
      case "RuntimeEventHandler.thinkingActive":
        dependencies.resetTerminalThinkingActive(sessionId);
        break;
      case "RuntimeEventHandler.pendingThinkingFlushes":
        dependencies.clearTerminalPendingThinkingFlush(sessionId);
        break;
      default: {
        const unhandled: never = reset;
        throw new Error(`Unhandled terminal transient reset: ${String(unhandled)}`);
      }
    }
  }
}

export interface TerminalV1PublicationDependencies {
  nextSeq(sessionId: string): number;
  chainEmit(sessionId: string, work: () => Promise<void>): Promise<void>;
  emitMessageAppended(sessionId: string, message: PickySessionMessage, seq: number): void;
  emitMessageRemoved(sessionId: string, messageId: string, seq: number): void;
  emitMessageReplaced(sessionId: string, messageId: string, message: PickySessionMessage, seq: number): void;
  emitActivityUpdated(sessionId: string, activity: PickyActivitySummary, seq: number): void;
  emitSessionMeta(session: PickyAgentSession): void;
  emitArtifact(sessionId: string, artifact: PickyArtifact): void;
}

/** Replays the unchanged v1 event dialect from the single committed terminal projection. */
export async function emitTerminalV1Compatibility(
  dependencies: TerminalV1PublicationDependencies,
  sessionId: string,
  before: PickyAgentSession,
  after: PickyAgentSession,
  committedActivity: boolean,
  emittedArtifacts: readonly PickyArtifact[],
): Promise<void> {
  const previousMessages = new Map((before.messages ?? []).map((message) => [message.id, message]));
  const nextMessages = new Map((after.messages ?? []).map((message) => [message.id, message]));
  const appended = (after.messages ?? []).filter((message) => !previousMessages.has(message.id));
  const removed = (before.messages ?? []).filter((message) => !nextMessages.has(message.id));
  const replaced = (after.messages ?? []).filter((message) => {
    const previous = previousMessages.get(message.id);
    return previous !== undefined && JSON.stringify(previous) !== JSON.stringify(message);
  });
  const emit = async (type: "append" | "remove" | "replace", message: PickySessionMessage): Promise<void> => {
    const seq = dependencies.nextSeq(sessionId);
    await dependencies.chainEmit(sessionId, async () => {
      if (type === "append") dependencies.emitMessageAppended(sessionId, message, seq);
      else if (type === "remove") dependencies.emitMessageRemoved(sessionId, message.id, seq);
      else dependencies.emitMessageReplaced(sessionId, message.id, message, seq);
    });
  };

  for (const message of appended.filter((message) => message.kind === "agent_text")) await emit("append", message);
  for (const message of removed) await emit("remove", message);
  for (const message of appended.filter((message) => message.kind === "agent_activity")) await emit("append", message);
  if (committedActivity) {
    const seq = dependencies.nextSeq(sessionId);
    await dependencies.chainEmit(sessionId, async () => { dependencies.emitActivityUpdated(sessionId, zeroActivitySummary(), seq); });
  }
  for (const message of appended.filter((message) => message.kind !== "agent_text" && message.kind !== "agent_activity")) await emit("append", message);
  for (const message of replaced) await emit("replace", message);
  dependencies.emitSessionMeta(after);
  for (const artifact of emittedArtifacts) dependencies.emitArtifact(sessionId, artifact);
}

function stageTerminalMessages(
  session: PickyAgentSession,
  journal: readonly PickySessionMessage[],
  assistantDraft: string,
  activitySnapshot: PickyActivitySummary | undefined,
  event: Extract<RuntimeEvent, { type: "status" }>,
  now: string,
): PickySessionMessage[] {
  const messages = journal
    .filter((message) => message.kind !== "agent_thinking")
    .map((message) => (
      session.pendingExtensionUiRequest?.id === message.id
        ? { ...message, cancelledAt: now }
        : structuredClone(message)
    ));
  if (assistantDraft) {
    messages.push({
      id: `msg-agent-text-${randomUUID()}`,
      kind: "agent_text",
      createdAt: now,
      text: assistantDraft,
      ...(event.assistantRun ? { assistantRun: event.assistantRun } : {}),
    });
  }
  if (activitySnapshot && hasActivity(activitySnapshot)) {
    messages.push({
      id: `msg-activity-${randomUUID()}`,
      kind: "agent_activity",
      createdAt: now,
      activitySnapshot: structuredClone(activitySnapshot),
    });
  }
  if (event.status === "failed" && !event.compactionFailed) {
    messages.push({ id: `msg-error-${randomUUID()}`, kind: "agent_error", createdAt: now, errorMessage: event.summary ?? "Agent failed" });
  }
  if (event.status === "cancelled") messages.push({ id: `msg-system-${randomUUID()}`, kind: "system", createdAt: now, text: "Cancelled by user" });
  return messages;
}
