import { describe, expect, it } from "vitest";
import { DebugTraceRing } from "./debug-trace-ring.js";
import type { DebugTraceRecord } from "../features/debug/schema.js";

function record(name: string, overrides: Partial<DebugTraceRecord> = {}): DebugTraceRecord {
  return {
    source: "daemon",
    name,
    timestamp: "2026-10-09T05:00:00.000Z",
    monotonicMs: 1,
    ...overrides,
  };
}

describe("DebugTraceRing", () => {
  it("returns only records after the caller's cursor and advances it", () => {
    const ring = new DebugTraceRing("instance-1");
    ring.record(record("first"));
    ring.record(record("second"));

    const firstPage = ring.read({ limit: 1 });
    expect(firstPage.records.map((entry) => entry.name)).toEqual(["first"]);
    expect(firstPage.truncated).toBe(false);

    const secondPage = ring.read({ afterSequence: firstPage.nextSequence });
    expect(secondPage.records.map((entry) => entry.name)).toEqual(["second"]);
    expect(secondPage.instanceId).toBe("instance-1");

    const emptyPage = ring.read({ afterSequence: secondPage.nextSequence });
    expect(emptyPage.records).toEqual([]);
    // An empty page must not rewind the cursor, or a poller re-reads the same window forever.
    expect(emptyPage.nextSequence).toBe(secondPage.nextSequence);
  });

  it("reports truncation only when eviction dropped records the cursor still expected", () => {
    const ring = new DebugTraceRing("instance-1", 2);
    ring.record(record("one"));
    ring.record(record("two"));
    ring.record(record("three"));

    expect(ring.size).toBe(2);
    const afterEvicted = ring.read({ afterSequence: 1 });
    expect(afterEvicted.truncated).toBe(false);
    expect(afterEvicted.records.map((entry) => entry.name)).toEqual(["two", "three"]);

    const fromStart = ring.read({ afterSequence: 0 });
    expect(fromStart.truncated).toBe(true);
    expect(fromStart.oldestSequence).toBe(2);

    // Reaching the page limit is not truncation: those records are still retained.
    expect(ring.read({ afterSequence: 1, limit: 1 })).toMatchObject({ truncated: false, nextSequence: 2 });
  });

  it("keeps records metadata-only and within the published bounds", () => {
    const ring = new DebugTraceRing("instance-1");
    const stored = ring.record(record("x".repeat(200), {
      contextId: "c".repeat(300),
      textLength: 12.7,
      monotonicMs: Number.NaN,
      modality: "audio",
    }), "2026-10-09T05:00:01.000Z");

    expect(stored.name).toHaveLength(96);
    expect(stored.contextId).toHaveLength(160);
    expect(stored.textLength).toBe(12);
    expect(stored.monotonicMs).toBe(0);
    expect(stored.sequence).toBe(1);
    expect(stored.receivedAt).toBe("2026-10-09T05:00:01.000Z");
    expect(Object.keys(stored).sort()).toEqual([
      "contextId",
      "modality",
      "monotonicMs",
      "name",
      "receivedAt",
      "sequence",
      "source",
      "textLength",
      "timestamp",
    ]);
  });

  it("starts an empty ring at sequence zero so a first reader has a usable cursor", () => {
    const ring = new DebugTraceRing("instance-1");
    expect(ring.read()).toMatchObject({ records: [], oldestSequence: 0, nextSequence: 0, truncated: false });
  });
});
