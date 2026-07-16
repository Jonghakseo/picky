import type {
  AgentSession,
  AgentSessionServices,
  CreateAgentSessionFromServicesOptions,
} from "@earendil-works/pi-coding-agent";
import type { RuntimeModelOption, ThinkingLevel } from "./types.js";
import { readModelMetadata as piReadModelMetadata, readThinkingLevel as piReadThinkingLevel } from "./pi-capabilities.js";
import { logAgentd } from "../local-log.js";

export type ScopedModelOption = NonNullable<CreateAgentSessionFromServicesOptions["scopedModels"]>[number];
type RuntimeModel = ScopedModelOption["model"];

export async function scopedModelsFromServices(services: AgentSessionServices): Promise<ScopedModelOption[]> {
  const patterns = services.settingsManager?.getEnabledModels?.();
  if (!patterns?.length) return [];

  const available = await availableModelsFromServices(services);
  if (available.length === 0) return [];

  const scoped: ScopedModelOption[] = [];
  for (const pattern of patterns) {
    const parsed = parseScopedModelPattern(pattern);
    const model = findScopedModel(parsed.modelPattern, available);
    if (!model || scoped.some((entry) => modelsEqual(entry.model, model))) continue;
    scoped.push({ model, ...(parsed.thinkingLevel ? { thinkingLevel: parsed.thinkingLevel } : {}) });
  }
  return scoped;
}

export async function availableModelsFromServices(services: AgentSessionServices): Promise<RuntimeModel[]> {
  return services.modelRegistry?.getAvailable?.() ?? [];
}

export async function modelFromServices(services: AgentSessionServices, pattern: string | undefined): Promise<RuntimeModel | undefined> {
  if (!pattern) return undefined;
  const available = await availableModelsFromServices(services);
  const model = findScopedModel(pattern, available);
  if (!model) logAgentd("pi fixed model not found", { pattern, available: available.length });
  return model;
}

export async function automaticModelFromServices(
  services: AgentSessionServices,
  scopedModels: ScopedModelOption[],
): Promise<RuntimeModel | undefined> {
  const defaultModel = await modelFromServices(services, services.settingsManager?.getDefaultModel?.());
  if (defaultModel) return defaultModel;

  const scopedModel = scopedModels[0]?.model;
  if (scopedModel) return scopedModel;

  const available = await availableModelsFromServices(services);
  return available.find((model) => services.modelRegistry?.hasConfiguredAuth?.(model)) ?? available[0];
}

export function runtimeModelOptionFromModel(model: RuntimeModel): RuntimeModelOption {
  return {
    provider: model.provider,
    modelId: model.id,
    displayName: model.name && model.name !== model.id ? `${model.name} (${model.provider}/${model.id})` : `${model.provider}/${model.id}`,
    pattern: `${model.provider}/${model.id}`,
  };
}

export function normalizeModelPattern(pattern: string | undefined): string | undefined {
  const trimmed = pattern?.trim();
  return trimmed ? trimmed : undefined;
}

function parseScopedModelPattern(pattern: string): { modelPattern: string; thinkingLevel?: ThinkingLevel } {
  const trimmed = pattern.trim();
  const colonIndex = trimmed.lastIndexOf(":");
  if (colonIndex === -1) return { modelPattern: trimmed };
  const suffix = trimmed.slice(colonIndex + 1);
  const thinkingLevel = parseThinkingLevel(suffix);
  if (!thinkingLevel) return { modelPattern: trimmed };
  return { modelPattern: trimmed.slice(0, colonIndex), thinkingLevel };
}

function findScopedModel(pattern: string, available: RuntimeModel[]): RuntimeModel | undefined {
  const normalized = pattern.trim().toLowerCase();
  if (!normalized) return undefined;
  const exact = available.find((model) => {
    const provider = model.provider.toLowerCase();
    const id = model.id.toLowerCase();
    return id === normalized || `${provider}/${id}` === normalized;
  });
  if (exact) return exact;
  return available.find((model) => model.id.toLowerCase().includes(normalized) || model.name?.toLowerCase().includes(normalized));
}

function modelsEqual(left: RuntimeModel, right: RuntimeModel): boolean {
  return left.provider === right.provider && left.id === right.id;
}

export function applyScopedModelsForCycling(session: AgentSession, scopedModels: ScopedModelOption[]): void {
  if (scopedModels.length === 0) return;
  const setScopedModels = (session as AgentSession & { setScopedModels?: (scopedModels: ScopedModelOption[]) => void }).setScopedModels;
  if (typeof setScopedModels !== "function") return;
  setScopedModels.call(session, scopedModels);
}

export function currentModelId(session: AgentSession): string | undefined {
  return piReadModelMetadata(session)?.modelId;
}

export function currentThinkingLevel(session: AgentSession): ThinkingLevel | undefined {
  return piReadThinkingLevel(session);
}

function parseThinkingLevel(value: unknown): ThinkingLevel | undefined {
  if (value === "off" || value === "minimal" || value === "low" || value === "medium" || value === "high" || value === "xhigh" || value === "max") return value;
  return undefined;
}
