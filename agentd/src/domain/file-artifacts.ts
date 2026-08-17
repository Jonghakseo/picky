import { createHash } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { basename, extname, isAbsolute, resolve, sep } from "node:path";
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
}

export function fileArtifactFromWrite({ filePath, fileExistedBefore: _fileExistedBefore, now }: FileArtifactFromWriteInput): PickyArtifact | undefined {
  if (!filePath || !isFileArtifactPath(filePath)) return undefined;
  return fileArtifact(filePath, now);
}

export function extractFileArtifactsFromAnswerText(
  text: string,
  cwd: string,
  fileExists: (path: string) => boolean,
): PickyArtifact[] {
  const now = new Date().toISOString();
  const artifacts = new Map<string, PickyArtifact>();
  for (const candidate of filePathCandidates(text)) {
    const path = normalizeFileArtifactPath(candidate, cwd);
    if (!path || !isFileArtifactPath(path) || !fileExists(path)) continue;
    const artifact = fileArtifact(path, now);
    artifacts.set(artifact.id, artifact);
  }
  return [...artifacts.values()];
}

export function normalizeFileArtifactPath(path: string, cwd: string): string | undefined {
  const trimmed = trimPathPunctuation(path.trim());
  if (!trimmed || trimmed.includes("\0") || trimmed.startsWith("http://") || trimmed.startsWith("https://")) return undefined;
  const expanded = trimmed === "~" || trimmed.startsWith(`~${sep}`)
    ? `${homedir()}${trimmed.slice(1)}`
    : trimmed;
  return resolve(isAbsolute(expanded) ? expanded : cwd, expanded);
}

export function isFileArtifactPath(path: string, temporaryDirectories: readonly string[] = [tmpdir()]): boolean {
  const normalizedPath = resolve(path);
  const segments = normalizedPath.split(sep).filter(Boolean);
  if (segments.some((segment) => segment.startsWith("."))) return false;
  if (segments.some((segment) => FILE_ARTIFACT_EXCLUDED_DIRECTORIES.has(segment))) return false;
  if (temporaryDirectories.some((directory) => isWithinDirectory(normalizedPath, directory))) return false;
  return FILE_ARTIFACT_EXTENSIONS.has(extname(normalizedPath).slice(1).toLowerCase());
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

function filePathCandidates(text: string): string[] {
  const withoutUrls = text.replace(/https?:\/\/\S+/gi, "");
  const candidates = new Set<string>();
  for (const match of withoutUrls.matchAll(/`([^`\n]+)`/g)) candidates.add(match[1]!);
  for (const match of withoutUrls.matchAll(/(?:^|\s)(~\/[^\s,;:!?]+|\/{1}[^\s,;:!?]+|\.\.?\/[^\s,;:!?]+|(?:[\w@-]+\/)+[\w@.-]+\.[A-Za-z0-9]+)(?=$|[\s,;:!?])/gm)) candidates.add(match[1]!);
  for (const match of withoutUrls.matchAll(/(?:created|updated|wrote|saved|file|path)\s*[:=-]?\s*([^\s,;:!?]+\.[A-Za-z0-9]+)/gi)) candidates.add(match[1]!);
  return [...candidates];
}

function trimPathPunctuation(path: string): string {
  return path.replace(/[),.;:!?]+$/g, "");
}
