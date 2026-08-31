import { createHash } from "node:crypto";
import {
  resolveModelScopeWithDiagnostics,
  type AgentSession,
  type AgentSessionServices,
  type CreateAgentSessionFromServicesOptions,
} from "@earendil-works/pi-coding-agent";
import type { RuntimeModelOption, RuntimeModelScope, RuntimeSessionOptions, ThinkingLevel } from "./types.js";
import { readModelMetadata as piReadModelMetadata, readThinkingLevel as piReadThinkingLevel } from "./pi-capabilities.js";
import { logAgentd } from "../local-log.js";

export type ScopedModelOption = NonNullable<CreateAgentSessionFromServicesOptions["scopedModels"]>[number];
type RuntimeModel = ScopedModelOption["model"];

export async function scopedModelsFromServices(services: AgentSessionServices): Promise<ScopedModelOption[]> {
  const patterns = services.settingsManager?.getEnabledModels?.();
  if (!patterns?.length) return [];
  // Pi owns enabledModels matching semantics, including globs and :thinking
  // suffixes. Do not duplicate the resolver in Picky.
  return (await resolveModelScopeWithDiagnostics(patterns, services.modelRuntime)).scopedModels;
}

/** A stable opaque value for compare-and-swap, not a persisted revision counter. */
export function modelScopeRevision(patterns: readonly string[] | undefined): string {
  // Compare exactly what Pi persisted. In particular, do not trim, de-duplicate,
  // or collapse an empty array into `undefined` before calculating the CAS token.
  const encoded = patterns === undefined ? "undefined" : JSON.stringify(patterns);
  return createHash("sha256").update(encoded).digest("base64url");
}

export function validateExactModelScope(patterns: readonly string[]): string[] {
  const seen = new Set<string>();
  const normalized = patterns.map((pattern) => pattern.trim()).filter((pattern) => {
    const canonical = pattern.toLowerCase();
    if (!canonical || seen.has(canonical)) return false;
    seen.add(canonical);
    return true;
  });
  if (normalized.length === 0) throw new Error("An exact model scope requires at least one model");
  return normalized;
}

/**
 * UI editing is deliberately limited to exact resolved provider/modelId values.
 * Pi supports richer glob and thinking-level patterns, which this UI preserves
 * by exposing them as read-only rather than rewriting user configuration.
 */
export function classifyGlobalModelScope(
  patterns: readonly string[] | undefined,
  available: readonly Pick<RuntimeModel, "provider" | "id">[],
): RuntimeModelScope {
  const normalized = patterns?.map((pattern) => pattern.trim()).filter(Boolean) ?? [];
  if (normalized.length === 0) {
    return { mode: "all", patterns: [], editable: true, revision: modelScopeRevision(patterns) };
  }
  const canonical = new Set(available.map((model) => `${model.provider}/${model.id}`.toLowerCase()));
  const advanced = normalized.some((pattern) => {
    const lower = pattern.toLowerCase();
    return /[*?![\]{}]/.test(pattern) || /:(off|minimal|low|medium|high|xhigh|max)$/i.test(pattern) || !canonical.has(lower);
  });
  return {
    mode: "exact",
    patterns: normalized,
    editable: !advanced,
    revision: modelScopeRevision(patterns),
    ...(advanced ? { reason: "advancedPatterns" as const } : {}),
  };
}

export function projectModelScope(
  settings: { enabledModels?: string[] },
  available: readonly Pick<RuntimeModel, "provider" | "id">[],
): RuntimeModelScope | undefined {
  if (settings.enabledModels === undefined) return undefined;
  const scope = classifyGlobalModelScope(settings.enabledModels, available);
  return { ...scope, revision: undefined };
}

export async function availableModelsFromServices(services: AgentSessionServices): Promise<RuntimeModel[]> {
  return [...await services.modelRuntime.getAvailable()];
}

/** Reload Pi settings and project the catalogue plus the three scope sources for a live picker. */
export async function runtimeModelScopesFromServices(
  services: AgentSessionServices,
  session: AgentSession,
): Promise<Pick<RuntimeSessionOptions, "models" | "allModels" | "globalScope" | "projectScope" | "effectiveScope">> {
  const settingsManager = services.settingsManager;
  if (typeof settingsManager?.reload === "function") await settingsManager.reload();
  const available = await availableModelsFromServices(services);
  const globalPatterns = settingsManager?.getGlobalSettings?.().enabledModels;
  const globalScope = {
    ...classifyGlobalModelScope(globalPatterns, available),
    resolvedModelIds: await resolvedGlobalModelIds(globalPatterns, services),
  };
  const projectScope = projectModelScope(settingsManager?.getProjectSettings?.() ?? {}, available);
  const effectiveScope = classifyGlobalModelScope(settingsManager?.getEnabledModels(), available);
  const scopedModels = await scopedModelsFromServices(services);
  synchronizeScopedModelsForCycling(session, scopedModels);
  return {
    models: (scopedModels.length > 0 ? scopedModels.map((entry) => entry.model) : available).map(runtimeModelOptionFromModel),
    allModels: available.map(runtimeModelOptionFromModel),
    globalScope,
    ...(projectScope ? { projectScope } : {}),
    effectiveScope,
  };
}

async function resolvedGlobalModelIds(patterns: readonly string[] | undefined, services: AgentSessionServices): Promise<string[]> {
  if (!patterns?.length) return [];
  const { scopedModels } = await resolveModelScopeWithDiagnostics([...patterns], services.modelRuntime);
  return [...new Set(scopedModels.map((entry) => `${entry.model.provider}/${entry.model.id}`))];
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
  return available.find((model) => services.modelRuntime.hasConfiguredAuth(model.provider)) ?? available[0];
}

export function runtimeModelOptionFromModel(model: RuntimeModel): RuntimeModelOption {
  const pattern = `${model.provider}/${model.id}`;
  return {
    provider: model.provider,
    modelId: model.id,
    displayName: pattern,
    pattern,
  };
}

export function normalizeModelPattern(pattern: string | undefined): string | undefined {
  const trimmed = pattern?.trim();
  return trimmed ? trimmed : undefined;
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

export function applyScopedModelsForCycling(session: AgentSession, scopedModels: ScopedModelOption[]): void {
  if (scopedModels.length === 0) return;
  session.setScopedModels(scopedModels);
}

/** Runtime-options refreshes need to clear a previously configured Pi scope. */
export function synchronizeScopedModelsForCycling(session: AgentSession, scopedModels: ScopedModelOption[]): void {
  session.setScopedModels(scopedModels);
}

export function currentModelId(session: AgentSession): string | undefined {
  return piReadModelMetadata(session)?.modelId;
}

export function currentThinkingLevel(session: AgentSession): ThinkingLevel | undefined {
  return piReadThinkingLevel(session);
}
