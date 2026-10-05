/**
 * Stand-in for `src/room/markdown/Markdown.tsx` (the conversation UI's renderer)
 * while that file does not exist. `web/build.mjs` resolves `picky:markdown` to
 * the real one as soon as it lands.
 *
 * Plain text, never HTML: markdown in a file preview comes from whatever the
 * agent read, and this origin's cookie is a shell key.
 */
import type { JSX } from "preact";
import type { MarkdownProps } from "../room/contract";

export function Markdown({ text }: MarkdownProps): JSX.Element {
  return <pre class="preview-text">{text}</pre>;
}
