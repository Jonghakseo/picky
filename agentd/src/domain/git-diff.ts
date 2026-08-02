export const SESSION_DIFF_PER_FILE_BYTES = 200 * 1024;
export const SESSION_DIFF_TOTAL_BYTES = 2 * 1024 * 1024;
export const SESSION_DIFF_MAX_FILES = 200;

export type SessionDiffView = "unstaged" | "staged";
export type SessionDiffFileStatus = "added" | "modified" | "deleted" | "renamed" | "untracked";

export interface GitStatusEntry {
  path: string;
  status: SessionDiffFileStatus;
  renamedFrom?: string;
}

export interface GitNumstat {
  additions: number;
  deletions: number;
}

export interface GitNumstatEntry extends GitNumstat {
  path: string;
}

export function parseGitStatusPorcelain(output: string, view: SessionDiffView): GitStatusEntry[] {
  const records = output.split("\0");
  const entries: GitStatusEntry[] = [];

  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (!record) continue;

    const indexStatus = record[0] ?? " ";
    const worktreeStatus = record[1] ?? " ";
    const path = record.slice(3);
    const isUntracked = indexStatus === "?" && worktreeStatus === "?";
    if (isUntracked) {
      if (view === "unstaged") entries.push({ path, status: "untracked" });
      continue;
    }

    const hasRename = indexStatus === "R" || indexStatus === "C" || worktreeStatus === "R" || worktreeStatus === "C";
    const renamedFrom = hasRename ? records[++index] || undefined : undefined;
    const statusCode = view === "staged" ? indexStatus : worktreeStatus;
    if (statusCode === " ") continue;
    const isRename = statusCode === "R" || statusCode === "C";
    entries.push({ path, status: statusFromGitCode(statusCode), ...(isRename && renamedFrom ? { renamedFrom } : {}) });
  }

  return entries;
}

export function parseGitNumstat(output: string): GitNumstat {
  const entry = parseGitNumstatEntries(output)[0];
  return entry ? { additions: entry.additions, deletions: entry.deletions } : { additions: 0, deletions: 0 };
}

/** Parses both normal and rename/copy `git diff --numstat -z` records. */
export function parseGitNumstatEntries(output: string): GitNumstatEntry[] {
  const records = output.split("\0");
  const entries: GitNumstatEntry[] = [];

  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (!record) continue;
    const firstTab = record.indexOf("\t");
    const secondTab = firstTab === -1 ? -1 : record.indexOf("\t", firstTab + 1);
    if (firstTab === -1 || secondTab === -1) continue;
    const additions = record.slice(0, firstTab);
    const deletions = record.slice(firstTab + 1, secondTab);
    const path = record.slice(secondTab + 1);

    // With `-z`, rename/copy records use an empty pathname followed by old and new paths.
    const resolvedPath = (path || records[index += 2] || "").replace(/\n$/, "");
    if (!resolvedPath) continue;
    entries.push({
      path: resolvedPath,
      additions: parseNumstatCount(additions),
      deletions: parseNumstatCount(deletions),
    });
  }

  return entries;
}

/** Splits a batch patch into its per-file sections without inspecting file paths. */
export function parseGitPatchSections(output: string): string[] {
  const patchStart = output.indexOf("diff --git ");
  if (patchStart < 0) return [];
  return output
    .slice(patchStart)
    .split(/(?=^diff --git )/m)
    .filter((section) => section.startsWith("diff --git "));
}

export function truncateDiff(text: string, maxBytes: number, forceTruncated = false): { text: string; truncated: boolean } {
  const truncated = forceTruncated || Buffer.byteLength(text) > maxBytes;
  if (!truncated) return { text, truncated: false };
  return { text: truncateUtf8(text, maxBytes), truncated: true };
}

function statusFromGitCode(statusCode: string): SessionDiffFileStatus {
  if (statusCode === "A") return "added";
  if (statusCode === "D") return "deleted";
  if (statusCode === "R" || statusCode === "C") return "renamed";
  return "modified";
}

function parseNumstatCount(value: string | undefined): number {
  if (!value || value === "-") return 0;
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
}

function truncateUtf8(text: string, maxBytes: number): string {
  let end = 0;
  let usedBytes = 0;
  for (const character of text) {
    const bytes = Buffer.byteLength(character);
    if (usedBytes + bytes > maxBytes) break;
    usedBytes += bytes;
    end += character.length;
  }
  return text.slice(0, end);
}
