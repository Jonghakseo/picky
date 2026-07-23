import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem } from "@earendil-works/pi-tui";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { ModelCycleDirection, PickyQueueMode, PickyTodoState } from "../protocol.js";

export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type RuntimeSlashCommandSource = "extension" | "prompt" | "skill" | "builtin";
export interface RuntimeSlashCommand {
  name: string;
  description?: string;
  source: RuntimeSlashCommandSource;
}
export interface RuntimeAutocompleteCapabilities {
  generation: number;
  triggerCharacters: string[];
}
export interface RuntimeAutocompleteQuery {
  generation: number;
  lines: string[];
  cursorLine: number;
  cursorCol: number;
  force?: boolean;
}
export interface RuntimeAutocompleteSuggestions {
  generation: number;
  prefix?: string;
  items: AutocompleteItem[];
}
export interface RuntimeAutocompleteApplyRequest extends RuntimeAutocompleteQuery {
  item: AutocompleteItem;
  prefix: string;
}
export interface RuntimeAutocompleteCompletion {
  generation: number;
  lines: string[];
  cursorLine: number;
  cursorCol: number;
}
export interface RewindTarget {
  entryId: string;
  text: string;
  createdAt?: string;
}
export interface RewindBranchMessage {
  role: "user" | "assistant";
  text: string;
}
export interface RewindResult {
  editorText?: string;
  cancelled: boolean;
}
export type RuntimeSessionStatus = "running" | "waiting_for_input" | "blocked" | "completed" | "failed" | "cancelled";
export interface RuntimeAssistantRunMetadata {
  model?: string;
  thinkingLevel?: ThinkingLevel;
}

export interface RuntimeTodoStateResolution {
  resolved: boolean;
  todoState?: PickyTodoState;
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

export type RuntimeEvent =
  | { type: "log"; line: string }
  | { type: "assistant_delta"; delta: string; inputId?: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }
  | { type: "input_delivery"; role: "user" | "custom"; text: string; originatedBy: "user" | "main_agent" | "pi_extension" | "internal"; queueKind?: "steering" | "followUp" }
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
  | { type: "todo_state"; todoState?: PickyTodoState }
  | { type: "extension_ui"; request: Record<string, unknown>; waitsForInput: boolean }
  | { type: "extension_ui_cancelled"; requestId: string }
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
  /** Reload credentials changed by another local Pi/Picky process without replacing the session. */
  reloadAuthentication?(): Promise<void>;
  /** Mirrors Pi TUI `/compact`: aborts an active turn first, then compacts the session. */
  compact?(customInstructions?: string): Promise<void>;
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
  getAutocompleteCapabilities?(): RuntimeAutocompleteCapabilities;
  queryAutocomplete?(query: RuntimeAutocompleteQuery): Promise<RuntimeAutocompleteSuggestions>;
  applyAutocomplete?(request: RuntimeAutocompleteApplyRequest): RuntimeAutocompleteCompletion;
  listRewindTargets?(): RewindTarget[];
  rewindToEntry?(entryId: string): Promise<RewindResult>;
  getActiveBranchTranscript?(): RewindBranchMessage[];
  getTodoStateResolution?(): RuntimeTodoStateResolution;
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
  /**
   * Reverse a Pi server-side input rewrite (slash-command / `>subagent` mention expansion) back
   * to the raw text the user submitted, using mappings the runtime learned while pairing echoes.
   * Returns the input unchanged when no mapping is known. Optional: runtimes that never rewrite
   * input (mock) may leave this unset.
   */
  reverseInputExpansion?(text: string): string;
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
  /**
   * When the host disables TTS, runtimes that produce audio output should
   * switch their output modality to text-only.
   */
  setMainAgentTTSEnabled?(enabled: boolean): void;
}
