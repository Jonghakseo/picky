import {
  chatgptAccountId,
  mapClaudeUsage,
  mapCodexUsage,
  type MappedProviderUsageLimits,
  type ProviderUsageLimitsEntry,
  type UsageLimitsProviderId,
  type UsageLimitsSnapshotData,
} from "../domain/usage-limits.js";
import { logAgentd } from "../local-log.js";

/**
 * Reads the OAuth access token Pi holds for a provider, refreshing it when needed.
 * Resolves `undefined` when the provider is signed out or uses an API key, which
 * has no subscription limits. Implemented by `runtime/pi-subscription-credentials.ts`.
 */
export interface SubscriptionCredentialsPort {
  oauthAccessToken(providerId: UsageLimitsProviderId): Promise<string | undefined>;
}

export type UsageLimitsFetch = (url: string, init: { headers: Record<string, string>; signal: AbortSignal }) => Promise<{
  status: number;
  json(): Promise<unknown>;
}>;

export interface UsageLimitsServiceOptions {
  credentials: SubscriptionCredentialsPort;
  fetch?: UsageLimitsFetch;
  now?: () => Date;
  /** A non-forced request inside this window reuses the last snapshot. */
  reuseWindowMs?: number;
  requestTimeoutMs?: number;
}

const PROVIDERS: readonly UsageLimitsProviderId[] = ["anthropic", "openai-codex"];
// Pi's own Anthropic OAuth requests identify as this Claude Code build; the
// usage endpoint withholds reset grants from clients it does not recognize.
const CLAUDE_USER_AGENT = "claude-cli/2.1.280 (external, cli)";

class UsageRequestError extends Error {}

/**
 * Subscription limits for the Hub, menu bar, and HUD. The app polls every five
 * minutes; this service dedupes overlapping requests and keeps the last good
 * values per provider so a transient failure shows stale data, not nothing.
 */
export class UsageLimitsService {
  private readonly credentials: SubscriptionCredentialsPort;
  private readonly fetch: UsageLimitsFetch;
  private readonly now: () => Date;
  private readonly reuseWindowMs: number;
  private readonly requestTimeoutMs: number;
  private readonly lastGood = new Map<UsageLimitsProviderId, ProviderUsageLimitsEntry>();
  private latest?: UsageLimitsSnapshotData;
  private inFlight?: Promise<UsageLimitsSnapshotData>;

  constructor(options: UsageLimitsServiceOptions) {
    this.credentials = options.credentials;
    this.fetch = options.fetch ?? ((url, init) => globalThis.fetch(url, init));
    this.now = options.now ?? (() => new Date());
    this.reuseWindowMs = options.reuseWindowMs ?? 60_000;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 10_000;
  }

  async snapshot(options: { force: boolean }): Promise<UsageLimitsSnapshotData> {
    if (this.inFlight) return this.inFlight;
    if (!options.force && this.latest && this.now().getTime() - Date.parse(this.latest.checkedAt) < this.reuseWindowMs) {
      return this.latest;
    }
    const operation = this.check().finally(() => { this.inFlight = undefined; });
    this.inFlight = operation;
    return operation;
  }

  private async check(): Promise<UsageLimitsSnapshotData> {
    const now = this.now();
    const entries = await Promise.all(PROVIDERS.map((provider) => this.checkProvider(provider, now)));
    const snapshot = { checkedAt: now.toISOString(), providers: entries.filter((entry) => entry !== undefined) };
    this.latest = snapshot;
    return snapshot;
  }

  private async checkProvider(provider: UsageLimitsProviderId, now: Date): Promise<ProviderUsageLimitsEntry | undefined> {
    let token: string | undefined;
    try {
      token = await this.credentials.oauthAccessToken(provider);
    } catch (error) {
      return this.failed(provider, error);
    }
    if (!token) {
      this.lastGood.delete(provider);
      return undefined;
    }
    try {
      const mapped = provider === "anthropic" ? await this.fetchClaude(token, now) : await this.fetchCodex(token, now);
      if (!mapped.subscribed) {
        this.lastGood.delete(provider);
        return undefined;
      }
      const entry: ProviderUsageLimitsEntry = {
        provider,
        plan: mapped.plan,
        checkedAt: now.toISOString(),
        errorMessage: null,
        session: mapped.session,
        weekly: mapped.weekly,
        resets: mapped.resets,
      };
      this.lastGood.set(provider, entry);
      return entry;
    } catch (error) {
      return this.failed(provider, error);
    }
  }

  private failed(provider: UsageLimitsProviderId, error: unknown): ProviderUsageLimitsEntry {
    const message = error instanceof Error ? error.message : String(error);
    logAgentd("usage limits check failed", { provider, error: message });
    const previous = this.lastGood.get(provider);
    if (previous) return { ...previous, errorMessage: message };
    return { provider, plan: null, checkedAt: null, errorMessage: message, session: null, weekly: null, resets: null };
  }

  private async fetchClaude(token: string, now: Date): Promise<MappedProviderUsageLimits> {
    const headers = {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "anthropic-beta": "oauth-2025-04-20",
      "User-Agent": CLAUDE_USER_AGENT,
    };
    // The profile only names the plan; a failure there must not hide the limits.
    const [usage, profile] = await Promise.all([
      this.getJson("https://api.anthropic.com/api/oauth/usage?cedar_ember=1", headers),
      this.getJson("https://api.anthropic.com/api/oauth/profile", headers).catch(() => undefined),
    ]);
    return mapClaudeUsage(usage, profile, now);
  }

  private async fetchCodex(token: string, now: Date): Promise<MappedProviderUsageLimits> {
    const accountId = chatgptAccountId(token);
    const headers: Record<string, string> = {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "User-Agent": "Picky",
      originator: "pi",
      ...(accountId ? { "ChatGPT-Account-Id": accountId } : {}),
    };
    // The dedicated endpoint adds reset expiries; the usage body still carries the count.
    const [usage, resetCredits] = await Promise.all([
      this.getJson("https://chatgpt.com/backend-api/wham/usage", headers),
      this.getJson("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", { ...headers, "OpenAI-Beta": "codex-1" }).catch(() => undefined),
    ]);
    return mapCodexUsage(usage, resetCredits, now);
  }

  private async getJson(url: string, headers: Record<string, string>): Promise<unknown> {
    const response = await this.fetch(url, { headers, signal: AbortSignal.timeout(this.requestTimeoutMs) });
    if (response.status < 200 || response.status >= 300) {
      throw new UsageRequestError(`HTTP ${response.status}`);
    }
    return response.json();
  }
}
