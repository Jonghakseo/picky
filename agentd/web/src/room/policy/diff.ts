/**
 * Reading the daemon's `sessionDiffResult` and classifying unified-diff lines.
 *
 * Swift sources: `PickySessionDiffFile` (the payload) and the changes tab of
 * the HUD work panel (which lines are green, red or muted).
 */
export type DiffFileStatus = "added" | "modified" | "deleted" | "renamed" | "untracked";

export interface DiffFile {
  path: string;
  status: DiffFileStatus;
  renamedFrom?: string;
  additions: number;
  deletions: number;
  diff: string;
  truncated: boolean;
}

export interface DiffResult {
  isGitRepo: boolean;
  files: DiffFile[];
  filesTruncated: boolean;
  errorMessage?: string;
}

const STATUSES: DiffFileStatus[] = ["added", "modified", "deleted", "renamed", "untracked"];

function asNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}

/**
 * The gateway relays whatever the daemon answered. Only the fields the panel
 * draws are required, so an older or newer daemon still renders something.
 */
export function parseDiffResult(data: unknown): DiffResult {
  const record = (data ?? {}) as Record<string, unknown>;
  const rawFiles = Array.isArray(record.files) ? record.files : [];
  const files: DiffFile[] = rawFiles.flatMap((entry) => {
    const file = (entry ?? {}) as Record<string, unknown>;
    if (typeof file.path !== "string" || file.path.length === 0) return [];
    const status = STATUSES.includes(file.status as DiffFileStatus) ? (file.status as DiffFileStatus) : "modified";
    return [
      {
        path: file.path,
        status,
        ...(typeof file.renamedFrom === "string" ? { renamedFrom: file.renamedFrom } : {}),
        additions: asNumber(file.additions),
        deletions: asNumber(file.deletions),
        diff: typeof file.diff === "string" ? file.diff : "",
        truncated: file.truncated === true,
      },
    ];
  });
  return {
    isGitRepo: record.isGitRepo !== false,
    files,
    filesTruncated: record.filesTruncated === true,
    ...(typeof record.errorMessage === "string" && record.errorMessage.length > 0
      ? { errorMessage: record.errorMessage }
      : {}),
  };
}

export type DiffLineKind = "add" | "remove" | "meta" | "context";

/** `+++`/`---` headers are metadata, not a one-line change. */
export function diffLineKind(line: string): DiffLineKind {
  if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@") || line.startsWith("diff ")) return "meta";
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "remove";
  return "context";
}

/** `+12 -3`, the same shorthand the HUD puts beside a changed file. */
export function changeCounts(additions: number, deletions: number): string {
  return `+${additions} -${deletions}`;
}
