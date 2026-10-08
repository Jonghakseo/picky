import { hasAsyncExecutionObligations, isAsyncTracked } from "./async-work-aggregate.js";
import { summaryFromFinalAnswer } from "./session-summary.js";
import type { PickyActivitySummary, PickyAgentSession, PickyContextPacket, PickyMainAgentMessage, PickyMainAgentState } from "../protocol.js";
import { zeroActivitySummary } from "./activity-summary.js";
import type { MainRolloverPickleSession } from "./main-agent-policy.js";
import { quickReplyOriginFromContextSource } from "./main-agent-policy.js";
import { appendUniqueLog } from "./pi-session-files.js";
import { isTerminalStatus } from "./session-status.js";
import { settleActiveTools } from "./tool-activity.js";

/**
 * Pure session shapes consumed by SessionSupervisor. The supervisor remains the
 * only owner that mutates, persists, or emits these projections.
 */
export function buildResumedHandoffPickleSession(input: {
  id: string;
  title: string;
  cwd: string | undefined;
  now: string;
  sessionFilePath: string;
  sourceSessionFilePath: string;
  artifacts: PickyAgentSession["artifacts"];
  notifyMainOnCompletion: boolean;
  notifyMacOSOnCompletion: boolean;
}): PickyAgentSession {
  return {
    id: input.id,
    revision: 0,
    title: input.title,
    status: "queued",
    cwd: input.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    lastSummary: "Resuming source Pi session",
    logs: [
      `pi session: ${input.sessionFilePath}`,
      `source pi session snapshot: ${input.sourceSessionFilePath}`,
    ],
    notifyMainOnCompletion: input.notifyMainOnCompletion,
    notifyMacOSOnCompletion: input.notifyMacOSOnCompletion,
    tools: [],
    artifacts: input.artifacts,
    changedFiles: [],
    activitySummary: zeroActivitySummary(),
    piSessionFilePath: input.sessionFilePath,
  };
}

export function buildEmptyPickleSession(input: {
  id: string;
  title: string;
  cwd: string | undefined;
  now: string;
  notifyMainOnCompletion: boolean;
  notifyMacOSOnCompletion: boolean;
}): PickyAgentSession {
  return {
    id: input.id,
    revision: 0,
    title: input.title,
    status: "waiting_for_input",
    cwd: input.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    lastSummary: "Ready for instructions",
    logs: [],
    notifyMainOnCompletion: input.notifyMainOnCompletion,
    notifyMacOSOnCompletion: input.notifyMacOSOnCompletion,
    tools: [],
    artifacts: [],
    changedFiles: [],
    activitySummary: zeroActivitySummary(),
  };
}

export function buildDuplicatedPickleSession(input: {
  id: string;
  source: PickyAgentSession;
  cwd: string | undefined;
  now: string;
  sessionFilePath: string;
}): PickyAgentSession {
  const baseTitle = input.source.title.trim() || "Pickle";
  const sourceMessages = input.source.messages ?? [];
  return {
    id: input.id,
    revision: 0,
    title: `(copy) ${baseTitle}`,
    status: "waiting_for_input",
    cwd: input.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    lastSummary: "Duplicated from existing Pickle",
    logs: [
      `duplicated from session: ${input.source.id}`,
      ...(input.cwd ? [`source cwd: ${input.cwd}`] : []),
      `pi session: ${input.sessionFilePath}`,
    ],
    notifyMainOnCompletion: input.source.notifyMainOnCompletion ?? false,
    notifyMacOSOnCompletion: input.source.notifyMacOSOnCompletion ?? false,
    tools: [],
    artifacts: [],
    changedFiles: [],
    activitySummary: zeroActivitySummary(),
    messages: sourceMessages.map((message) => ({ ...message })),
    piSessionFilePath: input.sessionFilePath,
  };
}

export function buildPinnedPickleSession(input: {
  id: string;
  title: string;
  context: PickyContextPacket;
  now: string;
  logs: string[];
  sessionFilePath: string | undefined;
  artifacts: PickyAgentSession["artifacts"];
}): PickyAgentSession {
  return {
    id: input.id,
    revision: 0,
    title: input.title,
    status: "completed",
    cwd: input.context.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    lastSummary: "Pinned completed Pi session",
    finalAnswer: "Pinned from an idle Pi session. No Pickle run has been started yet.",
    logs: input.logs,
    piSessionFilePath: input.sessionFilePath,
    ...(input.context.transcript?.trim() ? { lastRequest: { source: "transcript" as const, text: input.context.transcript.trim() } } : {}),
    notifyMainOnCompletion: false,
    notifyMacOSOnCompletion: false,
    pinned: true,
    tools: [],
    artifacts: input.artifacts,
    changedFiles: [],
    activitySummary: zeroActivitySummary(),
  };
}

export function buildVisibleSession(input: {
  id: string;
  title: string;
  cwd: string | undefined;
  now: string;
  notifyMainOnCompletion: boolean | undefined;
  notifyMacOSOnCompletion: boolean | undefined;
  artifacts: PickyAgentSession["artifacts"];
}): PickyAgentSession {
  return {
    id: input.id,
    revision: 0,
    title: input.title,
    status: "queued",
    cwd: input.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    logs: [],
    ...(input.notifyMainOnCompletion === undefined ? {} : { notifyMainOnCompletion: input.notifyMainOnCompletion }),
    ...(input.notifyMacOSOnCompletion === undefined ? {} : { notifyMacOSOnCompletion: input.notifyMacOSOnCompletion }),
    tools: [],
    artifacts: input.artifacts,
    changedFiles: [],
    activitySummary: zeroActivitySummary(),
  };
}

export function buildInterruptedRuntimeLiveStatePatch(session: PickyAgentSession): Partial<PickyAgentSession> {
  return {
    pendingExtensionUiRequest: undefined,
    thinkingPreview: undefined,
    tools: settleActiveTools(session.tools, "Tool was interrupted by a Picky daemon restart."),
    subagentRuns: (session.subagentRuns ?? []).map((run) => (
      run.status === "running" ? { ...run, status: "error", errorClass: "interrupted" } : run
    )),
    queuedSteers: [],
    queuedFollowUps: [],
    activitySummary: zeroActivitySummary(),
  };
}

export function buildOrphanedChildRecoverySession(
  session: PickyAgentSession,
  interruptedPatch: Partial<PickyAgentSession>,
  now: string,
  markerLog: string,
  summary: string,
): PickyAgentSession {
  return {
    ...session,
    ...interruptedPatch,
    status: "blocked",
    lastSummary: summary,
    logs: session.logs.filter((line) => line !== markerLog),
    updatedAt: now,
  };
}

export function buildArchivedSessionRestartCancellation(
  session: PickyAgentSession,
  interruptedPatch: Partial<PickyAgentSession>,
  now: string,
): PickyAgentSession {
  return {
    ...session,
    ...interruptedPatch,
    status: isAsyncTracked(session) ? "blocked" : "cancelled",
    lastSummary: "Archived session was not resumed after daemon restart",
    updatedAt: now,
  };
}

export function buildUnattachedRuntimeBlock(
  session: PickyAgentSession,
  interruptedPatch: Partial<PickyAgentSession>,
  now: string,
  failureLog: string,
): PickyAgentSession {
  return {
    ...session,
    ...interruptedPatch,
    status: "blocked",
    lastSummary: failureLog,
    logs: appendUniqueLog(session.logs, failureLog),
    updatedAt: now,
  };
}

export function buildRuntimeReattachPatch(
  session: PickyAgentSession,
  interruptedPatch: Partial<PickyAgentSession>,
  hadPendingExtensionUiRequest: boolean,
): Partial<PickyAgentSession> {
  if (isTerminalStatus(session.status)) return { ...interruptedPatch };
  // A never-started async Pickle has no model run to report as interrupted.
  if (session.status === "waiting_for_input" && hasNoAsyncReentryObligations(session)) return { ...interruptedPatch };
  return {
    ...interruptedPatch,
    status: "blocked",
    lastSummary: hadPendingExtensionUiRequest
      ? "Picky daemon restarted; the previous question can no longer be answered. Send a follow-up or steer message to continue."
      : "Previous run was interrupted by daemon restart; send a follow-up or steer message to continue.",
  };
}

export function buildRuntimeSessionReplacementPatch(input: {
  cwd: string | undefined;
  title: string;
  /** Carried through explicitly so a reset title also clears its user-assigned origin. */
  titleOrigin: PickyAgentSession["titleOrigin"];
  sessionFilePath: string | undefined;
}): Partial<PickyAgentSession> {
  return {
    title: input.title,
    titleOrigin: input.titleOrigin,
    status: "waiting_for_input",
    cwd: input.cwd,
    lastSummary: "Ready for instructions",
    finalAnswer: undefined,
    lastRequest: undefined,
    thinkingPreview: undefined,
    pendingExtensionUiRequest: undefined,
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    todoState: undefined,
    subagentRuns: [],
    messages: [],
    queuedSteers: [],
    queuedFollowUps: [],
    activitySummary: zeroActivitySummary(),
    contextUsage: undefined,
    piSessionFilePath: input.sessionFilePath,
    pinned: false,
  };
}

export function buildAppendedMainMessageState(
  state: PickyMainAgentState,
  role: PickyMainAgentMessage["role"],
  text: string,
  createdAt: string,
  messageLimit: number,
): { message: PickyMainAgentMessage; patch: Partial<PickyMainAgentState> } {
  const message: PickyMainAgentMessage = { role, text, createdAt };
  const patch: Partial<PickyMainAgentState> = { messages: [...state.messages, message].slice(-messageLimit) };
  if (role === "user") {
    patch.epochTurnCount = (state.epochTurnCount ?? 0) + 1;
    patch.epochStartedAt = state.epochStartedAt ?? createdAt;
  }
  return { message, patch };
}

export function projectMainAgentSessionInfo(state: PickyMainAgentState): { sessionFilePath?: string; cwd?: string } {
  const sessionFilePath = state.sessionFilePath?.trim();
  const cwd = state.cwd?.trim();
  return {
    ...(sessionFilePath ? { sessionFilePath } : {}),
    ...(cwd ? { cwd } : {}),
  };
}

export function projectMainRolloverPickleSessions(
  sessions: Iterable<PickyAgentSession>,
  pickleSessionIds: ReadonlySet<string>,
  limit: number,
): MainRolloverPickleSession[] {
  return [...sessions]
    .filter((session) => pickleSessionIds.has(session.id))
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
    .slice(0, limit)
    .map((session) => ({ id: session.id, title: session.title, status: session.status }));
}

export type MainReplyMetadata = {
  originSource: ReturnType<typeof quickReplyOriginFromContextSource> | "system";
  replyKind: "pickleCompletion" | "main";
  sessionId?: string;
};

export function projectMainReplyMetadata(
  contextId: string,
  currentContext: PickyContextPacket | undefined,
  pickleSessionIds: ReadonlySet<string>,
  externalPickleReplyContexts: ReadonlySet<string>,
  didStreamNarration = false,
): MainReplyMetadata & { didStreamNarration?: true } {
  const isPickleReply = pickleSessionIds.has(contextId) || externalPickleReplyContexts.has(contextId);
  return {
    originSource: contextId === currentContext?.id ? quickReplyOriginFromContextSource(currentContext.source) : "system",
    replyKind: isPickleReply ? "pickleCompletion" : "main",
    ...(isPickleReply ? { sessionId: contextId } : {}),
    ...(didStreamNarration ? { didStreamNarration: true } : {}),
  };
}

export const ARCHIVED_SESSION_RETENTION_DAYS = 7;
const ARCHIVED_SESSION_RETENTION_MS = ARCHIVED_SESSION_RETENTION_DAYS * 24 * 60 * 60 * 1000;

export function shouldPurgeArchivedSession(
  session: PickyAgentSession,
  now: number,
  hasRuntimeHandle: boolean,
): boolean {
  if (isAsyncTracked(session)) return false;
  if (session.archived !== true) return false;
  if (!isTerminalStatus(session.status)) return false;
  if (hasRuntimeHandle) return false;
  const ageSource = session.archivedAt ?? session.updatedAt;
  return now - new Date(ageSource).getTime() >= ARCHIVED_SESSION_RETENTION_MS;
}

/** An absent runtime cannot turn old-owner resources or delivery obligations into empty work. */
export function hasQuiescentReleasedAsyncOwner(session: PickyAgentSession): boolean {
  const control = session.asyncControl;
  const approval = control?.releasePrepared;
  const result = session.asyncControlJournal?.find((entry) => entry.result.operationId === approval?.operationId)?.result;
  return session.archived === true && !!approval && !!result && releaseEvidenceMatches(session, approval, result)
    && control?.admissionState === "closed" && session.asyncWorkSummary?.canReleaseRuntime === true
    && session.asyncWorkSummary.tracking === "ready" && !hasAsyncExecutionObligations(session.asyncTasks ?? [])
    && (session.completionTickets ?? []).every((ticket) => ticket.state === "handled" || ticket.state === "suppressed")
    && !control.operations.some((operation) => operation.outcome === "accepted" || operation.outcome === "blocked_cleanup" || operation.outcome === "blocked_delivery");
}

function releaseEvidenceMatches(session: PickyAgentSession, approval: NonNullable<NonNullable<PickyAgentSession["asyncControl"]>["releasePrepared"]>, result: NonNullable<PickyAgentSession["asyncControlJournal"]>[number]["result"]): boolean {
  return result.outcome === "settled" && result.releaseApproval?.releaseToken === approval.releaseToken
    && approval.sessionId === session.id && approval.archiveIntentId === session.asyncArchiveIntentId
    && approval.daemonInstanceId === result.daemonInstanceId && approval.runtimeInstanceId === result.runtimeInstanceId
    && approval.workRevision === session.asyncWorkSummary?.workRevision && approval.controlGeneration === session.asyncControl?.controlGeneration;
}

export function shouldRestoreInterruptedRuntime(session: PickyAgentSession, releasedOwner: boolean): boolean {
  return !isTerminalStatus(session.status) && !(session.archived === true && releasedOwner);
}

export function shouldResumeIdleAsyncSession(session: PickyAgentSession, releasedOwner: boolean, hasPiSessionFile: boolean): boolean {
  return isAsyncTracked(session) && !releasedOwner && session.archived !== true && session.status === "completed" && hasPiSessionFile;
}

const ASYNC_RESTART_SUMMARY = "Async owner restarted; resource and delivery reconciliation required";

function hasNoInterruptedSessionActivity(session: PickyAgentSession): boolean {
  return !session.pendingExtensionUiRequest && !(session.queuedSteers?.length || session.queuedFollowUps?.length)
    && !session.tools.some((tool) => tool.status === "running")
    && !(session.subagentRuns ?? []).some((run) => run.status === "running");
}

function hasNoAsyncReentryObligations(session: PickyAgentSession): boolean {
  return !!session.asyncWorkSummary && !!session.asyncControl && !session.agentCycle && !session.asyncWorkSummary.episode
    && hasNoInterruptedSessionActivity(session) && !session.asyncControl.releasePrepared
    && !hasAsyncExecutionObligations(session.asyncTasks ?? [])
    && (session.completionTickets ?? []).every((ticket) => ticket.state === "handled" || ticket.state === "suppressed")
    && !session.asyncControl?.operations.some((operation) => ["accepted", "blocked_cleanup", "blocked_delivery"].includes(operation.outcome));
}

function idleReentryStatus(session: PickyAgentSession): PickyAgentSession["status"] | undefined {
  if (session.archived || !hasNoAsyncReentryObligations(session)
    || session.asyncWorkSummary?.tracking !== "ready" || !session.asyncWorkSummary.canReleaseRuntime) return undefined;
  if (session.status === "completed") return "completed";
  if (session.status === "waiting_for_input") return "waiting_for_input";
  if (session.status !== "blocked" || session.lastSummary !== ASYNC_RESTART_SUMMARY) return undefined;
  return session.finalAnswer ? "completed" : "waiting_for_input";
}

export function recoverAsyncSession(session: PickyAgentSession): PickyAgentSession {
  if (!isAsyncTracked(session) || hasQuiescentReleasedAsyncOwner(session)) return session;
  const idleStatus = idleReentryStatus(session);
  const lastSummary = idleStatus === undefined
    ? session.status === "blocked" && session.lastSummary && session.lastSummary !== ASYNC_RESTART_SUMMARY ? session.lastSummary : ASYNC_RESTART_SUMMARY
    : session.status !== "blocked" ? session.lastSummary
      : session.finalAnswer ? summaryFromFinalAnswer(session.finalAnswer) : "Ready for instructions";
  return { ...session, status: idleStatus ?? "blocked", lastSummary,
    asyncTasks: session.asyncTasks?.map((task) => hasAsyncExecutionObligations([task]) && task.presence !== "unknown" ? { ...task, presence: "unknown", execution: "interrupted" } : task),
    completionTickets: session.completionTickets?.map((ticket) => ["handled", "suppressed"].includes(ticket.state) ? ticket : { ...ticket, state: "unknown" }),
    asyncControl: session.asyncControl ? { ...session.asyncControl, admissionState: "closed", releasePrepared: undefined,
      operations: session.asyncControl.operations.map((operation) => operation.outcome === "accepted" ? { ...operation, outcome: "blocked_cleanup", reason: "Owner restarted before operation settlement" } : operation) } : undefined,
    asyncWorkSummary: session.asyncWorkSummary ? { ...session.asyncWorkSummary, tracking: "reconciling", canReleaseRuntime: false } : undefined };
}
