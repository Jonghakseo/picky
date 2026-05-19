import { describe, expect, it } from "vitest";
import { normalizeCodexQuota } from "./codex-oauth.js";

describe("normalizeCodexQuota", () => {
  it("reads plan type and a single primary window from a flat rate_limit shape", () => {
    const snapshot = normalizeCodexQuota({
      plan_type: "plus",
      rate_limit: { used: 100, limit: 1000, remaining: 900, window: "5_hours", reset_at: "2026-05-09T05:00:00Z" },
    });
    expect(snapshot.planType).toBe("plus");
    expect(snapshot.primary).toEqual({
      used: 100,
      limit: 1000,
      remaining: 900,
      windowLabel: "5_hours",
      resetAt: "2026-05-09T05:00:00Z",
    });
    expect(snapshot.secondary).toBeUndefined();
  });

  it("reads nested primary and secondary windows by alias keys", () => {
    const snapshot = normalizeCodexQuota({
      plan_type: "pro",
      rate_limit: {
        five_hour: { used: 200, limit: 800 },
        weekly: { used: 7, limit: 60, remaining: 53 },
      },
    });
    expect(snapshot.primary?.used).toBe(200);
    expect(snapshot.primary?.limit).toBe(800);
    expect(snapshot.primary?.remaining).toBe(600);
    expect(snapshot.primary?.windowLabel).toBe("five_hour");
    expect(snapshot.secondary?.remaining).toBe(53);
    expect(snapshot.secondary?.windowLabel).toBe("weekly");
  });

  it("skips windows without a valid limit", () => {
    const snapshot = normalizeCodexQuota({
      rate_limit: { used: 5, limit: 0 },
    });
    expect(snapshot.primary).toBeUndefined();
  });
});
