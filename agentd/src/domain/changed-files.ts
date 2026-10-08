import { isAbsolute, relative } from "node:path";
import type { PickyAgentSession } from "../protocol.js";

type PickyChangedFile = PickyAgentSession["changedFiles"][number];

export function mergeChangedFiles(existing: PickyAgentSession["changedFiles"], incoming: PickyAgentSession["changedFiles"]): PickyAgentSession["changedFiles"] {
  const byPath = new Map(existing.map((file) => [file.path, file]));
  for (const file of incoming) byPath.set(file.path, file);
  return [...byPath.values()];
}

export interface FileMutation {
  /** Absolute path the successful `write`/`edit` tool call targeted. */
  filePath: string;
  /** `false` only when the call created the file. */
  fileExistedBefore?: boolean;
}

/**
 * Records a file the agent changed through a successful `write`/`edit` tool call, so the
 * changed-file list no longer depends on the agent spelling out `Changed file:` lines.
 * Paths inside the session cwd are stored relative to it, matching the git-status style
 * the explicit lines use, so both sources collapse onto one entry.
 */
export function mergeToolFileMutation(existing: PickyAgentSession["changedFiles"], mutation: FileMutation, cwd: string | undefined): PickyAgentSession["changedFiles"] {
  const path = changedFilePath(mutation.filePath, cwd);
  const previous = existing.find((file) => file.path === path);
  // A file created earlier in the session stays "added" after later edits; an explicit
  // entry the agent already wrote keeps its status and summary.
  if (previous) return existing;
  const incoming: PickyChangedFile = { path, status: mutation.fileExistedBefore === false ? "A" : "M" };
  return [...existing, incoming];
}

function changedFilePath(filePath: string, cwd: string | undefined): string {
  if (!cwd || !isAbsolute(cwd)) return filePath;
  const relativePath = relative(cwd, filePath);
  if (!relativePath || relativePath.startsWith("..") || isAbsolute(relativePath)) return filePath;
  return relativePath;
}
