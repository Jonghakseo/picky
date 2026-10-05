/**
 * Which Mac files a session makes reachable from the phone
 * (docs/remote-pwa-implementation.md 2.3, "Mac files").
 *
 * The phone may open a file only because the conversation already mentions it.
 * That keeps `/api/files/*` from becoming a remote file browser: there is no
 * "list a directory" and no path the agent never produced.
 *
 * Pure, so the allowlist can be tested without a filesystem.
 */
/**
 * The parts of a conversation that can mention a file. A Pickle's session
 * satisfies it as is; the Picky room builds one from its transcript.
 */
export interface FileReferenceSource {
  cwd?: string;
  messages?: ReadonlyArray<{ text?: string }>;
  tools?: ReadonlyArray<{ argsPreview?: string }>;
  artifacts?: ReadonlyArray<{ path?: string }>;
  changedFiles?: ReadonlyArray<{ path?: string }>;
}

/** Tool arguments that name a file. Mirrors the HUD's tool-detail rendering. */
const PATH_ARGUMENT_KEYS = new Set(["path", "file_path", "filePath", "paths", "image", "images", "imagePath", "image_path"]);

/** `[label](target)`, including the `<...>` form and an optional title. */
const MARKDOWN_LINK = /\[(?:\\.|[^\]\\])*\]\(\s*(<[^>]*>|[^()\s]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/g;

export function extractFileReferences(session: FileReferenceSource): string[] {
  const references = new Set<string>();

  for (const message of session.messages ?? []) {
    if (message.text) collectMarkdownLinks(message.text, references);
  }
  for (const tool of session.tools ?? []) {
    if (tool.argsPreview) collectToolArgumentPaths(tool.argsPreview, references);
  }
  for (const artifact of session.artifacts ?? []) {
    if (artifact.path) references.add(artifact.path);
  }
  for (const changed of session.changedFiles ?? []) {
    if (changed.path) references.add(changed.path);
  }
  return [...references];
}

export function collectMarkdownLinks(text: string, into: Set<string>): void {
  for (const match of text.matchAll(MARKDOWN_LINK)) {
    const raw = match[1].startsWith("<") ? match[1].slice(1, -1) : match[1];
    const target = localLinkTarget(raw);
    if (target) into.add(target);
  }
}

/**
 * `http(s)` links open in the browser and anything else is plain text, so only
 * bare paths and `file:` URLs become file references.
 */
export function localLinkTarget(raw: string): string | undefined {
  const trimmed = raw.trim();
  if (!trimmed || trimmed.startsWith("#")) return undefined;
  if (trimmed.toLowerCase().startsWith("file://")) {
    try {
      return decodeURIComponent(new URL(trimmed).pathname);
    } catch {
      return undefined;
    }
  }
  if (/^[a-z][a-z0-9+.-]*:/i.test(trimmed)) return undefined;
  const [withoutFragment] = trimmed.split("#");
  const [path] = withoutFragment.split("?");
  return path || undefined;
}

function collectToolArgumentPaths(argsPreview: string, into: Set<string>): void {
  let parsed: unknown;
  try {
    parsed = JSON.parse(argsPreview);
  } catch {
    return;
  }
  walkArguments(parsed, into, 0);
}

function walkArguments(value: unknown, into: Set<string>, depth: number): void {
  if (depth > 6 || value === null || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) walkArguments(item, into, depth + 1);
    return;
  }
  for (const [key, item] of Object.entries(value)) {
    if (PATH_ARGUMENT_KEYS.has(key)) addPathValue(item, into);
    walkArguments(item, into, depth + 1);
  }
}

function addPathValue(value: unknown, into: Set<string>): void {
  if (typeof value === "string" && value.trim()) into.add(value.trim());
  if (!Array.isArray(value)) return;
  for (const item of value) {
    if (typeof item === "string" && item.trim()) into.add(item.trim());
  }
}
