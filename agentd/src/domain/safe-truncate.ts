/**
 * Slice `text` to at most `end` UTF-16 code units, but back up by one if the
 * cut would split a surrogate pair. Without this guard, callers like
 * `titleFromContext` produce strings with a lone high surrogate when the
 * truncation point lands in the middle of an emoji, which breaks JSON
 * encoding and the rendered HUD title.
 */
export function sliceUtf16Safe(text: string, end: number): string {
  if (end <= 0) return "";
  if (end >= text.length) return text;
  const code = text.charCodeAt(end - 1);
  if (code >= 0xd800 && code <= 0xdbff) return text.slice(0, end - 1);
  return text.slice(0, end);
}
