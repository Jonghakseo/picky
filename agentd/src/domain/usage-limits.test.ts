import { describe, expect, it } from "vitest";
import { chatgptAccountId, mapClaudeUsage, mapCodexUsage } from "./usage-limits.js";

const now = new Date("2026-10-05T15:00:00.000Z");

// Trimmed from live `GET /api/oauth/usage?cedar_ember=1` and `/api/oauth/profile` replies.
const claudeUsage = {
  five_hour: { utilization: 7, resets_at: "2026-10-05T17:40:00.030313+00:00" },
  seven_day: { utilization: 3, resets_at: "2026-10-06T22:00:00.030339+00:00" },
  seven_day_opus: null,
  cedar_ember: {
    eligible: true,
    grants: [
      { resets_total: 1, resets_left: 1, ends_at: "2026-10-22T16:00:00+00:00" },
      { resets_total: 1, resets_left: 0, ends_at: "2026-10-10T16:00:00+00:00" },
      { resets_total: 1, resets_left: 1, ends_at: "2026-10-01T16:00:00+00:00" },
    ],
  },
};
const claudeProfile = { organization: { organization_type: "claude_max", rate_limit_tier: "default_claude_max_20x" } };

// Trimmed from live `GET /backend-api/wham/usage` and `/wham/rate-limit-reset-credits` replies (Plus plan).
const codexUsage = {
  plan_type: "plus",
  rate_limit: {
    primary_window: { used_percent: 20, limit_window_seconds: 604800, reset_after_seconds: 358923, reset_at: 1791580202 },
    secondary_window: null,
  },
  rate_limit_reset_credits: { available_count: 2 },
};
const codexResetCredits = {
  available_count: 2,
  credits: [
    { status: "available", expires_at: "2026-10-29T16:36:15.505511Z" },
    { status: "available", expires_at: "2026-10-22T20:31:42.482076Z" },
    { status: "redeemed", expires_at: "2026-10-06T00:00:00Z" },
  ],
};

describe("mapClaudeUsage", () => {
  it("reads the session and weekly windows, the plan, and unexpired reset grants", () => {
    expect(mapClaudeUsage(claudeUsage, claudeProfile, now)).toEqual({
      provider: "anthropic",
      plan: "Max 20x",
      subscribed: true,
      session: { usedPercent: 7, resetsAt: "2026-10-05T17:40:00.030Z" },
      weekly: { usedPercent: 3, resetsAt: "2026-10-06T22:00:00.030Z" },
      resets: { available: 1, nextExpiresAt: "2026-10-22T16:00:00.000Z" },
    });
  });

  it("treats a free organization as unsubscribed and keeps limits without a profile", () => {
    expect(mapClaudeUsage({}, { organization: { organization_type: "claude_free" } }, now).subscribed).toBe(false);
    const withoutProfile = mapClaudeUsage(claudeUsage, undefined, now);
    expect(withoutProfile).toMatchObject({ plan: null, subscribed: true, session: { usedPercent: 7 } });
    expect(mapClaudeUsage({ five_hour: null }, undefined, now)).toMatchObject({ subscribed: false, session: null, resets: null });
  });

  it("reports zero resets for an ineligible account and clamps utilization", () => {
    const mapped = mapClaudeUsage({ five_hour: { utilization: 130, resets_at: null }, cedar_ember: { eligible: false } }, claudeProfile, now);
    expect(mapped.session).toEqual({ usedPercent: 100, resetsAt: null });
    expect(mapped.resets).toEqual({ available: 0, nextExpiresAt: null });
  });
});

describe("mapCodexUsage", () => {
  it("classifies a single weekly primary window as weekly, not session", () => {
    expect(mapCodexUsage(codexUsage, codexResetCredits, now)).toEqual({
      provider: "openai-codex",
      plan: "Plus",
      subscribed: true,
      session: null,
      weekly: { usedPercent: 20, resetsAt: new Date(1791580202 * 1000).toISOString() },
      resets: { available: 2, nextExpiresAt: "2026-10-22T20:31:42.482Z" },
    });
  });

  it("maps a five-hour primary and weekly secondary window and falls back to the usage body reset count", () => {
    const mapped = mapCodexUsage({
      plan_type: "pro",
      rate_limit: {
        primary_window: { used_percent: 42, limit_window_seconds: 18000, reset_after_seconds: 600 },
        secondary_window: { used_percent: 61, limit_window_seconds: 604800, reset_at: 1791580202 },
      },
      rate_limit_reset_credits: { available_count: 1 },
    }, undefined, now);
    expect(mapped).toMatchObject({
      plan: "Pro 200",
      session: { usedPercent: 42, resetsAt: "2026-10-05T15:10:00.000Z" },
      weekly: { usedPercent: 61 },
      resets: { available: 1, nextExpiresAt: null },
    });
  });

  it("treats the free plan as unsubscribed", () => {
    expect(mapCodexUsage({ plan_type: "free", rate_limit: codexUsage.rate_limit }, undefined, now).subscribed).toBe(false);
  });
});

describe("chatgptAccountId", () => {
  it("reads the workspace id claim and tolerates malformed tokens", () => {
    const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-1" } })).toString("base64url");
    expect(chatgptAccountId(`header.${payload}.signature`)).toBe("acct-1");
    expect(chatgptAccountId("not-a-jwt")).toBeUndefined();
    expect(chatgptAccountId("a.%%%.c")).toBeUndefined();
  });
});
