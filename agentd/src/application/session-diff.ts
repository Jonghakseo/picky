import { spawn } from "node:child_process";
import {
  SESSION_DIFF_PER_FILE_BYTES,
  SESSION_DIFF_TOTAL_BYTES,
  parseGitNumstat,
  parseGitStatusPorcelain,
  truncateDiff,
  type SessionDiffFileStatus,
  type SessionDiffView,
} from "../domain/git-diff.js";

export interface SessionDiffFile {
  path: string;
  status: SessionDiffFileStatus;
  renamedFrom?: string;
  additions: number;
  deletions: number;
  diff: string;
}

export interface SessionDiffResult {
  isGitRepo: boolean;
  files: SessionDiffFile[];
  errorMessage?: string;
}

interface GitCommandResult {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  outputTruncated: boolean;
}

export async function readSessionDiff(cwd: string | undefined, view: SessionDiffView): Promise<SessionDiffResult> {
  if (!cwd?.trim()) return { isGitRepo: false, files: [] };

  try {
    const repository = await runGit(["rev-parse", "--is-inside-work-tree"], cwd, 1_024);
    if (repository.exitCode !== 0 || repository.stdout.trim() !== "true") return { isGitRepo: false, files: [] };

    const status = await runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd, SESSION_DIFF_TOTAL_BYTES);
    if (status.exitCode !== 0) return failure(status.stderr, true);

    const entries = parseGitStatusPorcelain(status.stdout, view);
    const files: SessionDiffFile[] = [];
    let remainingDiffBytes = SESSION_DIFF_TOTAL_BYTES;
    for (const entry of entries) {
      const file = await readFileDiff(cwd, view, entry, remainingDiffBytes);
      files.push(file);
      remainingDiffBytes -= Buffer.byteLength(file.diff);
    }
    return { isGitRepo: true, files };
  } catch (error) {
    return { isGitRepo: false, files: [], errorMessage: messageFor(error) };
  }
}

async function readFileDiff(
  cwd: string,
  view: SessionDiffView,
  entry: ReturnType<typeof parseGitStatusPorcelain>[number],
  remainingDiffBytes: number,
): Promise<SessionDiffFile> {
  const maxDiffBytes = Math.min(SESSION_DIFF_PER_FILE_BYTES, remainingDiffBytes);
  const diff = maxDiffBytes > 0
    ? await runGit(diffArgs(view, entry.status, entry.path), cwd, maxDiffBytes - markerByteBudget(maxDiffBytes))
    : undefined;
  if (diff && diff.exitCode !== 0 && diff.exitCode !== 1) throw new Error(`git diff failed: ${diff.stderr.trim() || diff.exitCode}`);

  const numstat = await runGit(numstatArgs(view, entry.status, entry.path), cwd, 64 * 1024);
  if (numstat.exitCode !== 0 && numstat.exitCode !== 1) throw new Error(`git diff --numstat failed: ${numstat.stderr.trim() || numstat.exitCode}`);

  const truncated = diff
    ? truncateDiff(diff.stdout, maxDiffBytes, diff.outputTruncated)
    : { text: "", truncated: false };
  const counts = parseGitNumstat(numstat.stdout);
  return {
    path: entry.path,
    status: entry.status,
    ...(entry.renamedFrom ? { renamedFrom: entry.renamedFrom } : {}),
    ...counts,
    diff: truncated.text,
  };
}

function diffArgs(view: SessionDiffView, status: SessionDiffFileStatus, path: string): string[] {
  if (status === "untracked") return ["diff", "--no-index", "--no-ext-diff", "--no-color", "--patch", "--", "/dev/null", path];
  return ["diff", "--no-ext-diff", "--no-color", "--patch", "--find-renames", ...(view === "staged" ? ["--cached"] : []), "--", path];
}

function numstatArgs(view: SessionDiffView, status: SessionDiffFileStatus, path: string): string[] {
  if (status === "untracked") return ["diff", "--no-index", "--no-ext-diff", "--numstat", "--", "/dev/null", path];
  return ["diff", "--no-ext-diff", "--numstat", "--find-renames", ...(view === "staged" ? ["--cached"] : []), "--", path];
}

function markerByteBudget(maxDiffBytes: number): number {
  return Math.min(maxDiffBytes, Buffer.byteLength("\n[diff truncated]\n"));
}

async function runGit(args: string[], cwd: string, maxOutputBytes: number): Promise<GitCommandResult> {
  return await new Promise<GitCommandResult>((resolve, reject) => {
    const child = spawn("git", args, { cwd, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let stdoutBytes = 0;
    let outputTruncated = false;

    child.stdout.on("data", (chunk: Buffer) => {
      if (outputTruncated) return;
      const remaining = maxOutputBytes - stdoutBytes;
      if (chunk.length <= remaining) {
        stdout.push(chunk);
        stdoutBytes += chunk.length;
        return;
      }
      if (remaining > 0) stdout.push(chunk.subarray(0, remaining));
      outputTruncated = true;
      child.kill();
    });
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      resolve({
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
        exitCode,
        outputTruncated,
      });
    });
  });
}

function failure(stderr: string, isGitRepo: boolean): SessionDiffResult {
  return { isGitRepo, files: [], errorMessage: stderr.trim() || "git command failed" };
}

function messageFor(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
