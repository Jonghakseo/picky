import { describe, expect, it } from "vitest";
import type { PickyQueueItem } from "../protocol.js";
import { diffQueueRemovedItems, dropAlreadyMaterializedQueueEntries, matchPreviousQueueItems, queueItems, sameQueueItems, type PendingQueueDelivery } from "./queue-policy.js";

const enqueuedAt = "2026-06-03T00:00:00.000Z";

function item(id: string, text: string, queuedAt = "2026-06-02T00:00:00.000Z"): PickyQueueItem {
  return { id, text, enqueuedAt: queuedAt };
}

function idFactory(ids: string[]): () => string {
  return () => {
    const next = ids.shift();
    if (!next) throw new Error("id factory exhausted");
    return next;
  };
}

describe("queue policy", () => {
  it("matches existing queue entries from the front when the runtime queue grows", () => {
    const previous = [item("old-a", "a")];

    expect(queueItems(["a", "a"], enqueuedAt, previous, [], idFactory(["new-a"]))).toEqual([
      previous[0],
      item("new-a", "a", enqueuedAt),
    ]);
  });

  it("matches existing queue entries from the back when the runtime queue shrinks", () => {
    const previous = [item("old-a-1", "a"), item("old-a-2", "a")];

    expect(queueItems(["a"], enqueuedAt, previous, [], idFactory(["unused"]))).toEqual([
      previous[1],
    ]);
  });

  it("reuses pending delivery ids in FIFO order for duplicate texts", () => {
    expect(queueItems(
      ["same", "same"],
      enqueuedAt,
      [],
      [{ id: "pending-1", text: "same" }, { id: "pending-2", text: "same" }],
      idFactory(["unused"]),
    )).toEqual([
      item("pending-1", "same", enqueuedAt),
      item("pending-2", "same", enqueuedAt),
    ]);
  });

  it("does not reuse pending ids that already matched previous queue entries", () => {
    const previous = [item("pending-1", "same")];

    expect(queueItems(
      ["same", "same"],
      enqueuedAt,
      previous,
      [{ id: "pending-1", text: "same" }, { id: "pending-2", text: "same" }],
      idFactory(["unused"]),
    )).toEqual([
      previous[0],
      item("pending-2", "same", enqueuedAt),
    ]);
  });

  it("falls back to the injected id factory when there is no previous or pending identity", () => {
    expect(queueItems(["new"], enqueuedAt, [], [], idFactory(["generated"]))).toEqual([
      item("generated", "new", enqueuedAt),
    ]);
  });

  it("preserves duplicate identities across an unchanged full snapshot", () => {
    const previous = [item("first-a", "same"), item("middle-b", "other"), item("second-a", "same")];

    expect(queueItems(["same", "other", "same"], enqueuedAt, previous, [], idFactory(["unused"]))).toEqual(previous);
  });

  it("treats a reordered front item as new while preserving duplicate suffix identities", () => {
    const previous = [item("first-a", "same"), item("middle-b", "other"), item("second-a", "same")];

    expect(queueItems(["other", "same", "same"], enqueuedAt, previous, [], idFactory(["new-other"]))).toEqual([
      item("new-other", "other", enqueuedAt),
      previous[0],
      previous[2],
    ]);
  });

  it("reports reordered duplicate removals by previous queue identity", () => {
    const previousFollowUps = [item("first-a", "same"), item("middle-b", "other"), item("second-a", "same")];

    expect(diffQueueRemovedItems([], previousFollowUps, [], ["other", "same", "same"])).toEqual([
      previousFollowUps[1],
    ]);
  });

  it("compares queue item identity, text, and timestamp", () => {
    const queue = [item("id", "text")];

    expect(sameQueueItems(queue, [item("id", "text")])).toBe(true);
    expect(sameQueueItems(queue, [item("other", "text")])).toBe(false);
    expect(sameQueueItems(queue, [item("id", "other")])).toBe(false);
    expect(sameQueueItems(queue, [item("id", "text", enqueuedAt)])).toBe(false);
    expect(sameQueueItems(queue, [])).toBe(false);
  });

  it("computes removed items while accounting for duplicate text occurrences", () => {
    const previousSteers = [item("steer-a", "a"), item("steer-b", "b")];
    const previousFollowUps = [item("follow-1", "same"), item("follow-2", "same")];

    expect(diffQueueRemovedItems(previousSteers, previousFollowUps, ["b"], ["same"])).toEqual([
      previousSteers[0],
      previousFollowUps[0],
    ]);
  });

  it("exposes matched indexes for callers that need precise duplicate accounting", () => {
    const previous = [item("first", "same"), item("second", "same"), item("third", "other")];
    const { matched, usedPreviousIndexes } = matchPreviousQueueItems(["same"], previous);

    expect(matched).toEqual([previous[1]]);
    expect([...usedPreviousIndexes]).toEqual([1]);
  });

  it("drops runtime echoes for deliveries already materialized as user messages", () => {
    const materialized: PendingQueueDelivery[] = [
      { id: "delivered", kind: "followUp", text: "same", originatedBy: "user" },
    ];

    expect(dropAlreadyMaterializedQueueEntries(
      { steering: [], followUp: ["same"] },
      [],
      materialized,
    )).toEqual({
      queues: { steering: [], followUp: [] },
      remainingMaterialized: [],
    });
  });

  it("preserves a duplicate runtime entry while an identical delivery is still pending", () => {
    const pending: PendingQueueDelivery[] = [
      { id: "pending", kind: "followUp", text: "same", originatedBy: "user" },
    ];
    const materialized: PendingQueueDelivery[] = [
      { id: "delivered", kind: "followUp", text: "same", originatedBy: "user" },
    ];

    expect(dropAlreadyMaterializedQueueEntries(
      { steering: [], followUp: ["same", "same"] },
      pending,
      materialized,
    )).toEqual({
      queues: { steering: [], followUp: ["same"] },
      remainingMaterialized: [],
    });
  });

  it("keeps cross-kind text independent and retains unmatched materialized deliveries", () => {
    const materialized: PendingQueueDelivery[] = [
      { id: "steer-same", kind: "steering", text: "same", originatedBy: "user" },
      { id: "follow-later", kind: "followUp", text: "later", originatedBy: "user" },
    ];

    expect(dropAlreadyMaterializedQueueEntries(
      { steering: ["same"], followUp: ["same"] },
      [],
      materialized,
    )).toEqual({
      queues: { steering: [], followUp: ["same"] },
      remainingMaterialized: [materialized[1]],
    });
  });
});
