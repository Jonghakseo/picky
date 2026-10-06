import { describe, expect, it } from "vitest";
import { ANTHROPIC_FAST_MODE_BETA, applyFastModeToPayload, isFastModeSupported } from "./fast-mode-policy.js";

describe("fast mode policy", () => {
  it("supports only the documented direct-provider models", () => {
    const supported = [
      ["openai-codex", "gpt-5.4"], ["openai-codex", "gpt-5.5"], ["openai-codex", "gpt-5.6-sol"], ["openai-codex", "gpt-6-astra"],
      ["openai", "gpt-5.5"], ["openai", "gpt-6.1-sol"],
      ["anthropic", "claude-opus-5-5"], ["anthropic", "claude-opus-5"], ["anthropic", "claude-opus-4-8"], ["anthropic", "claude-opus-4-8-20260115"],
    ];
    const unsupported = [
      ["openai-codex", "gpt-5.3-codex-spark"], ["openai-codex", "gpt-5.1"], ["azure", "gpt-6-sol"], ["openrouter", "gpt-5.5"],
      ["anthropic", "claude-opus-4-7"], ["anthropic", "claude-opus-4-6"], ["anthropic", "claude-sonnet-5"], ["amazon-bedrock", "claude-opus-5-5"],
    ];
    for (const [provider, id] of supported) expect(isFastModeSupported({ provider: provider!, id: id! }), `${provider}/${id}`).toBe(true);
    for (const [provider, id] of unsupported) expect(isFastModeSupported({ provider: provider!, id: id! }), `${provider}/${id}`).toBe(false);
    expect(isFastModeSupported(undefined)).toBe(false);
  });

  it("requests the priority service tier from OpenAI", () => {
    const payload = { model: "gpt-5.5", input: [], text: { verbosity: "low" } };
    expect(applyFastModeToPayload(payload, { provider: "openai-codex", id: "gpt-5.5" })).toEqual({ ...payload, service_tier: "priority" });
  });

  it("adds fast speed and its beta to Claude requests without dropping existing betas", () => {
    const payload = { model: "claude-opus-5-5", messages: [], betas: ["claude-code-20250219", "oauth-2025-04-20"] };
    expect(applyFastModeToPayload(payload, { provider: "anthropic", id: "claude-opus-5-5" })).toEqual({
      ...payload, speed: "fast", betas: ["claude-code-20250219", "oauth-2025-04-20", ANTHROPIC_FAST_MODE_BETA],
    });
    const already = { model: "claude-opus-5-5", betas: [ANTHROPIC_FAST_MODE_BETA] };
    expect(applyFastModeToPayload(already, { provider: "anthropic", id: "claude-opus-5-5" })).toMatchObject({ betas: [ANTHROPIC_FAST_MODE_BETA] });
    expect(applyFastModeToPayload({ model: "claude-opus-5" }, { provider: "anthropic", id: "claude-opus-5" })).toEqual({
      model: "claude-opus-5", speed: "fast", betas: [ANTHROPIC_FAST_MODE_BETA],
    });
  });

  it("leaves unsupported models and non-object payloads unchanged", () => {
    const payload = { model: "gpt-6-sol", input: [] };
    expect(applyFastModeToPayload(payload, { provider: "azure", id: "gpt-6-sol" })).toBe(payload);
    expect(applyFastModeToPayload("raw", { provider: "openai-codex", id: "gpt-5.5" })).toBe("raw");
  });
});
