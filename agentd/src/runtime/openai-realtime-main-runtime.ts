import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import WebSocket, { type RawData } from "ws";
import { buildMainAgentBootstrapPair, type BuiltPrompt } from "../prompt-builder.js";
import type { OpenAIRealtimeAuthConfig, PickyAgentSession, PickyContextPacket } from "../protocol.js";
import type {
  MainRealtimeRuntime,
  RuntimeEvent,
  RuntimeSessionHandle,
  RuntimeSlashCommand,
  RuntimeSteerResult,
  ThinkingLevel,
} from "./types.js";
import { logAgentd } from "../local-log.js";
import type { PickySkillDetails, PickySkillSummary } from "../application/skill-catalog.js";

export interface OpenAIRealtimeMainRuntimeOptions {
  toolHandlers: OpenAIRealtimeToolHandlers;
  defaultConfig?: OpenAIRealtimeAuthConfig;
  webSocketFactory?: RealtimeWebSocketFactory;
}

export interface OpenAIRealtimeToolHandlers {
  handoff(request: { title: string; instructions: string; userMessage?: string; cwd?: string }): Promise<{ sessionId: string; title: string; cwd?: string }>;
  listPickleSessions(request: { includeTerminal?: boolean; page?: number; limit?: number }): PickyAgentSession[];
  steerPickleSession(request: { sessionId: string; message: string }): Promise<PickyAgentSession>;
  searchSkills(request: { query?: string; limit?: number; cwd?: string }): Promise<{ query: string; root: string; roots?: string[]; total: number; skills: PickySkillSummary[] }>;
  getSkillDetails(request: { name: string; cwd?: string }): Promise<PickySkillDetails>;
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

export type RealtimeWebSocketFactory = (url: string, headers: Record<string, string>) => RealtimeWebSocketLike;

type RealtimeToolName = "picky_start_pickle" | "picky_pickle_sessions" | "picky_steer_pickle" | "picky_skills_search" | "picky_skill_details";

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
const PICKY_TRANSCRIPTION_PROMPT = [
  "This audio is a voice command for controlling the Picky macOS app. Users may speak in any language or mix languages, including English, Korean, Japanese, Chinese, Spanish, and developer jargon.",
  "Transcribe in the original spoken language. Do not translate, summarize, or rewrite the speech.",
  "Preserve product names and developer terms exactly in Latin characters when the context fits.",
  "Picky is the app name and may be pronounced in many ways, including Picky, Picky-ya, 피키, or ピッキー. If it sounds like Bicky, Vicky, Mickey, 비키, or 미키, transcribe it as Picky when the context fits.",
  "Pickle is the name for a task session inside Picky and may be pronounced like 피클 or ピックル. Pi is the local coding agent name and may sound like pie, 파이, or パイ.",
  "Key terms: Picky, Pickle, Pi, HUD, dock, agentd, repo, branch, cwd, Codex, SwiftUI, Xcode, Vercel, Next.js, localhost.",
].join("\n");

export class OpenAIRealtimeMainRuntime implements MainRealtimeRuntime {
  private config?: OpenAIRealtimeAuthConfig;
  private handle?: OpenAIRealtimeSessionHandle;
  private thinkingLevel: ThinkingLevel = "medium";

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
    if (!this.handle) {
      this.handle = new OpenAIRealtimeSessionHandle({
        id: options.sessionId ?? "picky",
        cwd: options.cwd,
        config: this.config,
        thinkingLevel: this.thinkingLevel,
        toolHandlers: this.options.toolHandlers,
        webSocketFactory: this.options.webSocketFactory,
      });
    } else {
      this.handle.setCwd(options.cwd);
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
  private outputTranscriptByInputId = new Map<string, string>();
  private inputTranscriptByInputId = new Map<string, string>();
  private functionCalls = new Map<string, PendingFunctionCall>();
  private completedFunctionCallIds = new Set<string>();
  private generation = 0;
  private thinkingLevel: ThinkingLevel;
  private cwd?: string;

  constructor(private readonly options: {
    id: string;
    cwd?: string;
    config?: OpenAIRealtimeAuthConfig;
    thinkingLevel: ThinkingLevel;
    toolHandlers: OpenAIRealtimeToolHandlers;
    webSocketFactory?: RealtimeWebSocketFactory;
  }) {
    this.id = options.id;
    this.config = options.config;
    this.thinkingLevel = options.thinkingLevel;
    this.cwd = options.cwd;
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
    this.activeInputId = this.activeInputId ?? `text-${randomUUID()}`;
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

  async abort(): Promise<void> {
    await this.cancelVoiceTurn(this.activeInputId);
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
      this.activeInputId = undefined;
      this.activeResponseId = undefined;
      this.activeAssistantAudioItem = undefined;
      this.emit({ type: "main_realtime_turn_done", inputId: currentInputId, status: "cancelled" });
      this.emit({ type: "main_realtime_state", state: this.config ? "ready" : "failed", message: this.config ? undefined : "API key required" });
    }
  }

  private async ensureConnected(): Promise<void> {
    if (this.ws?.readyState === OPENAI_WS_READY_STATE_OPEN) return;
    if (!this.config) {
      this.emit({ type: "main_realtime_state", state: "failed", message: "OpenAI Realtime API key required" });
      throw new Error("OpenAI Realtime API key required");
    }
    if (this.connectPromise) return this.connectPromise;
    this.connectPromise = this.connect().finally(() => { this.connectPromise = undefined; });
    return this.connectPromise;
  }

  private async connect(): Promise<void> {
    const config = this.config!;
    const connection = buildRealtimeConnection(config);
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
      if (this.ws === ws) this.ws = undefined;
      const message = reason.toString("utf8").trim();
      this.emit({ type: "main_realtime_state", state: "failed", message: message || "Realtime WebSocket closed" });
    });
    ws.on("error", (error) => {
      this.emit({ type: "main_realtime_state", state: "failed", message: error.message });
    });
    this.sendSessionUpdate();
    const bootstrap = buildMainAgentBootstrapPair();
    await this.injectInitialBootstrap(bootstrap);
    this.emit({ type: "main_realtime_state", state: "ready" });
    logAgentd("main realtime connected", { provider: config.provider, modelOrDeployment: config.modelOrDeployment, endpointHost: connection.host });
  }

  private sendSessionUpdate(): void {
    const config = this.config;
    if (!config || this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) return;
    this.sendClientEvent({
      type: "session.update",
      session: this.usesAzurePreviewProtocol()
        ? buildAzurePreviewSessionUpdate(config)
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
            instructions: buildRealtimeInstructions(),
            tools: realtimeTools(),
            tool_choice: "auto",
          },
    });
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
    this.sendClientEvent({
      type: "response.create",
      response: this.usesAzurePreviewProtocol()
        ? { modalities: ["text", "audio"] }
        : { output_modalities: ["audio"] },
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
    switch (type) {
      case "response.created":
        this.activeResponseId = stringField(event, "response.id") ?? stringField(event, "response_id") ?? this.activeResponseId;
        break;
      case "response.output_audio.delta":
      case "response.audio.delta": {
        const delta = stringField(event, "delta");
        if (!delta) return;
        this.activeResponseId = stringField(event, "response_id") ?? this.activeResponseId;
        this.emit({ type: "main_realtime_state", state: "speaking" });
        this.emit({ type: "main_realtime_output_audio_delta", inputId: this.activeInputId, audioBase64: delta });
        break;
      }
      case "response.output_audio.done":
      case "response.audio.done":
        this.emit({ type: "main_realtime_output_audio_done", inputId: this.activeInputId });
        break;
      case "response.output_audio_transcript.delta":
      case "response.audio_transcript.delta": {
        const delta = stringField(event, "delta");
        if (!delta) return;
        const inputId = this.activeInputId;
        if (inputId) this.outputTranscriptByInputId.set(inputId, (this.outputTranscriptByInputId.get(inputId) ?? "") + delta);
        this.emit({ type: "main_realtime_output_transcript_delta", inputId, delta });
        break;
      }
      case "response.output_audio_transcript.done":
      case "response.audio_transcript.done": {
        const inputId = this.activeInputId;
        const transcript = stringField(event, "transcript") ?? (inputId ? this.outputTranscriptByInputId.get(inputId) : undefined) ?? "";
        this.emit({ type: "main_realtime_output_transcript_completed", inputId, transcript });
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
        const status = normalizeResponseStatus(stringField(event, "response.status"));
        if (status === "failed") this.emit({ type: "main_realtime_state", state: "failed", message: stringField(event, "response.status_details.error.message") });
        const inputId = this.activeInputId;
        const finalTranscript = inputId ? this.outputTranscriptByInputId.get(inputId) : undefined;
        this.activeResponseId = undefined;
        this.activeAssistantAudioItem = undefined;
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
        this.activeInputId = undefined;
        break;
      }
      case "error":
        this.emit({ type: "main_realtime_state", state: "failed", message: stringField(event, "error.message") ?? "Realtime API error" });
        break;
      default:
        break;
    }
  }

  private async handleOutputItemDone(event: Record<string, unknown>): Promise<void> {
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
    const result = await this.executeTool(name, parsed);
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

  private async executeTool(name: RealtimeToolName, args: Record<string, unknown>): Promise<unknown> {
    switch (name) {
      case "picky_start_pickle":
        return this.options.toolHandlers.handoff({
          title: stringArg(args, "title"),
          instructions: stringArg(args, "instructions"),
          userMessage: optionalStringArg(args, "userMessage"),
          cwd: optionalStringArg(args, "cwd"),
        });
      case "picky_pickle_sessions":
        return summarizeRealtimePickleSessions(
          this.options.toolHandlers.listPickleSessions({
            includeTerminal: typeof args.includeTerminal === "boolean" ? args.includeTerminal : undefined,
            page: numberArg(args, "page"),
            limit: numberArg(args, "limit"),
          }),
          {
            includeTerminal: typeof args.includeTerminal === "boolean" ? args.includeTerminal : undefined,
            page: numberArg(args, "page"),
            limit: numberArg(args, "limit"),
          },
        );
      case "picky_steer_pickle":
        return summarizeRealtimePickleSteerSession(await this.options.toolHandlers.steerPickleSession({ sessionId: stringArg(args, "sessionId"), message: stringArg(args, "message") }));
      case "picky_skills_search":
        return summarizeRealtimeSkillSearch(await this.options.toolHandlers.searchSkills({
          query: optionalStringArg(args, "query"),
          limit: numberArg(args, "limit"),
          cwd: this.cwd,
        }));
      case "picky_skill_details":
        return summarizeRealtimeSkillDetails(await this.options.toolHandlers.getSkillDetails({ name: stringArg(args, "name"), cwd: this.cwd }));
    }
  }

  private handleToolError(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error);
    logAgentd("main realtime tool failed", { error: message });
    this.emit({ type: "main_realtime_state", state: "failed", message });
  }

  private sendClientEvent(event: Record<string, unknown>): void {
    if (this.ws?.readyState !== OPENAI_WS_READY_STATE_OPEN) throw new Error("Realtime WebSocket is not connected");
    this.ws.send(JSON.stringify({ event_id: `event-${randomUUID()}`, ...event }));
  }

  private isCurrentInput(inputId: string): boolean {
    return this.activeInputId === inputId;
  }

  private emit(event: RuntimeEvent): void {
    this.emitter.emit("event", event);
  }
}

export function buildRealtimeConnection(config: OpenAIRealtimeAuthConfig): { url: string; headers: Record<string, string>; host: string } {
  if (config.provider === "openai") {
    return {
      url: `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(config.modelOrDeployment)}`,
      host: "api.openai.com",
      headers: openAIRealtimeHeaders(config),
    };
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
      headers: { "api-key": config.apiKey },
    };
  }
  return {
    url: `wss://${endpoint.host}/openai/v1/realtime?model=${encodeURIComponent(endpoint.deployment)}`,
    host: endpoint.host,
    headers: { "api-key": config.apiKey },
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

function openAIRealtimeHeaders(config: OpenAIRealtimeAuthConfig): Record<string, string> {
  const headers: Record<string, string> = { Authorization: `Bearer ${config.apiKey}` };
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
    apiKey: config.apiKey.trim(),
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

function buildAzurePreviewSessionUpdate(config: OpenAIRealtimeAuthConfig): Record<string, unknown> {
  return {
    modalities: ["text", "audio"],
    instructions: buildRealtimeInstructions(),
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

function mapReasoningEffort(level: ThinkingLevel, fallback: OpenAIRealtimeAuthConfig["reasoningEffort"]): "low" | "medium" | "high" {
  if (fallback) return fallback;
  switch (level) {
    case "off":
    case "minimal":
    case "low":
      return "low";
    case "high":
    case "xhigh":
      return "high";
    case "medium":
    default:
      return "medium";
  }
}

function buildRealtimeInstructions(): string {
  return [
    buildMainAgentBootstrapPair().user,
    "",
    "## Realtime voice mode overrides",
    "- You are speaking directly to the user. Keep spoken Korean replies concise and natural.",
    "- Never speak or emit [POINT:...] tags. Realtime main has no pointing tool; describe UI locations verbally when needed.",
    "- Use `picky_skills_search` to discover available Pi skills before delegating specialized work, then `picky_skill_details` for exact usage guidance when needed.",
    "- You cannot execute Pi skills directly. If a skill is relevant, include the skill name and the essential details in `picky_start_pickle.instructions` or `picky_steer_pickle.message` for the Pickle.",
    "- Pickle hover follow-ups bypass you and go directly to the Pickle. If the user refers to delegated work during a Picky turn, call `picky_pickle_sessions` before deciding whether to use `picky_steer_pickle`.",
  ].join("\n");
}

function buildRealtimeContextText(context: PickyContextPacket): string {
  const lines = [
    "# Picky realtime voice context",
    "",
    "The user is currently speaking via OpenAI Realtime audio. Use this neutral desktop context together with the committed input audio.",
    "",
    `- Context ID: ${context.id}`,
    `- Source: ${context.source}`,
    `- Captured at: ${context.capturedAt}`,
  ];
  if (context.cwd) lines.push(`- CWD: ${context.cwd}`);
  if (context.activeApp?.name || context.activeApp?.bundleId) lines.push(`- Active app: ${[context.activeApp.name, context.activeApp.bundleId].filter(Boolean).join(" / ")}`);
  if (context.activeWindow?.title) lines.push(`- Active window: ${context.activeWindow.title}`);
  if (context.browser?.title) lines.push(`- Browser title: ${context.browser.title}`);
  if (context.browser?.url) lines.push(`- Browser URL: ${context.browser.url}`);
  if (context.selectedText) lines.push("", "## Selected text", context.selectedText);
  if (context.screenshots.length > 0) {
    lines.push("", "## Screenshots");
    for (const screenshot of context.screenshots) {
      const screen = screenshot.screenId ? ` (${screenshot.screenId})` : "";
      const focus = context.screenshots.length > 1 && screenshot.isCursorScreen ? "; primary cursor/focus screen" : "";
      const pixels = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels ? `; screenshotPixels=${screenshot.screenshotWidthInPixels}x${screenshot.screenshotHeightInPixels}` : "";
      const cursor = screenshot.cursor ? `; cursorScreenshotPixel=${screenshot.cursor.screenshotPixel.x},${screenshot.cursor.screenshotPixel.y}` : "";
      lines.push(`- ${screenshot.label}${screen}${focus}${pixels}${cursor}: ${screenshot.path}`);
    }
  }
  if (context.inkMarks.length > 0) {
    lines.push("", "## User-marked screen regions");
    lines.push("The user drew these semi-transparent Picky highlighter strokes during input. The attached screenshot files are annotated with matching blue strokes and number badges.");
    for (const [index, mark] of context.inkMarks.entries()) {
      const screen = mark.screenId ? ` on ${mark.screenId}` : "";
      const bounds = `${formatCoordinate(mark.bounds.x)},${formatCoordinate(mark.bounds.y)},${formatCoordinate(mark.bounds.width)}x${formatCoordinate(mark.bounds.height)}`;
      const samplePoints = mark.points.slice(0, 8).map(formatPoint).join(" -> ");
      const suffix = mark.points.length > 8 ? ` -> … (${mark.points.length} points)` : ` (${mark.points.length} points)`;
      lines.push(`- mark${index + 1}${screen}: ${mark.kind}; bbox=${bounds}; strokeWidth=${formatCoordinate(mark.strokeWidth)}; opacity=${formatCoordinate(mark.opacity)}; points=${samplePoints}${suffix}`);
    }
  }
  if (context.warnings.length > 0) lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  return lines.join("\n");
}

function formatPoint(point: { x: number; y: number }): string {
  return `${formatCoordinate(point.x)},${formatCoordinate(point.y)}`;
}

function formatCoordinate(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}

function realtimeTools(): Array<Record<string, unknown>> {
  return [
    {
      type: "function",
      name: "picky_start_pickle",
      description: "Delegate complex, long-running, tool-heavy, or multi-turn work to a Pickle shown in Picky's dock.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          title: { type: "string", description: "Short Korean title for the Pickle card." },
          instructions: { type: "string", description: "Compact delta-first brief for the Pickle." },
          userMessage: { type: "string", description: "Optional Korean message to tell the user after starting Pickle." },
          cwd: { type: "string", description: "Optional absolute working directory for the Pickle." },
        },
        required: ["title", "instructions"],
      },
    },
    {
      type: "function",
      name: "picky_pickle_sessions",
      description: "List current and recent Pickles delegated from Picky.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          includeTerminal: { type: "boolean" },
          page: { type: "number" },
          limit: { type: "number" },
        },
        required: [],
      },
    },
    {
      type: "function",
      name: "picky_steer_pickle",
      description: "Send delta-only steering instructions to an existing Pickle.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          sessionId: { type: "string" },
          message: { type: "string" },
        },
        required: ["sessionId", "message"],
      },
    },
    {
      type: "function",
      name: "picky_skills_search",
      description: "Search local Pi skill specifications available to Pickles. Returns matching skill names, descriptions, paths, and snippets.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string", description: "Optional keywords, e.g. sentry, slack, release, debugging. Empty lists top skills." },
          limit: { type: "number", description: "Maximum number of matches to return. Defaults to 8, max 20." },
        },
        required: [],
      },
    },
    {
      type: "function",
      name: "picky_skill_details",
      description: "Read the full SKILL.md instructions for one local Pi skill by name before delegating skill-specific work to a Pickle.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          name: { type: "string", description: "Skill name, with or without the skill: prefix." },
        },
        required: ["name"],
      },
    },
  ];
}

const REALTIME_PICKLE_SESSIONS_DEFAULT_LIMIT = 10;
const REALTIME_PICKLE_SESSIONS_MAX_LIMIT = 10;

type RealtimePickleSessionsRequest = { includeTerminal?: boolean; page?: number; limit?: number };

type RealtimePickleSessionSummary = {
  id: string;
  title: string;
  cwd?: string;
  lastMessage?: string;
};

type RealtimePickleSteerSummary = {
  id: string;
  title: string;
  status: PickyAgentSession["status"];
  cwd?: string;
};

type RealtimeSkillSearchSummary = {
  total: number;
  skills: Array<{ name: string; description: string; match?: string }>;
};

type RealtimeSkillDetailsSummary = {
  name: string;
  description: string;
  instructions: string;
};

function summarizeRealtimePickleSessions(sessions: PickyAgentSession[], request: RealtimePickleSessionsRequest): {
  sessions: RealtimePickleSessionSummary[];
  page: number;
  pageSize: number;
  total: number;
  hasMore: boolean;
  nextPage?: number;
} {
  const includeTerminal = request.includeTerminal !== false;
  const page = normalizePage(request.page);
  const pageSize = clampRealtimePickleSessionLimit(request.limit);
  const filtered = sessions.filter((session) => includeTerminal || !["completed", "failed", "cancelled"].includes(session.status));
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

function summarizeRealtimePickleSteerSession(session: PickyAgentSession): RealtimePickleSteerSummary {
  const summary: RealtimePickleSteerSummary = {
    id: session.id,
    title: session.title,
    status: session.status,
  };
  if (session.cwd) summary.cwd = session.cwd;
  return summary;
}

function summarizeRealtimeSkillSearch(result: { total: number; skills: PickySkillSummary[] }): RealtimeSkillSearchSummary {
  return {
    total: result.total,
    skills: result.skills.map((skill) => {
      const summary: { name: string; description: string; match?: string } = {
        name: skill.name,
        description: skill.description,
      };
      if (skill.match) summary.match = skill.match;
      return summary;
    }),
  };
}

function summarizeRealtimeSkillDetails(skill: PickySkillDetails): RealtimeSkillDetailsSummary {
  return {
    name: skill.name,
    description: skill.description,
    instructions: skill.content.trim(),
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

function responseIncludesFunctionCall(event: Record<string, unknown>): boolean {
  const response = objectField(event, "response");
  const output = response?.output;
  return Array.isArray(output) && output.some((item) => Boolean(item) && typeof item === "object" && (item as Record<string, unknown>).type === "function_call");
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
    case "picky_skills_search":
    case "picky_skill_details":
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

function numberArg(args: Record<string, unknown>, key: string): number | undefined {
  const value = args[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
