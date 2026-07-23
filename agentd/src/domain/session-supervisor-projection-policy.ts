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
}): PickyAgentSession {
  return {
    id: input.id,
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
    notifyMainOnCompletion: true,
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
}): PickyAgentSession {
  return {
    id: input.id,
    title: input.title,
    status: "waiting_for_input",
    cwd: input.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    lastSummary: "Ready for instructions",
    logs: [],
    notifyMainOnCompletion: false,
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
    title: input.title,
    status: "completed",
    cwd: input.context.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    lastSummary: "Pinned completed Pi session",
    finalAnswer: "Pinned from an idle Pi session. No Pickle run has been started yet.",
    logs: input.logs,
    piSessionFilePath: input.sessionFilePath,
    notifyMainOnCompletion: false,
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
  artifacts: PickyAgentSession["artifacts"];
}): PickyAgentSession {
  return {
    id: input.id,
    title: input.title,
    status: "queued",
    cwd: input.cwd,
    createdAt: input.now,
    updatedAt: input.now,
    logs: [],
    ...(input.notifyMainOnCompletion === undefined ? {} : { notifyMainOnCompletion: input.notifyMainOnCompletion }),
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
    status: "cancelled",
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
  sessionFilePath: string | undefined;
}): Partial<PickyAgentSession> {
  return {
    title: input.title,
    status: "waiting_for_input",
    cwd: input.cwd,
    lastSummary: "Ready for instructions",
    finalAnswer: undefined,
    thinkingPreview: undefined,
    pendingExtensionUiRequest: undefined,
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    todoState: undefined,
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
  if (session.archived !== true) return false;
  if (!isTerminalStatus(session.status)) return false;
  if (hasRuntimeHandle) return false;
  const ageSource = session.archivedAt ?? session.updatedAt;
  return now - new Date(ageSource).getTime() >= ARCHIVED_SESSION_RETENTION_MS;
}
