import { describe, expect, it } from "vitest";
import { activityTotal, hasActivity, zeroActivitySummary } from "./activity-summary.js";

describe("activity summary", () => {
  it("creates a zero-valued summary with every activity bucket", () => {
    expect(zeroActivitySummary()).toEqual({
      read: 0,
      bash: 0,
      edit: 0,
      write: 0,
      thinking: 0,
      other: 0,
    });
  });

  it("returns a new summary object each time", () => {
    const first = zeroActivitySummary();
    const second = zeroActivitySummary();

    first.read = 1;

    expect(second.read).toBe(0);
  });

  it("sums all activity buckets", () => {
    expect(activityTotal({ read: 1, bash: 2, edit: 3, write: 4, todo: 5, subagent: 6, thinking: 7, other: 8 })).toBe(36);
  });

  it.each(["read", "bash", "edit", "write", "todo", "subagent", "thinking", "other"] as const)("reports %s activity independently", (bucket) => {
    expect(hasActivity(zeroActivitySummary())).toBe(false);
    expect(hasActivity({ ...zeroActivitySummary(), [bucket]: 1 })).toBe(true);
  });
});
