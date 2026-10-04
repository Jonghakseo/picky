/**
 * Which models accept a provider "fast mode" request, and how a provider request
 * body opts into it. Single source of truth for both the request rewrite and the
 * clients' "is fast mode available" signal, so the toggle is never offered for a
 * model whose requests would be sent unchanged.
 *
 * - OpenAI (Responses API, including the Codex subscription endpoint):
 *   `service_tier: "priority"`. OpenAI renamed priority processing to Fast mode
 *   and accepts both "priority" and "fast"; "priority" is the value every
 *   supported model and the Codex endpoint already understand.
 * - Anthropic (Claude API only, research preview): `speed: "fast"` plus the
 *   `fast-mode-2026-02-01` beta. pi-ai builds `betas` into the request body
 *   before the payload hook, so the beta is appended there. Setting an
 *   `anthropic-beta` header instead would replace pi-ai's own beta list
 *   (including the OAuth betas), so it must not be used.
 *
 * Proxies and cloud resellers (Azure, Bedrock, Vertex, OpenRouter) are excluded:
 * Claude fast mode is unavailable there, and their OpenAI routes do not honour
 * the service tier the same way.
 */
export interface FastModeModel {
  readonly provider: string;
  readonly id: string;
}

export const ANTHROPIC_FAST_MODE_BETA = "fast-mode-2026-02-01";

type FastModeFamily = "openai" | "anthropic";

const OPENAI_PROVIDERS = new Set(["openai", "openai-codex"]);
const OPENAI_MODELS = /^gpt-(5\.4|5\.5|5\.6(-[a-z0-9]+)?|6(\.\d+)?(-[a-z0-9]+)?)$/;
const ANTHROPIC_MODELS = /^claude-opus-(5-5|5|4-8)(-\d{8})?$/;

function fastModeFamily(model: FastModeModel | undefined): FastModeFamily | undefined {
  if (!model) return undefined;
  if (OPENAI_PROVIDERS.has(model.provider) && OPENAI_MODELS.test(model.id)) return "openai";
  if (model.provider === "anthropic" && ANTHROPIC_MODELS.test(model.id)) return "anthropic";
  return undefined;
}

export function isFastModeSupported(model: FastModeModel | undefined): boolean {
  return fastModeFamily(model) !== undefined;
}

/**
 * Returns the request body with fast mode applied, or the original body when the
 * model is unsupported or the body is not a JSON object.
 */
export function applyFastModeToPayload(payload: unknown, model: FastModeModel | undefined): unknown {
  const family = fastModeFamily(model);
  if (!family || !isRecord(payload)) return payload;
  if (family === "openai") return { ...payload, service_tier: "priority" };
  const betas = Array.isArray(payload.betas) ? payload.betas.filter((beta): beta is string => typeof beta === "string") : [];
  return {
    ...payload,
    speed: "fast",
    betas: betas.includes(ANTHROPIC_FAST_MODE_BETA) ? betas : [...betas, ANTHROPIC_FAST_MODE_BETA],
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
