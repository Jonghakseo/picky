/**
 * The running-work line under the last message.
 *
 * The Mac builds `PickyConversationPresencePresentation` from live daemon
 * signals (`isWritingReply`, `isPreparingToolCall`) that the projection does
 * not carry. The phone derives the same phases from what a remote client can
 * see: the session status and the tool call that is still running.
 */
import type { PickyAgentSession, PickyToolActivity } from "../../../../src/protocol";
import { t } from "../i18n";

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

/**
 * One string value out of a tool's argument preview, which is JSON that may be
 * cut off mid-way. Port of `PickyToolHistoryRenderer.recoverStringValue`.
 */
export function recoverStringValue(json: string | undefined, key: string): string | undefined {
  if (!json) return undefined;
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`"${escaped}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)`).exec(json);
  if (!match || match[1] === undefined) return undefined;
  let output = "";
  let escaping = false;
  for (const character of match[1]) {
    if (escaping) {
      output += character === "n" ? "\n" : character === "r" ? "\r" : character === "t" ? "\t" : character;
      escaping = false;
    } else if (character === "\\") {
      escaping = true;
    } else {
      output += character;
    }
  }
  if (escaping) output += "\\";
  return output.length > 0 ? output : undefined;
}

function firstLine(text: string | undefined): string | undefined {
  const line = text?.split(/\r?\n/)[0]?.trim();
  return line ? line : undefined;
}

/** `read` of `.../skills/<name>/SKILL.md` is a skill step. `PickyToolActivityPresentation.skillName`. */
export function skillName(tool: PickyToolActivity): string | undefined {
  if (tool.name.toLowerCase() !== "read") return undefined;
  const path = recoverStringValue(tool.argsPreview, "path");
  if (!path) return undefined;
  const parts = path.trim().split("/").filter((part) => part.length > 0);
  if (parts.length < 3) return undefined;
  if (parts[parts.length - 1]?.toLowerCase() !== "skill.md" || parts[parts.length - 3]?.toLowerCase() !== "skills") return undefined;
  const name = parts[parts.length - 2] ?? "";
  return /^[A-Za-z0-9._-]+$/.test(name) ? name : undefined;
}

/** File phase for `read`, `edit`/`multiedit` and `write`; a skill read is not one. */
function fileStep(tool: PickyToolActivity): { phase: PresencePhase; name?: string; path?: string } | null {
  let phase: PresencePhase;
  switch (tool.name.toLowerCase()) {
    case "read":
      if (skillName(tool)) return null;
      phase = "readingFile";
      break;
    case "edit":
    case "multiedit":
      phase = "editingFile";
      break;
    case "write":
      phase = "writingFile";
      break;
    default:
      return null;
  }
  const path = ["path", "file_path", "filePath", "file"]
    .map((key) => firstLine(recoverStringValue(tool.argsPreview, key)))
    .find((value) => value !== undefined);
  if (!path || path.endsWith("/")) return { phase };
  const name = path.split("/").filter((part) => part.length > 0).pop();
  return name ? { phase, name, path } : { phase };
}

/**
 * Detail for other tools, as `PickyConversationPresencePresentation.detail(for:)`:
 * a skill name, a `bash`/`bash_async` title, or the delegated subagents.
 * Anything else shows only "working": a tool's argument or output preview is
 * raw JSON or command text, never a description.
 */
export function workingDetail(tool: PickyToolActivity): string | undefined {
  const skill = skillName(tool);
  if (skill) return t("hud.presence.skill", skill);
  switch (tool.name.toLowerCase()) {
    case "bash":
    case "bash_async":
      return firstLine(recoverStringValue(tool.argsPreview, "title"));
    case "subagent": {
      const agents = (tool.subagentSummary?.agents ?? []).map((agent) => firstLine(agent)).filter((agent): agent is string => !!agent);
      return agents.length > 0 ? t("hud.presence.subagent", agents.join(", ")) : undefined;
    }
    default:
      return undefined;
  }
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
  // Background work (bash_async, subagents) keeps the session running after the
  // agent has answered. The HUD drops the line then; the work shows in the
  // background-work footer instead of as a "thinking" that never ends.
  if (!isAgentResponding(session)) return null;

  const tool = runningTool(session.tools);
  if (!tool) {
    return { phase: "thinking", startedAt: session.updatedAt };
  }
  const file = fileStep(tool);
  if (file) {
    return { phase: file.phase, detail: file.name, detailHelp: file.path, startedAt: tool.startedAt };
  }
  return { phase: "working", detail: workingDetail(tool), startedAt: tool.startedAt };
}

/** `isAgentResponding` in `PickyConversationListView.presence(for:)`. */
export function isAgentResponding(session: Pick<PickyAgentSession, "agentCycle">): boolean {
  const phase = session.agentCycle?.phase;
  return phase !== "idle" && phase !== "settled";
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
