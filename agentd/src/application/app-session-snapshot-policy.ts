import { sliceUtf16Safe } from "../domain/safe-truncate.js";
import {
  PROTOCOL_VERSION,
  PickyAgentSessionSchema,
  type EventEnvelope,
  type PickyAgentSession,
  type PickyAgentSessionParsed,
} from "../protocol.js";

export const APP_EVENT_FRAME_BYTE_LIMIT = 8 * 1024 * 1024;
export const APP_EVENT_ENVELOPE_BYTE_RESERVE = 4 * 1024;
export const APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT = APP_EVENT_FRAME_BYTE_LIMIT - APP_EVENT_ENVELOPE_BYTE_RESERVE;
export const APP_SNAPSHOT_TITLE_CHAR_LIMIT = 500;
export const APP_SNAPSHOT_PATH_CHAR_LIMIT = 2_000;

export function compactSessionForAppSnapshot(session: PickyAgentSessionParsed): PickyAgentSessionParsed {
  return protocolSession({
    ...session,
    logs: [],
    tools: [],
    subagentRuns: [],
    messages: [],
    messageJournalAvailable: false,
  });
}

export function minimalSessionForAppSnapshot(session: PickyAgentSessionParsed): PickyAgentSessionParsed {
  return protocolSession({
    id: session.id,
    title: truncateText(session.title, APP_SNAPSHOT_TITLE_CHAR_LIMIT),
    status: session.status,
    cwd: session.cwd ? truncateText(session.cwd, APP_SNAPSHOT_PATH_CHAR_LIMIT) : session.cwd,
    piSessionFilePath: session.piSessionFilePath ? truncateText(session.piSessionFilePath, APP_SNAPSHOT_PATH_CHAR_LIMIT) : session.piSessionFilePath,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    lastSummary: session.lastSummary,
    thinkingPreview: session.thinkingPreview,
    finalAnswer: session.finalAnswer,
    logs: [],
    tools: [],
    subagentRuns: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    messageJournalAvailable: false,
    activitySummary: session.activitySummary,
    contextUsage: session.contextUsage,
    notifyMainOnCompletion: session.notifyMainOnCompletion,
    archived: session.archived,
    archivedAt: session.archivedAt,
    pinned: session.pinned,
  });
}

export function boundedSessionForAppHydration(session: PickyAgentSessionParsed): {
  session?: PickyAgentSessionParsed;
  omittedFields: string[];
} {
  return boundedSessionForFrame(session, (candidate) => ({ type: "sessionUpdated", session: candidate }), {
    minimal: minimalSessionForAppSnapshot,
    minimalOmittedFields: ["subagentRuns", "tools", "messages", "extendedMetadata"],
  });
}

/**
 * Reuses the P0 hydration field-drop order while measuring the actual dormant
 * v2 recovery envelope. Unlike app hydration, every omission here names a
 * persisted session field so Swift can clear or mark that child store
 * unavailable instead of silently retaining stale data.
 */
export function boundedSessionForProjectionSnapshot(
  session: PickyAgentSessionParsed,
  metadata: { requestId?: string; epoch: string },
): { session?: PickyAgentSessionParsed; omittedFields: string[] } {
  return boundedSessionForFrame(session, (candidate, omittedFields) => ({
    type: "sessionProjectionSnapshot",
    ...(metadata.requestId === undefined ? {} : { requestId: metadata.requestId }),
    sessionId: candidate.id,
    epoch: metadata.epoch,
    revision: candidate.revision,
    complete: omittedFields.length === 0,
    omittedFields,
    projection: candidate,
  }), {
    // The app's minimal list summary does not need a durable cursor, whereas a
    // projection recovery snapshot does. Preserve the source revision even
    // when every large child section is omitted.
    minimal: (candidate) => protocolSession({ ...minimalSessionForAppSnapshot(candidate), revision: candidate.revision }),
    minimalOmittedFields: [
      "logs", "tools", "todoState", "subagentRuns", "artifacts", "changedFiles", "messages",
      "messageJournalAvailable", "queuedSteers", "queuedFollowUps", "steeringMode", "followUpMode",
      "currentAssistantRun", "pendingExtensionUiRequest",
    ],
  });
}

function boundedSessionForFrame(
  session: PickyAgentSessionParsed,
  payload: (candidate: PickyAgentSessionParsed, omittedFields: string[]) => EventPayload,
  fallback: { minimal: (session: PickyAgentSessionParsed) => PickyAgentSessionParsed; minimalOmittedFields: string[] },
): { session?: PickyAgentSessionParsed; omittedFields: string[] } {
  if (eventPayloadByteLength(payload(session, [])) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) return { session, omittedFields: [] };

  const withoutSubagentRuns = protocolSession({ ...session, subagentRuns: [] });
  if (eventPayloadByteLength(payload(withoutSubagentRuns, ["subagentRuns"])) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) {
    return { session: withoutSubagentRuns, omittedFields: ["subagentRuns"] };
  }

  const withoutTools = protocolSession({ ...withoutSubagentRuns, tools: [] });
  if (eventPayloadByteLength(payload(withoutTools, ["subagentRuns", "tools"])) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) {
    return { session: withoutTools, omittedFields: ["subagentRuns", "tools"] };
  }

  const withoutMessages = protocolSession({ ...withoutTools, messages: [], messageJournalAvailable: false });
  if (eventPayloadByteLength(payload(withoutMessages, ["subagentRuns", "tools", "messages"])) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) {
    return { session: withoutMessages, omittedFields: ["subagentRuns", "tools", "messages"] };
  }

  const minimalSession = fallback.minimal(session);
  if (eventPayloadByteLength(payload(minimalSession, fallback.minimalOmittedFields)) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) {
    return { session: minimalSession, omittedFields: fallback.minimalOmittedFields };
  }
  return { omittedFields: ["entireSession"] };
}

export function sessionUpdatedPayloadFitsAppFrame(session: PickyAgentSessionParsed): boolean {
  return eventPayloadByteLength({ type: "sessionUpdated", session }) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT;
}

export function eventPayloadByteLength(payload: EventPayload): number {
  const event = {
    id: "event-00000000-0000-0000-0000-000000000000",
    protocolVersion: PROTOCOL_VERSION,
    timestamp: "2026-01-01T00:00:00.000Z",
    ...payload,
  };
  return Buffer.byteLength(JSON.stringify(event), "utf8");
}

export function truncateText(text: string, limit: number): string {
  if (text.length <= limit) return text;
  return `${sliceUtf16Safe(text, limit)}…`;
}

function protocolSession(session: PickyAgentSession): PickyAgentSessionParsed {
  return PickyAgentSessionSchema.parse(session);
}

type RemoveEnvelope<T> = T extends unknown ? Omit<T, "id" | "protocolVersion" | "timestamp"> : never;
type EventPayload = RemoveEnvelope<EventEnvelope>;
