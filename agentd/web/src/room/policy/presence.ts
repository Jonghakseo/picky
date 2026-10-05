/**
 * The running-work line under the last message.
 *
 * The Mac builds `PickyConversationPresencePresentation` from live daemon
 * signals (`isWritingReply`, `isPreparingToolCall`) that the projection does
 * not carry. The phone derives the same phases from what a remote client can
 * see: the session status and the tool call that is still running.
 */
import type { PickyAgentSession, PickyToolActivity } from "../../../../src/protocol";

export type PresencePhase =
  | "thinking"
  | "readingFile"
  | "editingFile"
  | "writingFile"
  | "working"
  | "waitingForInput";

export interface Presence {
  phase: PresencePhase;
  /** Human-written description of the step. Never a raw command or JSON argument. */
  detail?: string;
  /** Full text behind a shortened detail, such as the path behind a file name. */
  detailHelp?: string;
  startedAt?: string;
}

const PHASE_TITLE_KEYS: Record<PresencePhase, string> = {
  thinking: "hud.presence.thinking",
  readingFile: "hud.presence.readingFile",
  editingFile: "hud.presence.editingFile",
  writingFile: "hud.presence.writingFile",
  working: "hud.liveStep.working",
  waitingForInput: "hud.conversation.status.waiting",
};

export function presenceTitleKey(phase: PresencePhase): string {
  return PHASE_TITLE_KEYS[phase];
}

function fileName(path: string): string {
  const parts = path.split("/").filter((part) => part.length > 0);
  return parts[parts.length - 1] ?? path;
}

/** A tool's argument preview is a path for the file tools; otherwise it is a summary. */
function filePhase(name: string): PresencePhase | null {
  const tool = name.toLowerCase();
  if (tool === "read") return "readingFile";
  if (tool === "edit" || tool === "multiedit") return "editingFile";
  if (tool === "write") return "writingFile";
  return null;
}

export function runningTool(tools: PickyToolActivity[] | undefined): PickyToolActivity | undefined {
  if (!tools) return undefined;
  for (let index = tools.length - 1; index >= 0; index -= 1) {
    const tool = tools[index];
    if (tool && tool.status === "running") return tool;
  }
  return undefined;
}

/** `null` while nothing is in flight: the room shows no line at all. */
export function derivePresence(session: PickyAgentSession): Presence | null {
  if (session.status === "waiting_for_input") {
    return session.pendingExtensionUiRequest ? null : { phase: "waitingForInput" };
  }
  if (session.status !== "running" && session.status !== "queued") return null;

  const tool = runningTool(session.tools);
  if (!tool) {
    return { phase: "thinking", startedAt: session.updatedAt };
  }
  const phase = filePhase(tool.name);
  if (phase) {
    const path = (tool.argsPreview ?? tool.preview ?? "").trim();
    return {
      phase,
      detail: path ? fileName(path) : undefined,
      detailHelp: path || undefined,
      startedAt: tool.startedAt,
    };
  }
  const subagents = tool.subagentSummary?.agents ?? [];
  if (subagents.length > 0) {
    return { phase: "working", detail: subagentDetailKeyArgs(subagents), startedAt: tool.startedAt };
  }
  const preview = (tool.preview ?? tool.argsPreview ?? "").trim();
  return { phase: "working", detail: preview || undefined, startedAt: tool.startedAt };
}

/** "worker에게 맡김" for one agent, "worker 외 2개에게 맡김" is not a catalog string, so join them. */
function subagentDetailKeyArgs(agents: string[]): string {
  return agents.join(", ");
}

/** mm:ss elapsed since `startedAt`, like the HUD's hover badge. */
export function elapsedText(startedAt: string | undefined, now: number): string | null {
  if (!startedAt) return null;
  const started = Date.parse(startedAt);
  if (Number.isNaN(started)) return null;
  const seconds = Math.max(0, Math.floor((now - started) / 1000));
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return `${minutes}:${String(rest).padStart(2, "0")}`;
}
