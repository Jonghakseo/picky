import type { BuiltPrompt } from "../prompt-builder.js";
import { STEER_PREFIX } from "../domain/log-prefixes.js";
import type { PickyQueueMode } from "../protocol.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, RuntimeSteerResult } from "./types.js";

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
  readonly steeringMode: PickyQueueMode = "one-at-a-time";
  readonly followUpMode: PickyQueueMode = "one-at-a-time";

  constructor(readonly id: string) {}

  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.followUpQueue.push(prompt.text);
    this.emit({ type: "log", line: `follow-up queued (${prompt.text.length} chars)` });
    this.emit({ type: "status", status: "running", summary: "Follow-up received" });
  }

  async steer(text: string): Promise<RuntimeSteerResult> {
    this.steering.push(text);
    this.emit({ type: "log", line: `${STEER_PREFIX}${text}` });
    return { handledSynchronously: false };
  }

  async abort(): Promise<void> {
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled by app" });
  }

  clearQueue(): { steering: string[]; followUp: string[] } {
    const result = { steering: [...this.steering], followUp: [...this.followUpQueue] };
    this.steering = [];
    this.followUpQueue = [];
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
}
