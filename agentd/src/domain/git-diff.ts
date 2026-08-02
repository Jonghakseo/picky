export const SESSION_DIFF_PER_FILE_BYTES = 200 * 1024;
export const SESSION_DIFF_TOTAL_BYTES = 2 * 1024 * 1024;
export const DIFF_TRUNCATION_MARKER = "\n[diff truncated]\n";

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
    entries.push({ path, status: statusFromGitCode(statusCode, false), ...(isRename && renamedFrom ? { renamedFrom } : {}) });
  }

  return entries;
}

export function parseGitNumstat(output: string): GitNumstat {
  const line = output.split("\n", 1)[0] ?? "";
  const [additions, deletions] = line.split("\t", 3);
  return { additions: parseNumstatCount(additions), deletions: parseNumstatCount(deletions) };
}

export function truncateDiff(text: string, maxBytes: number, forceTruncated = false): { text: string; truncated: boolean } {
  const markerBytes = Buffer.byteLength(DIFF_TRUNCATION_MARKER);
  const exceedsLimit = Buffer.byteLength(text) > maxBytes;
  const truncated = forceTruncated || exceedsLimit;
  if (!truncated) return { text, truncated: false };
  if (maxBytes <= markerBytes) return { text: "", truncated: true };

  return { text: `${truncateUtf8(text, maxBytes - markerBytes)}${DIFF_TRUNCATION_MARKER}`, truncated: true };
}

function statusFromGitCode(statusCode: string, isUntracked: boolean): SessionDiffFileStatus {
  if (isUntracked) return "untracked";
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
