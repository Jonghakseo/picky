/**
 * Reading a Mac file the phone is allowed to see
 * (docs/remote-pwa-implementation.md 2.3, "Mac files").
 *
 * Resolution copies the HUD's link handler
 * (`Picky/HUD/Conversation/Bubbles/PickyMarkdownLinkHandler.swift`): `~` is
 * home, a relative path is relative to the session `cwd`, then standardize.
 * The decision is made on `realpath` of both sides, so a symlink planted inside
 * `cwd` resolves to its target and only matches if the conversation already
 * referenced that target.
 */
import { open, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import type { PickyAgentSession } from "../protocol.js";
import { REMOTE_LIMITS } from "../remote/constants.js";
import type { RemoteFileKind } from "../remote/protocol.js";
import { extractFileReferences } from "./file-references.js";

export const MAX_PREVIEW_IMAGE_BYTES = 20 * 1024 * 1024;

export interface FileAccessContext {
  session: PickyAgentSession;
  home?: string;
}

export type FileAccessResult =
  | { ok: true; path: string }
  | { ok: false; reason: "unresolved" | "notReferenced" | "missing" };

export function expandHome(path: string, home: string): string {
  if (path === "~") return home;
  if (path.startsWith("~/")) return join(home, path.slice(2));
  return path;
}

/** Absolute, standardized path for a link target, before any realpath check. */
export function resolveSessionPath(raw: string, cwd: string | undefined, home: string): string | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  const expanded = expandHome(trimmed, home);
  if (isAbsolute(expanded)) return resolve(expanded);
  if (!cwd) return undefined;
  const base = expandHome(cwd, home);
  if (!isAbsolute(base)) return undefined;
  return resolve(base, expanded);
}

export async function resolveReferencedFile(
  requestedPath: string,
  { session, home = homedir() }: FileAccessContext,
): Promise<FileAccessResult> {
  const resolved = resolveSessionPath(requestedPath, session.cwd, home);
  if (!resolved) return { ok: false, reason: "unresolved" };

  const realRequested = await realpath(resolved).catch(() => undefined);
  if (!realRequested) return { ok: false, reason: "missing" };

  for (const reference of extractFileReferences(session)) {
    const candidate = resolveSessionPath(reference, session.cwd, home);
    if (!candidate) continue;
    const realReference = await realpath(candidate).catch(() => undefined);
    if (realReference && realReference === realRequested) return { ok: true, path: await standardize(realRequested) };
  }
  return { ok: false, reason: "notReferenced" };
}

/**
 * Mirror of Foundation `standardizingPath`, which drops a leading `/private`
 * when the shorter name points at the same file. `realpath` is right for the
 * decision but wrong for the answer: on macOS it turns `/tmp/report.md` into
 * `/private/tmp/report.md`, so the phone would show a path the HUD never shows
 * and the user could not paste back into the Mac.
 */
async function standardize(path: string): Promise<string> {
  if (!path.startsWith("/private/")) return path;
  const shortened = path.slice("/private".length);
  const resolved = await realpath(shortened).catch(() => undefined);
  return resolved === path ? shortened : path;
}

const IMAGE_SIGNATURES: Array<{ mime: string; test: (bytes: Buffer) => boolean }> = [
  { mime: "image/png", test: (b) => b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) },
  { mime: "image/jpeg", test: (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  { mime: "image/gif", test: (b) => b.subarray(0, 6).toString("latin1") === "GIF87a" || b.subarray(0, 6).toString("latin1") === "GIF89a" },
  { mime: "image/webp", test: (b) => b.subarray(0, 4).toString("latin1") === "RIFF" && b.subarray(8, 12).toString("latin1") === "WEBP" },
  { mime: "image/heic", test: (b) => b.subarray(4, 8).toString("latin1") === "ftyp" && /heic|heix|mif1|msf1/.test(b.subarray(8, 12).toString("latin1")) },
];

/** Magic bytes, never the file extension: the phone renders what this says. */
export function sniffImageMime(bytes: Buffer): string | undefined {
  return IMAGE_SIGNATURES.find((signature) => signature.test(bytes))?.mime;
}

export function fileKindFor(path: string, head: Buffer): RemoteFileKind {
  if (sniffImageMime(head)) return "image";
  if (head.subarray(0, 5).toString("latin1") === "%PDF-") return "pdf";
  const lower = path.toLowerCase();
  if (lower.endsWith(".svg")) return "svg";
  if (lower.endsWith(".html") || lower.endsWith(".htm")) return "html";
  if (lower.endsWith(".md") || lower.endsWith(".markdown")) return "markdown";
  return head.includes(0) ? "binary" : "text";
}

export const PREVIEW_CONTENT_TYPES: Readonly<Record<RemoteFileKind, string>> = Object.freeze({
  text: "text/plain; charset=utf-8",
  markdown: "text/markdown; charset=utf-8",
  image: "application/octet-stream",
  pdf: "application/pdf",
  html: "text/html; charset=utf-8",
  svg: "image/svg+xml",
  binary: "application/octet-stream",
  directory: "application/json; charset=utf-8",
});

export interface FileDescription {
  kind: RemoteFileKind;
  name: string;
  path: string;
  size: number;
  modifiedAt?: string;
  text?: string;
  truncated?: boolean;
}

export async function describeFile(path: string): Promise<FileDescription> {
  const info = await stat(path);
  const name = path.split("/").pop() ?? path;
  if (info.isDirectory()) {
    return { kind: "directory", name, path, size: 0, modifiedAt: info.mtime.toISOString() };
  }

  const head = await readHead(path, 512);
  const kind = fileKindFor(path, head);
  const description: FileDescription = {
    kind,
    name,
    path,
    size: info.size,
    modifiedAt: info.mtime.toISOString(),
  };
  if (kind === "text" || kind === "markdown") {
    const limit = REMOTE_LIMITS.previewTextBytes;
    description.text = (await readHead(path, limit)).toString("utf8");
    description.truncated = info.size > limit;
  }
  return description;
}

/** Never pulls a whole file into memory just to classify or preview it. */
async function readHead(path: string, bytes: number): Promise<Buffer> {
  const handle = await open(path, "r");
  try {
    const buffer = Buffer.alloc(bytes);
    const { bytesRead } = await handle.read(buffer, 0, bytes, 0);
    return buffer.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}
