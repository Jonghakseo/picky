import { z } from "zod";
import { usageSampleTokens, type PickleStatisticsRecord, type PickleUsageSample } from "../domain/pickle-statistics.js";

/**
 * Statistics outlive their Pickles. Archived Pickles are purged after 30 days
 * and users can delete Pickles, but streaks, badges, totals, and all-time
 * records must not roll back when that happens. The history keeps the last
 * known record and owned usage of every Pickle the service has seen.
 */
export interface HubStatisticsHistory {
  version: 1;
  records: Record<string, PickleStatisticsRecord>;
  usage: Record<string, PickleUsageSample[]>;
}

export const EMPTY_HUB_STATISTICS_HISTORY: HubStatisticsHistory = { version: 1, records: {}, usage: {} };

const nonnegativeInt = z.number().int().nonnegative();
const HistoryRecordSchema = z.object({
  id: z.string(),
  title: z.string(),
  project: z.string(),
  cwd: z.string().optional(),
  createdAt: z.string(),
  lastActivityAt: z.string(),
  status: z.string().optional(),
  followUpCount: nonnegativeInt,
  delegationCount: nonnegativeInt,
  reviewCount: nonnegativeInt,
  category: z.enum(["fix", "research", "create", "review", "unclassified"]),
  changedFileCount: nonnegativeInt.default(0),
  artifactCount: nonnegativeInt.default(0),
  toolCallCount: nonnegativeInt.default(0),
  subagentCount: nonnegativeInt.default(0),
  activeDurationMs: nonnegativeInt.default(0),
  totalTokens: nonnegativeInt.default(0),
});
const HistoryUsageSchema = z.object({
  day: z.string(),
  provider: z.string(),
  model: z.string(),
  project: z.string().optional(),
  inputTokens: nonnegativeInt,
  outputTokens: nonnegativeInt,
  cacheTokens: nonnegativeInt,
});
const HistorySchema = z.object({
  version: z.literal(1),
  records: z.record(z.string(), HistoryRecordSchema),
  usage: z.record(z.string(), z.array(HistoryUsageSchema)),
});

export function parseHubStatisticsHistory(raw: unknown): HubStatisticsHistory {
  return HistorySchema.parse(raw) as HubStatisticsHistory;
}

export interface HistoryMergeResult {
  history: HubStatisticsHistory;
  /** Pickles that no longer exist on disk, with their last known state. */
  retiredRecords: PickleStatisticsRecord[];
  retiredUsage: PickleUsageSample[];
}

/**
 * Live data always wins for Pickles that still exist. A live Pickle whose
 * transcript can no longer be read keeps its previously recorded usage, so a
 * missing Pi file does not erase tokens either.
 */
export function mergeHubStatisticsHistory(
  history: HubStatisticsHistory,
  liveRecords: readonly PickleStatisticsRecord[],
  liveUsageBySession: ReadonlyMap<string, readonly PickleUsageSample[]>,
): HistoryMergeResult {
  const records: Record<string, PickleStatisticsRecord> = { ...history.records };
  const usage: Record<string, PickleUsageSample[]> = { ...history.usage };
  const liveIds = new Set<string>();
  for (const record of liveRecords) {
    liveIds.add(record.id);
    const samples = liveUsageBySession.get(record.id);
    if (samples && samples.length > 0) usage[record.id] = [...samples];
    const owned = usage[record.id] ?? [];
    records[record.id] = { ...record, totalTokens: owned.reduce((sum, sample) => sum + usageSampleTokens(sample), 0) };
  }
  const retiredRecords = Object.values(records).filter((record) => !liveIds.has(record.id));
  const retiredUsage = Object.entries(usage)
    .filter(([id]) => !liveIds.has(id))
    .flatMap(([, samples]) => samples);
  return { history: { version: 1, records, usage }, retiredRecords, retiredUsage };
}

/** Reset clears work classifications everywhere, including retired Pickles. */
export function clearHistoryClassifications(history: HubStatisticsHistory): HubStatisticsHistory {
  const records = Object.fromEntries(Object.entries(history.records)
    .map(([id, record]) => [id, { ...record, category: "unclassified" as const }]));
  return { ...history, records };
}
