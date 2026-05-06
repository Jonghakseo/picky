import { randomUUID } from "node:crypto";
import { readFile, readdir, stat } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import {
  type AgentSession,
  type AgentSessionRuntime,
  type CreateAgentSessionRuntimeFactory,
  type CreateAgentSessionServicesOptions,
  type ToolDefinition,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  getAgentDir,
  SessionManager,
} from "@mariozechner/pi-coding-agent";
import type { BuiltPrompt } from "../prompt-builder.js";
import { ExtensionUiBridge } from "../application/extension-ui-bridge.js";
import { runtimeEventFromPiEvent } from "../domain/pi-event-normalizer.js";
import type { AgentRuntime, RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, RuntimeSteerResult, ThinkingLevel } from "./types.js";
import type { ModelCycleDirection, PickyQueueMode } from "../protocol.js";
import { logAgentd } from "../local-log.js";

// Picky exposes a curated subset of Pi's BUILTIN_SLASH_COMMANDS. Each entry must be backed by a
// public AgentSession API call inside handleBuiltinSlashCommand below; do not list a command we
// cannot actually execute, otherwise users will see autocomplete suggestions that silently fall
// through to the LLM as plain user text.
const PICKY_BUILTIN_SLASH_COMMANDS: ReadonlyArray<{ name: string; description: string }> = [
  { name: "name", description: "Set the Pi session display name (usage: /name <session name>)" },
  { name: "compact", description: "Manually compact the session context (optional: /compact <focus instructions>)" },
];

export interface PiSdkRuntimeOptions {
  agentDir?: string;
  createRuntime?: typeof createAgentSessionRuntime;
  createServices?: typeof createAgentSessionServices;
  createSessionFromServices?: typeof createAgentSessionFromServices;
  getAgentDir?: typeof getAgentDir;
  resourceLoaderOptions?: CreateAgentSessionServicesOptions["resourceLoaderOptions"];
  customTools?: ToolDefinition[];
  thinkingLevel?: ThinkingLevel;
  disableBlockingDialogs?: boolean;
}

export class PiSdkRuntime implements AgentRuntime {
  private thinkingLevel?: ThinkingLevel;

  constructor(private readonly options: PiSdkRuntimeOptions = {}) {
    this.thinkingLevel = options.thinkingLevel;
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevel = level;
  }

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime create", { sessionId: options.sessionId, cwd: options.cwd, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    const handle = await this.createHandle(options);
    setTimeout(() => {
      handle.reportDiagnostics();
      void handle.prompt(prompt);
    }, 0);
    return handle;
  }

  async prewarm(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime prewarm", { sessionId: options.sessionId, cwd: options.cwd });
    const handle = await this.createHandle(options);
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  async resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime resume", { sessionId: options.sessionId, cwd: options.cwd, sessionFilePath });
    const handle = await this.createHandle({ ...options, sessionFilePath });
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  private async createHandle(options: { cwd?: string; sessionId?: string; sessionFilePath?: string }): Promise<PiSdkRuntimeSession> {
    const cwd = options.cwd ?? process.cwd();
    const sessionId = options.sessionId ?? "picky-pi-session";
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const createSessionFromServices = this.options.createSessionFromServices ?? createAgentSessionFromServices;
    const createRuntimeImpl = this.options.createRuntime ?? createAgentSessionRuntime;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();
    const customTools = this.options.customTools ?? [];

    const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd: runtimeCwd, sessionManager, sessionStartEvent }) => {
      const services = await createServices({ cwd: runtimeCwd, agentDir, resourceLoaderOptions: this.options.resourceLoaderOptions });
      return {
        ...(await createSessionFromServices({ services, sessionManager, sessionStartEvent, customTools, thinkingLevel: this.thinkingLevel })),
        services,
        diagnostics: services.diagnostics,
      };
    };

    const runtime = await createRuntimeImpl(createRuntime, {
      cwd,
      agentDir,
      sessionManager: options.sessionFilePath ? SessionManager.open(options.sessionFilePath, undefined, cwd) : SessionManager.create(cwd),
    });

    const handle = new PiSdkRuntimeSession(sessionId, runtime, this.thinkingLevel, { disableBlockingDialogs: this.options.disableBlockingDialogs ?? false });
    await handle.bindCurrentSession();
    return handle;
  }
}

interface ExpectedInputDelivery {
  id: string;
  text: string;
  originatedBy: "user" | "main_agent" | "internal" | "pi_extension";
  suppress: boolean;
}

class PiSdkRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  private unsubscribe?: () => void;
  private uiBridge: ExtensionUiBridge;
  private readonly transcriptRepairLogLine?: string;
  private queuedSteeringCount = 0;
  private queuedFollowUpCount = 0;
  private pendingExtensionUiRequestIds = new Set<string>();
  private pendingTerminalError?: Extract<RuntimeEvent, { type: "status" }>;
  private pendingTerminalErrorTimer?: ReturnType<typeof setTimeout>;
  private expectedInputDeliveries: ExpectedInputDelivery[] = [];
  // Cache of extension baseDir -> whether any of its source files use ctx.ui.custom. Picky's
  // ExtensionUiBridge throws on custom() so commands from those extensions will always fail in
  // Picky; hiding them from autocomplete keeps users from invoking known-broken slash commands.
  private readonly extensionOverlayUiCache = new Map<string, Promise<boolean>>();

  constructor(readonly id: string, private readonly runtime: AgentSessionRuntime, private configuredThinkingLevel?: ThinkingLevel, private readonly bridgeOptions: { disableBlockingDialogs?: boolean } = {}) {
    this.uiBridge = this.createBridge();
    this.transcriptRepairLogLine = repairDanglingToolCalls(runtime.session);
    this.runtime.setRebindSession(async () => this.bindCurrentSession());
  }

  async prompt(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi prompt", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    if (await this.handleBuiltinSlashCommand(prompt.text)) return;
    const wasStreaming = this.runtime.session.isStreaming;
    const expected = this.expectInputDelivery(prompt.text);
    try {
      await this.runtime.session.prompt(prompt.text, { images: await imageOptions(prompt.imagePaths), source: "rpc" });
    } catch (error) {
      this.cancelExpectedInputDelivery(expected.id);
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      return;
    }
    if (this.maybeEmitImmediateCompletion(wasStreaming)) this.cancelExpectedInputDelivery(expected.id);
  }

  async followUp(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi follow-up", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      await this.promptWithOptions(prompt, "followUp");
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async interrupt(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi interrupt", { sessionId: this.id, wasStreaming: this.runtime.session.isStreaming, promptChars: prompt.text.length });
    try {
      if (this.runtime.session.isStreaming) {
        await this.runtime.session.abort();
      }
      await this.promptWithOptions(prompt);
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async steer(prompt: BuiltPrompt): Promise<RuntimeSteerResult> {
    logAgentd("pi steer", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      const handledSynchronously = await this.promptWithOptions(prompt, "steer");
      return { handledSynchronously };
    } catch (error) {
      this.emit({ type: "status", status: "failed", summary: messageOf(error) });
      throw error;
    }
  }

  async abort(): Promise<void> {
    logAgentd("pi abort", { sessionId: this.id });
    await this.runtime.session.abort();
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
  }

  async answerExtensionUi(requestId: string, value: unknown): Promise<void> {
    this.pendingExtensionUiRequestIds.delete(requestId);
    this.uiBridge.answer(requestId, normalizeAnswer(value));
  }

  setThinkingLevel(level: ThinkingLevel): void {
    const session = this.runtime.session as unknown as { setThinkingLevel?: (level: ThinkingLevel) => void };
    if (!session.setThinkingLevel) {
      this.emit({ type: "log", line: "pi thinking level change skipped: active session does not support setThinkingLevel" });
      return;
    }
    session.setThinkingLevel(level);
    this.configuredThinkingLevel = level;
    logAgentd("pi thinking level set", { sessionId: this.id, level });
  }

  cycleThinkingLevel(): RuntimeAssistantRunMetadata | undefined {
    const session = this.runtime.session as unknown as { cycleThinkingLevel?: () => ThinkingLevel | undefined };
    if (typeof session.cycleThinkingLevel !== "function") {
      this.emit({ type: "log", line: "pi thinking level cycle skipped: active session does not support cycleThinkingLevel" });
      return this.currentAssistantRunMetadata();
    }
    const level = session.cycleThinkingLevel();
    if (!level) {
      this.emit({ type: "log", line: "pi thinking level cycle skipped: current model does not support thinking" });
      return this.currentAssistantRunMetadata();
    }
    this.configuredThinkingLevel = level;
    logAgentd("pi thinking level cycled", { sessionId: this.id, level });
    return this.currentAssistantRunMetadata();
  }

  async cycleModel(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined> {
    const session = this.runtime.session as unknown as { cycleModel?: (direction: ModelCycleDirection) => Promise<{ thinkingLevel?: ThinkingLevel } | undefined> };
    if (typeof session.cycleModel !== "function") {
      this.emit({ type: "log", line: "pi model cycle skipped: active session does not support cycleModel" });
      return this.currentAssistantRunMetadata();
    }
    const result = await session.cycleModel(direction);
    if (!result) {
      this.emit({ type: "log", line: "pi model cycle skipped: only one model available" });
      return this.currentAssistantRunMetadata();
    }
    if (result.thinkingLevel) this.configuredThinkingLevel = result.thinkingLevel;
    const metadata = this.currentAssistantRunMetadata();
    logAgentd("pi model cycled", { sessionId: this.id, direction, model: metadata?.model, thinkingLevel: metadata?.thinkingLevel });
    return metadata;
  }

  private currentAssistantRunMetadata(): RuntimeAssistantRunMetadata | undefined {
    const model = currentModelId(this.runtime.session);
    const thinkingLevel = currentThinkingLevel(this.runtime.session) ?? this.configuredThinkingLevel;
    const metadata = {
      ...(model ? { model } : {}),
      ...(thinkingLevel ? { thinkingLevel } : {}),
    };
    return metadata.model || metadata.thinkingLevel ? metadata : undefined;
  }

  async listSlashCommands(): Promise<RuntimeSlashCommand[]> {
    const commands: RuntimeSlashCommand[] = [
      ...PICKY_BUILTIN_SLASH_COMMANDS.map((command) => ({ ...command, source: "builtin" as const })),
    ];
    for (const command of this.runtime.session.extensionRunner.getRegisteredCommands()) {
      const baseDir = extensionBaseDir(command);
      if (baseDir && (await this.extensionRequiresOverlayUi(baseDir))) {
        logAgentd("slash command hidden (requires overlay UI)", { name: command.invocationName, baseDir });
        continue;
      }
      commands.push({ name: command.invocationName, description: command.description, source: "extension" });
    }
    for (const template of this.runtime.session.promptTemplates) {
      commands.push({ name: template.name, description: template.description, source: "prompt" });
    }
    for (const skill of this.runtime.session.resourceLoader.getSkills().skills) {
      commands.push({ name: `skill:${skill.name}`, description: skill.description, source: "skill" });
    }
    return commands;
  }

  clearQueue(): { steering: string[]; followUp: string[] } {
    return this.runtime.session.clearQueue();
  }

  getSteeringMessages(): readonly string[] {
    return this.runtime.session.getSteeringMessages();
  }

  getFollowUpMessages(): readonly string[] {
    return this.runtime.session.getFollowUpMessages();
  }

  get steeringMode(): PickyQueueMode {
    return this.runtime.session.steeringMode;
  }

  get followUpMode(): PickyQueueMode {
    return this.runtime.session.followUpMode;
  }

  get isStreaming(): boolean {
    return this.runtime.session.isStreaming;
  }

  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    const session = this.runtime.session;
    const existing = (session.state.messages ?? []) as unknown[];
    if (existing.length > 0) {
      logAgentd("pi inject bootstrap skipped", { sessionId: this.id, reason: "non-empty session", existingCount: existing.length });
      return;
    }

    const model = asRecord((session.state as unknown as Record<string, unknown>).model);
    const api = stringValue(model.api);
    const provider = stringValue(model.provider);
    const modelId = stringValue(model.id);
    if (!api || !provider || !modelId) {
      logAgentd("pi inject bootstrap skipped", { sessionId: this.id, reason: "model metadata missing" });
      return;
    }

    const now = Date.now();
    const userMessage = {
      role: "user" as const,
      content: messages.user,
      timestamp: now,
    };
    const assistantMessage = {
      role: "assistant" as const,
      content: [{ type: "text" as const, text: messages.assistant }],
      api,
      provider,
      model: modelId,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop" as const,
      timestamp: now,
    };

    try {
      session.sessionManager.appendMessage(userMessage as never);
      session.sessionManager.appendMessage(assistantMessage as never);
      session.state.messages = [...existing, userMessage, assistantMessage] as never;
      logAgentd("pi inject bootstrap", {
        sessionId: this.id,
        userChars: messages.user.length,
        assistantChars: messages.assistant.length,
        provider,
        model: modelId,
      });
    } catch (error) {
      logAgentd("pi inject bootstrap failed", { sessionId: this.id, error: messageOf(error) });
      throw error;
    }
  }

  async bindCurrentSession(): Promise<void> {
    logAgentd("pi bind session", { sessionId: this.id });
    this.unsubscribe?.();
    this.uiBridge = this.createBridge();
    const session = this.runtime.session;
    await session.bindExtensions({ uiContext: this.uiBridge.createContext(), onError: (error) => this.emit({ type: "log", line: `extension error: ${messageOf(error)}` }) });
    this.unsubscribe = session.subscribe((event: unknown) => {
      const runtimeEvent = this.runtimeEventFromPiEvent(event);
      if (runtimeEvent) this.emit(runtimeEvent);
      // Pi only updates AssistantMessage.usage when a turn ends, so piggyback on status terminal
      // events to refresh the context usage snapshot. Without this the HUD would only ever see
      // the value captured at session start.
      if (runtimeEvent?.type === "status" && ["completed", "failed", "cancelled", "waiting_for_input"].includes(runtimeEvent.status)) {
        this.emitContextUsageSnapshot();
      }
    });
  }

  private emitContextUsageSnapshot(): void {
    const session = this.runtime.session as unknown as { getContextUsage?: () => { tokens: number | null; contextWindow: number; percent: number | null } | undefined };
    if (typeof session.getContextUsage !== "function") return;
    let usage: { tokens: number | null; contextWindow: number; percent: number | null } | undefined;
    try {
      usage = session.getContextUsage();
    } catch (error) {
      logAgentd("context usage read failed", { sessionId: this.id, error: messageOf(error) });
      return;
    }
    this.emit({ type: "context_usage", usage });
  }

  reportDiagnostics(): void {
    if (this.transcriptRepairLogLine) this.emit({ type: "log", line: this.transcriptRepairLogLine });
    for (const diagnostic of this.runtime.diagnostics) {
      this.emit({ type: "log", line: `pi diagnostic: ${JSON.stringify(diagnostic)}` });
    }
    const sessionFile = this.runtime.session.sessionFile;
    if (sessionFile) {
      logAgentd("pi session file", { sessionId: this.id, sessionFile });
      this.emit({ type: "log", line: `pi session: ${sessionFile}` });
    }
  }

  getSessionFilePath(): string | undefined {
    return this.runtime.session.sessionFile ?? undefined;
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private runtimeEventFromPiEvent(event: unknown): RuntimeEvent | undefined {
    const record = asRecord(event);
    if (record.type === "queue_update") {
      const steering = Array.isArray(record.steering) ? (record.steering as readonly string[]) : [];
      const followUp = Array.isArray(record.followUp) ? (record.followUp as readonly string[]) : [];
      this.queuedSteeringCount = steering.length;
      this.queuedFollowUpCount = followUp.length;
      return { type: "queue_update", steering, followUp };
    }

    const inputMessageEvent = this.runtimeEventFromInputMessagePiEvent(record);
    if (inputMessageEvent) return inputMessageEvent;

    const recoveryEvent = this.runtimeEventFromRecoveryPiEvent(record);
    if (recoveryEvent) return recoveryEvent;

    const runtimeEvent = runtimeEventFromPiEvent(event, {
      hasQueuedSteering: this.queuedSteeringCount > 0,
      hasQueuedFollowUp: this.queuedFollowUpCount > 0,
      hasPendingExtensionUiRequest: this.pendingExtensionUiRequestIds.size > 0,
      currentModel: currentModelId(this.runtime.session),
      currentThinkingLevel: currentThinkingLevel(this.runtime.session) ?? this.configuredThinkingLevel,
    });

    if (runtimeEvent?.type === "extension_ui" && runtimeEvent.waitsForInput) {
      const requestId = typeof runtimeEvent.request.id === "string" ? runtimeEvent.request.id : undefined;
      if (requestId) this.pendingExtensionUiRequestIds.add(requestId);
    }

    if (runtimeEvent?.type === "status") {
      if (runtimeEvent.status === "failed" && record.type === "agent_end" && lastAssistantStopReason(record.messages) === "error") {
        this.deferTerminalError(runtimeEvent);
        return undefined;
      }
      this.cancelDeferredTerminalError();
    }

    return runtimeEvent;
  }

  private runtimeEventFromInputMessagePiEvent(event: Record<string, unknown>): RuntimeEvent | undefined {
    if (event.type !== "message_start") return undefined;
    const message = asRecord(event.message);
    const role = stringValue(message.role);
    if (role !== "user" && role !== "custom") return undefined;

    const text = textFromPiMessageContent(message.content).trim();
    if (!text) return undefined;

    if (role === "user") {
      const expected = this.consumeExpectedInputDelivery(text);
      if (expected?.suppress !== false) return undefined;
      return { type: "input_message", role, text, originatedBy: expected.originatedBy };
    }

    const display = message.display;
    return {
      type: "input_message",
      role,
      text,
      originatedBy: "pi_extension",
      ...(typeof display === "boolean" ? { display } : {}),
      ...(typeof message.customType === "string" ? { customType: message.customType } : {}),
    };
  }

  private expectInputDelivery(text: string, originatedBy: "user" | "main_agent" | "internal" = "internal", suppress = true): ExpectedInputDelivery {
    const delivery = { id: randomUUID(), text, originatedBy, suppress };
    this.expectedInputDeliveries.push(delivery);
    return delivery;
  }

  private consumeExpectedInputDelivery(text: string): ExpectedInputDelivery {
    const exactIndex = this.expectedInputDeliveries.findIndex((delivery) => delivery.text === text);
    if (exactIndex >= 0) return this.expectedInputDeliveries.splice(exactIndex, 1)[0]!;
    const slashIndex = this.expectedInputDeliveries.findIndex((delivery) => delivery.text.trim().startsWith("/"));
    if (slashIndex >= 0) return this.expectedInputDeliveries.splice(slashIndex, 1)[0]!;
    return { id: "pi-extension", text, originatedBy: "pi_extension", suppress: false };
  }

  private cancelExpectedInputDelivery(id: string): void {
    const index = this.expectedInputDeliveries.findIndex((delivery) => delivery.id === id);
    if (index >= 0) this.expectedInputDeliveries.splice(index, 1);
  }

  private isExpectedInputQueued(text: string): boolean {
    const session = this.runtime.session as unknown as { getSteeringMessages?: () => readonly string[]; getFollowUpMessages?: () => readonly string[] };
    return (session.getSteeringMessages?.() ?? []).includes(text) || (session.getFollowUpMessages?.() ?? []).includes(text);
  }

  private runtimeEventFromRecoveryPiEvent(event: Record<string, unknown>): RuntimeEvent | undefined {
    if (event.type === "auto_retry_start") {
      this.cancelDeferredTerminalError();
      const attempt = numberValue(event.attempt);
      const maxAttempts = numberValue(event.maxAttempts);
      const summary = attempt && maxAttempts ? `Retrying after transient Pi error (${attempt}/${maxAttempts})…` : "Retrying after transient Pi error…";
      return { type: "status", status: "running", summary };
    }
    if (event.type === "auto_retry_end") {
      this.cancelDeferredTerminalError();
      if (event.success === false) return { type: "status", status: "failed", summary: stringValue(event.finalError) ?? "Pi runtime retry failed" };
      return undefined;
    }
    if (event.type === "compaction_start") {
      this.cancelDeferredTerminalError();
      const reason = stringValue(event.reason);
      return { type: "status", status: "running", summary: reason === "overflow" ? "Compacting after context overflow…" : "Compacting session…" };
    }
    if (event.type === "compaction_end") {
      if (event.willRetry === true) {
        this.cancelDeferredTerminalError();
        return { type: "status", status: "running", summary: "Compaction completed; retrying…" };
      }
      if (stringValue(event.reason) === "overflow" && stringValue(event.errorMessage)) {
        this.cancelDeferredTerminalError();
        return { type: "status", status: "failed", summary: stringValue(event.errorMessage) };
      }
    }
    return undefined;
  }

  private deferTerminalError(event: Extract<RuntimeEvent, { type: "status" }>): void {
    this.cancelDeferredTerminalError();
    this.pendingTerminalError = event;
    this.pendingTerminalErrorTimer = setTimeout(() => {
      const pending = this.pendingTerminalError;
      this.pendingTerminalError = undefined;
      this.pendingTerminalErrorTimer = undefined;
      if (pending) this.emit(pending);
    }, 0);
  }

  private cancelDeferredTerminalError(): void {
    if (this.pendingTerminalErrorTimer) clearTimeout(this.pendingTerminalErrorTimer);
    this.pendingTerminalError = undefined;
    this.pendingTerminalErrorTimer = undefined;
  }

  private async promptWithOptions(prompt: BuiltPrompt, streamingBehavior?: "steer" | "followUp"): Promise<boolean> {
    if (await this.handleBuiltinSlashCommand(prompt.text)) return true;
    return this.promptUntilAccepted(prompt.text, {
      images: await imageOptions(prompt.imagePaths),
      source: "rpc",
      streamingBehavior,
    });
  }

  // Pi exposes session.setSessionName() / session.compact() as public APIs but only its TUI
  // interactive-mode wires them to /name and /compact slash commands. Picky doesn't run that
  // mode, so we intercept the built-in slash commands here before they would otherwise be
  // forwarded to the LLM as ordinary user text. The synthetic completed/noTurnRan status keeps
  // higher layers from treating the call as a real agent turn (no side-completion notification,
  // no artifact materialization).
  private async handleBuiltinSlashCommand(text: string): Promise<boolean> {
    const trimmed = text.trim();
    if (trimmed === "/name" || trimmed.startsWith("/name ")) {
      const name = trimmed.replace(/^\/name\s*/, "").trim();
      if (!name) {
        this.emit({ type: "log", line: "/name requires a name argument (usage: /name <session name>)" });
        this.emit({ type: "status", status: "completed", summary: "/name: missing argument", noTurnRan: true, preserveSessionState: true });
        return true;
      }
      try {
        this.runtime.session.setSessionName(name);
        this.emit({ type: "log", line: `session renamed to "${name}"` });
        // Pi emits session_info_changed internally, so the title flips via the normalized event.
        this.emit({ type: "status", status: "completed", summary: `Session renamed to ${name}`, noTurnRan: true, preserveSessionState: true });
      } catch (error) {
        const message = messageOf(error);
        logAgentd("slash /name failed", { sessionId: this.id, error: message });
        this.emit({ type: "log", line: `/name failed: ${message}` });
        this.emit({ type: "status", status: "completed", summary: `/name failed: ${message}`, noTurnRan: true, preserveSessionState: true });
      }
      return true;
    }
    if (trimmed === "/compact" || trimmed.startsWith("/compact ")) {
      const instructions = trimmed.replace(/^\/compact\s*/, "").trim() || undefined;
      const session = this.runtime.session as unknown as { compact?: (instructions?: string) => Promise<unknown> };
      if (typeof session.compact !== "function") {
        this.emit({ type: "status", status: "failed", summary: "/compact is not supported by this Pi runtime" });
        return true;
      }
      this.emit({ type: "status", status: "running", summary: instructions ? `Compacting (${instructions})…` : "Compacting session…" });
      try {
        await session.compact(instructions);
        this.emit({ type: "log", line: instructions ? `compact completed with instructions: ${instructions}` : "compact completed" });
        this.emit({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true });
      } catch (error) {
        const message = messageOf(error);
        logAgentd("slash /compact failed", { sessionId: this.id, error: message });
        this.emit({ type: "status", status: "failed", summary: `/compact failed: ${message}` });
      }
      return true;
    }
    return false;
  }

  private async promptUntilAccepted(
    text: string,
    options: { images?: Awaited<ReturnType<typeof imageOptions>>; source: "rpc"; streamingBehavior?: "steer" | "followUp" },
  ): Promise<boolean> {
    const wasStreaming = this.runtime.session.isStreaming;
    let accepted = false;
    let promptResolved = false;
    let settled = false;
    let resolveAccepted!: () => void;
    let rejectAccepted!: (error: unknown) => void;
    const acceptedPromise = new Promise<void>((resolve, reject) => {
      resolveAccepted = resolve;
      rejectAccepted = reject;
    });
    const resolveOnce = () => {
      if (settled) return;
      settled = true;
      resolveAccepted();
    };
    const rejectOnce = (error: unknown) => {
      if (settled) return;
      settled = true;
      rejectAccepted(error);
    };

    const expected = this.expectInputDelivery(text);
    const promptPromise = this.runtime.session.prompt(text, {
      ...options,
      preflightResult: (success: boolean) => {
        if (!success) {
          this.cancelExpectedInputDelivery(expected.id);
          return;
        }
        accepted = true;
        resolveOnce();
      },
    });

    void promptPromise
      .then(() => {
        promptResolved = true;
        resolveOnce();
      })
      .catch((error) => {
        promptResolved = true;
        this.cancelExpectedInputDelivery(expected.id);
        if (accepted) {
          this.emit({ type: "status", status: "failed", summary: messageOf(error) });
          return;
        }
        rejectOnce(error);
      });

    await acceptedPromise;
    // Microtask ordering race: when Pi handles `/slash` extension commands, `session.prompt()`
    // suspends at its internal `await _tryExecuteExtensionCommand` and then synchronously runs
    // `preflightResult(true)` -> `return` upon resume. That order schedules our awaiting
    // `acceptedPromise` continuation BEFORE the `.then` handler that sets `promptResolved`, so
    // a naive check here would always observe `promptResolved === false` for synchronously
    // handled prompts under the real Pi runtime (the silent-slash test happens to pass because
    // its FakeSession.prompt has no internal awaits and queues the .then handler first).
    // Yield once to let any already-scheduled `promptPromise.then` microtask run so we can
    // tell synchronous-handle paths apart from agent-turn paths.
    await Promise.resolve();
    const handledSynchronously = promptResolved ? this.maybeEmitImmediateCompletion(wasStreaming) : false;
    if (handledSynchronously || (promptResolved && !this.isExpectedInputQueued(text))) this.cancelExpectedInputDelivery(expected.id);
    return handledSynchronously;
  }

  // Pi handles `/slash` extension commands and input handlers that return `handled` synchronously
  // inside `session.prompt()` without emitting any agent_start / turn_end / agent_end events. The
  // prompt promise resolves immediately and `isStreaming` stays false, so the caller would otherwise
  // be stuck in a permanent "running" state on the Picky side. Synthesize a completed status when we
  // detect that no agent turn was actually started, and report whether we did so to the caller so
  // higher layers (e.g. session-supervisor.steer) can avoid resurrecting the session as `running`.
  // The `noTurnRan: true` marker tells RuntimeEventHandler to release the loading state without
  // running terminal side effects (notifying the main agent, re-materializing artifacts), since
  // no real agent turn produced any new state to report.
  private maybeEmitImmediateCompletion(wasStreaming: boolean): boolean {
    if (wasStreaming) return false;
    if (this.runtime.session.isStreaming) return false;
    this.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
    return true;
  }

  private createBridge(): ExtensionUiBridge {
    const bridge = new ExtensionUiBridge(this.id, { disableBlockingDialogs: this.bridgeOptions.disableBlockingDialogs ?? false });
    bridge.on("request", (request, waitsForInput) => {
      const waits = Boolean(waitsForInput);
      if (waits) this.pendingExtensionUiRequestIds.add(request.id);
      this.emit({ type: "extension_ui", request, waitsForInput: waits });
    });
    return bridge;
  }

  private extensionRequiresOverlayUi(baseDir: string): Promise<boolean> {
    const cached = this.extensionOverlayUiCache.get(baseDir);
    if (cached) return cached;
    const promise = scanForUiCustom(baseDir).catch((error) => {
      logAgentd("extension overlay ui scan failed", { baseDir, error: messageOf(error) });
      return false;
    });
    this.extensionOverlayUiCache.set(baseDir, promise);
    return promise;
  }

  private emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

async function imageOptions(imagePaths: string[] | undefined): Promise<Array<{ type: "image"; data: string; mimeType: string }> | undefined> {
  if (!imagePaths || imagePaths.length === 0) return undefined;
  return Promise.all(
    imagePaths.map(async (imagePath) => ({
      type: "image" as const,
      mimeType: mediaTypeFromPath(imagePath),
      data: await readFile(imagePath, "base64"),
    })),
  );
}

function mediaTypeFromPath(path: string): string {
  const extension = extname(path).toLowerCase();
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".webp") return "image/webp";
  return "image/png";
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

function textFromPiMessageContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) {
    if (content === undefined || content === null) return "";
    return typeof content === "object" ? JSON.stringify(content) : String(content);
  }
  return content
    .map((block) => {
      const record = asRecord(block);
      if (record.type === "text" && typeof record.text === "string") return record.text;
      return "";
    })
    .join("");
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

function lastAssistantStopReason(messages: unknown): string | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = asRecord(messages[index]);
    if (message.role === "assistant") return stringValue(message.stopReason);
  }
  return undefined;
}

function currentModelId(session: AgentSession): string | undefined {
  const directModel = asRecord((session as unknown as Record<string, unknown>).model);
  const stateModel = asRecord(asRecord((session as unknown as Record<string, unknown>).state).model);
  return stringValue(directModel.id) ?? stringValue(directModel.model) ?? stringValue(stateModel.id) ?? stringValue(stateModel.model);
}

function currentThinkingLevel(session: AgentSession): ThinkingLevel | undefined {
  return parseThinkingLevel((session as unknown as Record<string, unknown>).thinkingLevel)
    ?? parseThinkingLevel(asRecord((session as unknown as Record<string, unknown>).state).thinkingLevel);
}

function parseThinkingLevel(value: unknown): ThinkingLevel | undefined {
  if (value === "off" || value === "minimal" || value === "low" || value === "medium" || value === "high" || value === "xhigh") return value;
  return undefined;
}

function repairDanglingToolCalls(session: AgentSession): string | undefined {
  const messages = (session.state.messages ?? []) as unknown[];
  const repair = repairDanglingToolCallsInMessages(messages);
  if (repair.count === 0) return undefined;
  const names = [...new Set(repair.toolNames)].join(", ");
  return `pi transcript repaired: skipped ${repair.count} interrupted tool call(s)${names ? ` (${names})` : ""} from a previous runtime`;
}

function repairDanglingToolCallsInMessages(messages: unknown[]): { count: number; toolNames: string[] } {
  let pending: { message: Record<string, unknown>; calls: Array<{ id: string; name: string }>; matchedIds: Set<string> } | undefined;
  let count = 0;
  const toolNames: string[] = [];

  const repairPending = () => {
    if (!pending) return;
    const missing = pending.calls.filter((call) => !pending!.matchedIds.has(call.id));
    if (missing.length === 0) return;
    repairAssistantMessageWithDanglingToolCalls(pending.message, pending.matchedIds, missing);
    count += missing.length;
    toolNames.push(...missing.map((call) => call.name));
  };

  for (const value of messages) {
    const message = asRecord(value);
    if (pending) {
      const toolCallId = message.role === "toolResult" ? stringValue(message.toolCallId) : undefined;
      if (toolCallId && pending.calls.some((call) => call.id === toolCallId)) {
        pending.matchedIds.add(toolCallId);
        if (pending.calls.every((call) => pending!.matchedIds.has(call.id))) pending = undefined;
        continue;
      }
      repairPending();
      pending = undefined;
    }

    if (message.role !== "assistant") continue;
    const calls = toolCallsFromContent(message.content);
    if (calls.length > 0) pending = { message, calls, matchedIds: new Set() };
  }

  if (pending) repairPending();
  return { count, toolNames };
}

function repairAssistantMessageWithDanglingToolCalls(message: Record<string, unknown>, matchedIds: Set<string>, missing: Array<{ id: string; name: string }>): void {
  const content = Array.isArray(message.content) ? message.content : [];
  const textBlocks = content.filter((block) => asRecord(block).type === "text");
  const matchedToolCallBlocks = content.filter((block) => {
    const record = asRecord(block);
    return record.type === "toolCall" && typeof record.id === "string" && matchedIds.has(record.id);
  });
  const names = [...new Set(missing.map((call) => call.name))].join(", ") || "tool";
  const note = {
    type: "text",
    text: `[Picky note: previous ${names} tool call${missing.length === 1 ? "" : "s"} did not finish because the local Picky runtime restarted. Continue from the current filesystem state and rerun any needed checks.]`,
  };
  message.content = [...textBlocks, note, ...matchedToolCallBlocks];
  if (matchedToolCallBlocks.length === 0 && message.stopReason === "toolUse") message.stopReason = "end_turn";
}

function toolCallsFromContent(content: unknown): Array<{ id: string; name: string }> {
  if (!Array.isArray(content)) return [];
  return content.flatMap((block) => {
    const record = asRecord(block);
    const id = stringValue(record.id);
    if (record.type !== "toolCall" || !id) return [];
    return [{ id, name: stringValue(record.name) ?? "tool" }];
  });
}

function normalizeAnswer(value: unknown): { value?: unknown; confirmed?: boolean; cancelled?: boolean } {
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if ("value" in record || "confirmed" in record || "cancelled" in record) {
      return record as { value?: unknown; confirmed?: boolean; cancelled?: boolean };
    }
  }
  return { value };
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function extensionBaseDir(command: { sourceInfo?: { baseDir?: string; path?: string } }): string | undefined {
  const info = command.sourceInfo;
  if (!info) return undefined;
  if (info.baseDir) return info.baseDir;
  // Some Pi sources only carry a file path. Strip the filename so the directory scan starts at
  // the extension root.
  return info.path ? dirname(info.path) : undefined;
}

async function scanForUiCustom(dir: string): Promise<boolean> {
  let stats;
  try {
    stats = await stat(dir);
  } catch {
    return false;
  }
  if (!stats.isDirectory()) return false;

  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return false;
  }
  for (const entry of entries) {
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
    const next = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (await scanForUiCustom(next)) return true;
      continue;
    }
    if (!entry.isFile()) continue;
    if (!/\.(ts|js|mjs|cjs)$/.test(entry.name)) continue;
    try {
      const text = await readFile(next, "utf8");
      if (/\bui\.custom\b/.test(text)) return true;
    } catch {}
  }
  return false;
}

export type { AgentSession, AgentSessionRuntime };
