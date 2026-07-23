import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { AuthInteraction, AuthPrompt, Credential, Provider } from "@earendil-works/pi-ai";
import { describe, expect, it, vi } from "vitest";
import { PiOAuthService, type PiOAuthRuntime } from "./pi-oauth-service.js";

const anthropicProvider = {
  id: "anthropic",
  name: "Anthropic",
  auth: { oauth: { name: "Anthropic OAuth" } },
} as unknown as Provider;

describe("PiOAuthService", () => {
  it("reads built-in provider status through the public ModelRuntime API", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "picky-pi-oauth-"));
    const service = new PiOAuthService({
      createRuntime: () => ModelRuntime.create({
        authPath: join(agentDir, "auth.json"),
        modelsPath: join(agentDir, "models.json"),
        allowModelNetwork: false,
      }),
    });

    await expect(service.status("anthropic")).resolves.toEqual({ configured: false });
    await expect(service.status("openai-codex")).resolves.toEqual({ configured: false });
  });

  it("forwards provider prompts and notifications and persists the final status", async () => {
    const owner = {};
    const emittedPrompts: Array<{ promptId: string; prompt: AuthPrompt }> = [];
    const emittedNotifications: Parameters<AuthInteraction["notify"]>[0][] = [];
    const runtime = fakeRuntime(async (_providerId, _type, interaction) => {
      const method = await interaction.prompt({
        type: "select",
        message: "Choose a login method",
        options: [{ id: "browser", label: "Browser" }, { id: "device", label: "Device" }],
      });
      expect(method).toBe("browser");
      interaction.notify({ type: "auth_url", url: "https://example.com/oauth" });
      return oauthCredential();
    });
    runtime.getProviderAuthStatus.mockReturnValue({ configured: true, source: "stored" });
    const service = new PiOAuthService({ createRuntime: async () => runtime });

    const login = service.login({
      requestId: "login-1",
      providerId: "anthropic",
      owner,
      onPrompt: (promptId, prompt) => emittedPrompts.push({ promptId, prompt }),
      onNotify: (event) => emittedNotifications.push(event),
    });

    await waitUntil(() => emittedPrompts.length === 1);
    service.answerPrompt({ owner, requestId: "login-1", promptId: emittedPrompts[0]!.promptId, value: "browser" });

    await expect(login).resolves.toEqual({ configured: true, source: "stored" });
    expect(emittedNotifications).toEqual([{ type: "auth_url", url: "https://example.com/oauth" }]);
    expect(runtime.login).toHaveBeenCalledWith("anthropic", "oauth", expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });

  it("rejects the pending provider prompt when the owning request is cancelled", async () => {
    const owner = {};
    let interactionSignal: AbortSignal | undefined;
    const prompts: string[] = [];
    const runtime = fakeRuntime(async (_providerId, _type, interaction) => {
      interactionSignal = interaction.signal;
      await interaction.prompt({ type: "manual_code", message: "Paste the redirect URL" });
      return oauthCredential();
    });
    const service = new PiOAuthService({ createRuntime: async () => runtime });

    const login = service.login({
      requestId: "login-cancel",
      providerId: "anthropic",
      owner,
      onPrompt: (promptId) => prompts.push(promptId),
      onNotify: () => {},
    });
    await waitUntil(() => prompts.length === 1);

    expect(service.cancel(owner, "login-cancel")).toBe(true);
    await expect(login).rejects.toThrow("cancelled");
    expect(interactionSignal?.aborted).toBe(true);
  });

  it("does not let another websocket answer or cancel an owned login", async () => {
    const owner = {};
    const intruder = {};
    const prompts: string[] = [];
    const runtime = fakeRuntime(async (_providerId, _type, interaction) => {
      await interaction.prompt({ type: "select", message: "Choose", options: [{ id: "browser", label: "Browser" }] });
      return oauthCredential();
    });
    const service = new PiOAuthService({ createRuntime: async () => runtime });
    const login = service.login({
      requestId: "login-owned",
      providerId: "anthropic",
      owner,
      onPrompt: (promptId) => prompts.push(promptId),
      onNotify: () => {},
    });
    await waitUntil(() => prompts.length === 1);

    expect(() => service.answerPrompt({ owner: intruder, requestId: "login-owned", promptId: prompts[0]!, value: "browser" }))
      .toThrow("owned by another client");
    expect(() => service.cancel(intruder, "login-owned")).toThrow("owned by another client");

    service.cancel(owner, "login-owned");
    await expect(login).rejects.toThrow("cancelled");
  });

  it("reserves a provider before runtime initialization and honors cancellation during initialization", async () => {
    const owner = {};
    const runtime = fakeRuntime(async () => oauthCredential());
    let resolveRuntime!: (runtime: PiOAuthRuntime) => void;
    const runtimeReady = new Promise<PiOAuthRuntime>((resolve) => { resolveRuntime = resolve; });
    const service = new PiOAuthService({ createRuntime: () => runtimeReady });

    const first = service.login({
      requestId: "login-initializing",
      providerId: "anthropic",
      owner,
      onPrompt: () => {},
      onNotify: () => {},
    });
    await expect(service.login({
      requestId: "login-racing",
      providerId: "anthropic",
      owner,
      onPrompt: () => {},
      onNotify: () => {},
    })).rejects.toThrow("already in progress");

    expect(service.cancel(owner, "login-initializing")).toBe(true);
    resolveRuntime(runtime);
    await expect(first).rejects.toThrow("cancelled");
    expect(runtime.login).not.toHaveBeenCalled();
  });

  it("enforces one active login per provider", async () => {
    const owner = {};
    const prompts: string[] = [];
    const runtime = fakeRuntime(async (_providerId, _type, interaction) => {
      await interaction.prompt({ type: "manual_code", message: "Wait" });
      return oauthCredential();
    });
    const service = new PiOAuthService({ createRuntime: async () => runtime });
    const first = service.login({
      requestId: "login-first",
      providerId: "anthropic",
      owner,
      onPrompt: (promptId) => prompts.push(promptId),
      onNotify: () => {},
    });
    await waitUntil(() => prompts.length === 1);

    await expect(service.login({
      requestId: "login-second",
      providerId: "anthropic",
      owner,
      onPrompt: () => {},
      onNotify: () => {},
    })).rejects.toThrow("already in progress");

    service.cancel(owner, "login-first");
    await expect(first).rejects.toThrow("cancelled");
  });
});

function fakeRuntime(login: PiOAuthRuntime["login"]): PiOAuthRuntime & {
  getProviderAuthStatus: ReturnType<typeof vi.fn>;
  login: ReturnType<typeof vi.fn>;
} {
  return {
    getProvider: vi.fn(() => anthropicProvider),
    getProviderAuthStatus: vi.fn(() => ({ configured: false })),
    login: vi.fn(login),
  } as unknown as PiOAuthRuntime & {
    getProviderAuthStatus: ReturnType<typeof vi.fn>;
    login: ReturnType<typeof vi.fn>;
  };
}

function oauthCredential(): Credential {
  return { type: "oauth", access: "access", refresh: "refresh", expires: Date.now() + 60_000 };
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  throw new Error("condition not reached");
}
