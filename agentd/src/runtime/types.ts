import type { BuiltPrompt } from "../prompt-builder.js";
import type { PickyQueueMode } from "../protocol.js";

export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
export type RuntimeSlashCommandSource = "extension" | "prompt" | "skill" | "builtin";
export interface RuntimeSlashCommand {
  name: string;
  description?: string;
  source: RuntimeSlashCommandSource;
}
export type RuntimeSessionStatus = "running" | "waiting_for_input" | "blocked" | "completed" | "failed" | "cancelled";
export interface RuntimeAssistantRunMetadata {
  model?: string;
  thinkingLevel?: ThinkingLevel;
}

export type RuntimeEvent =
  | { type: "log"; line: string }
  | { type: "assistant_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }
  | { type: "input_message"; role: "user" | "custom"; text: string; originatedBy: "user" | "main_agent" | "pi_extension" | "internal"; display?: boolean; customType?: string }
  | { type: "status"; status: RuntimeSessionStatus; summary?: string; finalAnswer?: string; noTurnRan?: boolean; preserveSessionState?: boolean; assistantRun?: RuntimeAssistantRunMetadata }
  | { type: "tool"; toolCallId: string; name: string; status: "running" | "succeeded" | "failed"; preview?: string }
  | { type: "extension_ui"; request: Record<string, unknown>; waitsForInput: boolean }
  | { type: "session_info"; name: string }
  | { type: "context_usage"; usage: { tokens: number | null; contextWindow: number; percent: number | null } | undefined };

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
  steer(prompt: BuiltPrompt): Promise<RuntimeSteerResult>;
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
  setThinkingLevel?(level: ThinkingLevel): void;
  listSlashCommands?(): RuntimeSlashCommand[] | Promise<RuntimeSlashCommand[]>;
  clearQueue(): { steering: string[]; followUp: string[] };
  getSteeringMessages(): readonly string[];
  getFollowUpMessages(): readonly string[];
  readonly steeringMode: PickyQueueMode;
  readonly followUpMode: PickyQueueMode;
  /**
   * True when Pi is mid-turn (LLM streaming or awaiting tool result). Callers use this to
   * decide whether a new prompt will be queued by Pi (true) or executed inline (false).
   */
  readonly isStreaming: boolean;
  /**
   * Path to the on-disk Pi JSONL transcript backing this runtime session. Returns undefined
   * for runtimes that do not persist transcripts (e.g. mock). Callers use this to fork an
   * existing session before any diagnostic `pi session: <path>` log line has surfaced.
   */
  getSessionFilePath?(): string | undefined;
  subscribe(listener: (event: RuntimeEvent) => void): () => void;
}

export interface AgentRuntime {
  create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
  prewarm?(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
  resume?(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle>;
  setThinkingLevel?(level: ThinkingLevel): void;
}
