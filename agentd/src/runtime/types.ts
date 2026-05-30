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
  /**
   * Per-turn assistant text flush. Emitted when a turn ends with both assistant
   * text and tool calls so the supervisor can speak the text-so-far through TTS
   * before the tool runs, instead of waiting until agent_end and concatenating
   * every text block of the agent run into one playback.
   */
  | { type: "turn_text_complete"; text: string; inputId?: string; assistantRun?: RuntimeAssistantRunMetadata }
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
  | { type: "main_realtime_turn_done"; inputId?: string; status: "completed" | "cancelled" | "failed" | "incomplete"; finalTranscript?: string }
  | { type: "main_realtime_usage"; inputId?: string; lastTurn: MainRealtimeUsageSnapshot; session: MainRealtimeUsageSnapshot }
  | { type: "main_realtime_quota"; quota: MainRealtimeQuotaSnapshot | undefined };

export interface MainRealtimeUsageSnapshot {
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
  cachedInputTokens: number;
  inputTextTokens: number;
  inputAudioTokens: number;
  outputTextTokens: number;
  outputAudioTokens: number;
}

export interface MainRealtimeQuotaSnapshot {
  planType?: string;
  primary?: MainRealtimeQuotaWindow;
  secondary?: MainRealtimeQuotaWindow;
  fetchedAt: string;
}

export interface MainRealtimeQuotaWindow {
  used: number;
  limit: number;
  remaining: number;
  windowLabel?: string;
  resetAt?: string;
}

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
  setModel?(pattern?: string): Promise<RuntimeAssistantRunMetadata | undefined>;
  cycleModel?(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined>;
  listSlashCommands?(): RuntimeSlashCommand[] | Promise<RuntimeSlashCommand[]>;
  /**
   * Lets the host (supervisor) tell the runtime whether it currently surfaces
   * a pending extension UI request to the user. The runtime uses the callback
   * at end-of-turn normalization to disambiguate a legitimate waiting_for_input
   * (runtime tracks a pending request AND host has the matching question
   * bubble) from a ghost waiting_for_input (runtime resurrected a stale
   * pending request via Pi resume but the host has no question to answer).
   * No-op runtimes (mock, tests without supervisor) may leave this unset.
   */
  setHostPendingExtensionUiPresent?(present: () => boolean): void;
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
   * True when the underlying agent session is currently running a compaction.
   * Optional capability: runtimes that cannot answer (mock, transcription-only)
   * leave this undefined and the supervisor treats it as not-compacting.
   */
  readonly isCompacting?: boolean;
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
  /**
   * When the host disables TTS, runtimes that produce audio output (Realtime)
   * should switch their output modality to text-only.
   */
  setMainAgentTTSEnabled?(enabled: boolean): void;
}

export interface MainRealtimeHistoryMessage {
  role: "user" | "assistant";
  text: string;
}

export type MainRealtimeHistoryProvider = () => MainRealtimeHistoryMessage[];

/**
 * Long-term user memory snapshot the runtime can embed in every Realtime
 * session.update.instructions. The provider returns the *current* memory
 * set each time the runtime needs to rebuild instructions — not a one-shot
 * snapshot — so a `picky_remember` tool call mid-session flushes immediately
 * when the runtime resends the session payload.
 */
export interface MainRealtimeUserMemoryItem {
  id: string;
  content: string;
}

export type MainRealtimeUserMemoryProvider = () => MainRealtimeUserMemoryItem[];

export interface MainRealtimeRuntime extends AgentRuntime {
  configureMainRealtimeAuth(config: OpenAIRealtimeAuthConfig): Promise<void> | void;
  beginMainRealtimeVoiceTurn(turn: { inputId: string; context: PickyContextPacket }): Promise<void>;
  appendMainRealtimeInputAudio(inputId: string, audioBase64: string): Promise<void>;
  commitMainRealtimeVoiceTurn(inputId: string, context?: PickyContextPacket): Promise<void>;
  cancelMainRealtimeVoiceTurn(inputId?: string, playedAudioMs?: number): Promise<void>;
  /**
   * Source of truth for transcript history that should be re-injected when a
   * new realtime WebSocket session is created (reconnect, 60-minute rollover,
   * voice turn after a long idle). Realtime can only restore text turns, so
   * the provider must already filter/cap whatever the supervisor wants to send.
   */
  setMainRealtimeHistoryProvider?(provider: MainRealtimeHistoryProvider | undefined): void;
  /**
   * Source of truth for long-term user memories the runtime should embed in
   * every `session.update.instructions`. The supervisor swaps the provider in
   * during `configureMainRealtimeAuth`; the runtime re-queries it on every
   * connect, every session refresh, and immediately after a memory CRUD tool
   * call so the model sees the latest set without waiting for a reconnect.
   */
  setMainRealtimeUserMemoryProvider?(provider: MainRealtimeUserMemoryProvider | undefined): void;
  /**
   * Ask the runtime to push a refreshed `session.update` so the latest user
   * memory snapshot lands in the model's instructions before the next turn.
   * Called by the supervisor after every memory CRUD tool call. Fast-path
   * no-ops when the runtime has no live socket; the regular connect path
   * will pick up the new set on its next session.update anyway.
   */
  refreshUserMemoryInstructions?(): void;
  /**
   * Ask the runtime to push a refreshed `session.update` so the most recent N
   * turns of the Picky conversation land in the model's instructions before
   * the next turn. Called by the supervisor at every realtime turn boundary
   * so the model treats freshly-completed exchanges as its own memory
   * (instructions-level weight) instead of relying solely on the bulk
   * conversation-item replay that the model treats as background context.
   * Fast-path no-ops when the runtime has no live socket; the next regular
   * connect path's session.update picks up the new snapshot anyway.
   */
  refreshConversationInstructions?(): void;
  /**
   * Ask the runtime to re-snapshot the local Picky skills directory and push a
   * refreshed `session.update` so newly-installed plugins land in the model's
   * instructions and tool list immediately. Called by the supervisor after the
   * Picky plugin manager applies an install/uninstall. Implementations that
   * cache skill lists should invalidate them inside this call. Fast-path no-ops
   * when the runtime has no live socket; the next connect picks up the change.
   */
  refreshAfterPluginsChange?(): Promise<void> | void;
  /**
   * True when the realtime runtime currently has an in-flight voice turn the
   * supervisor's plugin-reload flow should consider cancelling. Optional; runtimes
   * that cannot answer treat the supervisor's reload as best-effort and skip the
   * cancel step.
   */
  isMainRealtimeSpeaking?(): boolean;
  /**
   * Trigger a best-effort Codex quota refresh. Errors are swallowed; the
   * runtime emits a `main_realtime_quota` event on success or a quota=undefined
   * event on failure.
   */
  refreshCodexQuota?(): Promise<void>;
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
