import { createAgentSessionServices, getAgentDir } from "@earendil-works/pi-coding-agent";
import type { AgentSessionServices } from "@earendil-works/pi-coding-agent";
import { scopedModelsFromServices } from "./pi-model-resolution.js";
import type { RuntimeTextCompleter } from "./types.js";

const CLASSIFICATION_MAX_TOKENS = 300;

export interface PiTextCompleterOptions {
  cwd?: string;
  agentDir?: string;
  createServices?: typeof createAgentSessionServices;
  getAgentDir?: typeof getAgentDir;
}

interface LowCostModel {
  id: string;
  provider: string;
  input: readonly string[];
  cost: { input: number; output: number; cacheRead: number; cacheWrite: number };
}

/**
 * Opens no Pi session and writes no transcript. It resolves only authenticated
 * models and uses Pi's published per-million-token price metadata to avoid a
 * user's expensive default model for background classification.
 */
export class PiTextCompleter implements RuntimeTextCompleter {
  constructor(private readonly options: PiTextCompleterOptions = {}) {}

  async complete(input: { system: string; prompt: string; maxTokens?: number; signal?: AbortSignal }): Promise<string> {
    const services = await this.createServices();
    const model = await lowCostAuthenticatedModelFromServices(services);
    if (!model) throw new Error("No authenticated text model is available for background classification");
    const maxTokens = boundedMaxTokens(input.maxTokens);
    const response = await services.modelRuntime.completeSimple(model, {
      systemPrompt: input.system,
      messages: [{ role: "user", content: [{ type: "text", text: input.prompt }], timestamp: Date.now() }],
    }, { maxTokens, signal: input.signal });
    return response.content
      .filter((part) => part.type === "text")
      .map((part) => part.text)
      .join("");
  }

  private async createServices(): Promise<AgentSessionServices> {
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();
    return await createServices({ cwd: this.options.cwd ?? process.cwd(), agentDir });
  }
}

export async function lowCostAuthenticatedModelFromServices(services: AgentSessionServices) {
  const enabledModels = services.settingsManager?.getEnabledModels?.();
  const scopedModels = await scopedModelsFromServices(services);
  // An unmatched explicit scope is still a constraint, not permission to send
  // background work to another authenticated provider.
  const candidates = enabledModels?.length
    ? scopedModels.map((entry) => entry.model)
    : await services.modelRuntime.getAvailable();
  return selectLowCostAuthenticatedModel(candidates, (provider) => services.modelRuntime.hasConfiguredAuth(provider));
}

export function selectLowCostAuthenticatedModel<T extends LowCostModel>(
  candidates: readonly T[],
  hasConfiguredAuth: (provider: string) => boolean,
): T | undefined {
  return candidates
    .filter((model) => model.input.includes("text") && hasConfiguredAuth(model.provider))
    .sort((lhs, rhs) => (
      totalRate(lhs).localeCompare(totalRate(rhs))
      || lhs.provider.localeCompare(rhs.provider)
      || lhs.id.localeCompare(rhs.id)
    ))[0];
}

function boundedMaxTokens(requested: number | undefined): number {
  if (!Number.isFinite(requested)) return CLASSIFICATION_MAX_TOKENS;
  return Math.min(CLASSIFICATION_MAX_TOKENS, Math.max(1, Math.floor(requested!)));
}

function totalRate(model: LowCostModel): string {
  // Fixed-width encoding preserves numeric order without making assumptions about
  // provider or model names. All rates are Pi's published USD-per-million values.
  const total = model.cost.input + model.cost.output + model.cost.cacheRead + model.cost.cacheWrite;
  return total.toFixed(12).padStart(24, "0");
}
