import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";
import { PICKLE_TOOL_NAMES } from "./picky-tool-names.js";
import type { PickyAgentSession } from "../protocol.js";

export interface PickyHandoffRequest {
  title: string;
  instructions: string;
  userMessage?: string;
  cwd?: string;
}

interface PickyHandoffResult {
  sessionId: string;
  title: string;
  cwd?: string;
}

export interface PickyPickleSteerRequest {
  sessionId: string;
  message: string;
}

export interface PickyPickleAbortRequest {
  sessionId: string;
}


interface PickleSessionSummary {
  id: string;
  title: string;
  status: PickyAgentSession["status"];
  updatedAt: string;
  cwd?: string;
  pendingInput: boolean;
  lastSummary?: string;
  changedFilesCount: number;
  archived: boolean;
}

type PickleToolNames = typeof PICKLE_TOOL_NAMES;


export function createPickyStartPickleTool(onHandoff: (request: PickyHandoffRequest) => Promise<PickyHandoffResult>): ToolDefinition {
  return createPickyStartPickleToolWithNames(onHandoff, PICKLE_TOOL_NAMES);
}


function createPickyStartPickleToolWithNames(
  onHandoff: (request: PickyHandoffRequest) => Promise<PickyHandoffResult>,
  names: PickleToolNames,
): ToolDefinition {
  return defineTool({
    name: names.start,
    label: "Picky start Pickle",
    description: "Delegate complex, long-running, tool-heavy, or multi-turn work to Pickle, shown in Picky's dock.",
    promptSnippet: `${names.start}: delegate complex or long-running work to Pickle in the Picky dock.`,
    promptGuidelines: [
      `Use ${names.start} for substantial work (code/repo, web/video, MCP, deep screen analysis, multi-turn).`,
      `Before creating, call ${names.sessions} and prefer ${names.steer} for a matching existing Pickle.`,
      "Deltas only — never paste full prompts, transcripts, logs, or screenshot metadata. See `instructions` for the brief format.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Short Pickle card title in the user's language." }),
      instructions: Type.String({ description: "Compact delta-first brief (~300 chars in the user's language): goal, essential constraints, key paths/URLs/IDs, known decisions, expected output. No full prompts, transcripts, logs, or screenshot metadata." }),
      userMessage: Type.Optional(Type.String({ description: "Optional short follow-up line you intend to tell the user after starting Pickle, in their language." })),
      cwd: Type.Optional(Type.String({ description: "Optional absolute working directory. Omit to use Picky's configured default cwd." })),
    }),
    execute: async (_toolCallId, params) => {
      const session = await onHandoff({
        title: params.title,
        instructions: params.instructions,
        userMessage: params.userMessage,
        cwd: normalizeOptionalString(params.cwd),
      });
      return {
        content: [
          {
            type: "text",
            text: `Pickle started: ${session.title} (${session.sessionId}). Now tell the user (in their language) that you delegated this work to Pickle and that they can check progress in the Picky dock.`,
          },
        ],
        details: session,
      };
    },
  });
}

const PICKLE_SESSIONS_DEFAULT_PAGE_SIZE = 10;
const PICKLE_SESSIONS_MAX_PAGE_SIZE = 10;

export function createPickyPickleSessionsTool(onList: () => PickyAgentSession[] | Promise<PickyAgentSession[]>): ToolDefinition {
  return createPickyPickleSessionsToolWithNames(onList, PICKLE_TOOL_NAMES);
}


function createPickyPickleSessionsToolWithNames(onList: () => PickyAgentSession[] | Promise<PickyAgentSession[]>, names: PickleToolNames): ToolDefinition {
  return defineTool({
    name: names.sessions,
    label: "Picky Pickle sessions",
    description: "List one bounded page of Pickles that Picky has already delegated work to, so steering requests can reuse the right Pickle instead of starting a duplicate.",
    promptSnippet: `${names.sessions}: list one bounded page of current and recent Pickles in the Picky dock before deciding whether to steer one.`,
    promptGuidelines: [
      `Use ${names.sessions} when the user references an existing/recent Pickle or asks for progress.`,
      "Returns one page; follow nextPage only if needed.",
      `Prefer ${names.steer} on a matching session over creating a duplicate.`,
    ],
    parameters: Type.Object({
      includeTerminal: Type.Optional(Type.Boolean({ description: "Whether to include completed, failed, and cancelled Pickle sessions. Defaults to true." })),
      includeArchived: Type.Optional(Type.Boolean({ description: "Whether to include archived Pickle sessions hidden from the Picky dock. Defaults to false." })),
      page: Type.Optional(Type.Number({ description: "1-based page number to return. Defaults to 1.", minimum: 1 })),
      limit: Type.Optional(Type.Number({ description: `Maximum number of Pickle sessions to return on this page. Defaults to ${PICKLE_SESSIONS_DEFAULT_PAGE_SIZE}; capped at ${PICKLE_SESSIONS_MAX_PAGE_SIZE}.`, minimum: 1, maximum: PICKLE_SESSIONS_MAX_PAGE_SIZE })),
    }),
    execute: async (_toolCallId, params) => {
      const includeTerminal = params.includeTerminal !== false;
      const includeArchived = params.includeArchived === true;
      const page = normalizePage(params.page);
      const pageSize = clampLimit(params.limit, PICKLE_SESSIONS_DEFAULT_PAGE_SIZE);
      const start = (page - 1) * pageSize;
      const end = start + pageSize;
      const allSessions = (await onList()).filter((session) => {
        if (!includeArchived && session.archived === true) return false;
        return includeTerminal || !["completed", "failed", "cancelled"].includes(session.status);
      });
      const sessions = allSessions.slice(start, end).map(summarizePickleSession);
      const hasMore = allSessions.length > end;
      const nextPage = hasMore ? page + 1 : undefined;
      return {
        content: [{ type: "text", text: formatPickleSessions(sessions, { page, pageSize, hasMore, nextPage }) }],
        details: { sessions, page, pageSize, hasMore, nextPage },
      };
    },
  });
}

export function createPickySteerPickleTool(onSteer: (request: PickyPickleSteerRequest) => Promise<PickyAgentSession>): ToolDefinition {
  return createPickySteerPickleToolWithNames(onSteer, PICKLE_TOOL_NAMES);
}


function createPickySteerPickleToolWithNames(
  onSteer: (request: PickyPickleSteerRequest) => Promise<PickyAgentSession>,
  names: PickleToolNames,
): ToolDefinition {
  return defineTool({
    name: names.steer,
    label: "Picky steer Pickle",
    description: `Send steering instructions to an existing Pickle that was started by ${names.start}.`,
    promptSnippet: `${names.steer}: steer an existing delegated Pickle with additional user instructions.`,
    promptGuidelines: [
      `Use ${names.steer} after ${names.sessions} identifies the target Pickle.`,
      "Delta only — no full-task restate, no transcript/log paste.",
      `Use ${names.start} for unrelated new work.`,
    ],
    parameters: Type.Object({
      sessionId: Type.String({ description: `ID of the Pickle session to steer, as returned by ${names.sessions}.` }),
      message: Type.String({ description: "Delta-only steering instruction for Pickle, with only essential references. Do not restate the whole task or paste prior transcript, tool logs, or captured context." }),
    }),
    execute: async (_toolCallId, params) => {
      const session = await onSteer({ sessionId: params.sessionId, message: params.message });
      const summary = summarizePickleSession(session);
      return {
        content: [
          {
            type: "text",
            text: `Steering sent to Pickle: ${session.title} (${session.id}). Status is ${session.status}. Now tell the user (in their language) that the existing Pickle was steered and progress can be checked in the Picky dock.`,
          },
        ],
        details: { session: summary },
      };
    },
  });
}

export function createPickyAbortPickleTool(onAbort: (request: PickyPickleAbortRequest) => Promise<PickyAgentSession>): ToolDefinition {
  return createPickyAbortPickleToolWithNames(onAbort, PICKLE_TOOL_NAMES);
}

function createPickyAbortPickleToolWithNames(
  onAbort: (request: PickyPickleAbortRequest) => Promise<PickyAgentSession>,
  names: PickleToolNames,
): ToolDefinition {
  return defineTool({
    name: names.abort,
    label: "Picky abort Pickle",
    description: `Stop an existing Pickle that was started by ${names.start}. The Pickle session transitions to cancelled and any in-flight tool calls are interrupted.`,
    promptSnippet: `${names.abort}: stop a delegated Pickle session immediately.`,
    promptGuidelines: [
      `Use ${names.abort} only on explicit user request to stop a Pickle.`,
      `If the session is ambiguous, call ${names.sessions} first; never guess the id.`,
    ],
    parameters: Type.Object({
      sessionId: Type.String({ description: `ID of the Pickle session to stop, as returned by ${names.sessions}.` }),
    }),
    execute: async (_toolCallId, params) => {
      const session = await onAbort({ sessionId: params.sessionId });
      const summary = summarizePickleSession(session);
      return {
        content: [
          {
            type: "text",
            text: `Pickle aborted: ${session.title} (${session.id}). Status is ${session.status}. Now tell the user (in their language) that the Pickle was stopped and is cancelled in the Picky dock.`,
          },
        ],
        details: { session: summary },
      };
    },
  });
}

function summarizePickleSession(session: PickyAgentSession): PickleSessionSummary {
  return {
    id: session.id,
    title: session.title,
    status: session.status,
    updatedAt: session.updatedAt,
    cwd: session.cwd,
    pendingInput: Boolean(session.pendingExtensionUiRequest),
    lastSummary: session.lastSummary ? truncate(session.lastSummary, 200) : undefined,
    changedFilesCount: session.changedFiles.length,
    archived: session.archived === true,
  };
}

function formatPickleSessions(sessions: PickleSessionSummary[], pagination: { page: number; pageSize: number; hasMore: boolean; nextPage?: number }): string {
  if (sessions.length === 0) return `No Pickles returned on page ${pagination.page}.`;
  const nextPageHint = pagination.hasMore && pagination.nextPage ? `; more available, request page ${pagination.nextPage}` : "";
  const lines = [`Pickles page ${pagination.page} (${sessions.length} shown, page size ${pagination.pageSize}${nextPageHint}):`];
  for (const session of sessions) {
    const pendingInput = session.pendingInput ? "; waiting for input" : "";
    const summary = session.lastSummary ? `; summary=${session.lastSummary}` : "";
    const cwd = session.cwd ? `; cwd=${truncate(session.cwd, 120)}` : "";
    const changed = session.changedFilesCount > 0 ? `; changedFiles=${session.changedFilesCount}` : "";
    const archived = session.archived ? "; archived=true" : "";
    lines.push(`- ${session.id} | ${session.title} | status=${session.status}${archived}${pendingInput}; updated=${session.updatedAt}${cwd}${changed}${summary}`);
  }
  return lines.join("\n");
}

function clampLimit(value: number | undefined, fallback: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(1, Math.min(PICKLE_SESSIONS_MAX_PAGE_SIZE, Math.floor(value!)));
}

function normalizePage(value: number | undefined): number {
  if (!Number.isFinite(value)) return 1;
  return Math.max(1, Math.floor(value!));
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function truncate(value: string, maxChars: number): string {
  return value.length <= maxChars ? value : `${sliceUtf16Safe(value, Math.max(0, maxChars - 1))}…`;
}
