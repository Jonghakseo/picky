import { spawn } from "node:child_process";
import {
  SESSION_DIFF_MAX_FILES,
  SESSION_DIFF_PER_FILE_BYTES,
  SESSION_DIFF_TOTAL_BYTES,
  parseGitNumstatEntries,
  parseGitPatchSections,
  parseGitStatusPorcelain,
  truncateDiff,
  type GitNumstat,
  type GitStatusEntry,
  type SessionDiffFileStatus,
  type SessionDiffView,
} from "../domain/git-diff.js";

const UNTRACKED_DIFF_CONCURRENCY = 4;

export interface SessionDiffFile {
  path: string;
  status: SessionDiffFileStatus;
  renamedFrom?: string;
  additions: number;
  deletions: number;
  diff: string;
  truncated: boolean;
}

export interface SessionDiffResult {
  isGitRepo: boolean;
  files: SessionDiffFile[];
  filesTruncated: boolean;
  errorMessage?: string;
}

export interface ReadSessionDiffOptions {
  /** Test-only observation point for ensuring the file cap bounds Git process creation. */
  onGitSpawn?: () => void;
}

interface GitCommandResult {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  outputTruncated: boolean;
}

interface GitPatchResult {
  sections: Array<{ text: string; truncated: boolean }>;
  stderr: string;
  exitCode: number | null;
  outputTruncated: boolean;
}

export async function readSessionDiff(
  cwd: string | undefined,
  view: SessionDiffView,
  options: ReadSessionDiffOptions = {},
): Promise<SessionDiffResult> {
  if (!cwd?.trim()) return { isGitRepo: false, files: [], filesTruncated: false };

  try {
    const repository = await runGit(["rev-parse", "--is-inside-work-tree"], cwd, 1_024, options);
    if (repository.exitCode !== 0 || repository.stdout.trim() !== "true") return { isGitRepo: false, files: [], filesTruncated: false };

    const status = await runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd, SESSION_DIFF_TOTAL_BYTES, options);
    if (!status.outputTruncated && status.exitCode !== 0) return failure(status.stderr, true);

    const entries = parseGitStatusPorcelain(status.stdout, view);
    const selectedEntries = entries.slice(0, SESSION_DIFF_MAX_FILES);
    const trackedEntries = selectedEntries.filter((entry) => entry.status !== "untracked");
    const untrackedEntries = selectedEntries.filter((entry) => entry.status === "untracked");
    const trackedFiles = await readTrackedDiffs(cwd, view, trackedEntries, options);
    const remainingDiffBytes = Math.max(0, SESSION_DIFF_TOTAL_BYTES - trackedFiles.reduce((total, file) => total + Buffer.byteLength(file.diff), 0));
    const untrackedFiles = await readUntrackedDiffs(cwd, untrackedEntries, remainingDiffBytes, options);

    return {
      isGitRepo: true,
      files: mergeFilesInStatusOrder(selectedEntries, trackedFiles, untrackedFiles),
      filesTruncated: entries.length > selectedEntries.length,
    };
  } catch (error) {
    return { isGitRepo: false, files: [], filesTruncated: false, errorMessage: messageFor(error) };
  }
}

async function readTrackedDiffs(
  cwd: string,
  view: SessionDiffView,
  entries: GitStatusEntry[],
  options: ReadSessionDiffOptions,
): Promise<SessionDiffFile[]> {
  if (entries.length === 0) return [];

  const args = [
    "diff",
    "--no-ext-diff",
    "--no-color",
    "--find-renames",
    ...(view === "staged" ? ["--cached"] : []),
    "--",
    ...entries.flatMap((entry) => [entry.path, ...(entry.renamedFrom ? [entry.renamedFrom] : [])]),
  ];
  const [numstat, patch] = await Promise.all([
    runGit([...args.slice(0, 1), "--numstat", "-z", ...args.slice(1)], cwd, SESSION_DIFF_TOTAL_BYTES, options),
    runGitPatch([...args.slice(0, 1), "--patch", ...args.slice(1)], cwd, entries.length, options),
  ]);
  assertGitDiffSucceeded(numstat, "git diff --numstat");
  assertGitDiffSucceeded(patch, "git diff");

  const numstats = parseGitNumstatEntries(numstat.stdout);
  const countsByPath = new Map(numstats.map((entry) => [entry.path, entry]));
  const patchByPath = new Map(
    numstats.map((entry, index) => [
      entry.path,
      patch.sections[index] ?? { text: "", truncated: patch.outputTruncated },
    ]),
  );

  let remainingDiffBytes = SESSION_DIFF_TOTAL_BYTES;
  return entries.map((entry) => {
    const rawPatch = patchByPath.get(entry.path) ?? { text: "", truncated: patch.outputTruncated };
    const maxBytes = Math.min(SESSION_DIFF_PER_FILE_BYTES, remainingDiffBytes);
    const truncated = truncateDiff(rawPatch.text, maxBytes, rawPatch.truncated);
    remainingDiffBytes -= Buffer.byteLength(truncated.text);
    return makeFile(entry, countsByPath.get(entry.path), truncated.text, truncated.truncated);
  });
}

async function readUntrackedDiffs(
  cwd: string,
  entries: GitStatusEntry[],
  remainingDiffBytes: number,
  options: ReadSessionDiffOptions,
): Promise<SessionDiffFile[]> {
  let remaining = remainingDiffBytes;
  const budgets = entries.map(() => {
    const budget = Math.min(SESSION_DIFF_PER_FILE_BYTES, remaining);
    remaining -= budget;
    return budget;
  });

  return await mapWithConcurrency(entries, UNTRACKED_DIFF_CONCURRENCY, async (entry, index) => {
    const maxBytes = budgets[index] ?? 0;
    if (maxBytes === 0) return makeFile(entry, undefined, "", true);

    const result = await runGit(
      ["diff", "--no-index", "--no-ext-diff", "--no-color", "--numstat", "--patch", "-z", "--", "/dev/null", entry.path],
      cwd,
      maxBytes,
      options,
    );
    assertGitDiffSucceeded(result, "git diff --no-index");
    const counts = parseGitNumstatEntries(result.stdout)[0];
    const patch = parseGitPatchSections(result.stdout)[0] ?? "";
    const truncated = truncateDiff(patch, maxBytes, result.outputTruncated);
    return makeFile(entry, counts, truncated.text, truncated.truncated);
  });
}

function mergeFilesInStatusOrder(
  entries: GitStatusEntry[],
  trackedFiles: SessionDiffFile[],
  untrackedFiles: SessionDiffFile[],
): SessionDiffFile[] {
  const tracked = new Map(trackedFiles.map((file) => [file.path, file]));
  const untracked = new Map(untrackedFiles.map((file) => [file.path, file]));
  return entries.flatMap((entry) => [tracked.get(entry.path) ?? untracked.get(entry.path)].filter((file): file is SessionDiffFile => file !== undefined));
}

function makeFile(entry: GitStatusEntry, counts: GitNumstat | undefined, diff: string, truncated: boolean): SessionDiffFile {
  return {
    path: entry.path,
    status: entry.status,
    ...(entry.renamedFrom ? { renamedFrom: entry.renamedFrom } : {}),
    additions: counts?.additions ?? 0,
    deletions: counts?.deletions ?? 0,
    diff,
    truncated,
  };
}

function assertGitDiffSucceeded(result: Pick<GitCommandResult | GitPatchResult, "stderr" | "exitCode" | "outputTruncated">, command: string): void {
  // `git diff --no-index` returns 1 when it finds differences. A process stopped after
  // reaching the explicit output cap is also a successful partial result.
  if (result.outputTruncated || result.exitCode === 0 || result.exitCode === 1) return;
  throw new Error(`${command} failed: ${result.stderr.trim() || result.exitCode}`);
}

async function mapWithConcurrency<Value, Result>(
  values: Value[],
  concurrency: number,
  transform: (value: Value, index: number) => Promise<Result>,
): Promise<Result[]> {
  const results = new Array<Result>(values.length);
  let nextIndex = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (nextIndex < values.length) {
      const index = nextIndex++;
      results[index] = await transform(values[index]!, index);
    }
  }));
  return results;
}

async function runGitPatch(
  args: string[],
  cwd: string,
  expectedSectionCount: number,
  options: ReadSessionDiffOptions,
): Promise<GitPatchResult> {
  return await new Promise<GitPatchResult>((resolve, reject) => {
    options.onGitSpawn?.();
    const child = spawn("git", args, {
      cwd,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
    });
    const sections: Array<{ chunks: Buffer[]; bytes: number; truncated: boolean }> = [];
    const stderr: Buffer[] = [];
    const header = Buffer.from("diff --git ");
    let current: { chunks: Buffer[]; bytes: number; truncated: boolean } | undefined;
    let globalBytes = 0;
    let atLineStart = true;
    let headerCandidate: number[] = [];
    let outputTruncated = false;

    const append = (chunk: Buffer): void => {
      if (!current || chunk.length === 0) return;
      const remaining = Math.min(SESSION_DIFF_PER_FILE_BYTES - current.bytes, SESSION_DIFF_TOTAL_BYTES - globalBytes);
      if (remaining <= 0) {
        current.truncated = true;
        if (globalBytes >= SESSION_DIFF_TOTAL_BYTES) outputTruncated = true;
        return;
      }
      const retained = chunk.subarray(0, remaining);
      current.chunks.push(retained);
      current.bytes += retained.length;
      globalBytes += retained.length;
      if (retained.length < chunk.length) {
        current.truncated = true;
        if (globalBytes >= SESSION_DIFF_TOTAL_BYTES) outputTruncated = true;
      }
    };

    const beginSection = (): void => {
      current = { chunks: [], bytes: 0, truncated: false };
      sections.push(current);
    };

    const consume = (chunk: Buffer): void => {
      let index = 0;
      while (index < chunk.length) {
        if (atLineStart) {
          const byte = chunk[index]!;
          headerCandidate.push(byte);
          index += 1;
          const candidateIndex = headerCandidate.length - 1;
          if (byte === header[candidateIndex]) {
            if (headerCandidate.length === header.length) {
              beginSection();
              append(Buffer.from(headerCandidate));
              headerCandidate = [];
              atLineStart = false;
            }
            continue;
          }
          append(Buffer.from(headerCandidate));
          atLineStart = headerCandidate.at(-1) === 0x0A;
          headerCandidate = [];
          continue;
        }

        const newline = chunk.indexOf(0x0A, index);
        const end = newline === -1 ? chunk.length : newline + 1;
        append(chunk.subarray(index, end));
        atLineStart = newline !== -1;
        index = end;
      }
    };

    child.stdout.on("data", (chunk: Buffer) => {
      if (outputTruncated) return;
      consume(chunk);
      // Once the retained global budget is full, every remaining section would
      // be empty and marked truncated, so no more output can improve the result.
      if (globalBytes >= SESSION_DIFF_TOTAL_BYTES) {
        outputTruncated = true;
        child.kill();
      }
    });
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      if (headerCandidate.length > 0) append(Buffer.from(headerCandidate));
      resolve({
        sections: sections.map((section) => ({
          text: Buffer.concat(section.chunks).toString("utf8"),
          truncated: section.truncated,
        })),
        stderr: Buffer.concat(stderr).toString("utf8"),
        exitCode,
        outputTruncated,
      });
    });
  });
}

async function runGit(args: string[], cwd: string, maxOutputBytes: number, options: ReadSessionDiffOptions): Promise<GitCommandResult> {
  return await new Promise<GitCommandResult>((resolve, reject) => {
    options.onGitSpawn?.();
    const child = spawn("git", args, {
      cwd,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
    });
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
  return { isGitRepo, files: [], filesTruncated: false, errorMessage: stderr.trim() || "git command failed" };
}

function messageFor(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
