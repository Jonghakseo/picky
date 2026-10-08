/**
 * Task routing configuration.
 *
 * Picky owns this configuration. The original extension also read a `task` key from Pi's global
 * `settings.json` and the nearest project `.pi/task.json`; those user-file sources are deliberately
 * not ported. Defaults derive from the main agent's current model (see `PRESET_CATALOG`).
 */

import type { ModelSelection, TaskConfig, TaskTier, ThinkingLevel } from "../types.js";

export const TASK_TIERS: readonly TaskTier[] = ["fast", "balanced", "powerful"];

/** Thinking level each tier gets when it reuses the parent model. */
export const DEFAULT_TIER_THINKING: Record<TaskTier, ThinkingLevel> = {
  fast: "low",
  balanced: "medium",
  powerful: "high",
};

export interface ParentModel {
  provider: string;
  id: string;
}

export interface ProviderPresetEntry {
  presets: Record<TaskTier, ModelSelection>;
  evaluator: ModelSelection;
}

const select = (provider: string, model: string, thinking: ThinkingLevel): ModelSelection => ({
  provider,
  model,
  thinking,
});

/**
 * Per-provider defaults. Keys are Pi provider ids and every model id below exists in the Pi 1.1.0
 * catalog for that exact provider. Providers that merely proxy the same families (openrouter,
 * vercel-ai-gateway, github-copilot, amazon-bedrock, ...) use different model ids, so they are not
 * guessed here: see `resolveDefaultPresets`.
 */
export const PRESET_CATALOG: Readonly<Record<string, ProviderPresetEntry>> = {
  "openai-codex": {
    presets: {
      fast: select("openai-codex", "gpt-6-luna", "low"),
      balanced: select("openai-codex", "gpt-6-sol", "medium"),
      powerful: select("openai-codex", "gpt-6-astra", "high"),
    },
    evaluator: select("openai-codex", "gpt-6-luna", "low"),
  },
  openai: {
    presets: {
      fast: select("openai", "gpt-6-luna", "low"),
      balanced: select("openai", "gpt-6-sol", "medium"),
      powerful: select("openai", "gpt-6-astra", "high"),
    },
    evaluator: select("openai", "gpt-6-luna", "low"),
  },
  anthropic: {
    presets: {
      fast: select("anthropic", "claude-haiku-5-5", "low"),
      balanced: select("anthropic", "claude-sonnet-5-5", "medium"),
      powerful: select("anthropic", "claude-opus-5-5", "high"),
    },
    evaluator: select("anthropic", "claude-haiku-5-5", "low"),
  },
};

/** How the built-in presets were derived. */
export type PresetSource = "catalog" | "parent-model";

export interface ResolvedDefaultPresets {
  source: PresetSource;
  provider: string;
  presets: Record<TaskTier, ModelSelection>;
  evaluator: ModelSelection;
}

export function isKnownPresetProvider(provider: string | undefined): boolean {
  return provider !== undefined && Object.hasOwn(PRESET_CATALOG, provider);
}

/**
 * Catalog presets for the parent provider when known. Otherwise every tier reuses the parent model
 * itself and only the thinking level changes: an unknown provider never gets switched to a model id
 * that may not exist there.
 */
export function resolveDefaultPresets(parentModel: ParentModel): ResolvedDefaultPresets {
  const entry = PRESET_CATALOG[parentModel.provider];
  if (entry) {
    return {
      source: "catalog",
      provider: parentModel.provider,
      presets: { ...entry.presets },
      evaluator: { ...entry.evaluator },
    };
  }
  return {
    source: "parent-model",
    provider: parentModel.provider,
    presets: {
      fast: select(parentModel.provider, parentModel.id, DEFAULT_TIER_THINKING.fast),
      balanced: select(parentModel.provider, parentModel.id, DEFAULT_TIER_THINKING.balanced),
      powerful: select(parentModel.provider, parentModel.id, DEFAULT_TIER_THINKING.powerful),
    },
    evaluator: select(parentModel.provider, parentModel.id, "low"),
  };
}

/** Default `evaluatorFallbacks`: one lightweight evaluator per catalog provider. */
export function defaultEvaluatorFallbacks(): Record<string, ModelSelection> {
  const fallbacks: Record<string, ModelSelection> = {};
  for (const [provider, entry] of Object.entries(PRESET_CATALOG)) {
    fallbacks[provider] = { ...entry.evaluator };
  }
  return fallbacks;
}

/** The effective routing for one evaluation, derived from the main agent's current model. */
export function buildTaskConfig(parentModel: ParentModel): TaskConfig {
  const defaults = resolveDefaultPresets(parentModel);
  const evaluatorFallbacks = defaultEvaluatorFallbacks();
  if (!Object.hasOwn(evaluatorFallbacks, defaults.provider)) evaluatorFallbacks[defaults.provider] = { ...defaults.evaluator };
  return {
    preferClassifier: false,
    evaluator: defaults.evaluator,
    evaluatorFallbacks,
    presets: defaults.presets,
  };
}
