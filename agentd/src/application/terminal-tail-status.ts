import type { PiSessionTailEntry } from "./pi-session-tail-watcher.js";
import type { PickyAgentSession } from "../protocol.js";

/**
 * Picky-registered Pi tools that block the turn waiting for explicit user input. When the most
 * recent assistant entry has an open toolCall from this set, the dock should render the
 * "awaiting input" attention state instead of the running-breath. Extension authors who wrap
 * `ui.askUserQuestion` inside their own tool won't show up here — their open toolCall stays
 * classified as running because the wrapping tool name isn't on this list.
 */
const INPUT_BLOCKING_TOOL_NAMES = new Set(["ask_user_question"]);

/**
 * Walks newly-tailed JSONL entries in reverse and returns the most decisive status transition
 * we can claim. Used by `handleTerminalTailEntries` to keep the HUD dock icon animating while
 * the user is driving a Pickle through the Pi terminal overlay / inline TUI.
 *
 * Mapping (last decisive entry wins):
 * - user entry                     -> running   (a fresh prompt just hit the queue)
 * - assistant entry, no open tool  -> completed (turn finished)
 * - assistant entry, blocking tool -> waiting_for_input (e.g. ask_user_question is pending)
 * - assistant entry, other tool    -> running   (mid-turn, tool still resolving)
 */
export function inferTerminalStatusFromEntries(entries: PiSessionTailEntry[]): PickyAgentSession["status"] | undefined {
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i];
    if (!entry) continue;
    if (entry.type === "session_info") continue;
    const role = entry.message?.role;
    if (role === "user") return "running";
    if (role === "assistant") {
      const openTools = openToolCallNames(entry.message?.content);
      if (openTools.length === 0) return "completed";
      if (openTools.some((name) => INPUT_BLOCKING_TOOL_NAMES.has(name))) return "waiting_for_input";
      return "running";
    }
  }
  return undefined;
}

function openToolCallNames(content: unknown): string[] {
  if (!Array.isArray(content)) return [];
  const names: string[] = [];
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    const candidate = block as { type?: string; name?: unknown; toolResult?: unknown };
    if (candidate.type !== "toolCall" || candidate.toolResult !== undefined) continue;
    names.push(typeof candidate.name === "string" ? candidate.name : "");
  }
  return names;
}
