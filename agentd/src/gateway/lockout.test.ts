import { describe, expect, it } from "vitest";
import { LOCKOUT_DURATION_MS, LOCKOUT_THRESHOLD, LOCKOUT_WINDOW_MS, LockoutTracker } from "./lockout.js";

describe("per-IP lockout", () => {
  it("blocks after five failures inside the window", () => {
    let now = 0;
    const tracker = new LockoutTracker(() => now);
    for (let attempt = 1; attempt < LOCKOUT_THRESHOLD; attempt += 1) {
      expect(tracker.recordFailure("203.0.113.5")).toBeUndefined();
      expect(tracker.isBlocked("203.0.113.5")).toBe(false);
    }
    expect(tracker.recordFailure("203.0.113.5")).toBe(LOCKOUT_DURATION_MS);
    expect(tracker.isBlocked("203.0.113.5")).toBe(true);
  });

  it("forgets failures older than the window", () => {
    let now = 0;
    const tracker = new LockoutTracker(() => now);
    for (let attempt = 1; attempt < LOCKOUT_THRESHOLD; attempt += 1) tracker.recordFailure("198.51.100.9");
    now = LOCKOUT_WINDOW_MS + 1;
    expect(tracker.recordFailure("198.51.100.9")).toBeUndefined();
    expect(tracker.isBlocked("198.51.100.9")).toBe(false);
  });

  it("lifts the block after fifteen minutes", () => {
    let now = 0;
    const tracker = new LockoutTracker(() => now);
    for (let attempt = 0; attempt < LOCKOUT_THRESHOLD; attempt += 1) tracker.recordFailure("203.0.113.5");
    now = LOCKOUT_DURATION_MS - 1;
    expect(tracker.isBlocked("203.0.113.5")).toBe(true);
    now = LOCKOUT_DURATION_MS;
    expect(tracker.isBlocked("203.0.113.5")).toBe(false);
  });

  it("tracks each IP separately and clears on success", () => {
    const tracker = new LockoutTracker(() => 0);
    for (let attempt = 0; attempt < LOCKOUT_THRESHOLD; attempt += 1) tracker.recordFailure("203.0.113.5");
    expect(tracker.isBlocked("198.51.100.9")).toBe(false);
    tracker.recordSuccess("203.0.113.5");
    expect(tracker.isBlocked("203.0.113.5")).toBe(false);
  });
});
