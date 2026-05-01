import type { BuiltPrompt } from "../prompt-builder.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./types.js";

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
}

class MockRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  constructor(readonly id: string) {}

  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.emit({ type: "log", line: `follow-up queued (${prompt.text.length} chars)` });
    this.emit({ type: "status", status: "running", summary: "Follow-up received" });
  }

  async steer(text: string): Promise<void> {
    this.emit({ type: "log", line: `steer: ${text}` });
  }

  async abort(): Promise<void> {
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled by app" });
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}
