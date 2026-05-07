import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";
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

export interface PickySideSteerRequest {
  sessionId: string;
  message: string;
}

interface SideSessionSummary {
  id: string;
  title: string;
  status: PickyAgentSession["status"];
  updatedAt: string;
  lastSummary?: string;
  finalAnswer?: string;
  pendingInput: boolean;
  recentLogs: string[];
  artifacts: Array<{ kind: string; title: string; path?: string; url?: string }>;
  changedFiles: Array<{ path: string; status: string; summary?: string }>;
  cwd?: string;
}

export function createPickyHandoffTool(onHandoff: (request: PickyHandoffRequest) => Promise<PickyHandoffResult>): ToolDefinition {
  return defineTool({
    name: "picky_handoff",
    label: "Picky handoff",
    description: "Delegate complex, long-running, tool-heavy, or multi-turn work to a side Pi agent shown in Picky's top-right overlay.",
    promptSnippet: "picky_handoff: delegate complex or long-running work to a side Pi agent in the Picky HUD.",
    promptGuidelines: [
      "Use picky_handoff when the user's request needs new detailed screen analysis, code/repo/file work, web/video extraction, MCPs, or multiple turns.",
      "Before creating a new handoff for work that may already be delegated, call picky_side_sessions and prefer picky_side_steer for a matching existing side agent.",
      "Write instructions as a compact, action-oriented brief of about 300 Korean characters: goal, essential constraints, known decisions, key paths/URLs/IDs, and expected output.",
      "Do not paste the full current prompt, captured context, screenshot metadata, prior transcript, or tool logs into instructions; include only deltas and essential references.",
      "After calling picky_handoff, tell the user in Korean that a side agent has been started and progress is visible in the top-right overlay.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Short Korean title for the side-agent HUD card." }),
      instructions: Type.String({ description: "Compact delta-first brief for the side Pi agent, ideally about 300 Korean characters: goal, essential constraints, key paths/URLs/IDs, known decisions, and expected output. Do not paste full prompts, transcripts, logs, screenshot metadata, or captured context." }),
      userMessage: Type.Optional(Type.String({ description: "Optional short Korean message you intend to tell the user after handoff." })),
      cwd: Type.Optional(Type.String({ description: "Optional absolute working directory for the side Pi agent. Omit to use Picky's configured default cwd." })),
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
            text: `Side agent started: ${session.title} (${session.sessionId}). Now tell the user in Korean that you delegated this work and that they can watch progress in the top-right overlay.`,
          },
        ],
        details: session,
      };
    },
  });
}

const SIDE_SESSIONS_DEFAULT_PAGE_SIZE = 10;
const SIDE_SESSIONS_MAX_PAGE_SIZE = 10;

export function createPickySideSessionsTool(onList: () => PickyAgentSession[]): ToolDefinition {
  return defineTool({
    name: "picky_side_sessions",
    label: "Picky side sessions",
    description: "List one bounded page of side Pi agents that the Picky main agent has already delegated work to, so steering requests can reuse the right side agent instead of starting a duplicate.",
    promptSnippet: "picky_side_sessions: list one bounded page of current and recent side Pi agents in the Picky HUD before deciding whether to steer one.",
    promptGuidelines: [
      "Use picky_side_sessions when the user refers to an existing delegated task, side agent, running work, recent completion, or asks to continue/change/check progress.",
      "The tool returns at most one small page at a time; follow nextPage only when needed for the user's request.",
      "Prefer steering a relevant side session with picky_side_steer over creating a duplicate side agent.",
    ],
    parameters: Type.Object({
      includeTerminal: Type.Optional(Type.Boolean({ description: "Whether to include completed, failed, and cancelled side sessions. Defaults to true." })),
      page: Type.Optional(Type.Number({ description: "1-based page number to return. Defaults to 1.", minimum: 1 })),
      limit: Type.Optional(Type.Number({ description: `Maximum number of side sessions to return on this page. Defaults to ${SIDE_SESSIONS_DEFAULT_PAGE_SIZE}; capped at ${SIDE_SESSIONS_MAX_PAGE_SIZE}.`, minimum: 1, maximum: SIDE_SESSIONS_MAX_PAGE_SIZE })),
    }),
    execute: async (_toolCallId, params) => {
      const includeTerminal = params.includeTerminal !== false;
      const page = normalizePage(params.page);
      const pageSize = clampLimit(params.limit, SIDE_SESSIONS_DEFAULT_PAGE_SIZE);
      const start = (page - 1) * pageSize;
      const end = start + pageSize;
      const allSessions = onList().filter((session) => includeTerminal || !["completed", "failed", "cancelled"].includes(session.status));
      const sessions = allSessions.slice(start, end).map(summarizeSideSession);
      const hasMore = allSessions.length > end;
      const nextPage = hasMore ? page + 1 : undefined;
      return {
        content: [{ type: "text", text: formatSideSessions(sessions, { page, pageSize, hasMore, nextPage }) }],
        details: { sessions, page, pageSize, hasMore, nextPage },
      };
    },
  });
}

export function createPickySideSteerTool(onSteer: (request: PickySideSteerRequest) => Promise<PickyAgentSession>): ToolDefinition {
  return defineTool({
    name: "picky_side_steer",
    label: "Picky side steer",
    description: "Send steering instructions to an existing side Pi agent that was started by picky_handoff.",
    promptSnippet: "picky_side_steer: steer an existing delegated side Pi agent with additional user instructions.",
    promptGuidelines: [
      "Use picky_side_steer after picky_side_sessions identifies the side agent that should receive the user's new instruction.",
      "Send only the new delta instruction plus essential references; do not restate the whole task or paste prior transcript/tool logs.",
      "Do not use this for unrelated new work; call picky_handoff for a new delegated task instead.",
      "After calling picky_side_steer, tell the user in Korean that the existing side agent has been steered and progress remains visible in the top-right overlay.",
    ],
    parameters: Type.Object({
      sessionId: Type.String({ description: "ID of the side session to steer, as returned by picky_side_sessions." }),
      message: Type.String({ description: "Delta-only steering instruction for the side Pi agent, with only essential references. Do not restate the whole task or paste prior transcript, tool logs, or captured context." }),
    }),
    execute: async (_toolCallId, params) => {
      const session = await onSteer({ sessionId: params.sessionId, message: params.message });
      const summary = summarizeSideSession(session);
      return {
        content: [
          {
            type: "text",
            text: `Steering sent to side agent: ${session.title} (${session.id}). Status is ${session.status}. Now tell the user in Korean that the existing side agent was steered and progress is visible in the top-right overlay.`,
          },
        ],
        details: { session: summary },
      };
    },
  });
}

function summarizeSideSession(session: PickyAgentSession): SideSessionSummary {
  return {
    id: session.id,
    title: session.title,
    status: session.status,
    updatedAt: session.updatedAt,
    lastSummary: session.lastSummary,
    cwd: session.cwd,
    finalAnswer: session.finalAnswer,
    pendingInput: Boolean(session.pendingExtensionUiRequest),
    recentLogs: session.logs.slice(-3).map((line) => truncate(line, 240)),
    artifacts: session.artifacts.map((artifact) => ({ kind: artifact.kind, title: artifact.title, path: artifact.path, url: artifact.url })),
    changedFiles: session.changedFiles,
  };
}

function formatSideSessions(sessions: SideSessionSummary[], pagination: { page: number; pageSize: number; hasMore: boolean; nextPage?: number }): string {
  if (sessions.length === 0) return `No side agents returned on page ${pagination.page}.`;
  const nextPageHint = pagination.hasMore && pagination.nextPage ? `; more available, request page ${pagination.nextPage}` : "";
  const lines = [`Side agents page ${pagination.page} (${sessions.length} shown, page size ${pagination.pageSize}${nextPageHint}):`];
  for (const session of sessions) {
    const pendingInput = session.pendingInput ? "; waiting for input" : "";
    const summary = session.lastSummary ? `; summary=${truncate(session.lastSummary, 160)}` : "";
    const finalAnswer = session.finalAnswer ? `; final=${truncate(session.finalAnswer, 160)}` : "";
    const cwd = session.cwd ? `; cwd=${truncate(session.cwd, 120)}` : "";
    lines.push(`- ${session.id} | ${session.title} | status=${session.status}${pendingInput}; updated=${session.updatedAt}${cwd}${summary}${finalAnswer}`);
    if (session.recentLogs.length > 0) {
      lines.push(`  recent logs: ${session.recentLogs.join(" / ")}`);
    }
    if (session.artifacts.length > 0) {
      lines.push(`  artifacts: ${session.artifacts.map((artifact) => `${artifact.kind}:${artifact.title}`).join(", ")}`);
    }
  }
  return lines.join("\n");
}

function clampLimit(value: number | undefined, fallback: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(1, Math.min(SIDE_SESSIONS_MAX_PAGE_SIZE, Math.floor(value!)));
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
