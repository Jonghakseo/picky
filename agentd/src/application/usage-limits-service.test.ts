import { describe, expect, it } from "vitest";
import { UsageLimitsService, type UsageLimitsFetch } from "./usage-limits-service.js";
import type { UsageLimitsProviderId } from "../domain/usage-limits.js";

const claudeUsage = { five_hour: { utilization: 40, resets_at: "2026-10-05T17:00:00Z" }, seven_day: { utilization: 10, resets_at: null } };
const claudeProfile = { organization: { organization_type: "claude_max", rate_limit_tier: "default_claude_max_5x" } };
const codexUsage = { plan_type: "plus", rate_limit: { primary_window: { used_percent: 20, limit_window_seconds: 604800, reset_at: 1791580202 } } };

interface Harness {
  service: UsageLimitsService;
  requests: string[];
  tokens: Partial<Record<UsageLimitsProviderId, string>>;
  respond: Map<string, () => { status: number; body?: unknown }>;
  clock: { now: Date };
}

function harness(): Harness {
  const requests: string[] = [];
  const tokens: Harness["tokens"] = { anthropic: "claude-token", "openai-codex": "codex-token" };
  const respond = new Map<string, () => { status: number; body?: unknown }>([
    ["/api/oauth/usage", () => ({ status: 200, body: claudeUsage })],
    ["/api/oauth/profile", () => ({ status: 200, body: claudeProfile })],
    ["/wham/usage", () => ({ status: 200, body: codexUsage })],
    ["/wham/rate-limit-reset-credits", () => ({ status: 404 })],
  ]);
  const fetch: UsageLimitsFetch = async (url) => {
    requests.push(url);
    const path = new URL(url).pathname.replace("/backend-api", "");
    const reply = respond.get(path)?.() ?? { status: 404 };
    return { status: reply.status, json: async () => reply.body };
  };
  const clock = { now: new Date("2026-10-05T15:00:00.000Z") };
  const service = new UsageLimitsService({
    credentials: { oauthAccessToken: async (provider) => tokens[provider] },
    fetch,
    now: () => clock.now,
  });
  return { service, requests, tokens, respond, clock };
}

describe("UsageLimitsService", () => {
  it("returns only signed-in, subscribed providers", async () => {
    const { service, tokens, respond } = harness();
    tokens["openai-codex"] = undefined;
    const signedOut = await service.snapshot({ force: true });
    expect(signedOut.providers.map((entry) => entry.provider)).toEqual(["anthropic"]);
    expect(signedOut.providers[0]).toMatchObject({ plan: "Max 5x", errorMessage: null, session: { usedPercent: 40 } });

    tokens["openai-codex"] = "codex-token";
    respond.set("/wham/usage", () => ({ status: 200, body: { ...codexUsage, plan_type: "free" } }));
    const free = await service.snapshot({ force: true });
    expect(free.providers.map((entry) => entry.provider)).toEqual(["anthropic"]);
  });

  it("keeps the last good values with an error after a failed check", async () => {
    const { service, respond, clock } = harness();
    await service.snapshot({ force: true });
    respond.set("/api/oauth/usage", () => ({ status: 503 }));
    clock.now = new Date("2026-10-05T15:05:00.000Z");

    const stale = await service.snapshot({ force: true });
    const claude = stale.providers.find((entry) => entry.provider === "anthropic");
    expect(claude).toMatchObject({ errorMessage: "HTTP 503", checkedAt: "2026-10-05T15:00:00.000Z", session: { usedPercent: 40 } });
    expect(stale.providers.find((entry) => entry.provider === "openai-codex")).toMatchObject({ errorMessage: null, weekly: { usedPercent: 20 } });
  });

  it("reports a first-time failure without inventing limits", async () => {
    const { service, respond } = harness();
    respond.set("/wham/usage", () => ({ status: 401 }));
    const snapshot = await service.snapshot({ force: true });
    expect(snapshot.providers.find((entry) => entry.provider === "openai-codex")).toEqual({
      provider: "openai-codex", plan: null, checkedAt: null, errorMessage: "HTTP 401", session: null, weekly: null, resets: null,
    });
  });

  it("reuses a recent snapshot unless forced, and shares one in-flight check", async () => {
    const { service, requests, clock } = harness();
    await service.snapshot({ force: false });
    const firstCount = requests.length;

    clock.now = new Date("2026-10-05T15:00:30.000Z");
    await service.snapshot({ force: false });
    expect(requests.length).toBe(firstCount);

    await service.snapshot({ force: true });
    expect(requests.length).toBe(firstCount * 2);

    clock.now = new Date("2026-10-05T15:05:00.000Z");
    await Promise.all([service.snapshot({ force: true }), service.snapshot({ force: true })]);
    expect(requests.length).toBe(firstCount * 3);
  });
});
