import { describe, expect, it } from "vitest";
import {
  classifyGlobalModelScope,
  modelScopeRevision,
  projectModelScope,
  validateExactModelScope,
} from "./pi-model-resolution.js";

const catalog = [
  { provider: "anthropic", id: "claude-sonnet", name: "Claude Sonnet" },
  { provider: "openai-codex", id: "gpt-5.5", name: "GPT-5.5" },
];

describe("Pi model scope policy", () => {
  it("treats an absent global enabledModels value as the editable all-model scope", () => {
    expect(classifyGlobalModelScope(undefined, catalog)).toMatchObject({
      mode: "all",
      patterns: [],
      editable: true,
    });
  });

  it("keeps exact canonical model IDs editable", () => {
    expect(classifyGlobalModelScope(["anthropic/claude-sonnet", "openai-codex/gpt-5.5"], catalog)).toMatchObject({
      mode: "exact",
      patterns: ["anthropic/claude-sonnet", "openai-codex/gpt-5.5"],
      editable: true,
    });
  });

  it("marks glob, thinking suffix, and unresolved exact patterns read-only with a localized presentation reason", () => {
    for (const patterns of [["anthropic/*"], ["anthropic/claude-sonnet:high"], ["missing/model"]]) {
      expect(classifyGlobalModelScope(patterns, catalog)).toMatchObject({ editable: false, reason: "advancedPatterns" });
    }
  });

  it("detects a project enabledModels override without conflating it with global scope", () => {
    expect(projectModelScope({ enabledModels: ["openai-codex/gpt-5.5"] }, catalog)).toMatchObject({
      mode: "exact",
      patterns: ["openai-codex/gpt-5.5"],
      editable: true,
    });
    expect(projectModelScope({}, catalog)).toBeUndefined();
  });

  it("rejects an empty exact selection, de-duplicates canonical IDs, and produces stable opaque revisions", () => {
    expect(() => validateExactModelScope([])).toThrow("at least one model");
    expect(validateExactModelScope(["OpenAI-Codex/GPT-5.5", "openai-codex/gpt-5.5"])).toEqual(["OpenAI-Codex/GPT-5.5"]);
    expect(modelScopeRevision(["anthropic/claude-sonnet"])).toBe(modelScopeRevision(["anthropic/claude-sonnet"]));
    expect(modelScopeRevision(["anthropic/claude-sonnet"])).not.toBe(modelScopeRevision(["openai-codex/gpt-5.5"]));
  });

  it("keeps raw persisted scope values distinct from normalized display values", () => {
    expect(modelScopeRevision(undefined)).not.toBe(modelScopeRevision([]));
    expect(modelScopeRevision([" openai-codex/gpt-5.5 "]))
      .not.toBe(modelScopeRevision(["openai-codex/gpt-5.5"]));
    expect(classifyGlobalModelScope([" openai-codex/gpt-5.5 "], catalog)).toMatchObject({
      patterns: ["openai-codex/gpt-5.5"],
      revision: modelScopeRevision([" openai-codex/gpt-5.5 "]),
    });
  });
});
