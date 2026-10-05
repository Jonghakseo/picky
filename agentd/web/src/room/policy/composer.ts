/**
 * Composer policies ported from the HUD. Pure functions, no DOM.
 *
 * Swift sources:
 *   - submit kind, option-return kind: `PickyConversationComposerView.defaultSubmitKind`
 *     / `optionReturnSubmitKind` (Picky/HUD/Conversation/PickyConversationComposerView.swift)
 *   - placeholder: `PickyComposerLabelPolicy.placeholder`
 *   - bash mode: `PickyConversationComposerView+Policy.bashMode(in:)`, itself a mirror of
 *     agentd's `parseUserBashInput`
 *   - submission text: `PickyConversationComposerView+Policy.submissionText`
 *   - border state: `PickyConversationComposerView+Policy.composerBorderState`
 *   - queued-input restore: `PickyQueuedInputDraftPolicy`
 *   - dictation append: `PickyComposerDictationController.draft(_:appending:)`
 */
import type { PickyQueueItem, SessionStatus } from "../../../../src/protocol";

export type SubmitKind = "steer" | "followUp";
export type BashMode = "none" | "visible" | "private";
export type ComposerBorderState = "bash" | "running" | "focused" | "rest";

/**
 * The status the composer acts on: `PickySessionMetadata.submitStatus`. A
 * session kept running only by background work, with the agent idle, takes a
 * new message as a follow-up, the way a finished one does.
 */
export function submitStatus(status: SessionStatus, agentPhase: string | undefined): SessionStatus {
  if (status === "running" && (agentPhase === "idle" || agentPhase === "settled")) return "completed";
  return status;
}

export type ReturnKeyAction = "none" | "newline" | "submit" | "submitAfterReply" | "openSendTiming";

/**
 * What Return does in the composer. `returnKeyAction(for:)` in
 * PickyConversationComposerView+Policy.swift: Return sends, Shift+Return is a
 * new line, Option+Return sends once the current reply ends. A browser on the
 * Mac adds Command (or Control) + Return for the send-timing menu, which the
 * HUD opens from the split button only.
 *
 * A phone keyboard has no modifiers and its Return is the only way to start a
 * new line, so without a hardware keyboard Return stays a new line. While an
 * IME is composing (Korean), Return commits the syllable and does nothing else.
 */
export function returnKeyAction(event: {
  key: string;
  shiftKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  ctrlKey: boolean;
  composing: boolean;
  hardwareKeyboard: boolean;
}): ReturnKeyAction {
  if (event.key !== "Enter" || event.composing) return "none";
  if (!event.hardwareKeyboard) return "none";
  if (event.shiftKey) return "newline";
  if (event.metaKey || event.ctrlKey) return "openSendTiming";
  if (event.altKey) return "submitAfterReply";
  return "submit";
}

/** What the send button does by default for this session status. */
export function defaultSubmitKind(status: SessionStatus): SubmitKind {
  switch (status) {
    case "running":
    case "queued":
    case "waiting_for_input":
    case "cancelled":
    case "failed":
      return "steer";
    case "completed":
    case "blocked":
      return "followUp";
  }
}

/**
 * What the send-timing menu's "이번 응답이 끝나면" row sends. `null` means the
 * row is disabled: a cancelled or failed Pickle has no reply to follow.
 * Mirrors `optionReturnSubmitKind` (the Mac's ⌥↵ route).
 */
export function afterCurrentReplySubmitKind(status: SessionStatus): SubmitKind | null {
  switch (status) {
    case "running":
    case "queued":
    case "waiting_for_input":
    case "completed":
    case "blocked":
      return "followUp";
    case "cancelled":
    case "failed":
      return null;
  }
}

/** Catalog key for the editor placeholder. The phone uses its own steer copy (no ⌥↵/esc hints). */
export function placeholderKey(status: SessionStatus, isCompacting: boolean): string {
  if (isCompacting) return "hud.composer.placeholder.compacting";
  switch (status) {
    case "running":
    case "queued":
      return "remote.room.composer.placeholder.steer";
    case "waiting_for_input":
      return "hud.composer.placeholder.question";
    case "completed":
    case "blocked":
      return "hud.composer.placeholder.followUp";
    case "cancelled":
      return "hud.composer.placeholder.resume";
    case "failed":
      return "hud.composer.placeholder.recovery";
  }
}

/**
 * `!` runs a shell command and feeds its output to the next turn, `!!` runs it
 * without adding the output. A bare `!` with no command is not bash mode.
 */
export function bashMode(text: string): BashMode {
  const trimmed = text.trim();
  if (!trimmed.startsWith("!")) return "none";
  const isPrivate = trimmed.startsWith("!!");
  const command = trimmed.slice(isPrivate ? 2 : 1).trim();
  if (command.length === 0) return "none";
  return isPrivate ? "private" : "visible";
}

/**
 * Attachments disable bash mode: the HUD prefixes a space so agentd's parser
 * does not treat the message as a command once file paths ride along. The phone
 * sends uploads out of band, so it only has to suppress the badge and the run
 * icon while attachments are present.
 */
export function effectiveBashMode(text: string, attachmentCount: number): BashMode {
  return attachmentCount > 0 ? "none" : bashMode(text);
}

export function composerBorderState(input: {
  bashMode: BashMode;
  isRunning: boolean;
  isFocused: boolean;
}): ComposerBorderState {
  if (input.bashMode !== "none") return "bash";
  if (input.isRunning) return "running";
  if (input.isFocused) return "focused";
  return "rest";
}

/** The stop button only exists while there is a run to stop. */
export function canStop(status: SessionStatus, hasAnyMessage: boolean): boolean {
  if (status === "running") return true;
  // A fresh manual Pickle parks on `waiting_for_input` with nothing to stop yet.
  if (status === "waiting_for_input") return hasAnyMessage;
  return false;
}

/** A queue entry shows the user's own instruction, not the built prompt envelope. */
export function queueItemText(item: PickyQueueItem): string {
  const display = item.displayText?.trim();
  return display && display.length > 0 ? display : item.text;
}

/** Queued texts merged for the composer, in queue order. `null` when nothing is queued. */
export function queuedInputText(items: PickyQueueItem[]): string | null {
  const merged = items
    .map(queueItemText)
    .map((text) => text.trim())
    .filter((text) => text.length > 0)
    .join("\n\n");
  return merged.length > 0 ? merged : null;
}

/**
 * Draft after moving the queue back into the composer, as the HUD does before
 * aborting (`abortRestoringQueuedInputs`). `null` leaves the draft untouched.
 */
export function draftRestoringQueuedInputs(draft: string, items: PickyQueueItem[]): string | null {
  const queued = queuedInputText(items);
  if (queued === null) return null;
  return draft.length === 0 ? queued : `${draft}\n\n${queued}`;
}

/**
 * Transcript appended to the end of the draft, separated by one space unless
 * the draft is empty or already ends in whitespace. Never sends by itself.
 */
export function draftAppendingTranscript(draft: string, transcript: string): string {
  const incoming = transcript.trim();
  if (incoming.length === 0) return draft;
  if (draft.trim().length === 0) return incoming;
  const last = draft[draft.length - 1] ?? "";
  if (/\s/.test(last)) return draft + incoming;
  return `${draft} ${incoming}`;
}
