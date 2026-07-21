import type { EventEnvelope, PickyMainAgentState } from "../protocol.js";
import { sliceUtf16Safe } from "./safe-truncate.js";

export type QuickReplyEvent = Extract<EventEnvelope, { type: "quickReply" }>;
export type QuickReplyMetadata = Pick<QuickReplyEvent, "originSource" | "replyKind" | "sessionId" | "inputId" | "didStreamNarration">;

export const MAIN_AGENT_MESSAGE_LIMIT = 100;
export const MAIN_AGENT_ROLLOVER_TURN_LIMIT = 20;
export const MAIN_AGENT_ROLLOVER_CONTEXT_PERCENT = 60;
// Minimum idle time (no main-agent activity) required before a threshold-triggered
// in-place compaction may run. Compaction never interrupts active use; it only fires
// once the user has been quiet for this long, so delay timers and other in-memory
// session state survive the compaction instead of being lost to a session teardown.
export const MAIN_AGENT_COMPACT_IDLE_MS = 5 * 60 * 1000;
// On restart, only tear down (start a fresh session file) when the persisted main Pi
// session file has grown past this size. In-place compaction appends to the same file, so a
// long-lived session bloats over time; a fresh short session stays small and resumes normally.
export const MAIN_AGENT_RESTART_TEARDOWN_SESSION_BYTES = 2_000_000;
export const MAIN_AGENT_COMPACT_SUMMARY_LIMIT = 4_000;
export const MAIN_AGENT_SUMMARY_MESSAGE_LIMIT = 16;
export const MAIN_AGENT_SUMMARY_PICKLE_SESSION_LIMIT = 10;

export function normalizeMainAgentState(state: PickyMainAgentState): PickyMainAgentState {
  const compactSummary = state.compactSummary ? truncateMainSummaryText(state.compactSummary, MAIN_AGENT_COMPACT_SUMMARY_LIMIT) : undefined;
  return { ...state, messages: state.messages.slice(-MAIN_AGENT_MESSAGE_LIMIT), ...(compactSummary ? { compactSummary } : { compactSummary: undefined }) };
}

export function truncateMainSummaryText(value: string, maxChars: number): string {
  const normalized = value.replace(/[\t ]+\n/g, "\n").trim();
  if (normalized.length <= maxChars) return normalized;
  return `${sliceUtf16Safe(normalized, Math.max(0, maxChars - 1))}…`;
}

export function quickReplyOriginFromContextSource(source: string | undefined): QuickReplyMetadata["originSource"] {
  switch (source) {
    case "voice":
      return "voice";
    case "voice-follow-up":
    case "voiceFollowUp":
    case "voice_follow_up":
      return "voiceFollowUp";
    case "text":
      return "text";
    case "text-follow-up":
    case "textFollowUp":
    case "text_follow_up":
      return "textFollowUp";
    case "cli":
      // External picky CLI submissions surface as cursor bubble + TTS in the app
      // (PickyContextOwner.cli mirrors .quickInputText semantics), so propagate the
      // dedicated origin instead of collapsing to "unknown" which would render as a
      // silent text-reply update.
      return "cli";
    case undefined:
    default:
      return "unknown";
  }
}
