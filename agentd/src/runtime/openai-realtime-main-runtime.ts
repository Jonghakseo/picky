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

export interface OpenAIRealtimeMainRuntimeOptions {
  toolHandlers: OpenAIRealtimeToolHandlers;
  defaultConfig?: OpenAIRealtimeAuthConfig;
  webSocketFactory?: RealtimeWebSocketFactory;
}

export interface OpenAIRealtimeToolHandlers {
  handoff(request: { title: string; instructions: string; userMessage?: string; cwd?: string }): Promise<{ sessionId: string; title: string; cwd?: string }>;
  listSideSessions(request: { includeTerminal?: boolean; page?: number; limit?: number }): PickyAgentSession[];
  steerSideSession(request: { sessionId: string; message: string }): Promise<PickyAgentSession>;
  showPointer(request: { x: number; y: number; screenId?: string; label?: string }): Promise<{ request: unknown }>;
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

type RealtimeToolName = "picky_handoff" | "picky_side_sessions" | "picky_side_steer" | "picky_pointer_overlay";

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
    await (await this.ensureHandle({ cwd: turn.context.cwd, sessionId: "picky-main-agent" })).beginVoiceTurn(turn);
  }

  async appendMainRealtimeInputAudio(inputId: string, audioBase64: string): Promise<void> {
    await (await this.ensureHandle({ sessionId: "picky-main-agent" })).appendVoiceAudio(inputId, audioBase64);
  }

  async commitMainRealtimeVoiceTurn(inputId: string): Promise<void> {
    await (await this.ensureHandle({ sessionId: "picky-main-agent" })).commitVoiceTurn(inputId);
  }

  async cancelMainRealtimeVoiceTurn(inputId?: string, playedAudioMs?: number): Promise<void> {
    await (await this.ensureHandle({ sessionId: "picky-main-agent" })).cancelVoiceTurn(inputId, playedAudioMs);
  }

  private async ensureHandle(options: { cwd?: string; sessionId?: string }): Promise<OpenAIRealtimeSessionHandle> {
    if (!this.handle) {
      this.handle = new OpenAIRealtimeSessionHandle({
        id: options.sessionId ?? "picky-main-agent",
        cwd: options.cwd,
        config: this.config,
        thinkingLevel: this.thinkingLevel,
        toolHandlers: this.options.toolHandlers,
        webSocketFactory: this.options.webSocketFactory,
      });
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
  private generation = 0;
  private thinkingLevel: ThinkingLevel;

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
    throw new Error("OpenAI Realtime main runtime does not support side-session steer handles.");
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
      item: { type: "message", role: "assistant", content: [{ type: "text", text: messages.assistant }] },
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

  async commitVoiceTurn(inputId: string): Promise<void> {
    if (!this.isCurrentInput(inputId)) return;
    await this.ensureConnected();
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
        this.emit({ type: "main_realtime_turn_done", inputId, status, finalTranscript });
        this.emit({ type: "main_realtime_state", state: status === "failed" ? "failed" : "ready" });
        this.activeResponseId = undefined;
        this.activeAssistantAudioItem = undefined;
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
      case "picky_handoff":
        return this.options.toolHandlers.handoff({
          title: stringArg(args, "title"),
          instructions: stringArg(args, "instructions"),
          userMessage: optionalStringArg(args, "userMessage"),
          cwd: optionalStringArg(args, "cwd"),
        });
      case "picky_side_sessions":
        return { sessions: this.options.toolHandlers.listSideSessions({
          includeTerminal: typeof args.includeTerminal === "boolean" ? args.includeTerminal : undefined,
          page: numberArg(args, "page"),
          limit: numberArg(args, "limit"),
        }) };
      case "picky_side_steer":
        return this.options.toolHandlers.steerSideSession({ sessionId: stringArg(args, "sessionId"), message: stringArg(args, "message") });
      case "picky_pointer_overlay":
        return this.options.toolHandlers.showPointer({
          x: requiredNumberArg(args, "x"),
          y: requiredNumberArg(args, "y"),
          screenId: optionalStringArg(args, "screenId"),
          label: optionalStringArg(args, "label"),
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
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        "OpenAI-Beta": "realtime=v1",
      },
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
    "- Never speak or emit [POINT:...] tags. In Realtime mode, use the `picky_pointer_overlay` function tool for visual pointing.",
    "- Side HUD hover follow-ups bypass you and go directly to the side Pi agent. If the user refers to delegated work during a main-agent turn, call `picky_side_sessions` and then `picky_side_steer` when appropriate.",
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
  if (context.warnings.length > 0) lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  return lines.join("\n");
}

function realtimeTools(): Array<Record<string, unknown>> {
  return [
    {
      type: "function",
      name: "picky_handoff",
      description: "Delegate complex, long-running, tool-heavy, or multi-turn work to a side Pi agent shown in Picky's HUD overlay.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          title: { type: "string", description: "Short Korean title for the side-agent HUD card." },
          instructions: { type: "string", description: "Compact delta-first brief for the side Pi agent." },
          userMessage: { type: "string", description: "Optional Korean message to tell the user after handoff." },
          cwd: { type: "string", description: "Optional absolute working directory for the side Pi agent." },
        },
        required: ["title", "instructions"],
      },
    },
    {
      type: "function",
      name: "picky_side_sessions",
      description: "List current and recent side Pi agents delegated from Picky.",
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
      name: "picky_side_steer",
      description: "Send delta-only steering instructions to an existing side Pi agent.",
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
      name: "picky_pointer_overlay",
      description: "Show a visual-only pointer overlay at screenshot-pixel coordinates. Does not move or click the real cursor.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          x: { type: "number" },
          y: { type: "number" },
          screenId: { type: "string" },
          label: { type: "string" },
        },
        required: ["x", "y"],
      },
    },
  ];
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
    case "picky_handoff":
    case "picky_side_sessions":
    case "picky_side_steer":
    case "picky_pointer_overlay":
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

function requiredNumberArg(args: Record<string, unknown>, key: string): number {
  const value = numberArg(args, key);
  if (value === undefined) throw new Error(`Missing required number argument: ${key}`);
  return value;
}
