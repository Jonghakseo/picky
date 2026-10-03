import { describe, expect, it } from "vitest";
import type { PickyQueueItem } from "../protocol.js";
import { findScheduledMessage, locateRuntimeQueueItem, remainingDelayMs } from "./session-queue-commands.js";

const item = (id: string, text: string): PickyQueueItem => ({ id, text, enqueuedAt: "2026-05-05T00:00:00.000Z" });

describe("session queue commands", () => {
  it("resolves a projected item to its runtime queue position", () => {
    const location = locateRuntimeQueueItem(
      { steering: [item("s1", "steer one")], followUp: [item("f1", "follow one"), item("f2", "follow two")] },
      { steering: ["steer one"], followUp: ["follow one", "follow two"] },
      "f2",
    );

    expect(location).toMatchObject({ kind: "followUp", index: 1 });
  });

  it("addresses the nth duplicate rather than the first match", () => {
    const location = locateRuntimeQueueItem(
      { steering: [], followUp: [item("f1", "retry"), item("f2", "retry"), item("f3", "retry")] },
      { steering: [], followUp: ["retry", "retry", "retry"] },
      "f3",
    );

    expect(location?.index).toBe(2);
  });

  it("skips adapter-held entries that shift the runtime snapshot", () => {
    // The runtime snapshot can carry entries the projection does not show (held during
    // compaction). Position must come from text occurrence, not the projected index.
    const location = locateRuntimeQueueItem(
      { steering: [], followUp: [item("f1", "second")] },
      { steering: [], followUp: ["first", "second"] },
      "f1",
    );

    expect(location?.index).toBe(1);
  });

  it("addresses the live duplicate when an identical message was already journaled", () => {
    // Pi's snapshot still lists the entry whose user bubble was recorded, and the projection
    // hides it. Counting that position would edit a message the user can no longer see.
    const location = locateRuntimeQueueItem(
      { steering: [], followUp: [item("f2", "retry")] },
      { steering: [], followUp: ["retry", "retry"] },
      "f2",
      { materialized: [{ id: "f1", kind: "followUp", text: "retry" }] },
    );

    expect(location?.index).toBe(1);
  });

  it("reports no location once the agent drained the entry", () => {
    expect(locateRuntimeQueueItem(
      { steering: [], followUp: [item("f1", "gone")] },
      { steering: [], followUp: [] },
      "f1",
    )).toBeUndefined();
    expect(locateRuntimeQueueItem({ steering: [], followUp: [] }, { steering: [], followUp: [] }, "missing")).toBeUndefined();
  });

  it("keeps the original due time when re-scheduling an edited message", () => {
    const now = Date.parse("2026-05-05T00:00:00.000Z");
    expect(remainingDelayMs("2026-05-05T00:05:00.000Z", now)).toBe(300_000);
    // Already due: the extension still needs a positive timer.
    expect(remainingDelayMs("2026-05-04T23:00:00.000Z", now)).toBe(1_000);
    expect(remainingDelayMs("not a date", now)).toBe(1_000);
  });

  it("finds a scheduled message by id", () => {
    const message = { id: "delay-1", text: "ping", dueAt: "2026-05-05T00:05:00.000Z", createdAt: "2026-05-05T00:00:00.000Z" };
    expect(findScheduledMessage([message], "delay-1")).toBe(message);
    expect(findScheduledMessage([message], "delay-2")).toBeUndefined();
    expect(findScheduledMessage(undefined, "delay-1")).toBeUndefined();
  });
});
