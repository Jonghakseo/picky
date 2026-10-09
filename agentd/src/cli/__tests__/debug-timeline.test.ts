import { describe, expect, it } from "vitest";
import type { EventEnvelope } from "../../protocol.js";
import { debugTimeline } from "../debug-timeline.js";

type Record = Extract<EventEnvelope, { type: "debugTrace" }>["records"][number];
const record = (fields: Partial<Record>): Record => ({ source: "app", name: "transition", timestamp: "2026-10-09T00:00:00.000Z", receivedAt: "2026-10-09T00:00:00.001Z", monotonicMs: 0, sequence: 1, ...fields });

describe("debug timeline measurements", () => {
  it("follows explicit input/context links across sources without merging another turn in the same session", () => {
    const records = [
      record({ sequence: 1, inputId: "i1", monotonicMs: 100 }),
      record({ sequence: 2, source: "daemon", contextId: "c1", sessionId: "picky", monotonicMs: 8000 }),
      record({ sequence: 3, inputId: "i1", contextId: "c1", monotonicMs: 125 }),
      record({ sequence: 4, source: "daemon", contextId: "c2", sessionId: "picky", monotonicMs: 8010 }),
      record({ sequence: 5, source: "daemon", contextId: "c1", monotonicMs: 8040 }),
    ];
    const timeline = debugTimeline(records, { input: "i1" });
    expect(timeline.map((entry) => entry.sequence)).toEqual([1, 2, 3, 5]);
    expect(timeline.map((entry) => entry.sourceElapsedMs)).toEqual([0, 0, 25, 40]);
    expect(timeline.map((entry) => entry.sourceDeltaMs)).toEqual([0, 0, 25, 40]);
    expect(debugTimeline(records, { input: "i1", session: "picky" }).map((entry) => entry.sequence)).toEqual([2]);
  });

  it("marks an out-of-order source clock as unknown rather than reporting zero latency", () => {
    const timeline = debugTimeline([record({ monotonicMs: 800 }), record({ monotonicMs: 12 })], {});
    expect(timeline[1]).toMatchObject({ sourceElapsedMs: null, sourceDeltaMs: null, timingDiscontinuity: true });
  });
});
