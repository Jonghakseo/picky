import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { AuthEvent, AuthInteraction, AuthPrompt, Credential, Provider } from "@earendil-works/pi-ai";

export interface PiOAuthAuthStatus {
  configured: boolean;
  source?: string;
  label?: string;
}

export interface PiOAuthRuntime {
  getProvider(providerId: string): Provider | undefined;
  getProviderAuthStatus(providerId: string): PiOAuthAuthStatus;
  login(providerId: string, type: "oauth", interaction: AuthInteraction): Promise<Credential>;
}

export interface PiOAuthLoginRequest {
  requestId: string;
  providerId: string;
  owner: object;
  onNotify(event: AuthEvent): void;
  onPrompt(promptId: string, prompt: AuthPrompt): void;
}

export interface PiOAuthPromptAnswer {
  owner: object;
  requestId: string;
  promptId: string;
  value?: string;
  cancelled?: boolean;
}

export interface PiOAuthServiceOptions {
  createRuntime?: () => Promise<PiOAuthRuntime>;
}

export interface PiOAuthHandling {
  status(providerId: string): Promise<PiOAuthAuthStatus>;
  login(request: PiOAuthLoginRequest): Promise<PiOAuthAuthStatus>;
  answerPrompt(answer: PiOAuthPromptAnswer): void;
  cancel(owner: object, requestId: string): boolean;
  cancelOwnedBy(owner: object): number;
}

interface PendingPrompt {
  resolve(value: string): void;
  reject(error: Error): void;
  cleanup(): void;
}

interface PendingLogin {
  providerId: string;
  owner: object;
  controller: AbortController;
  prompts: Map<string, PendingPrompt>;
  promptSequence: number;
}

/**
 * Owns Pi provider OAuth orchestration for app-facing Settings requests.
 *
 * Every login is bound to both its command id and the WebSocket object that
 * started it. Prompt answers, cancellation, and disconnect cleanup must match
 * that owner so a second local client cannot observe or steer another client's
 * credentials flow.
 */
export class PiOAuthService implements PiOAuthHandling {
  private readonly createRuntime: () => Promise<PiOAuthRuntime>;
  private runtimePromise: Promise<PiOAuthRuntime> | undefined;
  private readonly logins = new Map<string, PendingLogin>();
  private readonly providerRequests = new Map<string, string>();

  constructor(options: PiOAuthServiceOptions = {}) {
    this.createRuntime = options.createRuntime ?? (() => ModelRuntime.create({ allowModelNetwork: false }));
  }

  async status(providerId: string): Promise<PiOAuthAuthStatus> {
    const runtime = await this.runtime();
    this.requireOAuthProvider(runtime, providerId);
    return runtime.getProviderAuthStatus(providerId);
  }

  async login(request: PiOAuthLoginRequest): Promise<PiOAuthAuthStatus> {
    if (this.logins.has(request.requestId)) {
      throw new Error(`Pi OAuth request already exists: ${request.requestId}`);
    }
    const existingRequestId = this.providerRequests.get(request.providerId);
    if (existingRequestId) {
      throw new Error(`Pi OAuth login already in progress for '${request.providerId}' (${existingRequestId})`);
    }

    // Reserve synchronously before the first await. WebSocket commands can be
    // dispatched concurrently while ModelRuntime is still initializing; a
    // post-await reservation lets two requests pass both single-flight checks.
    const pending: PendingLogin = {
      providerId: request.providerId,
      owner: request.owner,
      controller: new AbortController(),
      prompts: new Map(),
      promptSequence: 0,
    };
    this.logins.set(request.requestId, pending);
    this.providerRequests.set(request.providerId, request.requestId);

    try {
      const runtime = await this.runtime();
      if (pending.controller.signal.aborted) throw new Error("Pi OAuth login cancelled");
      this.requireOAuthProvider(runtime, request.providerId);
      await runtime.login(request.providerId, "oauth", {
        signal: pending.controller.signal,
        notify: request.onNotify,
        prompt: (prompt) => this.prompt(request, pending, prompt),
      });
      return runtime.getProviderAuthStatus(request.providerId);
    } finally {
      this.finishLogin(request.requestId, pending, new Error("Pi OAuth login finished"));
    }
  }

  answerPrompt(answer: PiOAuthPromptAnswer): void {
    const login = this.ownedLogin(answer.owner, answer.requestId);
    const prompt = login.prompts.get(answer.promptId);
    if (!prompt) throw new Error(`Unknown Pi OAuth prompt: ${answer.promptId}`);
    login.prompts.delete(answer.promptId);
    prompt.cleanup();
    if (answer.cancelled === true) {
      prompt.reject(new Error("Pi OAuth prompt cancelled"));
      return;
    }
    if (answer.value === undefined) throw new Error("Pi OAuth prompt answer requires a value");
    prompt.resolve(answer.value);
  }

  cancel(owner: object, requestId: string): boolean {
    const login = this.logins.get(requestId);
    if (!login) return false;
    if (login.owner !== owner) throw new Error(`Pi OAuth request '${requestId}' is owned by another client`);
    this.cancelLogin(login, new Error("Pi OAuth login cancelled"));
    return true;
  }

  cancelOwnedBy(owner: object): number {
    let cancelled = 0;
    for (const login of this.logins.values()) {
      if (login.owner !== owner) continue;
      this.cancelLogin(login, new Error("Pi OAuth login cancelled because the client disconnected"));
      cancelled += 1;
    }
    return cancelled;
  }

  private async runtime(): Promise<PiOAuthRuntime> {
    this.runtimePromise ??= this.createRuntime();
    return await this.runtimePromise;
  }

  private requireOAuthProvider(runtime: PiOAuthRuntime, providerId: string): void {
    const provider = runtime.getProvider(providerId);
    if (!provider?.auth.oauth) {
      throw new Error(`Unknown Pi OAuth provider '${providerId}'`);
    }
  }

  private prompt(request: PiOAuthLoginRequest, login: PendingLogin, prompt: AuthPrompt): Promise<string> {
    if (login.controller.signal.aborted) return Promise.reject(new Error("Pi OAuth login cancelled"));
    const promptId = `${request.requestId}-prompt-${++login.promptSequence}`;
    return new Promise<string>((resolve, reject) => {
      let settled = false;
      const settle = (result: { value: string } | { error: Error }) => {
        if (settled) return;
        settled = true;
        login.prompts.delete(promptId);
        cleanup();
        if ("value" in result) resolve(result.value);
        else reject(result.error);
      };
      const onLoginAbort = () => settle({ error: new Error("Pi OAuth login cancelled") });
      const onPromptAbort = () => settle({ error: new Error("Pi OAuth prompt cancelled") });
      const cleanup = () => {
        login.controller.signal.removeEventListener("abort", onLoginAbort);
        prompt.signal?.removeEventListener("abort", onPromptAbort);
      };
      login.controller.signal.addEventListener("abort", onLoginAbort, { once: true });
      prompt.signal?.addEventListener("abort", onPromptAbort, { once: true });
      login.prompts.set(promptId, {
        resolve: (value) => settle({ value }),
        reject: (error) => settle({ error }),
        cleanup,
      });
      request.onPrompt(promptId, prompt);
    });
  }

  private ownedLogin(owner: object, requestId: string): PendingLogin {
    const login = this.logins.get(requestId);
    if (!login) throw new Error(`Unknown Pi OAuth request: ${requestId}`);
    if (login.owner !== owner) throw new Error(`Pi OAuth request '${requestId}' is owned by another client`);
    return login;
  }

  private cancelLogin(login: PendingLogin, error: Error): void {
    for (const prompt of login.prompts.values()) {
      prompt.cleanup();
      prompt.reject(error);
    }
    login.prompts.clear();
    login.controller.abort(error);
  }

  private finishLogin(requestId: string, login: PendingLogin, error: Error): void {
    if (this.logins.get(requestId) !== login) return;
    this.logins.delete(requestId);
    if (this.providerRequests.get(login.providerId) === requestId) {
      this.providerRequests.delete(login.providerId);
    }
    for (const prompt of login.prompts.values()) {
      prompt.cleanup();
      prompt.reject(error);
    }
    login.prompts.clear();
  }
}
