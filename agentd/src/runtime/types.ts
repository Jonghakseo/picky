import type { BuiltPrompt } from "../prompt-builder.js";

export type RuntimeSessionStatus = "running" | "waiting_for_input" | "completed" | "failed" | "cancelled";

export type RuntimeEvent =
  | { type: "log"; line: string }
  | { type: "status"; status: RuntimeSessionStatus; summary?: string }
  | { type: "tool"; toolCallId: string; name: string; status: "running" | "succeeded" | "failed"; preview?: string };

export interface RuntimeSessionHandle {
  id: string;
  followUp(prompt: BuiltPrompt): Promise<void>;
  steer(text: string): Promise<void>;
  abort(): Promise<void>;
  subscribe(listener: (event: RuntimeEvent) => void): () => void;
}

export interface AgentRuntime {
  create(prompt: BuiltPrompt, options: { cwd?: string }): Promise<RuntimeSessionHandle>;
}
