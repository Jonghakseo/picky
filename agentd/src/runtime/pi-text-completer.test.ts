import { describe, expect, it, vi } from "vitest";
import type { AgentSessionServices } from "@earendil-works/pi-coding-agent";
import { lowCostAuthenticatedModelFromServices, selectLowCostAuthenticatedModel } from "./pi-text-completer.js";

const { resolveScope } = vi.hoisted(() => ({ resolveScope: vi.fn() }));
vi.mock("./pi-model-resolution.js", () => ({ scopedModelsFromServices: resolveScope }));

const models = [
  {
    provider: "anthropic",
    id: "expensive-default",
    input: ["text"],
    cost: { input: 15, output: 75, cacheRead: 1, cacheWrite: 2 },
  },
  {
    provider: "openai",
    id: "unconfigured-cheap",
    input: ["text"],
    cost: { input: 0.1, output: 0.4, cacheRead: 0.01, cacheWrite: 0.02 },
  },
  {
    provider: "anthropic",
    id: "authenticated-low-cost",
    input: ["text"],
    cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 0.6 },
  },
  {
    provider: "anthropic",
    id: "image-only",
    input: ["image"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  },
] as const;

describe("PiTextCompleter model selection", () => {
  it("does not broaden a nonempty enabledModels scope when no model resolves", async () => {
    resolveScope.mockResolvedValueOnce([]);
    const getAvailable = vi.fn().mockResolvedValue(models);
    const services = {
      settingsManager: { getEnabledModels: () => ["excluded-provider/unavailable-model"] },
      modelRuntime: { getAvailable, hasConfiguredAuth: () => true },
    } as unknown as AgentSessionServices;

    expect(await lowCostAuthenticatedModelFromServices(services)).toBeUndefined();
    expect(getAvailable).not.toHaveBeenCalled();
  });

  it("uses the authenticated catalogue only when no effective model scope is configured", async () => {
    resolveScope.mockResolvedValueOnce([]);
    const getAvailable = vi.fn().mockResolvedValue(models);
    const services = {
      settingsManager: { getEnabledModels: () => undefined },
      modelRuntime: { getAvailable, hasConfiguredAuth: (provider: string) => provider === "anthropic" },
    } as unknown as AgentSessionServices;

    expect((await lowCostAuthenticatedModelFromServices(services))?.id).toBe("authenticated-low-cost");
    expect(getAvailable).toHaveBeenCalledOnce();
  });

  it("chooses the lowest published-cost authenticated text model instead of an expensive default", () => {
    const selected = selectLowCostAuthenticatedModel(models, (provider) => provider === "anthropic");

    expect(selected?.id).toBe("authenticated-low-cost");
  });

  it("returns no model when no text-capable candidate has configured authentication", () => {
    expect(selectLowCostAuthenticatedModel(models, () => false)).toBeUndefined();
  });
});
