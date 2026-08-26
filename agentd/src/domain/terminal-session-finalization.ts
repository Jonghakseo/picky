import { extractChangedFilesFromExplicitText } from "../artifact-store.js";
import { mergeChangedFiles } from "./changed-files.js";
import { cleanFinalAnswer, summaryFromFinalAnswer } from "./session-summary.js";
import { settleActiveTools } from "./tool-activity.js";
import type {
  PickyActivitySummary,
  PickyAgentSession,
  PickyAssistantRunMetadata,
  PickyArtifact,
  PickySessionMessage,
  PickySessionProjectionMutation,
} from "../protocol.js";

export interface TerminalMessageSnapshot {
  readonly journal: readonly PickySessionMessage[];
  readonly removedIds: readonly string[];
  readonly cancelledIds: readonly string[];
  readonly assistantDraft: string;
  readonly thinkingDraft: string;
  readonly activeThinkingId?: string;
}

export interface TerminalRuntimeSnapshot {
  readonly assistantDraft: string;
  readonly thinkingDraft: string;
  readonly thinkingActive: boolean;
  readonly pendingThinkingDelta: string;
  readonly pendingThinkingPreview?: string;
  readonly seenToolCallIds: readonly string[];
  readonly processedTerminalRun: boolean;
}

export interface PreparedTerminalData {
  /**
   * Final journal staged by the caller from the immutable message snapshot. IDs are supplied by
   * the staging boundary rather than generated here so this planner remains deterministic.
   */
  readonly messages: readonly PickySessionMessage[];
  readonly artifacts: readonly PickyArtifact[];
  readonly activitySummary?: PickyActivitySummary;
}

export type TerminalRuntimeStatus = "running" | "waiting_for_input" | "blocked" | "completed" | "failed" | "cancelled";

/** Structural status-event shape keeps this pure domain reducer independent of runtime adapters. */
export interface TerminalRuntimeStatusEvent {
  readonly type: "status";
  readonly status: TerminalRuntimeStatus;
  readonly summary?: string;
  readonly finalAnswer?: string;
  readonly assistantRun?: PickyAssistantRunMetadata;
}

export interface TerminalSessionFinalizationInput {
  readonly currentSession: Readonly<PickyAgentSession>;
  readonly messageSnapshot: TerminalMessageSnapshot;
  readonly runtimeSnapshot: TerminalRuntimeSnapshot;
  readonly event: TerminalRuntimeStatusEvent;
  readonly prepared: PreparedTerminalData;
  /** Injected by the caller; this module never reads wall clock time. */
  readonly now: string;
}

export interface TerminalSessionFinalization {
  readonly nextSession: PickyAgentSession;
  readonly mutations: readonly PickySessionProjectionMutation[];
  /** Manifest IDs that W5.5 may reset only after SessionStore.save succeeds. */
  readonly transientResets: readonly TerminalTransientReset[];
}

export type TerminalTransientReset =
  | "SessionMessageBuilder.states"
  | "RuntimeEventHandler.assistantDrafts"
  | "RuntimeEventHandler.thinkingDrafts"
  | "RuntimeEventHandler.thinkingActive"
  | "RuntimeEventHandler.pendingThinkingFlushes";

const terminalResets: readonly TerminalTransientReset[] = [
  "SessionMessageBuilder.states",
  "RuntimeEventHandler.assistantDrafts",
  "RuntimeEventHandler.thinkingDrafts",
  "RuntimeEventHandler.thinkingActive",
  "RuntimeEventHandler.pendingThinkingFlushes",
];

/**
 * Produces a complete terminal session projection without mutating state or performing effects.
 * W5.4 will call it inside one SessionSupervisor.runSessionWrite transaction; this dormant W5.2
 * reducer intentionally does not save, emit, allocate IDs, or inspect clocks.
 */
export function finalizeTerminalSession(input: TerminalSessionFinalizationInput): TerminalSessionFinalization {
  const { currentSession, event, prepared, now } = input;
  if (!isTerminal(event.status)) throw new Error(`Terminal finalization requires a terminal status, got ${event.status}`);

  const eventFinalAnswer = cleanFinalAnswer(event.finalAnswer)
    ?? (event.status === "failed" ? undefined : cleanFinalAnswer(input.runtimeSnapshot.assistantDraft));
  const finalAnswer = eventFinalAnswer;
  const nextSession: PickyAgentSession = {
    ...currentSession,
    status: event.status,
    lastSummary: finalAnswer ? summaryFromFinalAnswer(finalAnswer) : event.summary,
    updatedAt: now,
    messages: clone([...prepared.messages]),
    artifacts: clone([...prepared.artifacts]),
    tools: settleActiveTools(currentSession.tools, terminalToolPreview(event.status), now),
    thinkingPreview: undefined,
    pendingExtensionUiRequest: undefined,
    ...(prepared.activitySummary ? { activitySummary: clone(prepared.activitySummary) } : {}),
    ...(event.assistantRun ? { currentAssistantRun: event.assistantRun } : {}),
    ...(finalAnswer ? {
      finalAnswer,
      changedFiles: mergeChangedFiles(currentSession.changedFiles, extractChangedFilesFromExplicitText(finalAnswer)),
    } : {}),
  };

  return {
    nextSession,
    mutations: buildSessionProjectionMutations(currentSession, nextSession),
    transientResets: terminalResets,
  };
}

/**
 * Builds the ordered v2 mutation plan for any durable session commit. Terminal
 * finalization and ordinary supervisor commits share this planner so their
 * projections cannot drift into two ownership models.
 */
export function buildSessionProjectionMutations(
  before: Readonly<PickyAgentSession>,
  after: PickyAgentSession,
  options: { forceCollectionReplacements?: boolean } = {},
): PickySessionProjectionMutation[] {
  return [
    ...metaMutations(before, after),
    ...logMutations(before, after, options.forceCollectionReplacements),
    ...messageMutations(before, after),
    ...toolAndStateMutations(before, after, options.forceCollectionReplacements),
    ...artifactAndPresentationMutations(before, after, options.forceCollectionReplacements),
  ];
}

function logMutations(before: Readonly<PickyAgentSession>, after: PickyAgentSession, forceReplacement = false): PickySessionProjectionMutation[] {
  const previous = before.logs;
  const next = after.logs;
  if (forceReplacement) return [{ type: "logsSet", logs: next }];
  if (same(previous, next)) return [];
  if (next.length > previous.length && previous.every((line, index) => line === next[index])) {
    return next.slice(previous.length).map((line) => ({ type: "logAppend" as const, line }));
  }
  return [{ type: "logsSet", logs: next }];
}

function metaMutations(before: Readonly<PickyAgentSession>, after: PickyAgentSession): PickySessionProjectionMutation[] {
  const metaPatch = changedMetaPatch(before, after);
  return Object.keys(metaPatch).length > 0 ? [{ type: "metaPatch", patch: metaPatch }] : [];
}

function messageMutations(before: Readonly<PickyAgentSession>, after: PickyAgentSession): PickySessionProjectionMutation[] {
  const mutations: PickySessionProjectionMutation[] = [];
  const beforeMessages = new Map((before.messages ?? []).map((message) => [message.id, message]));
  const afterMessages = new Map((after.messages ?? []).map((message) => [message.id, message]));
  for (const message of before.messages ?? []) {
    if (!afterMessages.has(message.id)) mutations.push({ type: "messageRemove", messageId: message.id });
  }
  const appended = (after.messages ?? []).filter((message) => !beforeMessages.has(message.id));
  if (appended.length > 0) mutations.push({ type: "messagesImport", messages: appended });
  for (const message of after.messages ?? []) {
    const previous = beforeMessages.get(message.id);
    if (previous && !same(previous, message)) mutations.push({ type: "messageReplace", messageId: message.id, message });
  }
  return mutations;
}

function toolAndStateMutations(before: Readonly<PickyAgentSession>, after: PickyAgentSession, forceReplacement = false): PickySessionProjectionMutation[] {
  const mutations: PickySessionProjectionMutation[] = [];
  const beforeTools = new Map(before.tools.map((tool) => [tool.toolCallId, tool]));
  if (forceReplacement || before.tools.some((tool) => !after.tools.some((candidate) => candidate.toolCallId === tool.toolCallId))) {
    mutations.push({ type: "toolsSet", tools: after.tools });
  } else {
    for (const tool of after.tools) {
      if (!same(beforeTools.get(tool.toolCallId), tool)) mutations.push({ type: "toolUpsert", tool });
    }
  }
  if (!same(before.todoState, after.todoState)) mutations.push({ type: "todoSet", todoState: after.todoState ?? null });
  if (!same(before.subagentRuns ?? [], after.subagentRuns ?? [])) mutations.push({ type: "subagentRunsSet", runs: after.subagentRuns ?? [] });
  return mutations;
}

function artifactAndPresentationMutations(before: Readonly<PickyAgentSession>, after: PickyAgentSession, forceReplacement = false): PickySessionProjectionMutation[] {
  const mutations: PickySessionProjectionMutation[] = [];
  const beforeArtifacts = new Map(before.artifacts.map((artifact) => [artifact.id, artifact]));
  if (forceReplacement || before.artifacts.some((artifact) => !after.artifacts.some((candidate) => candidate.id === artifact.id))) {
    mutations.push({ type: "artifactsSet", artifacts: after.artifacts });
  } else {
    for (const artifact of after.artifacts) {
      if (!same(beforeArtifacts.get(artifact.id), artifact)) mutations.push({ type: "artifactUpsert", artifact });
    }
  }
  if (!same(before.changedFiles, after.changedFiles)) mutations.push({ type: "changedFilesSet", changedFiles: after.changedFiles });
  if (!sameQueue(before, after)) {
    mutations.push({
      type: "queueSet",
      queuedSteers: after.queuedSteers ?? [],
      queuedFollowUps: after.queuedFollowUps ?? [],
      steeringMode: after.steeringMode ?? "one-at-a-time",
      followUpMode: after.followUpMode ?? "one-at-a-time",
    });
  }
  if (!same(before.activitySummary, after.activitySummary)) mutations.push({ type: "activitySet", activitySummary: after.activitySummary ?? zeroActivity() });
  if (!same(before.finalAnswer, after.finalAnswer)) mutations.push({ type: "finalAnswerSet", finalAnswer: after.finalAnswer ?? null });
  if (!same(before.pendingExtensionUiRequest, after.pendingExtensionUiRequest)) {
    mutations.push({ type: "extensionUiRequestSet", request: after.pendingExtensionUiRequest ?? null });
  }
  return mutations;
}

function changedMetaPatch(before: Readonly<PickyAgentSession>, after: PickyAgentSession): Extract<PickySessionProjectionMutation, { type: "metaPatch" }>['patch'] {
  const patch: Extract<PickySessionProjectionMutation, { type: "metaPatch" }>['patch'] = {};
  const fields = ["id", "title", "status", "cwd", "piSessionFilePath", "createdAt", "updatedAt", "lastSummary", "thinkingPreview", "messageJournalAvailable", "contextUsage", "currentAssistantRun", "notifyMainOnCompletion", "archived", "archivedAt", "pinned"] as const;
  for (const field of fields) {
    if (same(before[field], after[field])) continue;
    const value = after[field];
    Object.assign(patch, { [field]: value === undefined ? null : value });
  }
  return patch;
}

type TerminalStatus = "completed" | "failed" | "cancelled";

function isTerminal(status: TerminalRuntimeStatus): status is TerminalStatus {
  return status === "completed" || status === "failed" || status === "cancelled";
}

function terminalToolPreview(status: TerminalStatus): string {
  if (status === "cancelled") return "Tool stopped because the session was cancelled.";
  if (status === "failed") return "Tool stopped because the session failed.";
  return "Tool stopped when the session ended.";
}

function zeroActivity(): PickyActivitySummary {
  return { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 };
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function same(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function sameQueue(before: Readonly<PickyAgentSession>, after: PickyAgentSession): boolean {
  return same(before.queuedSteers ?? [], after.queuedSteers ?? [])
    && same(before.queuedFollowUps ?? [], after.queuedFollowUps ?? [])
    && (before.steeringMode ?? "one-at-a-time") === (after.steeringMode ?? "one-at-a-time")
    && (before.followUpMode ?? "one-at-a-time") === (after.followUpMode ?? "one-at-a-time");
}
