import { describe, expect, it } from "vitest";
import { buildTaskConfig, isKnownPresetProvider, PRESET_CATALOG, resolveDefaultPresets } from "./config.js";

describe("Task routing defaults", () => {
  it("uses the catalog tiers for a known provider instead of reusing the main model everywhere", () => {
    const config = buildTaskConfig({ provider: "anthropic", id: "claude-opus-5-5" });
    expect(config.presets.fast).toEqual({ provider: "anthropic", model: "claude-haiku-5-5", thinking: "low" });
    expect(config.presets.powerful).toEqual({ provider: "anthropic", model: "claude-opus-5-5", thinking: "high" });
    expect(config.evaluator).toEqual({ provider: "anthropic", model: "claude-haiku-5-5", thinking: "low" });
    expect(config.preferClassifier).toBe(false);
  });

  it("never guesses model ids for an unknown provider; it varies only the thinking level", () => {
    const resolved = resolveDefaultPresets({ provider: "openrouter", id: "anthropic/claude-sonnet-5-5" });
    expect(resolved.source).toBe("parent-model");
    expect(new Set(Object.values(resolved.presets).map((preset) => preset.model))).toEqual(new Set(["anthropic/claude-sonnet-5-5"]));
    expect(resolved.presets.fast.thinking).toBe("low");
    expect(resolved.presets.powerful.thinking).toBe("high");
  });

  it("offers the parent provider's evaluator as a fallback even when the provider is not in the catalog", () => {
    const config = buildTaskConfig({ provider: "openrouter", id: "some/model" });
    expect(config.evaluatorFallbacks.openrouter).toEqual({ provider: "openrouter", model: "some/model", thinking: "low" });
    for (const provider of Object.keys(PRESET_CATALOG)) expect(config.evaluatorFallbacks[provider]).toBeDefined();
    expect(isKnownPresetProvider("openrouter")).toBe(false);
    expect(isKnownPresetProvider("openai-codex")).toBe(true);
  });
});

describe("Task models the user chose in settings", () => {
  const main = { provider: "openai-codex", id: "gpt-6-sol" };

  it("replaces only what the user chose for each level and keeps the rest automatic", () => {
    const presets = buildTaskConfig(main, {
      fast: { model: { provider: "anthropic", id: "claude-haiku-5-5" } },
      powerful: { thinking: "xhigh" },
    }).presets;
    // A model without a thinking choice keeps the level's automatic thinking.
    expect(presets.fast).toEqual({ provider: "anthropic", model: "claude-haiku-5-5", thinking: "low" });
    expect(presets.balanced).toEqual({ provider: "openai-codex", model: "gpt-6-sol", thinking: "medium" });
    expect(presets.powerful).toEqual({ provider: "openai-codex", model: "gpt-6-astra", thinking: "xhigh" });
  });

  it("keeps the evaluator that picks the level automatic", () => {
    const config = buildTaskConfig(main, { fast: { model: { provider: "anthropic", id: "claude-haiku-5-5" }, thinking: "off" } });
    expect(config.evaluator).toEqual({ provider: "openai-codex", model: "gpt-6-luna", thinking: "low" });
  });
});
