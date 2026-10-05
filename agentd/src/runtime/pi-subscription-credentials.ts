import { ModelRuntime } from "@earendil-works/pi-coding-agent";

type ProviderId = "anthropic" | "openai-codex";

export interface SubscriptionCredentialRuntime {
  checkAuth(providerId: string): Promise<{ type: "api_key" | "oauth" } | undefined>;
  getAuth(providerId: string): Promise<{ auth: { apiKey?: string } } | undefined>;
}

/**
 * OAuth access tokens for subscription-limit checks. Pi's credential store
 * refreshes an expiring token under its own lock, so this never races a live
 * Pi session that refreshes the same login.
 */
export class PiSubscriptionCredentials {
  private runtimePromise?: Promise<SubscriptionCredentialRuntime>;

  constructor(private readonly createRuntime: () => Promise<SubscriptionCredentialRuntime> = () => ModelRuntime.create({ allowModelNetwork: false })) {}

  async oauthAccessToken(providerId: ProviderId): Promise<string | undefined> {
    const runtime = await this.runtime();
    const check = await runtime.checkAuth(providerId);
    if (check?.type !== "oauth") return undefined;
    const token = (await runtime.getAuth(providerId))?.auth.apiKey?.trim();
    return token ? token : undefined;
  }

  private runtime(): Promise<SubscriptionCredentialRuntime> {
    this.runtimePromise ??= this.createRuntime().catch((error: unknown) => {
      this.runtimePromise = undefined;
      throw error;
    });
    return this.runtimePromise;
  }
}
