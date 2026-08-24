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
  if (sessionUpdatedPayloadFitsAppFrame(session)) return { session, omittedFields: [] };

  const withoutSubagentRuns = protocolSession({ ...session, subagentRuns: [] });
  if (sessionUpdatedPayloadFitsAppFrame(withoutSubagentRuns)) {
    return { session: withoutSubagentRuns, omittedFields: ["subagentRuns"] };
  }

  const withoutTools = protocolSession({ ...withoutSubagentRuns, tools: [] });
  if (sessionUpdatedPayloadFitsAppFrame(withoutTools)) {
    return { session: withoutTools, omittedFields: ["subagentRuns", "tools"] };
  }

  const withoutMessages = protocolSession({ ...withoutTools, messages: [], messageJournalAvailable: false });
  if (sessionUpdatedPayloadFitsAppFrame(withoutMessages)) {
    return { session: withoutMessages, omittedFields: ["subagentRuns", "tools", "messages"] };
  }

  const minimalSession = minimalSessionForAppSnapshot(session);
  if (sessionUpdatedPayloadFitsAppFrame(minimalSession)) {
    return {
      session: minimalSession,
      omittedFields: ["subagentRuns", "tools", "messages", "extendedMetadata"],
    };
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
