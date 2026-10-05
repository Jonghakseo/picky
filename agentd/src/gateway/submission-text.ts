/**
 * TypeScript port of `PickyConversationComposerView.submissionText`
 * (`Picky/HUD/Conversation/PickyConversationComposerView+Policy.swift`).
 *
 * The phone's uploads land on the Mac as files, so a message with attachments
 * is the draft followed by their paths. The leading space matters: without it a
 * draft starting with `!` would hit agentd's shell shortcut and the appended
 * paths would become arguments to whatever the user typed.
 */
export function submissionTextWithAttachments(draft: string, attachmentPaths: readonly string[]): string {
  const trimmedDraft = draft.trim();
  const merged = appendAttachmentPaths(trimmedDraft, attachmentPaths);
  if (attachmentPaths.length > 0 && merged.startsWith("!")) return ` ${merged}`;
  return merged;
}

/** Mirror of `draftText(afterAppendingDroppedFilePaths:to:)`. */
export function appendAttachmentPaths(draft: string, attachmentPaths: readonly string[]): string {
  const normalized = attachmentPaths.map((path) => path.trim()).filter((path) => path.length > 0);
  if (normalized.length === 0) return draft;
  const dropped = normalized.join("\n");
  if (draft.trim().length === 0) return dropped;
  if (draft.endsWith("\n")) return draft + dropped;
  return `${draft}\n${dropped}`;
}

/** Mirror of `bashMode(in:)`; used for the audit log's shell-command field. */
export function bashCommandIn(text: string): string | undefined {
  const trimmed = text.trim();
  if (!trimmed.startsWith("!")) return undefined;
  const isPrivate = trimmed.startsWith("!!");
  const command = trimmed.slice(isPrivate ? 2 : 1).trim();
  return command.length > 0 ? command : undefined;
}
