import { describe, expect, it } from "vitest";
import type { PickleStatisticsRecord, PickleUsageSample } from "../domain/pickle-statistics.js";
import { EMPTY_HUB_STATISTICS_HISTORY, mergeHubStatisticsHistory, parseHubStatisticsHistory } from "./hub-statistics-history.js";

function record(id: string, overrides: Partial<PickleStatisticsRecord> = {}): PickleStatisticsRecord {
  return {
    id,
    title: id,
    project: "picky",
    createdAt: "2026-09-01T00:00:00.000Z",
    lastActivityAt: "2026-09-01T00:00:00.000Z",
    followUpCount: 0,
    delegationCount: 0,
    reviewCount: 0,
    category: "unclassified",
    changedFileCount: 0,
    artifactCount: 0,
    toolCallCount: 0,
    subagentCount: 0,
    activeDurationMs: 0,
    totalTokens: 0,
    ...overrides,
  };
}

const sample = (tokens: number): PickleUsageSample => ({
  day: "2026-09-01", provider: "anthropic", model: "m", project: "picky", inputTokens: tokens, outputTokens: 0, cacheTokens: 0,
});

describe("hub statistics history", () => {
  it("lets live data win and keeps Pickles that are gone", () => {
    const first = mergeHubStatisticsHistory(
      EMPTY_HUB_STATISTICS_HISTORY,
      [record("a", { toolCallCount: 1 }), record("b")],
      new Map([["a", [sample(10)]], ["b", [sample(5)]]]),
    );
    const second = mergeHubStatisticsHistory(first.history, [record("a", { toolCallCount: 4 })], new Map([["a", [sample(12)]]]));

    expect(second.history.records.a).toMatchObject({ toolCallCount: 4, totalTokens: 12 });
    expect(second.retiredRecords).toEqual([expect.objectContaining({ id: "b", totalTokens: 5 })]);
    expect(second.retiredUsage).toEqual([sample(5)]);
  });

  it("keeps recorded usage when a live Pickle's transcript can no longer be read", () => {
    const first = mergeHubStatisticsHistory(EMPTY_HUB_STATISTICS_HISTORY, [record("a")], new Map([["a", [sample(10)]]]));
    const second = mergeHubStatisticsHistory(first.history, [record("a")], new Map());

    expect(second.history.usage.a).toEqual([sample(10)]);
    expect(second.history.records.a?.totalTokens).toBe(10);
  });

  it("round-trips through the persisted schema and rejects malformed files", () => {
    const merged = mergeHubStatisticsHistory(EMPTY_HUB_STATISTICS_HISTORY, [record("a")], new Map([["a", [sample(1)]]]));
    expect(parseHubStatisticsHistory(JSON.parse(JSON.stringify(merged.history)))).toEqual(merged.history);
    expect(() => parseHubStatisticsHistory({ version: 2, records: {}, usage: {} })).toThrow();
  });
});
