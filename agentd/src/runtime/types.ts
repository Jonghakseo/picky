import type { BuiltPrompt } from "../prompt-builder.js";

export type RuntimeSessionStatus = "running" | "waiting_for_input" | "blocked" | "completed" | "failed" | "cancelled";

export type RuntimeEvent =
  | { type: "log"; line: string }
  | { type: "assistant_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "status"; status: RuntimeSessionStatus; summary?: string; finalAnswer?: string }
  | { type: "tool"; toolCallId: string; name: string; status: "running" | "succeeded" | "failed"; preview?: string }
  | { type: "extension_ui"; request: Record<string, unknown>; waitsForInput: boolean };

export interface RuntimeSteerResult {
  /**
   * True when Pi handled the prompt synchronously inside `session.prompt()` without starting an
   * agent turn (e.g. a `/slash` extension command or an `input` handler returning `handled`).
   * The runtime synthesizes a terminal `completed` status for those, and callers should NOT
   * resurrect the session into `running` afterwards.
   */
  handledSynchronously: boolean;
}

export interface RuntimeSessionHandle {
  id: string;
  /** Resolves when the follow-up is accepted/queued, not when the agent finishes the turn. */
  followUp(prompt: BuiltPrompt): Promise<void>;
  /** Resolves when replacement input is accepted/queued after interruption, not when the agent finishes the turn. */
  interrupt?(prompt: BuiltPrompt): Promise<void>;
  steer(text: string): Promise<RuntimeSteerResult>;
  abort(): Promise<void>;
  answerExtensionUi?(requestId: string, value: unknown): Promise<void>;
  openArtifact?(artifactId: string): Promise<string>;
  /**
   * Append a synthetic user/assistant pair to the start of a fresh session
   * transcript without invoking the model. No-op when the session already has
   * messages (resumed sessions). Implementations should also persist the pair
   * via their session manager so the messages survive a daemon restart.
   */
  injectInitialBootstrap?(messages: { user: string; assistant: string }): Promise<void>;
  subscribe(listener: (event: RuntimeEvent) => void): () => void;
}

export interface AgentRuntime {
  create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
  prewarm?(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
  resume?(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
}
