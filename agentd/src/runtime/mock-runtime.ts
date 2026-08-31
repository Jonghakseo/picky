import type { BuiltPrompt } from "../prompt-builder.js";
import { STEER_PREFIX } from "../domain/log-prefixes.js";
import type { ModelCycleDirection, PickyQueueMode } from "../protocol.js";
import type { AgentRuntime, RewindBranchMessage, RewindResult, RewindTarget, RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeGlobalModelScopeChange, RuntimeModelOption, RuntimeSessionHandle, RuntimeSessionOptions, RuntimeSlashCommand, RuntimeSteerResult, ThinkingLevel } from "./types.js";
import { modelScopeRevision, validateExactModelScope } from "./pi-model-resolution.js";
import { PiModelScopeConflictError } from "./model-scope-errors.js";

export class MockRuntime implements AgentRuntime {
  private sequence = 0;
  private globalModelPatterns: string[] | undefined;

  async setGlobalModelScope(change: RuntimeGlobalModelScopeChange): Promise<void> {
    if (modelScopeRevision(this.globalModelPatterns) !== change.expectedRevision) {
      throw new PiModelScopeConflictError();
    }
    this.globalModelPatterns = change.mode === "all" ? undefined : validateExactModelScope(change.patterns ?? []);
  }
  async create(prompt: BuiltPrompt): Promise<RuntimeSessionHandle> {
    const handle = new MockRuntimeSession(`mock-${++this.sequence}`, () => this.globalModelPatterns);
    handle.appendMockTurn(prompt.text, `Mock response to: ${prompt.text}`);
    queueMicrotask(() => {
      handle.emit({ type: "log", line: `mock runtime accepted prompt (${prompt.text.length} chars)` });
      handle.emit({ type: "status", status: "running", summary: "Mock session running" });
    });
    return handle;
  }

  async prewarm(): Promise<RuntimeSessionHandle> {
    const handle = new MockRuntimeSession(`mock-${++this.sequence}`, () => this.globalModelPatterns);
    queueMicrotask(() => {
      handle.emit({ type: "log", line: "mock runtime prewarmed" });
    });
    return handle;
  }
}

interface MockTreeEntry {
  entryId: string;
  role: "user" | "assistant";
  text: string;
  parentId?: string;
  createdAt: string;
}

export class MockRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  private treeEntries: MockTreeEntry[] = [];
  private leafId?: string;
  private rewindSequence = 0;
  private steering: string[] = [];
  private followUpQueue: string[] = [];
  private modelIndex = 0;
  private thinkingIndex = 3;
  private readonly models: RuntimeModelOption[] = [
    { provider: "mock", modelId: "gpt-5.5", displayName: "mock/gpt-5.5", pattern: "mock/gpt-5.5" },
    { provider: "mock", modelId: "opus-4-7", displayName: "mock/opus-4-7", pattern: "mock/opus-4-7" },
  ];
  private readonly thinkingLevels: ThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
  steeringMode: PickyQueueMode = "one-at-a-time";
  followUpMode: PickyQueueMode = "one-at-a-time";
  isStreaming = false;
  isCompacting = false;

  constructor(
    readonly id: string,
    private readonly globalModelPatterns: () => string[] | undefined = () => undefined,
  ) {}

  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.followUpQueue.push(prompt.text);
    this.appendMockTurn(prompt.text, `Mock response to: ${prompt.text}`);
    this.emitQueueUpdate();
    this.emit({ type: "log", line: `follow-up queued (${prompt.text.length} chars)` });
    this.emit({ type: "status", status: "running", summary: "Follow-up queued" });
  }

  async steer(prompt: BuiltPrompt): Promise<RuntimeSteerResult> {
    this.steering.push(prompt.text);
    this.emitQueueUpdate();
    this.emit({ type: "log", line: `${STEER_PREFIX}${prompt.text}` });
    return { handledSynchronously: false };
  }

  async abort(): Promise<void> {
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled by app" });
  }

  async compact(_customInstructions?: string): Promise<void> {
    // Match AgentSession.compact(): an active turn is stopped before manual compaction starts.
    this.isStreaming = false;
    this.isCompacting = true;
    this.emit({ type: "status", status: "running", summary: "Compacting session…", compactionStarted: true, compactionReason: "manual" });
    this.isCompacting = false;
    this.emit({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, compactionReason: "manual" });
  }

  getAssistantRunMetadata(): RuntimeAssistantRunMetadata {
    return this.currentAssistantRunMetadata();
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingIndex = this.thinkingLevels.indexOf(level);
  }

  cycleThinkingLevel(): RuntimeAssistantRunMetadata {
    this.thinkingIndex = (this.thinkingIndex + 1) % this.thinkingLevels.length;
    return this.currentAssistantRunMetadata();
  }

  async setExactModel(provider: string, modelId: string): Promise<RuntimeAssistantRunMetadata> {
    const selected = this.availableInGlobalScope().find((model) => model.provider === provider && model.modelId === modelId);
    if (!selected) throw new Error(`Model is not available in this session: ${provider}/${modelId}`);
    this.modelIndex = this.models.findIndex((model) => model.provider === selected.provider && model.modelId === selected.modelId);
    return this.currentAssistantRunMetadata();
  }

  async listRuntimeOptions(): Promise<RuntimeSessionOptions> {
    const patterns = this.globalModelPatterns();
    const current = this.models[this.modelIndex]!;
    const scopedModels = this.availableInGlobalScope();
    const scope = patterns?.length
      ? { mode: "exact" as const, patterns: [...patterns], editable: true, revision: modelScopeRevision(patterns), resolvedModelIds: scopedModels.map((model) => model.pattern) }
      : { mode: "all" as const, patterns: [], editable: true, revision: modelScopeRevision(undefined), resolvedModelIds: [] };
    return {
      models: scopedModels.map((model) => ({ ...model })),
      allModels: this.models.map((model) => ({ ...model })),
      globalScope: scope,
      effectiveScope: { ...scope, revision: undefined },
      thinkingLevels: [...this.thinkingLevels],
      currentModel: { provider: current.provider, modelId: current.modelId },
    };
  }

  async cycleModel(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined> {
    const scopedModels = this.availableInGlobalScope();
    if (scopedModels.length === 0) return this.currentAssistantRunMetadata();
    const current = this.models[this.modelIndex]!;
    const currentInScopeIndex = scopedModels.findIndex((model) => model.provider === current.provider && model.modelId === current.modelId);
    const nextIndex = currentInScopeIndex < 0
      ? direction === "backward" ? scopedModels.length - 1 : 0
      : (currentInScopeIndex + (direction === "backward" ? -1 : 1) + scopedModels.length) % scopedModels.length;
    const target = scopedModels[nextIndex]!;
    this.modelIndex = this.models.findIndex((model) => model.provider === target.provider && model.modelId === target.modelId);
    return this.currentAssistantRunMetadata();
  }

  private availableInGlobalScope(): RuntimeModelOption[] {
    const patterns = this.globalModelPatterns();
    if (!patterns?.length) return this.models;
    const allowed = new Set(patterns.map((pattern) => pattern.toLowerCase()));
    return this.models.filter((model) => allowed.has(model.pattern.toLowerCase()));
  }

  private currentAssistantRunMetadata(): RuntimeAssistantRunMetadata {
    return { model: this.models[this.modelIndex]!.pattern, thinkingLevel: this.thinkingLevels[this.thinkingIndex] };
  }

  clearQueue(): { steering: string[]; followUp: string[] } {
    const result = { steering: [...this.steering], followUp: [...this.followUpQueue] };
    this.steering = [];
    this.followUpQueue = [];
    this.emitQueueUpdate();
    return result;
  }

  getSteeringMessages(): readonly string[] {
    return this.steering;
  }

  getFollowUpMessages(): readonly string[] {
    return this.followUpQueue;
  }

  listSlashCommands(): RuntimeSlashCommand[] {
    return [
      { name: "mock", description: "Mock runtime command", source: "extension" },
      { name: "skill:mock-skill", description: "Mock skill command", source: "skill" },
    ];
  }

  appendMockTurn(userText: string, assistantText: string): { userEntryId: string; assistantEntryId: string } {
    const userEntryId = `mock-rewind-user-${++this.rewindSequence}`;
    const assistantEntryId = `mock-rewind-assistant-${++this.rewindSequence}`;
    const now = new Date().toISOString();
    this.treeEntries.push({ entryId: userEntryId, role: "user", text: userText, parentId: this.leafId, createdAt: now });
    this.treeEntries.push({ entryId: assistantEntryId, role: "assistant", text: assistantText, parentId: userEntryId, createdAt: now });
    this.leafId = assistantEntryId;
    return { userEntryId, assistantEntryId };
  }

  listRewindTargets(): RewindTarget[] {
    const activeIds = new Set(this.activeBranchEntries().map((entry) => entry.entryId));
    return this.treeEntries
      .filter((entry) => entry.role === "user" && activeIds.has(entry.entryId))
      .map((entry) => ({ entryId: entry.entryId, text: entry.text, createdAt: entry.createdAt }));
  }

  async rewindToEntry(entryId: string): Promise<RewindResult> {
    if (this.isStreaming) throw new Error("Cannot rewind while mock session is streaming");
    const entry = this.treeEntries.find((candidate) => candidate.entryId === entryId && candidate.role === "user");
    if (!entry) throw new Error(`Unknown rewind target: ${entryId}`);
    this.leafId = entry.parentId;
    return { editorText: entry.text, cancelled: false };
  }

  getActiveBranchTranscript(): RewindBranchMessage[] {
    return this.activeBranchEntries().map((entry) => ({ role: entry.role, text: entry.text }));
  }

  private activeBranchEntries(): MockTreeEntry[] {
    const byId = new Map(this.treeEntries.map((entry) => [entry.entryId, entry]));
    const branch: MockTreeEntry[] = [];
    let cursor = this.leafId;
    while (cursor) {
      const entry = byId.get(cursor);
      if (!entry) break;
      branch.push(entry);
      cursor = entry.parentId;
    }
    return branch.reverse();
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }

  private emitQueueUpdate(): void {
    this.emit({ type: "queue_update", steering: [...this.steering], followUp: [...this.followUpQueue] });
  }
}
