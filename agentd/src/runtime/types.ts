import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { MainAgentRuntimeMode, ModelCycleDirection, OpenAIRealtimeAuthConfig, PickyContextPacket, PickyQueueMode } from "../protocol.js";

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

export interface RuntimeBashExecutionResult {
  output: string;
  exitCode: number | undefined;
  cancelled: boolean;
  truncated: boolean;
  fullOutputPath?: string;
}

export interface RuntimeModelOption {
  provider: string;
  modelId: string;
  displayName: string;
  pattern: string;
}

export type MainRealtimeState = "connecting" | "ready" | "listening" | "thinking" | "speaking" | "failed";

export type RuntimeEvent =
  | { type: "log"; line: string }
  | { type: "assistant_delta"; delta: string; inputId?: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }
  | { type: "input_message"; role: "user" | "custom"; text: string; originatedBy: "user" | "main_agent" | "pi_extension" | "internal"; display?: boolean; customType?: string }
  | { type: "session_replaced"; reason: "new"; cwd?: string; sessionFilePath?: string }
  | { type: "status"; status: RuntimeSessionStatus; inputId?: string; summary?: string; finalAnswer?: string; noTurnRan?: boolean; preserveSessionState?: boolean; assistantRun?: RuntimeAssistantRunMetadata; compactionStarted?: boolean; compactionCompleted?: boolean; compactionFailed?: boolean; compactionReason?: string }
  | { type: "tool"; toolCallId: string; name: string; status: "running" | "succeeded" | "failed"; preview?: string; argsPreview?: string; resultPreview?: string }
  | { type: "extension_ui"; request: Record<string, unknown>; waitsForInput: boolean }
  | { type: "session_info"; name: string }
  | { type: "context_usage"; usage: { tokens: number | null; contextWindow: number; percent: number | null } | undefined }
  | { type: "main_realtime_state"; state: MainRealtimeState; message?: string }
  | { type: "main_realtime_input_transcript_delta"; inputId: string; delta: string }
  | { type: "main_realtime_input_transcript_completed"; inputId: string; transcript: string }
  | { type: "main_realtime_output_audio_delta"; inputId?: string; audioBase64: string }
  | { type: "main_realtime_output_audio_done"; inputId?: string }
  | { type: "main_realtime_output_transcript_delta"; inputId?: string; delta: string }
  | { type: "main_realtime_output_transcript_completed"; inputId?: string; transcript: string }
  | { type: "main_realtime_turn_done"; inputId?: string; status: "completed" | "cancelled" | "failed" | "incomplete"; finalTranscript?: string };

export interface RuntimeSteerResult {
  /**
   * True when Pi handled the prompt synchronously inside `session.prompt()` without starting an
   * agent turn (e.g. a `/slash` extension command or an `input` handler returning `handled`).
   * The runtime synthesizes a terminal `completed` status for those, and callers should NOT
   * resurrect the session into `running` afterwards.
   */
  handledSynchronously: boolean;
}

export interface AnswerExtensionUiOptions {
  ignoreUnknown?: boolean;
}

export interface RuntimeSessionHandle {
  id: string;
  /** Resolves when the follow-up is accepted/queued, not when the agent finishes the turn. */
  followUp(prompt: BuiltPrompt): Promise<void>;
  /** Resolves when replacement input is accepted/queued after interruption, not when the agent finishes the turn. */
  interrupt?(prompt: BuiltPrompt): Promise<void>;
  steer(prompt: BuiltPrompt): Promise<RuntimeSteerResult>;
  abort(): Promise<void>;
  newSession?(): Promise<{ cancelled: boolean }>;
  executeUserBash?(command: string, options?: { excludeFromContext?: boolean; onOutputChunk?: (chunk: string) => void }): Promise<RuntimeBashExecutionResult>;
  /**
   * Deliver an answer to an extension UI request. Set `options.ignoreUnknown`
   * when the caller is doing idempotent cleanup (e.g. supervisor cancel-on-followUp
   * for a dialog the runtime/bridge may have already discarded) and a stale
   * request id must not become a fatal error that blocks subsequent user input.
   */
  answerExtensionUi?(requestId: string, value: unknown, options?: AnswerExtensionUiOptions): Promise<void>;
  /**
   * Append a synthetic user/assistant pair to the start of a fresh session
   * transcript without invoking the model. No-op when the session already has
   * messages (resumed sessions). Implementations should also persist the pair
   * via their session manager so the messages survive a daemon restart.
   */
  injectInitialBootstrap?(messages: { user: string; assistant: string }): Promise<void>;
  setThinkingLevel?(level: ThinkingLevel): void;
  getAssistantRunMetadata?(): RuntimeAssistantRunMetadata | undefined;
  cycleThinkingLevel?(): RuntimeAssistantRunMetadata | undefined;
  cycleModel?(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined>;
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
  setModelPattern?(pattern?: string): boolean;
  setCustomTools?(tools: ToolDefinition[]): void;
  listAvailableModels?(options?: { cwd?: string }): Promise<RuntimeModelOption[]>;
  setMainAgentRuntimeMode?(mode: MainAgentRuntimeMode): boolean;
  getMainAgentRuntimeMode?(): MainAgentRuntimeMode;
}

export interface MainRealtimeRuntime extends AgentRuntime {
  configureMainRealtimeAuth(config: OpenAIRealtimeAuthConfig): Promise<void> | void;
  beginMainRealtimeVoiceTurn(turn: { inputId: string; context: PickyContextPacket }): Promise<void>;
  appendMainRealtimeInputAudio(inputId: string, audioBase64: string): Promise<void>;
  commitMainRealtimeVoiceTurn(inputId: string, context?: PickyContextPacket): Promise<void>;
  cancelMainRealtimeVoiceTurn(inputId?: string, playedAudioMs?: number): Promise<void>;
}

export function isMainRealtimeRuntime(runtime: AgentRuntime | undefined): runtime is MainRealtimeRuntime {
  return Boolean(
    runtime
      && typeof (runtime as Partial<MainRealtimeRuntime>).configureMainRealtimeAuth === "function"
      && typeof (runtime as Partial<MainRealtimeRuntime>).beginMainRealtimeVoiceTurn === "function"
      && typeof (runtime as Partial<MainRealtimeRuntime>).appendMainRealtimeInputAudio === "function"
      && typeof (runtime as Partial<MainRealtimeRuntime>).commitMainRealtimeVoiceTurn === "function"
      && typeof (runtime as Partial<MainRealtimeRuntime>).cancelMainRealtimeVoiceTurn === "function",
  );
}
