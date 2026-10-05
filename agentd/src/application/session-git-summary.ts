import { execFile } from "node:child_process";
import { open } from "node:fs/promises";
import { basename, join } from "node:path";

/**
 * Git context for a Pickle's working folder: the numbers the HUD context line
 * shows (repository, branch, uncommitted and branch-wide line counts,
 * ahead/behind). The HUD computes the same values in Swift
 * (`Picky/Sessions/PickyGitRepositoryStatus.swift`); this copy exists for
 * clients that only reach the daemon, such as the remote gateway. Keep the
 * two in step: same git invocations, same untracked-line counting, same base
 * ref candidates.
 */
export interface SessionGitLineCounts {
  insertions: number;
  deletions: number;
}

export interface SessionGitSummary {
  isGitRepo: boolean;
  repositoryName?: string;
  /** Current branch, or the short commit hash when HEAD is detached. */
  branchName?: string;
  hasUncommittedChanges: boolean;
  /** Working tree against HEAD, untracked text lines included. */
  uncommitted: SessionGitLineCounts;
  /** Everything since the fork from the default branch. Absent without an origin base. */
  branch?: SessionGitLineCounts;
  aheadCount: number;
  behindCount: number;
}

/** Per-command budget, matching the HUD's background probe timeout. */
const GIT_TIMEOUT_MS = 5_000;
const GIT_MAX_BUFFER = 4 * 1024 * 1024;
export const UNTRACKED_FILES_SCANNED = 500;
export const UNTRACKED_FILE_MAX_BYTES = 1024 * 1024;
const BRANCH_BASE_REF_CANDIDATES = ["origin/HEAD", "origin/main", "origin/master"];

const NOT_A_REPOSITORY: SessionGitSummary = {
  isGitRepo: false,
  hasUncommittedChanges: false,
  uncommitted: { insertions: 0, deletions: 0 },
  aheadCount: 0,
  behindCount: 0,
};

export async function readSessionGitSummary(cwd: string | undefined): Promise<SessionGitSummary> {
  const directory = cwd?.trim();
  if (!directory) return NOT_A_REPOSITORY;

  const inside = await git(["rev-parse", "--is-inside-work-tree"], directory);
  if (inside?.exitCode !== 0 || inside.stdout.trim() !== "true") return NOT_A_REPOSITORY;
  const topLevel = (await git(["rev-parse", "--show-toplevel"], directory))?.stdout.trim();
  if (!topLevel) return NOT_A_REPOSITORY;

  const [origin, branchName, status, numstat, untrackedInsertions, position] = await Promise.all([
    gitOutput(["remote", "get-url", "origin"], directory),
    currentBranchName(directory),
    gitOutput(["status", "--porcelain"], directory),
    gitOutput(["diff", "--numstat", "HEAD", "--"], directory),
    countUntrackedTextLines(directory, topLevel),
    gitOutput(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], directory),
  ]);
  const originUrl = origin.trim();
  const uncommittedTracked = parseNumstat(numstat);
  const { ahead, behind } = parseAheadBehind(position);

  return {
    isGitRepo: true,
    repositoryName: repositoryNameFromRemote(originUrl) ?? basename(topLevel),
    branchName,
    hasUncommittedChanges: status.trim().length > 0,
    uncommitted: { insertions: uncommittedTracked.insertions + untrackedInsertions, deletions: uncommittedTracked.deletions },
    ...(originUrl ? await branchDiff(directory, untrackedInsertions) : {}),
    aheadCount: ahead,
    behindCount: behind,
  };
}

async function branchDiff(cwd: string, untrackedInsertions: number): Promise<{ branch?: SessionGitLineCounts }> {
  for (const ref of BRANCH_BASE_REF_CANDIDATES) {
    const base = (await gitOutput(["merge-base", ref, "HEAD"], cwd)).trim();
    if (!base) continue;
    const stats = parseNumstat(await gitOutput(["diff", "--numstat", base, "--"], cwd));
    return { branch: { insertions: stats.insertions + untrackedInsertions, deletions: stats.deletions } };
  }
  return {};
}

async function currentBranchName(cwd: string): Promise<string> {
  const branch = (await gitOutput(["branch", "--show-current"], cwd)).trim();
  if (branch) return branch;
  const hash = (await gitOutput(["rev-parse", "--short", "HEAD"], cwd)).trim();
  return hash || "detached";
}

/** `git diff --numstat` counts; binary files report `-` and are skipped. */
export function parseNumstat(output: string): SessionGitLineCounts {
  let insertions = 0;
  let deletions = 0;
  for (const line of output.split(/\r?\n/)) {
    const [added, removed] = line.split("\t");
    if (!added || !removed || !/^\d+$/.test(added) || !/^\d+$/.test(removed)) continue;
    insertions += Number(added);
    deletions += Number(removed);
  }
  return { insertions, deletions };
}

/** `rev-list --left-right --count @{upstream}...HEAD` prints `behind ahead`. */
export function parseAheadBehind(output: string): { ahead: number; behind: number } {
  const [behind, ahead] = output.trim().split(/\s+/);
  if (!behind || !ahead || !/^\d+$/.test(behind) || !/^\d+$/.test(ahead)) return { ahead: 0, behind: 0 };
  return { ahead: Number(ahead), behind: Number(behind) };
}

/** Last path segment of the origin URL without `.git`: `git@github.com:me/picky.git` is `picky`. */
export function repositoryNameFromRemote(url: string): string | undefined {
  const trimmed = url.trim().replace(/\/+$/, "").replace(/\.git$/i, "");
  const name = trimmed.split(/[/:]/).pop()?.trim();
  return name ? name : undefined;
}

async function countUntrackedTextLines(cwd: string, topLevel: string): Promise<number> {
  const raw = await gitOutput(["ls-files", "--others", "--exclude-standard", "-z"], cwd);
  const paths = raw.split("\0").filter(Boolean).slice(0, UNTRACKED_FILES_SCANNED);
  const counts = await Promise.all(paths.map((path) => textFileLineCount(join(topLevel, path))));
  return counts.reduce<number>((total, count) => total + (count ?? 0), 0);
}

/** Line count with `git diff --numstat` semantics; `undefined` for binary or unreadable files. */
async function textFileLineCount(path: string): Promise<number | undefined> {
  let handle;
  try {
    handle = await open(path, "r");
    const buffer = Buffer.alloc(UNTRACKED_FILE_MAX_BYTES);
    const { bytesRead } = await handle.read(buffer, 0, UNTRACKED_FILE_MAX_BYTES, 0);
    const content = buffer.subarray(0, bytesRead);
    if (content.includes(0)) return undefined;
    if (content.length === 0) return 0;
    let lines = 0;
    for (const byte of content) if (byte === 0x0a) lines += 1;
    return content[content.length - 1] === 0x0a ? lines : lines + 1;
  } catch {
    return undefined;
  } finally {
    await handle?.close();
  }
}

async function gitOutput(args: string[], cwd: string): Promise<string> {
  return (await git(args, cwd))?.stdout ?? "";
}

function git(args: string[], cwd: string): Promise<{ stdout: string; exitCode: number } | undefined> {
  return new Promise((resolve) => {
    execFile(
      "git",
      args,
      { cwd, timeout: GIT_TIMEOUT_MS, maxBuffer: GIT_MAX_BUFFER, env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" } },
      (error, stdout) => {
        if (error && typeof error.code !== "number") {
          resolve(undefined);
          return;
        }
        resolve({ stdout: String(stdout), exitCode: typeof error?.code === "number" ? error.code : 0 });
      },
    );
  });
}
