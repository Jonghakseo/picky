import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import WebSocket, { type RawData } from "ws";
import { buildMainAgentBootstrapPair, type BuiltPrompt } from "../prompt-builder.js";
import type { OpenAIRealtimeAuthConfig, PickyAgentSession, PickyContextPacket } from "../protocol.js";
import {
  PICKY_TRANSCRIPTION_PROMPT,
  buildRealtimeContextText,
  buildRealtimeInstructions,
  realtimeTools,
} from "./openai-realtime-main-prompt.js";
import type {
  MainRealtimeRuntime,
  RuntimeEvent,
  RuntimeSessionHandle,
  RuntimeSlashCommand,
  RuntimeSteerResult,
  ThinkingLevel,
} from "./types.js";
import { logAgentd } from "../local-log.js";
import type { PickySkillSummary } from "../application/picky-skill-store.js";
import { type PickyUserGuideResult } from "../application/user-guide-tool.js";
import { buildCodexClientHeaders, fetchCodexQuota, loadCodexOAuth, type CodexOAuthLoader, type CodexQuotaFetcher, type CodexQuotaSnapshot, type ResolvedCodexOAuth } from "./codex-oauth.js";
import type { MainRealtimeHistoryMessage, MainRealtimeHistoryProvider, MainRealtimeQuotaSnapshot, MainRealtimeUsageSnapshot, MainRealtimeUserMemoryItem, MainRealtimeUserMemoryProvider } from "./types.js";

// Realtime sessions are capped server-side at 60 minutes. We rotate slightly
// earlier so an in-flight rollover never collides with the hard kill.
const MAIN_REALTIME_SESSION_MAX_MS = 50 * 60 * 1000;
// Cap how many historical messages we replay into a fresh WS session. Realtime
// can only restore text turns, and very long replays balloon the bootstrap
// latency. The supervisor is expected to provide newest-last ordered messages.
const MAIN_REALTIME_HISTORY_REPLAY_LIMIT = 60;
// How many of the *most recent* prior turns we additionally pack into
// `session.update.instructions` so the model treats them as its own memory.
// Conversation-item replay (above) is bulk older context with weaker model
// adherence; instructions-level history is the high-priority anchor used for
// short-term recall ("내 이름이 뭐였지", "이전 턴에 뭐 했지"). Keep this small so
// `session.update` payloads stay sub-10KB.
const MAIN_REALTIME_HISTORY_INSTRUCTIONS_LIMIT = 20;
const ZERO_USAGE: MainRealtimeUsageSnapshot = {
  totalTokens: 0,
  inputTokens: 0,
  outputTokens: 0,
  cachedInputTokens: 0,
  inputTextTokens: 0,
  inputAudioTokens: 0,
  outputTextTokens: 0,
  outputAudioTokens: 0,
};

interface OpenAIRealtimeMainRuntimeOptions {
  toolHandlers: OpenAIRealtimeToolHandlers;
  defaultConfig?: OpenAIRealtimeAuthConfig;
  webSocketFactory?: RealtimeWebSocketFactory;
  // Injected so tests can stub Codex OAuth resolution without touching the
  // filesystem-backed pi AuthStorage or ~/.codex/auth.json.
  codexOAuthLoader?: CodexOAuthLoader;
  codexQuotaFetcher?: CodexQuotaFetcher;
  now?: () => number;
}

interface OpenAIRealtimeToolHandlers {
  handoff(request: { title: string; instructions: string; cwd?: string }): Promise<{ sessionId: string; title: string; cwd?: string }>;
  /** Read a small chunk of a file, applying the realtime hard cap. Long
   *  contents may include an auto-generated `summary` field. Errors are
   *  surfaced as `{ ok: false, error }`. The runtime never throws from a
   *  tool dispatch — it always echoes the JSON back to the model. */
  readFile(request: { path: string; offset?: number; limit?: number; cwd?: string; callId: string }): Promise<RealtimeReadFileToolResult>;
  /** Run a short bash command with strict timeout. Full output is spilled to
   *  a per-session log file; the model only sees the tail (and optionally a
   *  summary). */
  runBash(request: { command: string; cwd?: string; callId: string }): Promise<RealtimeRunBashToolResult>;
  /** Overwrite or append a file. The body is never echoed back to the model. */
  writeFile(request: { path: string; content: string; mode?: "overwrite" | "append"; cwd?: string; callId: string }): Promise<RealtimeWriteFileToolResult>;
  listPickleSessions(request: { includeArchive?: boolean; page?: number; limit?: number }): PickyAgentSession[] | Promise<PickyAgentSession[]>;
  steerPickleSession(request: { sessionId: string; message: string }): Promise<PickyAgentSession>;
  /** Picky-only skills (user-authored behavior recipes under
   *  ~/Library/Application Support/Picky/skills/). Called once during
   *  `connect()` for the instruction snapshot and again by the `picky_skills`
   *  tool to refresh mid-session. Returns metadata only; the model reads the
   *  listed path with `picky_read_file` when it needs the body. */
  listPickySkills(): PickySkillSummary[] | Promise<PickySkillSummary[]>;
  readUserGuide(request: { section?: string; query?: string }): Promise<PickyUserGuideResult>;
  // Long-term user memory CRUD. Backed by the supervisor's userMemories store
  // in picky.json. The runtime never owns the storage — it just relays tool
  // calls and then asks the supervisor to flush a refreshed session.update
  // via refreshUserMemoryInstructions so the model sees the new set on the
  // very next turn.
  rememberUserFact(request: { content: string }): Promise<{ ok: true; memory: { id: string; content: string } } | { ok: false; error: string }>;
  updateUserFact(request: { id: string; content: string }): Promise<{ ok: true; memory: { id: string; content: string } } | { ok: false; error: string }>;
  forgetUserFact(request: { id: string }): Promise<{ ok: true; removed: { id: string; content: string } } | { ok: false; error: string }>;
  listUserFacts(): Promise<Array<{ id: string; content: string }>> | Array<{ id: string; content: string }>;
  /** Look up one Pickle session by id for `picky_inspect_active_pickle`. Returns
   *  the supervisor's authoritative in-memory snapshot or undefined when the id
   *  is unknown (the tool surface treats undefined as an error). */
  inspectPickleSession(request: { sessionId: string }): PickyAgentSession | undefined | Promise<PickyAgentSession | undefined>;
  /** Best-effort abort of a running Pickle for `picky_abort_pickle`. Returns the
   *  updated session so the model can confirm the new status to the user. */
  abortPickleSession(request: { sessionId: string }): Promise<PickyAgentSession>;
  /** Unarchive a Pickle so its dock card returns. Used by
   *  `picky_unarchive_pickle` after the model looks up an archived session
   *  with `picky_pickle_sessions({ includeArchive: true })`. Only flips the
   *  archived flag; the session's status (completed / cancelled / running)
   *  is preserved. Returns the updated session so the tool can echo the
   *  current status — the model uses that to decide whether to nudge the
   *  user toward `picky_steer_pickle` (still running) or
   *  `picky_start_pickle` (terminal). */
  unarchivePickleSession(request: { sessionId: string }): Promise<PickyAgentSession>;
}

export interface RealtimeWebSocketLike {
  readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  on(event: "open", listener: () => void): this;
  on(event: "message", listener: (data: RawData) => void): this;
  on(event: "close", listener: (code: number, reason: Buffer) => void): this;
  on(event: "error", listener: (error: Error) => void): this;
}

type RealtimeWebSocketFactory = (url: string, headers: Record<string, string>) => RealtimeWebSocketLike;

type RealtimeToolName =
  | "picky_start_pickle"
  | "picky_pickle_sessions"
  | "picky_steer_pickle"
  | "picky_skills"
  | "read_picky_user_guide"
  | "picky_remember"
  | "picky_list_memories"
  | "picky_update_memory"
  | "picky_forget"
  | "picky_inspect_active_pickle"
  | "picky_abort_pickle"
  | "picky_unarchive_pickle"
  | "picky_read_file"
  | "picky_run_bash"
  | "picky_write_file";

/** Outcome of a `picky_read_file` tool call. The `content` field is already
 *  truncated to the realtime cap; `truncated=true` signals that more bytes
 *  exist beyond what the model received. `summary` is best-effort and may be
 *  omitted on auth/timeout failures. */
export type RealtimeReadFileToolResult =
  | {
      ok: true;
      path: string;
      resolvedPath: string;
      content: string;
      totalLines: number;
      totalBytes: number;
      offset: number;
      limit: number;
      truncated: boolean;
      summary?: string;
    }
  | { ok: false; error: string };

/** Outcome of a `picky_run_bash` tool call. `output` is the tail captured
 *  within the hard cap; `logPath` points to the on-disk spill of the full
 *  combined stdout+stderr when the model only saw a tail. */
export type RealtimeRunBashToolResult =
  | {
      ok: true;
      command: string;
      cwd: string;
      exitCode: number | null;
      signal?: string | null;
      output: string;
      totalBytes: number;
      durationMs: number;
      timedOut: boolean;
      truncated: boolean;
      logPath?: string;
      summary?: string;
    }
  | { ok: false; error: string };

/** Outcome of a `picky_write_file` tool call. The written body is never
 *  echoed back to the model — only the resolved path and byte count. */
export type RealtimeWriteFileToolResult =
  | {
      ok: true;
      path: string;
      resolvedPath: string;
      bytesWritten: number;
      mode: "overwrite" | "append";
    }
  | { ok: false; error: string };

type PendingFunctionCall = {
  callId: string;
  name: RealtimeToolName;
  argumentsText: string;
};

type ActiveAssistantAudioItem = {
  responseId?: string;
  itemId: string;
  contentIndex: number;
};

const OPENAI_WS_READY_STATE_OPEN = 1;
const DEFAULT_VOICE = "marin";

export class OpenAIRealtimeMainRuntime implements MainRealtimeRuntime {
  private config?: OpenAIRealtimeAuthConfig;
  private handle?: OpenAIRealtimeSessionHandle;
  private thinkingLevel: ThinkingLevel = "medium";
  private historyProvider?: MainRealtimeHistoryProvider;
  private userMemoryProvider?: MainRealtimeUserMemoryProvider;
  private ttsEnabled = true;

  constructor(private readonly options: OpenAIRealtimeMainRuntimeOptions) {
    this.config = options.defaultConfig;
  }

  configureMainRealtimeAuth(config: OpenAIRealtimeAuthConfig): void {
    this.config = normalizeRealtimeConfig(config);
    this.handle?.configure(this.config);
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevel = level;
    this.handle?.setThinkingLevel(level);
  }

  setMainRealtimeHistoryProvider(provider: MainRealtimeHistoryProvider | undefined): void {
    this.historyProvider = provider;
    this.handle?.setHistoryProvider(provider);
  }

  setMainRealtimeUserMemoryProvider(provider: MainRealtimeUserMemoryProvider | undefined): void {
    this.userMemoryProvider = provider;
    this.handle?.setUserMemoryProvider(provider);
  }

  refreshUserMemoryInstructions(): void {
    this.handle?.refreshUserMemoryInstructions();
  }

  refreshConversationInstructions(): void {
    this.handle?.refreshConversationInstructions();
  }

  async refreshAfterPluginsChange(): Promise<void> {
    await this.handle?.refreshAfterPluginsChange();
  }

  isMainRealtimeSpeaking(): boolean {
    return this.handle?.isMainRealtimeSpeaking() ?? false;
  }

  setMainAgentTTSEnabled(enabled: boolean): void {
    this.ttsEnabled = enabled;
    this.handle?.setTTSEnabled(enabled);
  }

  async refreshCodexQuota(): Promise<void> {
    await this.handle?.refreshCodexQuota();
  }

  async prewarm(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    return this.ensureHandle(options);
  }

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    const handle = await this.ensureHandle(options);
    await handle.followUp(prompt);
    return handle;
  }

  async beginMainRealtimeVoiceTurn(turn: { inputId: string; context: PickyContextPacket }): Promise<void> {
    await (await this.ensureHandle({ cwd: turn.context.cwd, sessionId: "picky" })).beginVoiceTurn(turn);
  }

  async appendMainRealtimeInputAudio(inputId: string, audioBase64: string): Promise<void> {
    await (await this.ensureHandle({ sessionId: "picky" })).appendVoiceAudio(inputId, audioBase64);
  }

  async commitMainRealtimeVoiceTurn(inputId: string, context?: PickyContextPacket): Promise<void> {
    await (await this.ensureHandle({ cwd: context?.cwd, sessionId: "picky" })).commitVoiceTurn(inputId, context);
  }

  async cancelMainRealtimeVoiceTurn(inputId?: string, playedAudioMs?: number): Promise<void> {
    await (await this.ensureHandle({ sessionId: "picky" })).cancelVoiceTurn(inputId, playedAudioMs);
  }

  private async ensureHandle(options: { cwd?: string; sessionId?: string }): Promise<OpenAIRealtimeSessionHandle> {
    if (!this.handle || this.handle.isDisposed) {
      this.handle = new OpenAIRealtimeSessionHandle({
        id: options.sessionId ?? "picky",
        cwd: options.cwd,
        config: this.config,
        thinkingLevel: this.thinkingLevel,
        toolHandlers: this.options.toolHandlers,
        webSocketFactory: this.options.webSocketFactory,
        codexOAuthLoader: this.options.codexOAuthLoader,
        codexQuotaFetcher: this.options.codexQuotaFetcher,
        historyProvider: this.historyProvider,
        userMemoryProvider: this.userMemoryProvider,
        ttsEnabled: this.ttsEnabled,
        now: this.options.now,
      });
    } else {
      this.handle.setCwd(options.cwd);
      this.handle.setTTSEnabled(this.ttsEnabled);
    }
    if (this.config) this.handle.configure(this.config);
    return this.handle;
  }
}

class OpenAIRealtimeSessionHandle implements RuntimeSessionHandle {
  readonly steeringMode = "one-at-a-time" as const;
  readonly followUpMode = "one-at-a-time" as const;
  readonly isStreaming = false;

  private readonly emitter = new EventEmitter();
  private config?: OpenAIRealtimeAuthConfig;
  private ws?: RealtimeWebSocketLike;
  private connectPromise?: Promise<void>;
  private disposed = false;
  private bootstrapped = false;
  private activeInputId?: string;
  private activeResponseId?: string;
  private activeAssistantAudioItem?: ActiveAssistantAudioItem;
  private responseInputIds = new Map<string, string | undefined>();
  private cancelledResponseIds = new Set<string>();
  private outputTranscriptByInputId = new Map<string, string>();
  private inputTranscriptByInputId = new Map<string, string>();
  private functionCalls = new Map<string, PendingFunctionCall>();
  private completedFunctionCallIds = new Set<string>();
  // Debug-only counters so we can dump per-turn audio chunk traffic at the
  // end of each phase instead of logging every single base64 frame (those
  // arrive every ~20-40 ms and would drown agentd.stdout.log otherwise).
  private inputAudioMetrics = new Map<string, { chunks: number; b64Bytes: number }>();
  private outputAudioMetrics = new Map<string, { chunks: number; b64Bytes: number }>();
  private outputTranscriptChunkCount = new Map<string, number>();
  private inputTranscriptChunkCount = new Map<string, number>();
  private generation = 0;
  private thinkingLevel: ThinkingLevel;
  private cwd?: string;
  private historyProvider?: MainRealtimeHistoryProvider;
  private userMemoryProvider?: MainRealtimeUserMemoryProvider;
  private ttsEnabled: boolean;
  private codexAuth?: ResolvedCodexOAuth;
  // Snapshot of the user's Picky-only skill catalog, captured once per
  // `connect()` so the realtime instructions stay stable across the
  // memory/conversation refreshes that re-issue `session.update`. The model
  // can still call `picky_skills` mid-session to discover skills added after
  // the snapshot.
  private pickySkillsSnapshot: PickySkillSummary[] = [];
  private sessionStartedAt = 0;
  private sessionMaxTimer?: ReturnType<typeof setTimeout>;
  private sessionUsage: MainRealtimeUsageSnapshot = { ...ZERO_USAGE };
  private lastTurnUsage: MainRealtimeUsageSnapshot = { ...ZERO_USAGE };
  private readonly now: () => number;

  constructor(private readonly options: {
    id: string;
    cwd?: string;
    config?: OpenAIRealtimeAuthConfig;
    thinkingLevel: ThinkingLevel;
    toolHandlers: OpenAIRealtimeToolHandlers;
    webSocketFactory?: RealtimeWebSocketFactory;
    codexOAuthLoader?: CodexOAuthLoader;
    codexQuotaFetcher?: CodexQuotaFetcher;
    historyProvider?: MainRealtimeHistoryProvider;
    userMemoryProvider?: MainRealtimeUserMemoryProvider;
    ttsEnabled?: boolean;
    now?: () => number;
  }) {
    this.id = options.id;
    this.config = options.config;
    this.thinkingLevel = options.thinkingLevel;
    this.cwd = options.cwd;
    this.historyProvider = options.historyProvider;
    this.userMemoryProvider = options.userMemoryProvider;
    this.ttsEnabled = options.ttsEnabled ?? true;
    this.now = options.now ?? (() => Date.now());
  }

  setHistoryProvider(provider: MainRealtimeHistoryProvider | undefined): void {
    this.historyProvider = provider;
  }

  setUserMemoryProvider(provider: MainRealtimeUserMemoryProvider | undefined): void {
    this.userMemoryProvider = provider;
  }

  /** Resend `session.update` so the latest memory snapshot is reflected in
   * the model's instructions. Fast-path no-op when the socket is not open
   * yet; the next regular connect path picks the new set up automatically. */
  refreshUserMemoryInstructions(): void {
    if (this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) return;
    this.sendSessionUpdate();
  }

  /** Resend `session.update` so the latest recent-turn transcript snapshot
   * is reflected in the model's instructions. Called by the supervisor on
   * every realtime turn_done so the next user turn's instructions include the
   * exchange that just finished as part of the model's high-priority memory.
   * Same fast-path no-op as the user-memory refresh. */
  refreshConversationInstructions(): void {
    if (this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) return;
    this.sendSessionUpdate();
  }

  /** Re-read Picky skills from disk and resend `session.update` so newly
   * installed/uninstalled plugins land in the model's instructions and
   * `picky_skills` tool output before the next turn. Called by the supervisor
   * after Picky applies a plugin manager change. Fast-path no-op when the
   * socket is not open; the next connect picks up the new set automatically
   * via the regular `snapshotPickySkills` step. */
  async refreshAfterPluginsChange(): Promise<void> {
    await this.snapshotPickySkills();
    if (this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) return;
    this.sendSessionUpdate();
  }

  /** True while the realtime runtime currently has an in-flight voice turn the
   * plugin-reload flow should consider cancelling. Mirrors `activeInputId`
   * which is set when a voice turn is in progress and cleared on done/error. */
  isMainRealtimeSpeaking(): boolean {
    return this.activeInputId !== undefined;
  }

  setTTSEnabled(enabled: boolean): void {
    this.ttsEnabled = enabled;
  }

  setCwd(cwd: string | undefined): void {
    if (cwd) this.cwd = cwd;
  }

  id: string;

  configure(config: OpenAIRealtimeAuthConfig): void {
    this.config = normalizeRealtimeConfig(config);
    this.bootstrapped = false;
    if (this.ws?.readyState === OPENAI_WS_READY_STATE_OPEN) {
      this.sendSessionUpdate();
    }
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevel = level;
    if (this.ws?.readyState === OPENAI_WS_READY_STATE_OPEN) this.sendSessionUpdate();
  }

  async followUp(prompt: BuiltPrompt): Promise<void> {
    await this.ensureConnected();
    // Use a bare UUID (no `text-` prefix) so Picky's Swift event decoder,
    // which types inputId as UUID?, can parse outbound transcript / audio
    // / turn-done events. A prefixed string makes the entire envelope fail
    // to decode and Swift then surfaces a generic "올바른 포멃이 아니다" error.
    this.activeInputId = this.activeInputId ?? randomUUID();
    await this.sendPromptAsConversationItem(prompt);
    this.emit({ type: "main_realtime_state", state: "thinking" });
    this.sendResponseCreate();
  }

  async interrupt(prompt: BuiltPrompt): Promise<void> {
    await this.cancelVoiceTurn(this.activeInputId);
    await this.followUp(prompt);
  }

  async steer(_prompt: BuiltPrompt): Promise<RuntimeSteerResult> {
    throw new Error("OpenAI Realtime main runtime does not support Pickle steer handles.");
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  async abort(): Promise<void> {
    await this.cancelVoiceTurn(this.activeInputId);
    this.dispose("picky-abort");
  }

  private dispose(reason: string): void {
    if (this.disposed) return;
    this.disposed = true;
    this.clearSessionMaxTimer();
    const ws = this.ws;
    if (!ws) return;
    try {
      ws.close(1000, reason);
    } catch (error) {
      logAgentd("main realtime dispose close failed", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    await this.ensureConnected();
    if (this.bootstrapped) return;
    this.sendClientEvent({
      type: "conversation.item.create",
      item: { type: "message", role: "user", content: [{ type: "input_text", text: messages.user }] },
    });
    this.sendClientEvent({
      type: "conversation.item.create",
      item: { type: "message", role: "assistant", content: [{ type: this.assistantTextContentType(), text: messages.assistant }] },
    });
    this.bootstrapped = true;
  }

  clearQueue(): { steering: string[]; followUp: string[] } {
    return { steering: [], followUp: [] };
  }

  getSteeringMessages(): readonly string[] { return []; }
  getFollowUpMessages(): readonly string[] { return []; }
  listSlashCommands(): RuntimeSlashCommand[] { return []; }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.emitter.on("event", listener);
    return () => this.emitter.off("event", listener);
  }

  async beginVoiceTurn(turn: { inputId: string; context: PickyContextPacket }): Promise<void> {
    const generation = ++this.generation;
    this.activeInputId = turn.inputId;
    this.activeResponseId = undefined;
    this.activeAssistantAudioItem = undefined;
    this.outputTranscriptByInputId.delete(turn.inputId);
    this.inputTranscriptByInputId.delete(turn.inputId);
    await this.ensureConnected();
    if (generation !== this.generation) return;
    await this.sendContextForRealtimeVoice(turn.context);
    this.sendClientEvent({ type: "input_audio_buffer.clear" });
    this.emit({ type: "main_realtime_state", state: "listening" });
  }

  async appendVoiceAudio(inputId: string, audioBase64: string): Promise<void> {
    if (!this.isCurrentInput(inputId)) return;
    await this.ensureConnected();
    this.sendClientEvent({ type: "input_audio_buffer.append", audio: audioBase64 });
  }

  async commitVoiceTurn(inputId: string, context?: PickyContextPacket): Promise<void> {
    if (!this.isCurrentInput(inputId)) return;
    await this.ensureConnected();
    if (context) await this.sendContextForRealtimeVoice(context);
    this.sendClientEvent({ type: "input_audio_buffer.commit" });
    this.emit({ type: "main_realtime_state", state: "thinking" });
    this.sendResponseCreate();
  }

  async cancelVoiceTurn(inputId?: string, playedAudioMs?: number): Promise<void> {
    if (inputId && !this.isCurrentInput(inputId)) return;
    const currentInputId = this.activeInputId;
    try {
      if (this.ws?.readyState === OPENAI_WS_READY_STATE_OPEN) {
        if (this.activeResponseId || this.activeAssistantAudioItem) this.sendClientEvent({ type: "response.cancel" });
        if (this.activeAssistantAudioItem && typeof playedAudioMs === "number") {
          this.sendClientEvent({
            type: "conversation.item.truncate",
            item_id: this.activeAssistantAudioItem.itemId,
            content_index: this.activeAssistantAudioItem.contentIndex,
            audio_end_ms: Math.max(0, Math.floor(playedAudioMs)),
          });
        } else if (this.activeAssistantAudioItem) {
          logAgentd("main realtime truncate skipped", { reason: "playedAudioMs unavailable", itemId: this.activeAssistantAudioItem.itemId });
        }
        this.sendClientEvent({ type: "input_audio_buffer.clear" });
      }
    } catch (error) {
      logAgentd("main realtime cancel failed", { error: error instanceof Error ? error.message : String(error) });
    } finally {
      if (this.activeResponseId) this.cancelledResponseIds.add(this.activeResponseId);
      if (currentInputId) this.outputTranscriptByInputId.delete(currentInputId);
      this.activeInputId = undefined;
      this.activeResponseId = undefined;
      this.activeAssistantAudioItem = undefined;
      this.emit({ type: "main_realtime_turn_done", inputId: currentInputId, status: "cancelled" });
      this.emit({ type: "main_realtime_state", state: this.config ? "ready" : "failed", message: this.config ? undefined : "API key required" });
    }
  }

  private async ensureConnected(): Promise<void> {
    if (this.disposed) throw new Error("Realtime session handle is disposed");
    if (this.ws?.readyState === OPENAI_WS_READY_STATE_OPEN) return;
    if (!this.config) {
      this.emit({ type: "main_realtime_state", state: "failed", message: "OpenAI Realtime auth not configured" });
      throw new Error("OpenAI Realtime auth not configured");
    }
    if (this.connectPromise) return this.connectPromise;
    this.connectPromise = this.connect().finally(() => { this.connectPromise = undefined; });
    return this.connectPromise;
  }

  private async connect(): Promise<void> {
    const config = this.config!;
    const resolvedAuth = (config.authMode ?? "apiKey") === "codexOAuth"
      ? await (this.options.codexOAuthLoader ?? loadCodexOAuth)()
      : undefined;
    this.codexAuth = resolvedAuth;
    const connection = buildRealtimeConnection(config, resolvedAuth);
    this.emit({ type: "main_realtime_state", state: "connecting" });
    const factory = this.options.webSocketFactory ?? ((url, headers) => new WebSocket(url, { headers }) as RealtimeWebSocketLike);
    const ws = factory(connection.url, connection.headers);
    this.ws = ws;
    await new Promise<void>((resolve, reject) => {
      const onOpen = () => {
        cleanup();
        resolve();
      };
      const onError = (error: Error) => {
        cleanup();
        reject(error);
      };
      const cleanup = () => {
        // ws does not expose off on the small test interface; one-shot listeners are harmless.
      };
      ws.on("open", onOpen);
      ws.on("error", onError);
    });
    if (this.disposed) {
      ws.close();
      return;
    }
    ws.on("message", (data) => this.handleRawServerEvent(data));
    ws.on("close", (_code, reason) => {
      if (this.ws !== ws) return;
      this.ws = undefined;
      this.bootstrapped = false;
      this.clearSessionMaxTimer();
      const message = reason.toString("utf8").trim();
      // Do NOT emit `failed` or `connecting` here. A close that we triggered
      // (50-min rollover, manual dispose) or that the server sent for the
      // 60-minute cap is an expected lifecycle event, and the next
      // `ensureConnected()` call will naturally emit `connecting -> ready`
      // when the user kicks off the next turn. Emitting `connecting` on
      // close looked transient in code but in practice the cursor stayed
      // yellow / processing forever because nothing triggers a reconnect
      // until the user PTTs / submits text. We log the lifecycle event for
      // diagnostics and leave the last broadcast state (typically `ready`)
      // in place so the cursor returns to idle until the user interacts.
      logAgentd("main realtime disconnected", { message: message || "closed" });
    });
    ws.on("error", (error) => {
      this.emit({ type: "main_realtime_state", state: "failed", message: error.message });
    });
    this.sessionStartedAt = this.now();
    this.scheduleSessionMaxTimer();
    this.lastTurnUsage = { ...ZERO_USAGE };
    this.sessionUsage = { ...ZERO_USAGE };
    await this.snapshotPickySkills();
    this.sendSessionUpdate();
    const bootstrap = buildMainAgentBootstrapPair({ omitTtsParenthesisHint: true });
    await this.injectInitialBootstrap(bootstrap);
    await this.replayHistory();
    this.emit({ type: "main_realtime_state", state: "ready" });
    logAgentd("main realtime connected", { provider: config.provider, modelOrDeployment: config.modelOrDeployment, endpointHost: connection.host });
    void this.refreshCodexQuota();
  }

  private clearSessionMaxTimer(): void {
    if (!this.sessionMaxTimer) return;
    clearTimeout(this.sessionMaxTimer);
    this.sessionMaxTimer = undefined;
  }

  private scheduleSessionMaxTimer(): void {
    this.clearSessionMaxTimer();
    this.sessionMaxTimer = setTimeout(() => {
      this.sessionMaxTimer = undefined;
      this.rolloverDueToSessionAge();
    }, MAIN_REALTIME_SESSION_MAX_MS);
    // Don't keep the Node event loop alive purely for this timer.
    if (typeof (this.sessionMaxTimer as { unref?: () => void }).unref === "function") {
      (this.sessionMaxTimer as { unref: () => void }).unref();
    }
  }

  private rolloverDueToSessionAge(): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== OPENAI_WS_READY_STATE_OPEN) return;
    const ageMs = this.now() - this.sessionStartedAt;
    logAgentd("main realtime session rollover", { reason: "session-max-age", ageMs });
    try {
      ws.close(1000, "picky-rollover");
    } catch (error) {
      logAgentd("main realtime rollover close failed", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async replayHistory(): Promise<void> {
    const provider = this.historyProvider;
    if (!provider) return;
    let messages: MainRealtimeHistoryMessage[] = [];
    try {
      messages = provider().filter((m) => m.text && m.text.trim());
    } catch (error) {
      logAgentd("main realtime history provider failed", { error: error instanceof Error ? error.message : String(error) });
      return;
    }
    if (messages.length === 0) return;
    const trimmed = messages.length > MAIN_REALTIME_HISTORY_REPLAY_LIMIT
      ? messages.slice(messages.length - MAIN_REALTIME_HISTORY_REPLAY_LIMIT)
      : messages;
    // The Realtime API's `conversation.item.create` accepts assistant-role
    // text items without complaint but the model ignores their content in
    // practice (known limitation: OpenAI's own docs only guarantee replay
    // for user audio/text, and community reports confirm assistant text
    // round-trips silently). Replaying user + assistant alternation would
    // surface ~half the history at best, which is why Picky users saw the
    // model say "I don't remember" after an app restart even though
    // picky.json had every turn on disk.
    //
    // Workaround: pack the entire transcript into ONE user-role message,
    // explicitly framed as "this is the conversation that already happened,
    // do not answer it line by line". The model is now reading the history
    // as user-spoken context (which it does honour) instead of trying to
    // recall its own past audio. The bootstrap "OK" assistant turn already
    // injected before this method runs absorbs the implicit response slot,
    // so the next real user message lands cleanly as a new turn.
    const omittedCount = messages.length - trimmed.length;
    const narrativeBody = trimmed
      .map((m) => `${m.role === "user" ? "User" : "Picky"}: ${m.text}`)
      .join("\n\n");
    const omittedPrefix = omittedCount > 0
      ? `[${omittedCount} earlier turn(s) omitted due to replay capacity limits.]\n\n`
      : "";
    const primer = [
      "[Picky context replay] The block below is the conversation that already happened with this user in earlier turns of this Picky session. Treat each `User:` line as something the user previously said, and each `Picky:` line as something you (Picky) previously replied. Do NOT respond to these lines individually — they are background context only so you can answer the user's NEXT message with full memory of what was discussed. When the user references \"that\", \"earlier\", \"before\", or \"what we were talking about\", anchor on this block.",
      "",
      omittedPrefix + narrativeBody,
      "",
      "[End of context replay. Wait for the user's next message before responding.]",
    ].join("\n");
    this.sendClientEvent({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: primer }],
      },
    });
    logAgentd("main realtime history replayed", { messages: trimmed.length, omitted: omittedCount, primerChars: primer.length });
  }

  /** Pull the user's Picky-only skill list once at the start of a realtime
   *  connection. The result is cached for the lifetime of this connection;
   *  re-snapshotting on the inevitable rollover reconnect is intentional so
   *  newly authored skills become visible to the next chunk of the session. */
  private async snapshotPickySkills(): Promise<void> {
    try {
      const result = await this.options.toolHandlers.listPickySkills();
      this.pickySkillsSnapshot = Array.isArray(result) ? result : [];
      logAgentd("main realtime picky_skills snapshot", { count: this.pickySkillsSnapshot.length });
    } catch (error) {
      logAgentd("main realtime picky_skills snapshot failed", { error: error instanceof Error ? error.message : String(error) });
      this.pickySkillsSnapshot = [];
    }
  }

  async refreshCodexQuota(): Promise<void> {
    const auth = this.codexAuth;
    if (!auth) return;
    const fetcher = this.options.codexQuotaFetcher ?? fetchCodexQuota;
    try {
      const snapshot = await fetcher(auth);
      this.emit({ type: "main_realtime_quota", quota: toQuotaSnapshot(snapshot) });
    } catch (error) {
      logAgentd("main realtime quota fetch failed", { error: error instanceof Error ? error.message : String(error) });
      this.emit({ type: "main_realtime_quota", quota: undefined });
    }
  }

  private sendSessionUpdate(): void {
    const config = this.config;
    if (!config || this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) return;
    const memories = this.snapshotUserMemories();
    const recentHistory = this.snapshotRecentHistoryForInstructions();
    const pickySkills = this.pickySkillsSnapshot;
    this.sendClientEvent({
      type: "session.update",
      session: this.usesAzurePreviewProtocol()
        ? buildAzurePreviewSessionUpdate(config, memories, recentHistory, pickySkills)
        : {
            type: "realtime",
            model: config.modelOrDeployment,
            output_modalities: ["audio"],
            audio: {
              input: {
                format: { type: "audio/pcm", rate: 24000 },
                transcription: buildInputTranscriptionConfig(config),
                turn_detection: null,
              },
              output: {
                format: { type: "audio/pcm", rate: 24000 },
                voice: config.voice || DEFAULT_VOICE,
              },
            },
            reasoning: { effort: mapReasoningEffort(this.thinkingLevel, config.reasoningEffort) },
            instructions: buildRealtimeInstructions(memories, recentHistory, pickySkills),
            tools: realtimeTools(),
            tool_choice: "auto",
          },
    });
  }

  private snapshotRecentHistoryForInstructions(): MainRealtimeHistoryMessage[] {
    const provider = this.historyProvider;
    if (!provider) return [];
    let messages: MainRealtimeHistoryMessage[] = [];
    try {
      messages = provider().filter((m) => m.text && m.text.trim());
    } catch (error) {
      logAgentd("main realtime history provider failed (instructions snapshot)", { error: error instanceof Error ? error.message : String(error) });
      return [];
    }
    if (messages.length === 0) return [];
    return messages.slice(-MAIN_REALTIME_HISTORY_INSTRUCTIONS_LIMIT);
  }

  private snapshotUserMemories(): MainRealtimeUserMemoryItem[] {
    const provider = this.userMemoryProvider;
    if (!provider) return [];
    try {
      return provider();
    } catch (error) {
      logAgentd("main realtime user memory provider failed", { error: error instanceof Error ? error.message : String(error) });
      return [];
    }
  }

  private usesAzurePreviewProtocol(): boolean {
    return this.config?.provider === "azure_openai" && this.config.azure?.apiShape === "preview";
  }

  private assistantTextContentType(): "output_text" | "text" {
    return this.usesAzurePreviewProtocol() ? "text" : "output_text";
  }

  private async sendContextForRealtimeVoice(context: PickyContextPacket): Promise<void> {
    const prompt: BuiltPrompt = {
      text: buildRealtimeContextText(context),
      imagePaths: context.screenshots.map((s) => s.path),
    };
    await this.sendPromptAsConversationItem(prompt);
  }

  private async sendPromptAsConversationItem(prompt: BuiltPrompt): Promise<void> {
    const content: Array<Record<string, unknown>> = [{ type: "input_text", text: prompt.text }];
    if (!this.usesAzurePreviewProtocol()) {
      for (const imagePath of prompt.imagePaths) {
        const imageUrl = await imagePathToDataUrl(imagePath);
        if (imageUrl) content.push({ type: "input_image", image_url: imageUrl });
      }
    } else if (prompt.imagePaths.length > 0) {
      logAgentd("main realtime images omitted", { reason: "azure-preview-no-input-image", images: prompt.imagePaths.length });
    }
    this.sendClientEvent({
      type: "conversation.item.create",
      item: { type: "message", role: "user", content },
    });
  }

  private sendResponseCreate(): void {
    const audio = this.ttsEnabled;
    this.sendClientEvent({
      type: "response.create",
      response: this.usesAzurePreviewProtocol()
        ? { modalities: audio ? ["text", "audio"] : ["text"] }
        : { output_modalities: audio ? ["audio"] : ["text"] },
    });
  }

  private handleRawServerEvent(data: RawData): void {
    const raw = data.toString();
    let event: Record<string, unknown>;
    try {
      event = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      logAgentd("main realtime event ignored", { reason: "invalid-json", chars: raw.length });
      return;
    }
    this.handleServerEvent(event);
  }

  private handleServerEvent(event: Record<string, unknown>): void {
    const type = String(event.type ?? "");
    this.traceServerEvent(type, event);
    switch (type) {
      case "response.created": {
        this.activeResponseId = stringField(event, "response.id") ?? stringField(event, "response_id") ?? this.activeResponseId;
        if (this.activeResponseId) this.responseInputIds.set(this.activeResponseId, this.activeInputId);
        break;
      }
      case "response.output_audio.delta":
      case "response.audio.delta": {
        const delta = stringField(event, "delta");
        if (!delta) return;
        if (this.isCancelledResponseEvent(event)) return;
        const inputId = this.inputIdForResponseEvent(event);
        this.activeResponseId = stringField(event, "response_id") ?? this.activeResponseId;
        this.emit({ type: "main_realtime_state", state: "speaking" });
        this.emit({ type: "main_realtime_output_audio_delta", inputId, audioBase64: delta });
        break;
      }
      case "response.output_audio.done":
      case "response.audio.done":
        if (this.isCancelledResponseEvent(event)) return;
        this.emit({ type: "main_realtime_output_audio_done", inputId: this.inputIdForResponseEvent(event) });
        break;
      case "response.output_audio_transcript.delta":
      case "response.audio_transcript.delta": {
        const delta = stringField(event, "delta");
        if (!delta) return;
        if (this.isCancelledResponseEvent(event)) return;
        const inputId = this.inputIdForResponseEvent(event);
        if (inputId) this.outputTranscriptByInputId.set(inputId, (this.outputTranscriptByInputId.get(inputId) ?? "") + delta);
        this.emit({ type: "main_realtime_output_transcript_delta", inputId, delta });
        break;
      }
      case "response.output_audio_transcript.done":
      case "response.audio_transcript.done": {
        if (this.isCancelledResponseEvent(event)) return;
        const inputId = this.inputIdForResponseEvent(event);
        const transcript = stringField(event, "transcript") ?? (inputId ? this.outputTranscriptByInputId.get(inputId) : undefined) ?? "";
        this.emit({ type: "main_realtime_output_transcript_completed", inputId, transcript });
        break;
      }
      // Text-only modality (ttsEnabled=false) emits these instead of the audio
      // transcript events. Same downstream channel — Picky's HUD only cares
      // about the assistant text, not whether it came from audio transcription.
      // Do not emit `speaking`: this path has no audio output, and response
      // modalities ensure text/audio transcript events are not duplicated.
      case "response.output_text.delta":
      case "response.text.delta": {
        const delta = stringField(event, "delta");
        if (!delta) return;
        if (this.isCancelledResponseEvent(event)) return;
        const inputId = this.inputIdForResponseEvent(event);
        if (inputId) this.outputTranscriptByInputId.set(inputId, (this.outputTranscriptByInputId.get(inputId) ?? "") + delta);
        this.emit({ type: "main_realtime_output_transcript_delta", inputId, delta });
        break;
      }
      case "response.output_text.done":
      case "response.text.done": {
        if (this.isCancelledResponseEvent(event)) return;
        const inputId = this.inputIdForResponseEvent(event);
        const text = stringField(event, "text") ?? (inputId ? this.outputTranscriptByInputId.get(inputId) : undefined) ?? "";
        this.emit({ type: "main_realtime_output_transcript_completed", inputId, transcript: text });
        break;
      }
      case "conversation.item.input_audio_transcription.delta": {
        const delta = stringField(event, "delta");
        if (!delta) return;
        const inputId = this.activeInputId;
        if (inputId) this.inputTranscriptByInputId.set(inputId, (this.inputTranscriptByInputId.get(inputId) ?? "") + delta);
        if (inputId) this.emit({ type: "main_realtime_input_transcript_delta", inputId, delta });
        break;
      }
      case "conversation.item.input_audio_transcription.completed": {
        const inputId = this.activeInputId;
        if (!inputId) return;
        const transcript = stringField(event, "transcript") ?? this.inputTranscriptByInputId.get(inputId) ?? "";
        this.emit({ type: "main_realtime_input_transcript_completed", inputId, transcript });
        break;
      }
      case "response.content_part.added": {
        const itemId = stringField(event, "item_id");
        const contentIndex = numberField(event, "content_index") ?? 0;
        const partType = stringField(event, "part.type");
        if (itemId && (!partType || partType.includes("audio"))) {
          this.activeAssistantAudioItem = { responseId: stringField(event, "response_id"), itemId, contentIndex };
        }
        break;
      }
      case "response.output_item.done":
        void this.handleOutputItemDone(event).catch((error) => this.handleToolError(error));
        break;
      case "response.function_call_arguments.delta":
        this.accumulateFunctionArguments(event);
        break;
      case "response.function_call_arguments.done":
        void this.handleFunctionArgumentsDone(event).catch((error) => this.handleToolError(error));
        break;
      case "response.done": {
        if (this.isCancelledResponseEvent(event)) return;
        const responseId = this.responseIdForEvent(event);
        const status = normalizeResponseStatus(stringField(event, "response.status"));
        if (status === "failed") this.emit({ type: "main_realtime_state", state: "failed", message: stringField(event, "response.status_details.error.message") });
        const inputId = this.inputIdForResponseEvent(event);
        const isActiveResponse = !responseId || responseId === this.activeResponseId;
        const finalTranscript = inputId ? this.outputTranscriptByInputId.get(inputId) : undefined;
        const turnUsage = extractUsageSnapshot(objectField(event, "response.usage"));
        if (turnUsage) {
          this.lastTurnUsage = turnUsage;
          this.sessionUsage = addUsage(this.sessionUsage, turnUsage);
          this.emit({ type: "main_realtime_usage", inputId, lastTurn: turnUsage, session: { ...this.sessionUsage } });
        }
        if (isActiveResponse) {
          this.activeResponseId = undefined;
          this.activeAssistantAudioItem = undefined;
        }
        if (responseId) this.responseInputIds.delete(responseId);
        if (responseIncludesFunctionCall(event)) {
          if (inputId) this.outputTranscriptByInputId.delete(inputId);
          this.emit({ type: "main_realtime_state", state: "thinking" });
          break;
        }
        this.emit({ type: "main_realtime_turn_done", inputId, status, finalTranscript });
        this.emit({ type: "main_realtime_state", state: status === "failed" ? "failed" : "ready" });
        if (inputId) {
          this.outputTranscriptByInputId.delete(inputId);
          this.inputTranscriptByInputId.delete(inputId);
        }
        if (!inputId || inputId === this.activeInputId) this.activeInputId = undefined;
        // Trigger a quota refresh on a completed turn (best-effort, fire-and-forget).
        if (status === "completed" && this.codexAuth) void this.refreshCodexQuota();
        break;
      }
      case "error": {
        const message = stringField(event, "error.message") ?? "Realtime API error";
        const code = stringField(event, "error.code");
        const type = stringField(event, "error.type");
        const param = stringField(event, "error.param");
        const eventId = stringField(event, "error.event_id");
        // Server-side `error` frames arrive over a healthy websocket and are
        // soft / recoverable signals (e.g. `input_audio_buffer_commit_empty`
        // when the user releases PTT before 100ms of audio is captured,
        // `response_cancel_not_active` when a cancel races response.done).
        // OpenAI keeps honoring any in-flight `response.create` that came
        // alongside the bad event, so the normal
        // response.created -> output_audio -> response.done chain still
        // arrives. Emitting `state: "failed"` here forced Picky's voice
        // machine to clearToIdle and reset the active turn, which corrupted
        // the HUD when the response landed a moment later. Mirror the
        // ws.close fix: log the diagnostic and leave the last broadcast
        // state in place. True failures still surface elsewhere -
        // response-level failures via `response.done` (status="failed") and
        // websocket-level failures via `ws.on("error")`.
        logAgentd("main realtime server error", { type, code, param, eventId, message });
        break;
      }
      default:
        break;
    }
  }

  /** Verbose tracing of every server → client frame. High-frequency frames
   *  (audio deltas, transcript deltas, function-call arg deltas) are folded
   *  into per-response counters that get dumped on the matching `.done`
   *  event so the log stays tractable while still exposing every transition
   *  the user might want for debugging. */
  private traceServerEvent(type: string, event: Record<string, unknown>): void {
    switch (type) {
      case "response.created": {
        logAgentd("main realtime recv response.created", {
          responseId: this.responseIdForEvent(event),
          inputId: this.activeInputId,
        });
        break;
      }
      case "response.output_audio.delta":
      case "response.audio.delta": {
        const responseId = this.responseIdForEvent(event) ?? "unknown";
        const delta = stringField(event, "delta") ?? "";
        const metrics = this.outputAudioMetrics.get(responseId) ?? { chunks: 0, b64Bytes: 0 };
        metrics.chunks += 1;
        metrics.b64Bytes += delta.length;
        this.outputAudioMetrics.set(responseId, metrics);
        break;
      }
      case "response.output_audio.done":
      case "response.audio.done": {
        const responseId = this.responseIdForEvent(event) ?? "unknown";
        const metrics = this.outputAudioMetrics.get(responseId) ?? { chunks: 0, b64Bytes: 0 };
        logAgentd("main realtime recv output_audio.done", {
          responseId,
          inputId: this.inputIdForResponseEvent(event),
          chunks: metrics.chunks,
          audioB64Bytes: metrics.b64Bytes,
        });
        this.outputAudioMetrics.delete(responseId);
        break;
      }
      case "response.output_audio_transcript.delta":
      case "response.audio_transcript.delta": {
        const responseId = this.responseIdForEvent(event) ?? "unknown";
        const next = (this.outputTranscriptChunkCount.get(responseId) ?? 0) + 1;
        this.outputTranscriptChunkCount.set(responseId, next);
        break;
      }
      case "response.output_audio_transcript.done":
      case "response.audio_transcript.done": {
        const responseId = this.responseIdForEvent(event) ?? "unknown";
        const inputId = this.inputIdForResponseEvent(event);
        const transcript = stringField(event, "transcript") ?? (inputId ? this.outputTranscriptByInputId.get(inputId) : undefined) ?? "";
        logAgentd("main realtime recv output_transcript.done", {
          responseId,
          inputId,
          chunks: this.outputTranscriptChunkCount.get(responseId) ?? 0,
          transcriptChars: transcript.length,
          transcript: summarizeTextForLog(transcript),
        });
        this.outputTranscriptChunkCount.delete(responseId);
        break;
      }
      case "response.output_text.delta":
      case "response.text.delta": {
        const responseId = this.responseIdForEvent(event) ?? "unknown";
        const next = (this.outputTranscriptChunkCount.get(responseId) ?? 0) + 1;
        this.outputTranscriptChunkCount.set(responseId, next);
        break;
      }
      case "response.output_text.done":
      case "response.text.done": {
        const responseId = this.responseIdForEvent(event) ?? "unknown";
        const inputId = this.inputIdForResponseEvent(event);
        const text = stringField(event, "text") ?? (inputId ? this.outputTranscriptByInputId.get(inputId) : undefined) ?? "";
        logAgentd("main realtime recv output_text.done", {
          responseId,
          inputId,
          chunks: this.outputTranscriptChunkCount.get(responseId) ?? 0,
          transcriptChars: text.length,
          transcript: summarizeTextForLog(text),
        });
        this.outputTranscriptChunkCount.delete(responseId);
        break;
      }
      case "conversation.item.input_audio_transcription.delta": {
        const key = this.activeInputId ?? "unknown";
        this.inputTranscriptChunkCount.set(key, (this.inputTranscriptChunkCount.get(key) ?? 0) + 1);
        break;
      }
      case "conversation.item.input_audio_transcription.completed": {
        const inputId = this.activeInputId;
        const transcript = stringField(event, "transcript") ?? (inputId ? this.inputTranscriptByInputId.get(inputId) : undefined) ?? "";
        logAgentd("main realtime recv input_transcript.completed", {
          inputId,
          chunks: this.inputTranscriptChunkCount.get(inputId ?? "unknown") ?? 0,
          transcriptChars: transcript.length,
          transcript: summarizeTextForLog(transcript),
        });
        if (inputId) this.inputTranscriptChunkCount.delete(inputId);
        break;
      }
      case "response.content_part.added": {
        logAgentd("main realtime recv content_part.added", {
          responseId: this.responseIdForEvent(event),
          itemId: stringField(event, "item_id"),
          contentIndex: numberField(event, "content_index"),
          partType: stringField(event, "part.type"),
        });
        break;
      }
      case "response.output_item.added":
      case "response.output_item.done": {
        const item = objectField(event, "item");
        logAgentd(`main realtime recv ${type === "response.output_item.added" ? "output_item.added" : "output_item.done"}`, {
          responseId: this.responseIdForEvent(event),
          itemId: stringField(event, "item.id") ?? stringField(event, "item_id"),
          itemType: item?.type as string | undefined,
          name: item?.name as string | undefined,
          callId: (item?.call_id ?? item?.callId) as string | undefined,
        });
        break;
      }
      case "response.function_call_arguments.delta": {
        // Args are reconstructed from deltas in accumulateFunctionArguments;
        // we'll get a full dump on the `.done` event.
        break;
      }
      case "response.function_call_arguments.done": {
        logAgentd("main realtime recv function_call_arguments.done", {
          callId: stringField(event, "call_id") ?? stringField(event, "item_id"),
          name: stringField(event, "name"),
          argsChars: (stringField(event, "arguments") ?? "").length,
          arguments: summarizeTextForLog(stringField(event, "arguments") ?? ""),
        });
        break;
      }
      case "response.done": {
        const status = stringField(event, "response.status") ?? "";
        const usage = objectField(event, "response.usage");
        logAgentd("main realtime recv response.done", {
          responseId: this.responseIdForEvent(event),
          inputId: this.inputIdForResponseEvent(event),
          status,
          includesFunctionCall: responseIncludesFunctionCall(event) ? 1 : 0,
          totalTokens: numberFieldFromAny(usage, "total_tokens"),
          inputTokens: numberFieldFromAny(usage, "input_tokens"),
          outputTokens: numberFieldFromAny(usage, "output_tokens"),
        });
        break;
      }
      case "response.in_progress":
      case "input_audio_buffer.committed":
      case "input_audio_buffer.speech_started":
      case "input_audio_buffer.speech_stopped":
      case "conversation.item.created":
      case "conversation.item.input_audio_transcription.failed":
      case "rate_limits.updated":
      case "session.created":
      case "session.updated":
      case "error":
        logAgentd(`main realtime recv ${type}`, {
          itemId: stringField(event, "item_id"),
          callId: stringField(event, "call_id"),
        });
        break;
      default: {
        logAgentd("main realtime recv other", { type });
        break;
      }
    }
  }

  private responseIdForEvent(event: Record<string, unknown>): string | undefined {
    return stringField(event, "response_id") ?? stringField(event, "response.id");
  }

  private inputIdForResponseEvent(event: Record<string, unknown>): string | undefined {
    const responseId = this.responseIdForEvent(event);
    return responseId && this.responseInputIds.has(responseId) ? this.responseInputIds.get(responseId) : this.activeInputId;
  }

  private isCancelledResponseEvent(event: Record<string, unknown>): boolean {
    const responseId = this.responseIdForEvent(event);
    if (!responseId) return false;
    if (!this.cancelledResponseIds.has(responseId)) return false;
    this.responseInputIds.delete(responseId);
    if (this.cancelledResponseIds.size > 200) this.cancelledResponseIds.clear();
    return true;
  }

  private async handleOutputItemDone(event: Record<string, unknown>): Promise<void> {
    if (this.isCancelledResponseEvent(event)) return;
    const item = objectField(event, "item");
    if (!item || item.type !== "function_call") return;
    const callId = String(item.call_id ?? item.callId ?? "").trim();
    const name = normalizeToolName(String(item.name ?? ""));
    if (!callId || !name) return;
    const args = typeof item.arguments === "string" ? item.arguments : "{}";
    await this.runFunctionCall(callId, name, args);
  }

  private accumulateFunctionArguments(event: Record<string, unknown>): void {
    const callId = stringField(event, "call_id") ?? stringField(event, "item_id");
    const name = normalizeToolName(stringField(event, "name") ?? "");
    if (!callId || !name) return;
    const current = this.functionCalls.get(callId) ?? { callId, name, argumentsText: "" };
    current.argumentsText += stringField(event, "delta") ?? "";
    this.functionCalls.set(callId, current);
  }

  private async handleFunctionArgumentsDone(event: Record<string, unknown>): Promise<void> {
    const callId = stringField(event, "call_id") ?? stringField(event, "item_id");
    if (!callId) return;
    const pending = this.functionCalls.get(callId);
    this.functionCalls.delete(callId);
    const name = normalizeToolName(stringField(event, "name") ?? pending?.name ?? "");
    if (!name) return;
    const args = stringField(event, "arguments") ?? pending?.argumentsText ?? "{}";
    await this.runFunctionCall(callId, name, args);
  }

  private async runFunctionCall(callId: string, name: RealtimeToolName, argumentsText: string): Promise<void> {
    let parsed: Record<string, unknown> = {};
    try {
      parsed = argumentsText.trim() ? JSON.parse(argumentsText) as Record<string, unknown> : {};
    } catch (error) {
      parsed = { _parseError: error instanceof Error ? error.message : String(error) };
    }
    if (this.completedFunctionCallIds.has(callId)) return;
    this.completedFunctionCallIds.add(callId);
    if (this.completedFunctionCallIds.size > 200) this.completedFunctionCallIds.clear();
    const startedAt = this.now();
    logAgentd("main realtime tool dispatch", {
      tool: name,
      callId,
      inputId: this.activeInputId,
      argsChars: argumentsText.length,
      arguments: summarizeTextForLog(argumentsText),
    });
    let result: unknown;
    try {
      result = await this.executeTool(name, parsed, callId);
      logAgentd("main realtime tool done", {
        tool: name,
        callId,
        elapsedMs: this.now() - startedAt,
        resultChars: typeof result === "string" ? result.length : JSON.stringify(result ?? null).length,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("main realtime tool threw", { tool: name, callId, elapsedMs: this.now() - startedAt, error: message });
      throw error;
    }
    this.sendClientEvent({
      type: "conversation.item.create",
      item: {
        type: "function_call_output",
        call_id: callId,
        output: JSON.stringify(result),
      },
    });
    this.emit({ type: "main_realtime_state", state: "thinking" });
    this.sendResponseCreate();
  }

  private async executeTool(name: RealtimeToolName, args: Record<string, unknown>, callId: string): Promise<unknown> {
    switch (name) {
      case "picky_start_pickle":
        return this.options.toolHandlers.handoff({
          title: stringArg(args, "title"),
          instructions: stringArg(args, "instructions"),
          cwd: optionalStringArg(args, "cwd"),
        });
      case "picky_pickle_sessions": {
        const request = {
          includeArchive: typeof args.includeArchive === "boolean" ? args.includeArchive : undefined,
          page: numberArg(args, "page"),
          limit: numberArg(args, "limit"),
        };
        return summarizeRealtimePickleSessions(await this.options.toolHandlers.listPickleSessions(request), request);
      }
      case "picky_steer_pickle":
        return summarizeRealtimePickleSteerSession(await this.options.toolHandlers.steerPickleSession({ sessionId: stringArg(args, "sessionId"), message: stringArg(args, "message") }));
      case "picky_skills":
        return summarizeRealtimePickySkillList(await this.options.toolHandlers.listPickySkills());
      case "read_picky_user_guide":
        return summarizeRealtimeUserGuide(await this.options.toolHandlers.readUserGuide({ section: optionalStringArg(args, "section"), query: optionalStringArg(args, "query") }));
      case "picky_remember":
        return this.options.toolHandlers.rememberUserFact({ content: stringArg(args, "content") });
      case "picky_list_memories":
        return { memories: await this.options.toolHandlers.listUserFacts() };
      case "picky_update_memory":
        return this.options.toolHandlers.updateUserFact({ id: stringArg(args, "id"), content: stringArg(args, "content") });
      case "picky_forget":
        return this.options.toolHandlers.forgetUserFact({ id: stringArg(args, "id") });
      case "picky_inspect_active_pickle": {
        const sessionId = stringArg(args, "sessionId");
        const session = await this.options.toolHandlers.inspectPickleSession({ sessionId });
        if (!session) return { ok: false, error: `no pickle with id ${JSON.stringify(sessionId)} (use picky_pickle_sessions to look up valid ids)` };
        return summarizeRealtimePickleInspection(session);
      }
      case "picky_abort_pickle":
        return summarizeRealtimePickleAbort(await this.options.toolHandlers.abortPickleSession({ sessionId: stringArg(args, "sessionId") }));
      case "picky_unarchive_pickle":
        return summarizeRealtimePickleUnarchive(await this.options.toolHandlers.unarchivePickleSession({ sessionId: stringArg(args, "sessionId") }));
      case "picky_read_file":
        return this.options.toolHandlers.readFile({
          path: stringArg(args, "path"),
          offset: numberArg(args, "offset"),
          limit: numberArg(args, "limit"),
          cwd: optionalStringArg(args, "cwd") ?? this.cwd,
          callId,
        });
      case "picky_run_bash":
        return this.options.toolHandlers.runBash({
          command: stringArg(args, "command"),
          cwd: optionalStringArg(args, "cwd") ?? this.cwd,
          callId,
        });
      case "picky_write_file":
        return this.options.toolHandlers.writeFile({
          path: stringArg(args, "path"),
          // Body must be passed through verbatim — trailing newlines and
          // significant whitespace are meaningful for file writes, so the
          // trim()-happy optionalStringArg helper is not used here.
          content: rawStringArg(args, "content"),
          mode: normalizeWriteFileMode(optionalStringArg(args, "mode")),
          cwd: optionalStringArg(args, "cwd") ?? this.cwd,
          callId,
        });
    }
  }

  private handleToolError(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error);
    logAgentd("main realtime tool failed", { error: message });
    this.emit({ type: "main_realtime_state", state: "failed", message });
  }

  private sendClientEvent(event: Record<string, unknown>): void {
    if (this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) throw new Error("Realtime WebSocket is not connected");
    this.traceClientEvent(event);
    this.ws.send(JSON.stringify({ event_id: `event-${randomUUID()}`, ...event }));
  }

  /** Verbose tracing of every client → server frame. Audio appends are folded
   *  into per-input counters and only dumped on commit/clear so the log file
   *  does not balloon at 25-50 frames per second. Everything else — session
   *  updates, conversation items, response triggers, tool outputs — is
   *  logged with its payload (truncated for very large fields) so the user
   *  can reconstruct exactly what the model saw and produced. */
  private traceClientEvent(event: Record<string, unknown>): void {
    const type = String((event as { type?: unknown }).type ?? "");
    switch (type) {
      case "session.update": {
        const session = ((event as { session?: Record<string, unknown> }).session) ?? {};
        const tools = Array.isArray(session.tools)
          ? (session.tools as Array<Record<string, unknown>>).map((t) => String(t.name ?? "")).filter((s) => s)
          : [];
        const instructions = typeof session.instructions === "string" ? session.instructions : "";
        const voice = typeof (session as { audio?: Record<string, unknown> }).audio === "object"
          ? String(((session as { audio?: { output?: { voice?: unknown } } }).audio?.output?.voice) ?? "")
          : String((session as { voice?: unknown }).voice ?? "");
        logAgentd("main realtime send session.update", {
          tools: tools.join(","),
          toolCount: tools.length,
          voice,
          instructionsChars: instructions.length,
          instructions: summarizeTextForLog(instructions),
        });
        break;
      }
      case "conversation.item.create": {
        const item = ((event as { item?: Record<string, unknown> }).item) ?? {};
        const itemType = String(item.type ?? "");
        if (itemType === "function_call_output") {
          const output = typeof item.output === "string" ? item.output : "";
          logAgentd("main realtime send function_call_output", {
            callId: String(item.call_id ?? item.callId ?? ""),
            outputChars: output.length,
            output: summarizeTextForLog(output),
          });
          break;
        }
        const content = (item.content as Array<Record<string, unknown>> | undefined) ?? [];
        const types = content.map((c) => String(c.type ?? "")).join(",");
        const text = content
          .filter((c) => typeof c.text === "string")
          .map((c) => c.text as string)
          .join("\n---\n");
        const imageRefs = content
          .filter((c) => typeof c.image_url === "string")
          .map((c) => String(c.image_url).slice(0, 80));
        logAgentd("main realtime send conversation.item", {
          role: String(item.role ?? ""),
          itemType,
          contentTypes: types,
          textChars: text.length,
          text: summarizeTextForLog(text),
          ...(imageRefs.length > 0 ? { images: imageRefs.length, imagePreview: imageRefs[0] } : {}),
        });
        break;
      }
      case "input_audio_buffer.append": {
        const audio = String((event as { audio?: unknown }).audio ?? "");
        const key = this.activeInputId ?? "unknown";
        const metrics = this.inputAudioMetrics.get(key) ?? { chunks: 0, b64Bytes: 0 };
        metrics.chunks += 1;
        metrics.b64Bytes += audio.length;
        this.inputAudioMetrics.set(key, metrics);
        // No per-frame log on purpose.
        break;
      }
      case "input_audio_buffer.commit": {
        const key = this.activeInputId ?? "unknown";
        const metrics = this.inputAudioMetrics.get(key) ?? { chunks: 0, b64Bytes: 0 };
        logAgentd("main realtime send input_audio commit", {
          inputId: this.activeInputId,
          chunks: metrics.chunks,
          audioB64Bytes: metrics.b64Bytes,
        });
        this.inputAudioMetrics.delete(key);
        break;
      }
      case "input_audio_buffer.clear": {
        const key = this.activeInputId ?? "unknown";
        const metrics = this.inputAudioMetrics.get(key);
        if (metrics) {
          logAgentd("main realtime send input_audio clear", {
            inputId: this.activeInputId,
            chunksDiscarded: metrics.chunks,
            b64BytesDiscarded: metrics.b64Bytes,
          });
          this.inputAudioMetrics.delete(key);
        } else {
          logAgentd("main realtime send input_audio clear", { inputId: this.activeInputId });
        }
        break;
      }
      case "response.create": {
        const response = ((event as { response?: Record<string, unknown> }).response) ?? {};
        const modalities = (response.output_modalities ?? response.modalities ?? []) as unknown[];
        logAgentd("main realtime send response.create", {
          inputId: this.activeInputId,
          modalities: Array.isArray(modalities) ? modalities.join(",") : String(modalities),
        });
        break;
      }
      case "response.cancel": {
        logAgentd("main realtime send response.cancel", {
          inputId: this.activeInputId,
          responseId: this.activeResponseId,
        });
        break;
      }
      case "conversation.item.truncate": {
        logAgentd("main realtime send item.truncate", {
          itemId: String((event as { item_id?: unknown }).item_id ?? ""),
          contentIndex: numberField(event, "content_index"),
          audioEndMs: numberField(event, "audio_end_ms"),
        });
        break;
      }
      default: {
        logAgentd("main realtime send other", { type });
        break;
      }
    }
  }

  private isCurrentInput(inputId: string): boolean {
    return this.activeInputId === inputId;
  }

  private emit(event: RuntimeEvent): void {
    this.emitter.emit("event", event);
  }
}

export function buildRealtimeConnection(
  config: OpenAIRealtimeAuthConfig,
  resolvedAuth?: ResolvedCodexOAuth,
): { url: string; headers: Record<string, string>; host: string } {
  if (config.provider === "openai") {
    return {
      url: `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(config.modelOrDeployment)}`,
      host: "api.openai.com",
      headers: openAIRealtimeHeaders(config, resolvedAuth),
    };
  }

  if (resolvedAuth) {
    throw new Error("Codex OAuth login only supports the openai provider");
  }

  const azure = config.azure;
  if (!azure) throw new Error("Azure OpenAI Realtime config is required");
  const endpoint = buildAzureRealtimeEndpoint(config);
  if (endpoint.apiShape === "preview") {
    const apiVersion = endpoint.apiVersion?.trim();
    if (!apiVersion) throw new Error("Azure OpenAI Realtime preview API requires apiVersion");
    return {
      url: `wss://${endpoint.host}/openai/realtime?api-version=${encodeURIComponent(apiVersion)}&deployment=${encodeURIComponent(endpoint.deployment)}`,
      host: endpoint.host,
      headers: { "api-key": config.apiKey ?? "" },
    };
  }
  return {
    url: `wss://${endpoint.host}/openai/v1/realtime?model=${encodeURIComponent(endpoint.deployment)}`,
    host: endpoint.host,
    headers: { "api-key": config.apiKey ?? "" },
  };
}

type AzureRealtimeEndpoint = {
  host: string;
  deployment: string;
  apiVersion?: string;
  apiShape: "ga" | "preview";
};

function buildAzureRealtimeEndpoint(config: OpenAIRealtimeAuthConfig): AzureRealtimeEndpoint {
  const azure = config.azure;
  if (!azure) throw new Error("Azure OpenAI Realtime config is required");
  const parsed = parseAzureRealtimeEndpointUrl(azure.resourceEndpoint);
  if (parsed) {
    return {
      host: parsed.host,
      deployment: parsed.deployment || config.modelOrDeployment,
      apiVersion: parsed.apiVersion ?? azure.apiVersion,
      apiShape: parsed.apiShape,
    };
  }
  const deployment = config.modelOrDeployment.trim();
  if (!deployment) throw new Error("Azure OpenAI Realtime deployment is required");
  return {
    host: normalizeAzureRealtimeHost(azure.resourceEndpoint),
    deployment,
    apiVersion: azure.apiVersion,
    apiShape: azure.apiShape,
  };
}

export function parseAzureRealtimeEndpointUrl(endpoint: string): AzureRealtimeEndpoint | undefined {
  const trimmed = endpoint.trim();
  if (!/^wss?:\/\//i.test(trimmed) && !/^https?:\/\//i.test(trimmed)) return undefined;
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error("Azure OpenAI Realtime URL must be a valid https or wss URL");
  }
  const scheme = url.protocol.replace(":", "").toLowerCase();
  if (!["https", "wss"].includes(scheme)) throw new Error("Azure OpenAI Realtime URL must use https or wss");
  const path = url.pathname.replace(/\/+$/, "");
  if (!path || path === "") return undefined;
  if (path === "/") return undefined;

  if (path === "/openai/realtime") {
    const apiVersion = url.searchParams.get("api-version")?.trim();
    const deployment = (url.searchParams.get("deployment") ?? url.searchParams.get("model") ?? "").trim();
    if (!apiVersion) throw new Error("Azure OpenAI Realtime preview URL requires api-version");
    if (!deployment) throw new Error("Azure OpenAI Realtime preview URL requires deployment");
    return { host: url.host, deployment, apiVersion, apiShape: "preview" };
  }

  if (path === "/openai/v1/realtime") {
    const deployment = (url.searchParams.get("model") ?? url.searchParams.get("deployment") ?? "").trim();
    if (!deployment) throw new Error("Azure OpenAI Realtime GA URL requires model");
    const apiVersion = url.searchParams.get("api-version")?.trim() || undefined;
    return { host: url.host, deployment, apiVersion, apiShape: "ga" };
  }

  throw new Error("Azure OpenAI Realtime URL must use /openai/realtime or /openai/v1/realtime");
}

export function normalizeAzureRealtimeHost(endpoint: string): string {
  const trimmed = endpoint.trim();
  if (!trimmed) throw new Error("Azure OpenAI endpoint is required");
  const candidate = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    throw new Error("Azure OpenAI endpoint must be a valid host or https URL");
  }
  if (url.pathname !== "/" || url.search || url.hash) throw new Error("Azure OpenAI endpoint must not include a path, query, or fragment");
  if (!url.hostname) throw new Error("Azure OpenAI endpoint host is required");
  return url.hostname;
}

function openAIRealtimeHeaders(config: OpenAIRealtimeAuthConfig, resolvedAuth?: ResolvedCodexOAuth): Record<string, string> {
  const headers: Record<string, string> = resolvedAuth
    ? buildCodexClientHeaders(resolvedAuth)
    : { Authorization: `Bearer ${config.apiKey ?? ""}` };
  if (requiresOpenAIBetaRealtimeHeader(config.modelOrDeployment)) headers["OpenAI-Beta"] = "realtime=v1";
  return headers;
}

function requiresOpenAIBetaRealtimeHeader(model: string): boolean {
  // Public OpenAI `gpt-realtime-*` models are GA-only. Sending the legacy
  // OpenAI-Beta realtime header downgrades the WebSocket to the beta schema,
  // where GA session fields like `session.type` are rejected.
  return !/^gpt-realtime(?:-|$)/i.test(model.trim());
}

function normalizeRealtimeConfig(config: OpenAIRealtimeAuthConfig): OpenAIRealtimeAuthConfig {
  return {
    ...config,
    apiKey: config.apiKey?.trim() ?? "",
    modelOrDeployment: config.modelOrDeployment.trim(),
    voice: config.voice.trim() || DEFAULT_VOICE,
    transcriptionLanguage: config.transcriptionLanguage?.trim(),
    azure: config.azure ? {
      ...config.azure,
      resourceEndpoint: config.azure.resourceEndpoint.trim(),
      apiVersion: config.azure.apiVersion?.trim(),
    } : undefined,
  };
}

function buildInputTranscriptionConfig(config: OpenAIRealtimeAuthConfig): Record<string, unknown> {
  const language = config.transcriptionLanguage?.trim();
  return {
    model: "gpt-4o-mini-transcribe",
    prompt: PICKY_TRANSCRIPTION_PROMPT,
    ...(language ? { language } : {}),
  };
}

function buildAzurePreviewSessionUpdate(config: OpenAIRealtimeAuthConfig, userMemories: MainRealtimeUserMemoryItem[] = [], recentHistory: MainRealtimeHistoryMessage[] = [], pickySkills: PickySkillSummary[] = []): Record<string, unknown> {
  return {
    modalities: ["text", "audio"],
    instructions: buildRealtimeInstructions(userMemories, recentHistory, pickySkills),
    voice: azurePreviewVoice(config.voice),
    input_audio_format: "pcm16",
    output_audio_format: "pcm16",
    input_audio_transcription: buildInputTranscriptionConfig(config),
    turn_detection: null,
    tools: realtimeTools(),
    tool_choice: "auto",
    max_response_output_tokens: "inf",
  };
}

function azurePreviewVoice(voice: string | undefined): string {
  const normalized = voice?.trim();
  const supported = new Set(["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]);
  return normalized && supported.has(normalized) ? normalized : "verse";
}

function mapReasoningEffort(level: ThinkingLevel, fallback: OpenAIRealtimeAuthConfig["reasoningEffort"]): "low" | "medium" | "high" | "xhigh" {
  if (fallback) return fallback;
  switch (level) {
    case "off":
    case "minimal":
    case "low":
      return "low";
    case "xhigh":
      return "xhigh";
    case "high":
      return "high";
    case "medium":
    default:
      return "medium";
  }
}

// All model-facing prompt strings (instructions, context envelope, tool
// descriptions, transcription prompt) live in `openai-realtime-main-prompt.ts`.
// Edit them there.

function normalizeWriteFileMode(value: string | undefined): "overwrite" | "append" | undefined {
  if (!value) return undefined;
  return value === "append" ? "append" : "overwrite";
}

const REALTIME_PICKLE_SESSIONS_DEFAULT_LIMIT = 10;
const REALTIME_PICKLE_SESSIONS_MAX_LIMIT = 10;

type RealtimePickleSessionsRequest = { includeArchive?: boolean; page?: number; limit?: number };

type RealtimePickleSessionSummary = {
  id: string;
  title: string;
  cwd?: string;
  lastMessage?: string;
};

/// Plain-text success line shared with the Pi SDK runtime's
/// `picky_steer_pickle` reply. Returned bare (no session metadata) so the
/// realtime voice agent cannot misread a session snapshot whose `status`
/// happens to be `completed` as a failed steer.
type RealtimePickleSteerSummary = {
  message: string;
};

type RealtimePickySkillListSummary = {
  total: number;
  skills: Array<{ name: string; description: string; path: string }>;
};

type RealtimeUserGuideSummary = {
  section?: string;
  query?: string;
  content: string;
  excerpted: boolean;
};

function summarizeRealtimePickleSessions(sessions: PickyAgentSession[], request: RealtimePickleSessionsRequest): {
  sessions: RealtimePickleSessionSummary[];
  page: number;
  pageSize: number;
  total: number;
  hasMore: boolean;
  nextPage?: number;
} {
  const includeArchive = request.includeArchive === true;
  const page = normalizePage(request.page);
  const pageSize = clampRealtimePickleSessionLimit(request.limit);
  const filtered = sessions.filter((session) => includeArchive || session.archived !== true);
  const start = (page - 1) * pageSize;
  const selected = filtered.slice(start, start + pageSize).map(summarizeRealtimePickleSession);
  const hasMore = filtered.length > start + pageSize;
  return {
    sessions: selected,
    page,
    pageSize,
    total: filtered.length,
    hasMore,
    nextPage: hasMore ? page + 1 : undefined,
  };
}

function summarizeRealtimePickleSession(session: PickyAgentSession): RealtimePickleSessionSummary {
  const summary: RealtimePickleSessionSummary = {
    id: session.id,
    title: session.title,
  };
  if (session.cwd) summary.cwd = session.cwd;
  const lastMessage = lastPickleSessionMessage(session);
  if (lastMessage) summary.lastMessage = lastMessage;
  return summary;
}

function lastPickleSessionMessage(session: PickyAgentSession): string | undefined {
  const messages = session.messages ?? [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    const text = message.text ?? message.errorMessage ?? message.question?.prompt ?? message.question?.title;
    if (text?.trim()) return compactRealtimePickleSessionText(text);
  }
  return compactRealtimePickleSessionText(session.finalAnswer ?? session.lastSummary ?? session.thinkingPreview);
}

function compactRealtimePickleSessionText(text: string | undefined): string | undefined {
  const compact = text?.replace(/\s+/g, " ").trim();
  if (!compact) return undefined;
  return compact.length > 240 ? `${compact.slice(0, 237)}...` : compact;
}

function summarizeRealtimePickleSteerSession(_session: PickyAgentSession): RealtimePickleSteerSummary {
  return { message: "Steering sent to Pickle" };
}

/** Compact inspection summary for one Pickle session. Includes status, last
 *  summary line, the 5 most recent tool calls (name + status), and the changed
 *  files list (path + insertion/deletion counts when present). Everything
 *  flattened and capped so the model can answer "지금 어떻게 돼가" in one
 *  turn without blowing the token budget. */
function summarizeRealtimePickleInspection(session: PickyAgentSession): Record<string, unknown> {
  const summary: Record<string, unknown> = {
    id: session.id,
    title: session.title,
    status: session.status,
    updatedAt: session.updatedAt,
  };
  if (session.cwd) summary.cwd = session.cwd;
  if (session.archived) summary.archived = true;
  const lastSummary = compactRealtimePickleSessionText(session.lastSummary);
  if (lastSummary) summary.lastSummary = lastSummary;
  if (session.tools.length > 0) {
    summary.recentToolCalls = session.tools.slice(-5).map((tool) => ({
      name: tool.name,
      status: tool.status,
      ...(tool.preview ? { preview: compactRealtimePickleSessionText(tool.preview) } : {}),
    }));
  }
  if (session.changedFiles.length > 0) {
    summary.changedFiles = session.changedFiles.slice(0, 10).map((file) => ({
      path: file.path,
      status: file.status,
      ...(file.summary ? { summary: compactRealtimePickleSessionText(file.summary) } : {}),
    }));
    if (session.changedFiles.length > 10) summary.changedFilesTruncated = session.changedFiles.length - 10;
  }
  if (session.activitySummary) {
    const activity = session.activitySummary;
    const compact: Record<string, number> = {};
    if (activity.read) compact.read = activity.read;
    if (activity.bash) compact.bash = activity.bash;
    if (activity.write) compact.write = activity.write;
    if (activity.edit) compact.edit = activity.edit;
    if (activity.other) compact.other = activity.other;
    if (activity.thinking) compact.thinking = activity.thinking;
    if (Object.keys(compact).length > 0) summary.activity = compact;
  }
  return summary;
}

function summarizeRealtimePickleAbort(session: PickyAgentSession): Record<string, unknown> {
  const summary: Record<string, unknown> = {
    id: session.id,
    title: session.title,
    status: session.status,
  };
  if (session.cwd) summary.cwd = session.cwd;
  return summary;
}

function summarizeRealtimePickleUnarchive(session: PickyAgentSession): Record<string, unknown> {
  const summary: Record<string, unknown> = {
    id: session.id,
    title: session.title,
    status: session.status,
    archived: session.archived === true,
  };
  if (session.cwd) summary.cwd = session.cwd;
  return summary;
}

function summarizeRealtimePickySkillList(skills: PickySkillSummary[]): RealtimePickySkillListSummary {
  return {
    total: skills.length,
    skills: skills.map((skill) => ({
      name: skill.name,
      description: skill.description,
      path: skill.path,
    })),
  };
}

function summarizeRealtimeUserGuide(guide: PickyUserGuideResult): RealtimeUserGuideSummary {
  return {
    section: guide.section,
    query: guide.query,
    content: guide.content.trim(),
    excerpted: guide.excerpted,
  };
}

function normalizePage(page: number | undefined): number {
  if (typeof page !== "number" || !Number.isFinite(page)) return 1;
  return Math.max(1, Math.floor(page));
}

function clampRealtimePickleSessionLimit(limit: number | undefined): number {
  if (typeof limit !== "number" || !Number.isFinite(limit)) return REALTIME_PICKLE_SESSIONS_DEFAULT_LIMIT;
  return Math.max(1, Math.min(REALTIME_PICKLE_SESSIONS_MAX_LIMIT, Math.floor(limit)));
}

async function imagePathToDataUrl(path: string): Promise<string | undefined> {
  try {
    const data = await readFile(path);
    return `data:${mimeTypeForPath(path)};base64,${data.toString("base64")}`;
  } catch (error) {
    logAgentd("main realtime image skipped", { path, error: error instanceof Error ? error.message : String(error) });
    return undefined;
  }
}

function mimeTypeForPath(path: string): string {
  switch (extname(path).toLowerCase()) {
    case ".png": return "image/png";
    case ".webp": return "image/webp";
    case ".gif": return "image/gif";
    case ".jpg":
    case ".jpeg":
    default:
      return "image/jpeg";
  }
}

function stringField(value: unknown, path: string): string | undefined {
  const leaf = field(value, path);
  return typeof leaf === "string" ? leaf : undefined;
}

function numberField(value: unknown, path: string): number | undefined {
  const leaf = field(value, path);
  return typeof leaf === "number" && Number.isFinite(leaf) ? leaf : undefined;
}

function objectField(value: unknown, path: string): Record<string, unknown> | undefined {
  const leaf = field(value, path);
  return leaf && typeof leaf === "object" && !Array.isArray(leaf) ? leaf as Record<string, unknown> : undefined;
}

function field(value: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((current, part) => {
    if (!current || typeof current !== "object") return undefined;
    return (current as Record<string, unknown>)[part];
  }, value);
}

function numberFieldFromAny(source: Record<string, unknown> | undefined, key: string): number | undefined {
  if (!source) return undefined;
  const value = source[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

// Head + tail summarization so very long realtime payloads (entire system
// prompt, full history replay primer, long bash outputs) still land in
// agentd.stdout.log without producing a multi-megabyte single line that is
// hostile to `tail -f`. Keeps the leading context (where intent shows up)
// and a trailing slice (so the final assistant words / error suffix is
// still visible). Adjust REALTIME_LOG_TEXT_MAX_CHARS if you need to see
// more raw content while debugging.
const REALTIME_LOG_TEXT_MAX_CHARS = 8000;

export function summarizeTextForLog(text: string, maxChars: number = REALTIME_LOG_TEXT_MAX_CHARS): string {
  if (!text) return "";
  if (text.length <= maxChars) return text;
  const tail = Math.min(400, Math.floor(maxChars / 8));
  const head = Math.max(0, maxChars - tail - 40);
  const elided = text.length - head - tail;
  return `${text.slice(0, head)}…[${elided} chars elided]…${text.slice(-tail)}`;
}

function responseIncludesFunctionCall(event: Record<string, unknown>): boolean {
  const response = objectField(event, "response");
  const output = response?.output;
  return Array.isArray(output) && output.some((item) => Boolean(item) && typeof item === "object" && (item as Record<string, unknown>).type === "function_call");
}

function pickNumber(source: Record<string, unknown> | undefined, ...keys: string[]): number {
  if (!source) return 0;
  for (const key of keys) {
    const value = source[key];
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return 0;
}

export function extractUsageSnapshot(usage: Record<string, unknown> | undefined): MainRealtimeUsageSnapshot | undefined {
  if (!usage) return undefined;
  const totalTokens = pickNumber(usage, "total_tokens", "totalTokens");
  const inputTokens = pickNumber(usage, "input_tokens", "inputTokens");
  const outputTokens = pickNumber(usage, "output_tokens", "outputTokens");
  if (totalTokens === 0 && inputTokens === 0 && outputTokens === 0) return undefined;
  const inputDetails = usage.input_token_details && typeof usage.input_token_details === "object"
    ? usage.input_token_details as Record<string, unknown>
    : (usage.inputTokenDetails && typeof usage.inputTokenDetails === "object" ? usage.inputTokenDetails as Record<string, unknown> : undefined);
  const outputDetails = usage.output_token_details && typeof usage.output_token_details === "object"
    ? usage.output_token_details as Record<string, unknown>
    : (usage.outputTokenDetails && typeof usage.outputTokenDetails === "object" ? usage.outputTokenDetails as Record<string, unknown> : undefined);
  return {
    totalTokens,
    inputTokens,
    outputTokens,
    cachedInputTokens: pickNumber(inputDetails, "cached_tokens", "cachedTokens"),
    inputTextTokens: pickNumber(inputDetails, "text_tokens", "textTokens"),
    inputAudioTokens: pickNumber(inputDetails, "audio_tokens", "audioTokens"),
    outputTextTokens: pickNumber(outputDetails, "text_tokens", "textTokens"),
    outputAudioTokens: pickNumber(outputDetails, "audio_tokens", "audioTokens"),
  };
}

export function addUsage(a: MainRealtimeUsageSnapshot, b: MainRealtimeUsageSnapshot): MainRealtimeUsageSnapshot {
  return {
    totalTokens: a.totalTokens + b.totalTokens,
    inputTokens: a.inputTokens + b.inputTokens,
    outputTokens: a.outputTokens + b.outputTokens,
    cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens,
    inputTextTokens: a.inputTextTokens + b.inputTextTokens,
    inputAudioTokens: a.inputAudioTokens + b.inputAudioTokens,
    outputTextTokens: a.outputTextTokens + b.outputTextTokens,
    outputAudioTokens: a.outputAudioTokens + b.outputAudioTokens,
  };
}

export function toQuotaSnapshot(snapshot: CodexQuotaSnapshot | undefined): MainRealtimeQuotaSnapshot | undefined {
  if (!snapshot) return undefined;
  return {
    planType: snapshot.planType,
    primary: snapshot.primary,
    secondary: snapshot.secondary,
    fetchedAt: snapshot.fetchedAt,
  };
}

function normalizeResponseStatus(status: string | undefined): "completed" | "cancelled" | "failed" | "incomplete" {
  switch (status) {
    case "completed": return "completed";
    case "cancelled": return "cancelled";
    case "failed": return "failed";
    case "incomplete": return "incomplete";
    default: return "completed";
  }
}

function normalizeToolName(name: string): RealtimeToolName | undefined {
  switch (name) {
    case "picky_start_pickle":
    case "picky_pickle_sessions":
    case "picky_steer_pickle":
    case "picky_skills":
    case "read_picky_user_guide":
    case "picky_remember":
    case "picky_list_memories":
    case "picky_update_memory":
    case "picky_forget":
    case "picky_inspect_active_pickle":
    case "picky_abort_pickle":
    case "picky_unarchive_pickle":
    case "picky_read_file":
    case "picky_run_bash":
    case "picky_write_file":
      return name;
    default:
      return undefined;
  }
}

function stringArg(args: Record<string, unknown>, key: string): string {
  const value = optionalStringArg(args, key);
  if (!value) throw new Error(`Missing required string argument: ${key}`);
  return value;
}

function optionalStringArg(args: Record<string, unknown>, key: string): string | undefined {
  const value = args[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function rawStringArg(args: Record<string, unknown>, key: string): string {
  const value = args[key];
  if (typeof value !== "string") throw new Error(`Missing required string argument: ${key}`);
  return value;
}

function numberArg(args: Record<string, unknown>, key: string): number | undefined {
  const value = args[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
