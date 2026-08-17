import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, extname, resolve, sep } from "node:path";
import type { PickyArtifact } from "../protocol.js";

export const FILE_ARTIFACT_EXTENSIONS = new Set([
  "md",
  "markdown",
  "csv",
  "tsv",
  "json",
  "png",
  "jpg",
  "jpeg",
  "svg",
  "gif",
  "webp",
  "pdf",
  "html",
  "htm",
  "xlsx",
  "xls",
  "pptx",
  "docx",
  "txt",
]);

export const FILE_ARTIFACT_EXCLUDED_DIRECTORIES = new Set(["node_modules", "build", "dist", "out", "tmp", "temp"]);

export interface FileArtifactFromWriteInput {
  filePath?: string;
  fileExistedBefore?: boolean;
  now: string;
  existingUpdatedAt?: string;
}

export function fileArtifactFromWrite({ filePath, fileExistedBefore: _fileExistedBefore, now, existingUpdatedAt }: FileArtifactFromWriteInput): PickyArtifact | undefined {
  if (!filePath || !isFileArtifactPath(filePath)) return undefined;
  return fileArtifact(filePath, strictlyMonotonicUpdatedAt(now, existingUpdatedAt));
}

/** Keeps an existing artifact visibly new even when Date.now repeats or moves backward. */
export function strictlyMonotonicUpdatedAt(candidate: string, existing?: string): string {
  if (!existing) return candidate;
  const candidateMillis = Date.parse(candidate);
  const existingMillis = Date.parse(existing);
  if (!Number.isFinite(candidateMillis) || !Number.isFinite(existingMillis) || candidateMillis > existingMillis) return candidate;
  return new Date(existingMillis + 1).toISOString();
}

export function isFileArtifactPath(path: string, temporaryDirectories: readonly string[] = systemTemporaryDirectoryAliases()): boolean {
  const normalizedPath = resolve(path);
  const segments = normalizedPath.split(sep).filter(Boolean);
  if (segments.some((segment) => segment.startsWith("."))) return false;
  if (segments.some((segment) => FILE_ARTIFACT_EXCLUDED_DIRECTORIES.has(segment))) return false;
  if (temporaryDirectories.some((directory) => isWithinDirectory(normalizedPath, directory))) return false;
  return FILE_ARTIFACT_EXTENSIONS.has(extname(normalizedPath).slice(1).toLowerCase());
}

function systemTemporaryDirectoryAliases(): string[] {
  const aliases = new Set<string>();
  for (const directory of [tmpdir(), ...lexicalTemporaryAliases(tmpdir())]) {
    aliases.add(resolve(directory));
    const canonical = safeRealpath(directory);
    if (canonical) aliases.add(resolve(canonical));
  }
  return [...aliases];
}

function lexicalTemporaryAliases(directory: string): string[] {
  if (directory === "/var" || directory.startsWith("/var/")) return [`/private${directory}`];
  if (directory === "/private/var" || directory.startsWith("/private/var/")) return [directory.slice("/private".length)];
  return [];
}

function safeRealpath(path: string): string | undefined {
  try {
    return realpathSync.native(path);
  } catch {
    return undefined;
  }
}

function isWithinDirectory(path: string, directory: string): boolean {
  const normalizedDirectory = resolve(directory);
  return path === normalizedDirectory || path.startsWith(`${normalizedDirectory}${sep}`);
}

function fileArtifact(path: string, updatedAt: string): PickyArtifact {
  return {
    id: `file-${hashPath(path)}`,
    kind: "file",
    title: basename(path),
    path,
    updatedAt,
  };
}

function hashPath(path: string): string {
  return createHash("sha1").update(path).digest("hex").slice(0, 12);
}
