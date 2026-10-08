/**
 * Which bubble a journal message becomes, and how a long user message folds.
 *
 * Swift sources: `PickyConversationBubbleKind` (PickyConversationListView.swift),
 * `PickyAgentResponsePreview` (Bubbles/PickyAgentBubbleView.swift) and
 * `PickyErrorBubbleView.isRecoverableRuntimeRace`. The `system` branch lives in
 * `policy/system-message.ts`, which is where the HUD keeps it too.
 */
import type { PickyAgentSession, PickySessionMessage } from "../../../../src/protocol";
import { t } from "../i18n";
import {
  extensionCustomMessagePresentation,
  isBackgroundWorkVisible,
  isCompactCompletionMessage,
  isCompactFailureMessage,
} from "./system-message";

export type BubbleKind =
  | "userText"
  | "agentText"
  | "question"
  | "questionFallback"
  | "error"
  | "activitySummary"
  | "subagentInvocation"
  | "toolImage"
  | "compactCompletion"
  | "compactFailure"
  | "notify"
  | "extensionCustomMessage"
  | "systemText"
  | "hidden";

/** Tool categories the activity summary counts; `thinking` never shows a row. */
const ACTIVITY_CATEGORIES = ["read", "bash", "edit", "write", "todo", "subagent", "other"] as const;
export type ActivityCategory = (typeof ACTIVITY_CATEGORIES)[number];

export function visibleActivityCounts(
  snapshot: NonNullable<PickySessionMessage["activitySnapshot"]> | undefined,
): Array<{ category: ActivityCategory; count: number }> {
  if (!snapshot) return [];
  return ACTIVITY_CATEGORIES.map((category) => ({ category, count: snapshot[category] ?? 0 })).filter(
    (entry) => entry.count > 0,
  );
}

/** Up to this many seconds the completed turn reads "Completed instantly". */
export const ACTIVITY_INSTANT_MAX_SECONDS = 5;

/**
 * Completed-turn label in the activity summary: "Completed instantly" up to
 * 5 seconds, otherwise "Completed in <duration>" with zero parts left out.
 * Mirrors `PickyActivityDurationFormat.completionText` in PickyActivitySummaryView.swift.
 */
export function activityCompletionText(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  if (total <= ACTIVITY_INSTANT_MAX_SECONDS) return t("hud.activity.summary.completedInstantly");
  const parts: string[] = [];
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = total % 60;
  if (hours > 0) parts.push(t("hud.activity.summary.duration.hours", hours));
  if (minutes > 0) parts.push(t("hud.activity.summary.duration.minutes", minutes));
  if (rest > 0) parts.push(t("hud.activity.summary.duration.seconds", rest));
  return t("hud.activity.summary.completedAfter", parts.join(" "));
}

export function bubbleKind(message: PickySessionMessage): BubbleKind {
  if (!isBackgroundWorkVisible(message)) return "hidden";
  switch (message.kind) {
    case "user_text":
    case "command_receipt":
      return "userText";
    case "agent_text":
      return "agentText";
    case "agent_thinking":
      // Thinking never renders in the transcript; the presence line carries it.
      return "hidden";
    case "agent_question":
      return message.question ? "question" : "questionFallback";
    case "agent_error":
      return "error";
    case "agent_activity":
      return visibleActivityCounts(message.activitySnapshot).length > 0 ? "activitySummary" : "hidden";
    case "subagent_invocation":
      return message.subagentInvocation ? "subagentInvocation" : "hidden";
    case "system":
      if (message.toolImage) return "toolImage";
      if (isCompactCompletionMessage(message)) return "compactCompletion";
      if (isCompactFailureMessage(message)) return "compactFailure";
      if (message.notifyType) return "notify";
      if (extensionCustomMessagePresentation(message)) return "extensionCustomMessage";
      return "systemText";
  }
}

export const PREVIEW_MAX_LINES = 8;
export const PREVIEW_MAX_CHARACTERS = 500;

/** True when the bubble would visibly cut the text, so it offers "더 보기". */
export function isTruncated(
  text: string,
  maxLines = PREVIEW_MAX_LINES,
  maxCharacters = PREVIEW_MAX_CHARACTERS,
): boolean {
  if (maxLines <= 0 || maxCharacters <= 0) return false;
  if ([...text].length > maxCharacters) return true;
  return text.split("\n").length > maxLines;
}

/** Folded form of a long message: first 8 lines, then 500 characters, then "...". */
export function truncatedMarkdown(
  text: string,
  maxLines = PREVIEW_MAX_LINES,
  maxCharacters = PREVIEW_MAX_CHARACTERS,
): string {
  if (maxLines <= 0 || maxCharacters <= 0) return "...";
  let candidate = text;
  let didTruncate = false;
  const lines = text.split("\n");
  if (lines.length > maxLines) {
    candidate = lines.slice(0, maxLines).join("\n");
    didTruncate = true;
  }
  const characters = [...candidate];
  if (characters.length > maxCharacters) {
    candidate = characters.slice(0, maxCharacters).join("");
    didTruncate = true;
  }
  if (!didTruncate) return text;
  return `${candidate.trim()}...`;
}

/**
 * Pi can reject a prompt it never delivered ("Agent is already processing a
 * prompt"). Resending that text is safe, so the chip offers 다시 시도; every
 * other runtime failure was accepted, so it offers 이어가기 instead.
 */
export function isRecoverableRuntimeRace(errorMessage: string | undefined): boolean {
  if (!errorMessage) return false;
  return errorMessage.toLowerCase().includes("agent is already processing a prompt");
}

export type ErrorRecovery =
  /** Resend the request Pi never accepted. */
  | { kind: "retryLastRequest"; text: string }
  /** Nudge the accepted-but-failed turn forward. */
  | { kind: "continue"; text: string };

/** The text a "이어가기" chip steers with. */
export const CONTINUE_PROMPT_KEY = "hud.error.retry.continuePrompt";

/**
 * What the error bubble's chip sends. A runtime race resends the request that
 * never arrived; anything else continues the turn with a short prompt. `null`
 * when the race left nothing to resend, which also hides the chip.
 */
export function errorRecovery(
  message: Pick<PickySessionMessage, "errorMessage">,
  lastRequest: PickyAgentSession["lastRequest"],
  continuePrompt: string,
): ErrorRecovery | null {
  if (isRecoverableRuntimeRace(message.errorMessage)) {
    const text = lastRequest?.text.trim();
    return text ? { kind: "retryLastRequest", text } : null;
  }
  return { kind: "continue", text: continuePrompt };
}

/** The chip's label: 다시 시도 for a race, 이어가기 for an accepted failure. */
export function errorRecoveryLabelKey(recovery: ErrorRecovery): string {
  return recovery.kind === "retryLastRequest" ? "hud.error.retry" : "hud.error.continue";
}
