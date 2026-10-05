/**
 * What a `system` journal message is, and how much of it the room shows.
 *
 * The daemon writes one `system` kind for very different things: a compaction
 * outcome, a `ctx.ui.notify` from an extension, a Pi `role="custom"` payload,
 * background-work bookkeeping, and plain prose. The HUD splits them apart
 * before rendering, and the phone has to do the same: a single-line
 * `[subagent:worker#67] completed ...` dropped into a nowrap row widens the
 * whole transcript.
 *
 * Swift sources: `PickyConversationBackgroundWorkVisibility`,
 * `PickyExtensionCustomMessagePresentation`,
 * `Bubbles/PickyCompactStatusViews.swift` (`isCompactCompletionMessage`,
 * `isCompactFailureMessage`, `compactFailureDetailText`,
 * `abbreviatedTokenCount`), `Bubbles/PickyAgentBubbleView.swift`
 * (`PickyNotifyBubbleView`) and `PickyMessagePresentationCopy.swift`.
 */
import type { PickyCompactionResult, PickyExtensionNotifyType, PickySessionMessage } from "../../../../src/protocol";

/**
 * Terminal output reaches the journal with its escapes intact. The HUD strips
 * them before display; the same bytes would show up as literal `[0m` here.
 * Handles CSI (`ESC [ … final`) and OSC (`ESC ] … BEL` or `ESC \`), and drops a
 * lone two-character escape like `ESC (`.
 */
export function stripAnsi(value: string): string {
  return value.replace(/\u001B\[[0-?]*[ -/]*[@-~]|\u001B\][\s\S]*?(?:\u0007|\u001B\\)|\u001B[@-Z\\-_]/g, "");
}

/** `customType`s whose content the task footer already owns on the Mac. */
const HIDDEN_CUSTOM_TYPES = new Set(["bash-async-completion", "subagent-tool"]);

/**
 * `ctx.ui.notify` carries no extension identity, so only the bundled subagent
 * tool's lifecycle grammar is matched, never a generic mention of a tool.
 * JavaScript `^`/`$` without the `m` flag anchor to the whole string, which is
 * what Swift's `\A`/`\z` do.
 */
const SUBAGENT_LIFECYCLE_NOTIFICATIONS = [
  /^(?:Started|Resumed) subagent #[0-9]+: [^\r\n]+$/,
  /^subagent tool run #[0-9]+(?: \([^\r\n]+\))? (?:completed|failed|aborted)(?:: [\s\S]*)?$/,
  /^subagent batch [^\s]+ (?:completed|aborted|finished with errors)$/,
];

/**
 * False for the duplicate surfaces of background work. The journal keeps them
 * for Pi, reconnect and reports; only the conversation row is suppressed.
 *
 * Unlike the HUD this does not hide `subagent_invocation`: the Mac moves those
 * runs into the task footer, and the phone has no such surface yet, so hiding
 * them here would drop the delegation from the room entirely.
 */
export function isBackgroundWorkVisible(message: PickySessionMessage): boolean {
  if (message.kind !== "system") return true;
  const customType = message.customType?.trim() ?? "";
  if (customType.length > 0) return !HIDDEN_CUSTOM_TYPES.has(customType);
  if (!message.notifyType || message.text === undefined) return true;
  const notification = message.text.trim();
  return !SUBAGENT_LIFECYCLE_NOTIFICATIONS.some((pattern) => pattern.test(notification));
}

export function isCompactCompletionMessage(message: PickySessionMessage): boolean {
  if (message.kind !== "system") return false;
  const code = message.presentation?.code;
  if (code) return code === "sessionCompacted" || code === "sessionCompactedAfterOverflow";
  const normalized = message.text?.trim().toLowerCase() ?? "";
  return normalized === "session compacted" || normalized === "session compacted after context overflow";
}

export function isCompactFailureMessage(message: PickySessionMessage): boolean {
  if (message.kind !== "system") return false;
  const code = message.presentation?.code;
  if (code) return code === "sessionCompactionFailed";
  return (message.text?.trim().toLowerCase() ?? "").startsWith("auto-compaction failed");
}

/** `128k → ~21k`; the after value is Pi's estimate of the kept context. */
export function compactTokenChangeText(compaction: PickyCompactionResult | undefined): string | null {
  if (!compaction) return null;
  const before = abbreviatedTokenCount(compaction.tokensBefore);
  if (compaction.tokensAfter === undefined) return before;
  return `${before} → ~${abbreviatedTokenCount(compaction.tokensAfter)}`;
}

export function abbreviatedTokenCount(count: number): string {
  const value = Math.max(0, count);
  if (value < 1_000) return String(Math.round(value));
  // One decimal below 10k, and `1k` rather than `1.0k`.
  if (value < 10_000) return `${Math.round(value / 100) / 10}k`;
  return `${Math.round(value / 1_000)}k`;
}

/**
 * Body of the compaction-failure bubble, in pieces the bubble turns into copy.
 * `localized` messages carry typed parameters, so the outcome sentence ("the
 * context was not reduced", plus usage when known) applies; older journals only
 * have the English text, whose first line is the title the bubble already draws.
 */
export interface CompactFailureDetail {
  /** The summarizer's own words. Empty when the daemon sent none. */
  detail: string;
  /** Usage when compaction gave up. `tokens: null` means Pi had reported no count. */
  usage: { tokens: number | null; windowTokens: number } | null;
  localized: boolean;
}

export function compactFailureDetail(message: PickySessionMessage): CompactFailureDetail | null {
  if (!isCompactFailureMessage(message)) return null;
  const presentation = message.presentation;
  if (presentation?.code === "sessionCompactionFailed") {
    const params = presentation.params;
    return {
      detail: params.detail.trim(),
      usage:
        params.contextWindowTokens === undefined
          ? null
          : { tokens: params.contextTokens ?? null, windowTokens: params.contextWindowTokens },
      localized: true,
    };
  }
  const lines = (message.text?.trim() ?? "").split("\n");
  const detail = lines.slice(1).join("\n").trim();
  return detail.length === 0 ? null : { detail, usage: null, localized: false };
}

/** The summary Pi kept, when it recorded one. */
export function compactSummaryPreview(compaction: PickyCompactionResult | undefined): string | null {
  const summary = compaction?.summary?.trim() ?? "";
  return summary.length === 0 ? null : summary;
}

/** Extension notices stay short in the transcript and expand in place. */
export const NOTIFY_PREVIEW_MAX_LINES = 4;
/** One source line can wrap into several on screen; four wrapped lines fit here. */
export const NOTIFY_PREVIEW_MAX_CHARACTERS = 180;

export function notifyLevel(message: PickySessionMessage): PickyExtensionNotifyType {
  return message.notifyType ?? "info";
}

export function notifyText(message: PickySessionMessage): string {
  return stripAnsi(message.text ?? "");
}

export function notifyLevelLabelKey(level: PickyExtensionNotifyType): string {
  switch (level) {
    case "warning":
      return "hud.extension.warning";
    case "error":
      return "hud.extension.error";
    default:
      return "hud.extension.info";
  }
}

/** Mirrors Pi's collapsed fallback budget for tool output (`FALLBACK_PREVIEW_LINES`). */
export const CUSTOM_MESSAGE_MAX_PREVIEW_LINES = 10;

/**
 * A tagged extension payload folded into a bounded preview plus the full text.
 *
 * Picky cannot run Pi's per-type terminal renderers, so it applies one
 * structural rule: keep the first line of each blank-line separated block.
 * That keeps a batched notification honest — a batch where job 1 succeeded and
 * job 2 failed shows both status headers while collapsed, instead of hiding
 * the failure behind the first job's output tail.
 */
export interface ExtensionCustomMessagePresentation {
  customType: string;
  /** Lines shown while collapsed, in document order. */
  previewLines: string[];
  fullText: string;
  hiddenLineCount: number;
  /** Nothing to hide means a plain labeled bubble with no disclosure control. */
  isCollapsible: boolean;
}

export function extensionCustomMessagePresentation(
  message: PickySessionMessage,
  maxPreviewLines = CUSTOM_MESSAGE_MAX_PREVIEW_LINES,
): ExtensionCustomMessagePresentation | null {
  if (message.kind !== "system") return null;
  const customType = message.customType?.trim() ?? "";
  if (customType.length === 0) return null;
  return makeExtensionCustomMessagePresentation(customType, message.text ?? "", maxPreviewLines);
}

export function makeExtensionCustomMessagePresentation(
  customType: string,
  text: string,
  maxPreviewLines = CUSTOM_MESSAGE_MAX_PREVIEW_LINES,
): ExtensionCustomMessagePresentation | null {
  const lines = contentLines(text);
  if (lines.length === 0) return null;
  const previewLines = blockHeadLines(lines).slice(0, Math.max(1, maxPreviewLines));
  const hiddenLineCount = Math.max(0, lines.length - previewLines.length);
  return {
    customType,
    previewLines,
    fullText: lines.join("\n"),
    hiddenLineCount,
    isCollapsible: hiddenLineCount > 0,
  };
}

/** Non-blank edges trimmed; interior blank lines survive as block separators. */
function contentLines(text: string): string[] {
  const lines = stripAnsi(text).split("\n");
  while (lines.length > 0 && lines[0].trim().length === 0) lines.shift();
  while (lines.length > 0 && lines[lines.length - 1].trim().length === 0) lines.pop();
  return lines;
}

function blockHeadLines(lines: string[]): string[] {
  const heads: string[] = [];
  let atBlockStart = true;
  for (const line of lines) {
    if (line.trim().length === 0) {
      atBlockStart = true;
      continue;
    }
    if (atBlockStart) {
      heads.push(line);
      atBlockStart = false;
    }
  }
  return heads;
}
