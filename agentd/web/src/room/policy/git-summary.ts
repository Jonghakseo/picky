/**
 * The work panel's Git summary: the phone's copy of the HUD context line.
 *
 * Swift sources: `PickyConversationContextSummaryPolicy`,
 * `PickyConversationUncommittedDiffPolicy`, and `PickyGitChangeMetricsPresentation`
 * in `Picky/HUD/Conversation/PickyConversationContextLineView.swift`. The data is
 * the daemon's `sessionGitSummaryResult`, which mirrors
 * `Picky/Sessions/PickyGitRepositoryStatus.swift`.
 */
export interface GitLineCounts {
  insertions: number;
  deletions: number;
}

export interface GitSummary {
  isGitRepo: boolean;
  repositoryName?: string;
  branchName?: string;
  hasUncommittedChanges: boolean;
  uncommitted: GitLineCounts;
  branch?: GitLineCounts;
  aheadCount: number;
  behindCount: number;
}

function count(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}

function lineCounts(value: unknown): GitLineCounts | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  return { insertions: count(record.insertions), deletions: count(record.deletions) };
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

/** Tolerates an older or newer daemon: anything unreadable becomes "not a repository". */
export function parseGitSummary(data: unknown): GitSummary {
  const record = (data ?? {}) as Record<string, unknown>;
  const repositoryName = text(record.repositoryName);
  const branchName = text(record.branchName);
  const branch = lineCounts(record.branch);
  return {
    isGitRepo: record.isGitRepo === true,
    ...(repositoryName ? { repositoryName } : {}),
    ...(branchName ? { branchName } : {}),
    hasUncommittedChanges: record.hasUncommittedChanges === true,
    uncommitted: lineCounts(record.uncommitted) ?? { insertions: 0, deletions: 0 },
    ...(branch ? { branch } : {}),
    aheadCount: count(record.aheadCount),
    behindCount: count(record.behindCount),
  };
}

export interface GitMetricPair {
  /** `+19`, absent when zero. */
  insertions?: string;
  /** `-3`, absent when zero. */
  deletions?: string;
}

export interface GitSummaryPresentation {
  repositoryName?: string;
  /** Branch with `*` only when the tree is dirty but no line count shows it. */
  branchLabel?: string;
  /** Whole branch since its fork; the uncommitted pair when there is no base to measure from. */
  total?: { pair: GitMetricPair; isBranch: boolean };
  /** Uncommitted subset, shown only beside a branch total it differs from. */
  uncommitted?: GitMetricPair;
  ahead: number;
  behind: number;
}

function pair(counts: GitLineCounts): GitMetricPair | undefined {
  const next: GitMetricPair = {
    ...(counts.insertions > 0 ? { insertions: `+${counts.insertions}` } : {}),
    ...(counts.deletions > 0 ? { deletions: `-${counts.deletions}` } : {}),
  };
  return next.insertions || next.deletions ? next : undefined;
}

function sameCounts(left: GitLineCounts, right: GitLineCounts): boolean {
  return left.insertions === right.insertions && left.deletions === right.deletions;
}

export function gitSummaryPresentation(summary: GitSummary): GitSummaryPresentation | undefined {
  if (!summary.isGitRepo) return undefined;
  const uncommittedPair = pair(summary.uncommitted);
  const branchLabel = summary.branchName
    ? summary.hasUncommittedChanges && !uncommittedPair
      ? `${summary.branchName}*`
      : summary.branchName
    : undefined;
  const branchPair = summary.branch ? pair(summary.branch) : undefined;
  const total = branchPair
    ? { pair: branchPair, isBranch: true }
    : !summary.branch && uncommittedPair
      ? { pair: uncommittedPair, isBranch: false }
      : undefined;
  const showUncommitted = Boolean(branchPair && uncommittedPair && summary.branch && !sameCounts(summary.branch, summary.uncommitted));
  return {
    ...(summary.repositoryName ? { repositoryName: summary.repositoryName } : {}),
    ...(branchLabel ? { branchLabel } : {}),
    ...(total ? { total } : {}),
    ...(showUncommitted && uncommittedPair ? { uncommitted: uncommittedPair } : {}),
    ahead: summary.aheadCount,
    behind: summary.behindCount,
  };
}

/** Counts beside the changes tab: what the tab itself lists, the uncommitted work. */
export function changesTabCounts(summary: GitSummary | null): GitMetricPair | undefined {
  if (!summary?.isGitRepo) return undefined;
  return pair(summary.uncommitted);
}

/**
 * `~/Documents/picky` for a path under a macOS home folder, like the HUD's
 * compact cwd. The phone never learns the Mac's home directory, so this reads
 * the `/Users/<name>` prefix instead.
 */
export function compactWorkspacePath(path: string): string {
  return path.replace(/^\/Users\/[^/]+(?=\/|$)/, "~");
}
