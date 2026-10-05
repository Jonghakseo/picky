/**
 * Subscription plan limits (5-hour session, weekly window, rate-limit resets)
 * for the providers Picky signs in to through Pi OAuth.
 *
 * Pure mapping only. The provider endpoints are undocumented, so every field is
 * read defensively: a shape change degrades to "no data" for that field instead
 * of failing the whole snapshot.
 */

export type UsageLimitsProviderId = "anthropic" | "openai-codex";

export interface UsageLimitWindow {
  /** 0-100, already clamped. */
  usedPercent: number;
  resetsAt: string | null;
}

export interface UsageLimitResets {
  available: number;
  /** Earliest expiry among the available resets, when the provider reports one. */
  nextExpiresAt: string | null;
}

export interface MappedProviderUsageLimits {
  provider: UsageLimitsProviderId;
  plan: string | null;
  /** False for a free plan: Picky only shows limits for paid subscriptions. */
  subscribed: boolean;
  session: UsageLimitWindow | null;
  weekly: UsageLimitWindow | null;
  resets: UsageLimitResets | null;
}

const SESSION_WINDOW_SECONDS = 5 * 60 * 60;
const WEEKLY_WINDOW_SECONDS = 7 * 24 * 60 * 60;

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function finiteNumber(value: unknown): number | undefined {
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function clampPercent(value: number): number {
  return Math.min(100, Math.max(0, value));
}

/** ISO string or epoch seconds/milliseconds to a normalized ISO timestamp. */
function isoDate(value: unknown): string | null {
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
  }
  const number = finiteNumber(value);
  if (number === undefined) return null;
  const milliseconds = Math.abs(number) < 1e10 ? number * 1000 : number;
  return new Date(milliseconds).toISOString();
}

function titleCase(raw: string): string {
  return raw
    .split(/[_\s]+/)
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join(" ");
}

// MARK: - Claude

function claudeWindow(value: unknown): UsageLimitWindow | null {
  const window = record(value);
  const used = finiteNumber(window?.utilization);
  if (!window || used === undefined) return null;
  return { usedPercent: clampPercent(used), resetsAt: isoDate(window.resets_at) };
}

function claudeResets(value: unknown, now: Date): UsageLimitResets | null {
  const program = record(value);
  if (!program) return null;
  if (program.eligible !== true) return { available: 0, nextExpiresAt: null };
  let available = 0;
  let nextExpiresAt: string | null = null;
  for (const entry of Array.isArray(program.grants) ? program.grants : []) {
    const grant = record(entry);
    const left = finiteNumber(grant?.resets_left);
    if (!grant || left === undefined || left < 1) continue;
    const endsAt = isoDate(grant.ends_at);
    if (endsAt && Date.parse(endsAt) <= now.getTime()) continue;
    available += Math.floor(left);
    if (endsAt && (!nextExpiresAt || endsAt < nextExpiresAt)) nextExpiresAt = endsAt;
  }
  return { available, nextExpiresAt };
}

/**
 * `organization_type: "claude_max"` plus `rate_limit_tier: "default_claude_max_20x"`
 * reads as "Max 20x". A free organization is not a subscription.
 */
export function claudePlan(profile: unknown): { plan: string | null; subscribed: boolean | undefined } {
  const organization = record(record(profile)?.organization);
  const type = typeof organization?.organization_type === "string" ? organization.organization_type.trim() : "";
  if (!type) return { plan: null, subscribed: undefined };
  const base = titleCase(type.replace(/^claude_/, ""));
  const tier = typeof organization?.rate_limit_tier === "string" ? organization.rate_limit_tier.match(/\d+x/)?.[0] : undefined;
  const subscribed = !/free/i.test(type);
  return { plan: tier ? `${base} ${tier}` : base, subscribed };
}

export function mapClaudeUsage(usage: unknown, profile: unknown, now: Date): MappedProviderUsageLimits {
  const body = record(usage) ?? {};
  const session = claudeWindow(body.five_hour);
  const weekly = claudeWindow(body.seven_day);
  const { plan, subscribed } = claudePlan(profile);
  return {
    provider: "anthropic",
    plan,
    // Without a readable profile, live window data is the subscription evidence.
    subscribed: subscribed ?? (session !== null || weekly !== null),
    session,
    weekly,
    resets: claudeResets(body.cedar_ember, now),
  };
}

// MARK: - ChatGPT (Codex)

const CODEX_PLAN_NAMES: Record<string, string> = {
  prolite: "Pro 100",
  pro: "Pro 200",
  promax: "Pro 500",
  self_serve_business_prolite: "Business Premium",
};

export function codexPlan(planType: unknown): { plan: string | null; subscribed: boolean | undefined } {
  const raw = typeof planType === "string" ? planType.trim().toLowerCase() : "";
  if (!raw) return { plan: null, subscribed: undefined };
  return { plan: CODEX_PLAN_NAMES[raw] ?? titleCase(raw), subscribed: raw !== "free" };
}

function codexWindow(value: unknown, now: Date): (UsageLimitWindow & { seconds?: number }) | null {
  const window = record(value);
  const used = finiteNumber(window?.used_percent);
  if (!window || used === undefined) return null;
  const resetAt = finiteNumber(window.reset_at);
  const resetAfter = finiteNumber(window.reset_after_seconds);
  const resetsAt = resetAt !== undefined
    ? isoDate(resetAt)
    : resetAfter !== undefined ? new Date(now.getTime() + resetAfter * 1000).toISOString() : null;
  return { usedPercent: clampPercent(used), resetsAt, seconds: finiteNumber(window.limit_window_seconds) };
}

/**
 * Codex reports `primary_window`/`secondary_window`, and their meaning depends on
 * the plan: Plus has a single weekly primary window. Classify by window length
 * first, then fall back to primary = session, secondary = weekly.
 */
function classifyCodexWindows(rateLimit: unknown, now: Date): { session: UsageLimitWindow | null; weekly: UsageLimitWindow | null } {
  const limits = record(rateLimit);
  const candidates = [
    { window: codexWindow(limits?.primary_window, now), fallback: "session" as const },
    { window: codexWindow(limits?.secondary_window, now), fallback: "weekly" as const },
  ].filter((candidate) => candidate.window !== null);
  const exactKind = (seconds: number | undefined) =>
    seconds === SESSION_WINDOW_SECONDS ? "session" : seconds === WEEKLY_WINDOW_SECONDS ? "weekly" : undefined;
  const pick = (kind: "session" | "weekly"): UsageLimitWindow | null => {
    const match = candidates.find((candidate) => exactKind(candidate.window?.seconds) === kind)
      ?? candidates.find((candidate) => exactKind(candidate.window?.seconds) === undefined && candidate.fallback === kind);
    if (!match?.window) return null;
    return { usedPercent: match.window.usedPercent, resetsAt: match.window.resetsAt };
  };
  return { session: pick("session"), weekly: pick("weekly") };
}

function codexResets(usageBody: Record<string, unknown>, resetCredits: unknown): UsageLimitResets | null {
  const dedicated = record(resetCredits);
  const source = finiteNumber(dedicated?.available_count) !== undefined ? dedicated : record(usageBody.rate_limit_reset_credits);
  const count = finiteNumber(source?.available_count);
  if (!source || count === undefined || count < 0) return null;
  let nextExpiresAt: string | null = null;
  for (const entry of Array.isArray(source.credits) ? source.credits : []) {
    const credit = record(entry);
    if (!credit || (typeof credit.status === "string" && credit.status !== "available")) continue;
    const expiresAt = isoDate(credit.expires_at);
    if (expiresAt && (!nextExpiresAt || expiresAt < nextExpiresAt)) nextExpiresAt = expiresAt;
  }
  return { available: Math.floor(count), nextExpiresAt };
}

export function mapCodexUsage(usage: unknown, resetCredits: unknown, now: Date): MappedProviderUsageLimits {
  const body = record(usage) ?? {};
  const { session, weekly } = classifyCodexWindows(body.rate_limit, now);
  const { plan, subscribed } = codexPlan(body.plan_type);
  return {
    provider: "openai-codex",
    plan,
    subscribed: subscribed ?? (session !== null || weekly !== null),
    session,
    weekly,
    resets: codexResets(body, resetCredits),
  };
}

/** The ChatGPT workspace id the usage endpoint requires, read from the access token's claims. */
export function chatgptAccountId(accessToken: string): string | undefined {
  const payload = accessToken.split(".")[1];
  if (!payload) return undefined;
  try {
    const claims = record(JSON.parse(Buffer.from(payload, "base64url").toString("utf8")));
    const accountId = record(claims?.["https://api.openai.com/auth"])?.chatgpt_account_id;
    return typeof accountId === "string" && accountId.length > 0 ? accountId : undefined;
  } catch {
    return undefined;
  }
}

// MARK: - Snapshot

export interface ProviderUsageLimitsEntry {
  provider: UsageLimitsProviderId;
  plan: string | null;
  /** Last successful check. */
  checkedAt: string | null;
  /** Set when the latest check failed; windows then hold the last known values. */
  errorMessage: string | null;
  session: UsageLimitWindow | null;
  weekly: UsageLimitWindow | null;
  resets: UsageLimitResets | null;
}

export interface UsageLimitsSnapshotData {
  checkedAt: string;
  providers: ProviderUsageLimitsEntry[];
}
