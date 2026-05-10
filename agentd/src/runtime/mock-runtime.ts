import type { BuiltPrompt } from "../prompt-builder.js";
import { STEER_PREFIX } from "../domain/log-prefixes.js";
import type { ModelCycleDirection, PickyQueueMode } from "../protocol.js";
import type { AgentRuntime, RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, RuntimeSteerResult, ThinkingLevel } from "./types.js";

export class MockRuntime implements AgentRuntime {
  private sequence = 0;
  async create(prompt: BuiltPrompt): Promise<RuntimeSessionHandle> {
    const handle = new MockRuntimeSession(`mock-${++this.sequence}`);
    queueMicrotask(() => {
      handle.emit({ type: "log", line: `mock runtime accepted prompt (${prompt.text.length} chars)` });
      handle.emit({ type: "status", status: "running", summary: "Mock session running" });
    });
    return handle;
  }

  async prewarm(): Promise<RuntimeSessionHandle> {
    const handle = new MockRuntimeSession(`mock-${++this.sequence}`);
    queueMicrotask(() => {
      handle.emit({ type: "log", line: "mock runtime prewarmed" });
    });
    return handle;
  }
}

export class MockRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  private steering: string[] = [];
  private followUpQueue: string[] = [];
  private modelIndex = 0;
  private thinkingIndex = 3;
  private readonly models = ["mock/gpt-5.5", "mock/opus-4-7"];
  private readonly thinkingLevels: ThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh"];
  steeringMode: PickyQueueMode = "one-at-a-time";
  followUpMode: PickyQueueMode = "one-at-a-time";
  isStreaming = false;

  constructor(readonly id: string) {}

  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.followUpQueue.push(prompt.text);
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

  getAssistantRunMetadata(): RuntimeAssistantRunMetadata {
    return this.currentAssistantRunMetadata();
  }

  cycleThinkingLevel(): RuntimeAssistantRunMetadata {
    this.thinkingIndex = (this.thinkingIndex + 1) % this.thinkingLevels.length;
    return this.currentAssistantRunMetadata();
  }

  async cycleModel(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined> {
    const step = direction === "backward" ? -1 : 1;
    this.modelIndex = (this.modelIndex + step + this.models.length) % this.models.length;
    return this.currentAssistantRunMetadata();
  }

  private currentAssistantRunMetadata(): RuntimeAssistantRunMetadata {
    return { model: this.models[this.modelIndex], thinkingLevel: this.thinkingLevels[this.thinkingIndex] };
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
