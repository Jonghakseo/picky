import type { BuiltPrompt } from "../prompt-builder.js";

export type RuntimeSessionStatus = "running" | "waiting_for_input" | "blocked" | "completed" | "failed" | "cancelled";

export type RuntimeEvent =
  | { type: "log"; line: string }
  | { type: "assistant_delta"; delta: string }
  | { type: "status"; status: RuntimeSessionStatus; summary?: string }
  | { type: "tool"; toolCallId: string; name: string; status: "running" | "succeeded" | "failed"; preview?: string }
  | { type: "extension_ui"; request: Record<string, unknown>; waitsForInput: boolean };

export interface RuntimeSessionHandle {
  id: string;
  followUp(prompt: BuiltPrompt): Promise<void>;
  steer(text: string): Promise<void>;
  abort(): Promise<void>;
  answerExtensionUi?(requestId: string, value: unknown): Promise<void>;
  openArtifact?(artifactId: string): Promise<string>;
  subscribe(listener: (event: RuntimeEvent) => void): () => void;
}

export interface AgentRuntime {
  create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
  prewarm?(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
}
