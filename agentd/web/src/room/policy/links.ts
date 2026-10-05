/**
 * How a markdown link target is treated on the phone.
 *
 * The HUD opens `http(s)` links in the browser and local paths in Finder/the
 * editor. The phone has neither, so a web link leaves the app and a path opens
 * the shell's read-only preview. Anything else (mailto, javascript, data, a
 * bare word) stays plain text: a phone cannot act on it and a tappable link
 * that does nothing is worse than none.
 */
export type LinkTarget =
  | { kind: "external"; url: string }
  | { kind: "file"; path: string }
  | { kind: "plain" };

const WEB_SCHEME = /^https?:\/\//i;
/** Any other `scheme:` prefix, including `mailto:` and `javascript:`. */
const OTHER_SCHEME = /^[a-z][a-z0-9+.-]*:/i;

export function classifyLink(href: string): LinkTarget {
  const trimmed = href.trim();
  if (trimmed.length === 0) return { kind: "plain" };
  if (WEB_SCHEME.test(trimmed)) return { kind: "external", url: trimmed };
  if (trimmed.startsWith("//") || trimmed.startsWith("#")) return { kind: "plain" };
  if (OTHER_SCHEME.test(trimmed)) return { kind: "plain" };
  if (trimmed.startsWith("/") || trimmed.startsWith("~/") || trimmed === "~") {
    return { kind: "file", path: trimmed };
  }
  if (trimmed.startsWith("./") || trimmed.startsWith("../")) return { kind: "file", path: trimmed };
  // A relative path needs a separator or an extension to be one; `see here`
  // style anchors and bare words are not paths.
  if (/[^\s]+\.[A-Za-z0-9]{1,8}(:\d+)?$/.test(trimmed) || trimmed.includes("/")) {
    return { kind: "file", path: trimmed };
  }
  return { kind: "plain" };
}
