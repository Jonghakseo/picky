import { randomUUID } from "node:crypto";
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
} from "@earendil-works/pi-coding-agent";
import { CombinedAutocompleteProvider, type SlashCommand } from "@earendil-works/pi-tui";
import type { BuiltPrompt } from "../prompt-builder.js";
import { ExtensionUiBridge } from "../application/extension-ui-bridge.js";
import { runtimeEventFromPiEvent } from "../domain/pi-event-normalizer.js";
import { resolveTodoStateFromPiSessionEntries } from "../domain/todo-state.js";
import { isTransientAgentBusyError } from "../domain/transient-runtime-error.js";
import type { AgentRuntime, AnswerExtensionUiOptions, RewindBranchMessage, RewindResult, RewindTarget, RuntimeAssistantRunMetadata, RuntimeAutocompleteApplyRequest, RuntimeAutocompleteCapabilities, RuntimeAutocompleteCompletion, RuntimeAutocompleteQuery, RuntimeAutocompleteSuggestions, RuntimeBashExecutionResult, RuntimeEvent, RuntimeModelOption, RuntimeSessionHandle, RuntimeSlashCommand, RuntimeSteerResult, ThinkingLevel } from "./types.js";
import type { ModelCycleDirection, PickyQueueMode } from "../protocol.js";
import { logAgentd } from "../local-log.js";
import {
  type ScopedModelOption,
  applyScopedModelsForCycling,
  automaticModelFromServices,
  availableModelsFromServices,
  currentModelId,
  currentThinkingLevel,
  modelFromServices,
  normalizeModelPattern,
  runtimeModelOptionFromModel,
  scopedModelsFromServices,
} from "./pi-model-resolution.js";
import {
  isCompacting as piIsCompacting,
  readModelMetadata as piReadModelMetadata,
  tryCompact as piTryCompact,
  tryCycleModel as piTryCycleModel,
  tryCycleThinkingLevel as piTryCycleThinkingLevel,
  tryGetBashSurface as piTryGetBashSurface,
  tryGetContextUsage as piTryGetContextUsage,
  tryRefreshSystemPromptFromActiveTools as piTryRefreshSystemPromptFromActiveTools,
  tryReload as piTryReload,
  trySetThinkingLevel as piTrySetThinkingLevel,
} from "./pi-capabilities.js";
import {
  asRecord,
  bashResultPreview,
  branchTranscriptFromEntries,
  emitUserBash,
  imageOptions,
  isAbortedTerminalPiEvent,
  lastAssistantStopReason,
  messageOf,
  normalizeAnswer,
  normalizeBashExecutionResult,
  numberValue,
  queueKindFromStreamingBehavior,
  repairDanglingToolCalls,
  resolveAutocompleteFdPath,
  shouldEmitContextUsageSnapshotAfterPiEvent,
  sliceUtf16,
  stringValue,
  textFromPiMessageContent,
} from "./pi-sdk-runtime-helpers.js";

// Re-exported so existing importers (e.g. pi-sdk-runtime-rewind.test.ts) keep working.
export { branchTranscriptFromEntries };

// Picky exposes a curated subset of Pi's BUILTIN_SLASH_COMMANDS. Each entry must be backed by a
// public AgentSession API call inside handleBuiltinSlashCommand below; do not list a command we
// cannot actually execute, otherwise users will see autocomplete suggestions that silently fall
// through to the LLM as plain user text.
const PICKY_BUILTIN_SLASH_COMMANDS: ReadonlyArray<{ name: string; description: string }> = [
  { name: "new", description: "Start a fresh Pi session in this Picky card" },
  { name: "name", description: "Set the Pi session display name (usage: /name <session name>)" },
  { name: "compact", description: "Manually compact the session context (optional: /compact <focus instructions>)" },
  { name: "reload", description: "Reload Pi skills, extensions, prompts, and context files" },
];

// Soft cap for the per-session `slashExpansions` map. A long-lived Pi session can submit many
// slash commands; in pathological cases Pi may never emit the matching role="custom" echo (e.g.
// extension changes mid-session), which would leak the mapping. The cap is generous enough to
// cover realistic concurrent in-flight slash commands while keeping memory bounded.
const SLASH_EXPANSION_MAP_CAP = 64;
const AUTOCOMPLETE_MAX_ITEMS = 20;
const AUTOCOMPLETE_QUERY_TIMEOUT_MS = 2_000;

interface PiSdkRuntimeOptions {
  agentDir?: string;
  createRuntime?: typeof createAgentSessionRuntime;
  createServices?: typeof createAgentSessionServices;
  createSessionFromServices?: typeof createAgentSessionFromServices;
  getAgentDir?: typeof getAgentDir;
  resourceLoaderOptions?: CreateAgentSessionServicesOptions["resourceLoaderOptions"];
  customTools?: ToolDefinition[];
  thinkingLevel?: ThinkingLevel;
  modelPattern?: string;
  disableBlockingDialogs?: boolean;
}

export class PiSdkRuntime implements AgentRuntime {
  private thinkingLevel?: ThinkingLevel;
  private modelPattern?: string;
  private customTools: ToolDefinition[];

  constructor(private readonly options: PiSdkRuntimeOptions = {}) {
    this.thinkingLevel = options.thinkingLevel;
    this.modelPattern = normalizeModelPattern(options.modelPattern);
    this.customTools = options.customTools ?? [];
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevel = level;
  }

  /// Replace the customTools list used at the next session creation. Existing
  /// sessions keep their original tools until the supervisor aborts and resets
  /// the main handle.
  setCustomTools(tools: ToolDefinition[]): void {
    this.customTools = tools;
  }

  setModelPattern(pattern?: string): boolean {
    const next = normalizeModelPattern(pattern);
    const changed = this.modelPattern !== next;
    this.modelPattern = next;
    return changed;
  }

  async listAvailableModels(options: { cwd?: string } = {}): Promise<RuntimeModelOption[]> {
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();
    const services = await createServices({ cwd: options.cwd ?? process.cwd(), agentDir, resourceLoaderOptions: this.options.resourceLoaderOptions });
    const available = await availableModelsFromServices(services);
    return available.map(runtimeModelOptionFromModel);
  }

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime create", { sessionId: options.sessionId, cwd: options.cwd, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    const handle = await this.createHandle(options);
    handle.scheduleInitialPrompt(prompt);
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
    const customTools = this.customTools;

    const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd: runtimeCwd, sessionManager, sessionStartEvent }) => {
      const services = await createServices({ cwd: runtimeCwd, agentDir, resourceLoaderOptions: this.options.resourceLoaderOptions });
      const fixedModel = await modelFromServices(services, this.modelPattern);
      const scopedModels = fixedModel
        ? [{ model: fixedModel, ...(this.thinkingLevel ? { thinkingLevel: this.thinkingLevel } : {}) }]
        : await scopedModelsFromServices(services);
      const sessionResult = await createSessionFromServices({
        services,
        sessionManager,
        sessionStartEvent,
        customTools,
        thinkingLevel: this.thinkingLevel,
        ...(fixedModel ? { model: fixedModel, scopedModels } : {}),
      });
      if (!fixedModel) applyScopedModelsForCycling(sessionResult.session, scopedModels);
      return {
        ...sessionResult,
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
  queueKind?: "steering" | "followUp";
}

class PiSdkRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  private unsubscribe?: () => void;
  private uiBridge: ExtensionUiBridge;
  private readonly transcriptRepairLogLine?: string;
  private queuedSteeringCount = 0;
  private queuedFollowUpCount = 0;
  private pendingExtensionUiRequestIds = new Set<string>();
  private hostPendingExtensionUiPresent?: () => boolean;
  private pendingTerminalError?: Extract<RuntimeEvent, { type: "status" }>;
  private pendingTerminalErrorTimer?: ReturnType<typeof setTimeout>;
  private initialPromptTimer?: ReturnType<typeof setTimeout>;
  private expectedInputDeliveries: ExpectedInputDelivery[] = [];
  // Pi expands slash commands like `/skill:<name>` server-side before enqueueing, so the queue
  // snapshot and the matching role="custom" message_start carry the expansion (e.g. the SKILL.md
  // body) instead of the raw text the user typed. We learn `expansion -> raw` mappings from Pi's
  // queue updates (including the first synchronous queue_update Pi emits before preflightResult)
  // and from a post-acceptance queue diff, then translate every outbound view of the queue
  // (queue_update events, getSteeringMessages/getFollowUpMessages) so downstream code sees the raw
  // text consistently and suppress the duplicate role="custom" echo when it arrives.
  private slashExpansions = new Map<string, { raw: string; count: number }>();
  private pendingSlashSubmissions: Array<{ raw: string; beforeQueue?: ReadonlyMap<string, number> }> = [];
  // After an explicit abort() we synthesize a `status: cancelled` event right away. Pi will
  // still drain the aborted turn and eventually emit its own turn_end/agent_end with
  // stopReason="aborted" (each normalized to another `status: cancelled`). Pi can emit BOTH
  // a `turn_end` and an `agent_end` for a single abort, so a once-only boolean flag let the
  // second event leak through and stamp a duplicate "Cancelled by user" bubble on top of any
  // steer/follow-up the user sent in between. Track the number of in-flight abort cycles
  // instead, suppress every aborted terminal event while the counter is non-zero, and only
  // clear the counter when Pi opens a fresh agent cycle (agent_start) so a real cancellation
  // of the new turn still surfaces.
  private pendingAbortAcknowledgements = 0;
  private autocompleteGeneration = 0;
  private autocompleteQueryController: AbortController | undefined;

  constructor(readonly id: string, private readonly runtime: AgentSessionRuntime, private configuredThinkingLevel?: ThinkingLevel, private readonly bridgeOptions: { disableBlockingDialogs?: boolean } = {}) {
    this.uiBridge = this.createBridge();
    this.transcriptRepairLogLine = repairDanglingToolCalls(runtime.session);
    this.runtime.setRebindSession(async () => this.bindCurrentSession());
  }

  scheduleInitialPrompt(prompt: BuiltPrompt): void {
    if (this.initialPromptTimer) clearTimeout(this.initialPromptTimer);
    this.initialPromptTimer = setTimeout(() => {
      this.initialPromptTimer = undefined;
      this.reportDiagnostics();
      void this.prompt(prompt);
    }, 0);
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
      this.emitPromptFailureStatus(error);
      return;
    }
    if (this.maybeEmitImmediateCompletion(wasStreaming)) this.cancelExpectedInputDelivery(expected.id);
  }

  async followUp(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi follow-up", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      await this.promptWithOptions(prompt, "followUp");
    } catch (error) {
      this.emitPromptFailureStatus(error);
      throw error;
    }
  }

  async interrupt(prompt: BuiltPrompt): Promise<void> {
    logAgentd("pi interrupt", { sessionId: this.id, wasStreaming: this.runtime.session.isStreaming, promptChars: prompt.text.length });
    try {
      if (this.runtime.session.isStreaming) {
        this.uiBridge.cancelAll();
        await this.runtime.session.abort();
      }
      await this.promptWithOptions(prompt);
    } catch (error) {
      this.emitPromptFailureStatus(error);
      throw error;
    }
  }

  async steer(prompt: BuiltPrompt): Promise<RuntimeSteerResult> {
    logAgentd("pi steer", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      const handledSynchronously = await this.promptWithOptions(prompt, "steer");
      return { handledSynchronously };
    } catch (error) {
      this.emitPromptFailureStatus(error);
      throw error;
    }
  }

  private emitPromptFailureStatus(error: unknown): void {
    const message = messageOf(error);
    if (isTransientAgentBusyError(message)) {
      logAgentd("pi prompt busy failure ignored", { sessionId: this.id, error: message });
      return;
    }
    this.emit({ type: "status", status: "failed", summary: message });
  }

  async compact(customInstructions?: string): Promise<void> {
    logAgentd("pi compact", {
      sessionId: this.id,
      wasStreaming: this.runtime.session.isStreaming,
      instructionChars: customInstructions?.length ?? 0,
    });
    await this.runCompact(customInstructions);
  }

  async abort(): Promise<void> {
    logAgentd("pi abort", { sessionId: this.id });
    if (this.initialPromptTimer) {
      clearTimeout(this.initialPromptTimer);
      this.initialPromptTimer = undefined;
    }
    this.pendingAbortAcknowledgements += 1;
    this.uiBridge.cancelAll();
    await this.runtime.session.abort();
    this.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
  }

  async executeUserBash(command: string, options: { excludeFromContext?: boolean; onOutputChunk?: (chunk: string) => void } = {}): Promise<RuntimeBashExecutionResult> {
    const trimmedCommand = command.trim();
    if (!trimmedCommand) throw new Error("Bash command cannot be empty");
    const bash = piTryGetBashSurface(this.runtime.session, this.id);
    if (!bash) throw new Error("Pi runtime does not support direct bash execution");
    if (bash.isBashRunning) throw new Error("A bash command is already running");

    const excludeFromContext = options.excludeFromContext === true;
    const toolCallId = `user-bash-${randomUUID()}`;
    logAgentd("pi user bash", { sessionId: this.id, commandChars: trimmedCommand.length, excludeFromContext });
    this.emit({ type: "tool", toolCallId, name: "bash", status: "running", preview: trimmedCommand, argsPreview: `$ ${trimmedCommand}` });

    try {
      const eventResult = await emitUserBash(bash, { command: trimmedCommand, excludeFromContext, cwd: this.runtime.cwd });
      const result = normalizeBashExecutionResult(eventResult?.result)
        ?? await bash.executeBash(trimmedCommand, (chunk: string) => {
          options.onOutputChunk?.(chunk);
          this.emit({ type: "tool", toolCallId, name: "bash", status: "running", preview: trimmedCommand, resultPreview: sliceUtf16(chunk, 500) });
        }, { excludeFromContext, operations: eventResult?.operations });

      if (eventResult?.result) bash.recordBashResult(trimmedCommand, result, { excludeFromContext });
      this.emit({
        type: "tool",
        toolCallId,
        name: "bash",
        status: result.exitCode && result.exitCode !== 0 ? "failed" : "succeeded",
        preview: trimmedCommand,
        resultPreview: bashResultPreview(result),
      });
      return result;
    } catch (error) {
      const message = messageOf(error);
      this.emit({ type: "tool", toolCallId, name: "bash", status: "failed", preview: trimmedCommand, resultPreview: message });
      throw error;
    }
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    logAgentd("pi new session", { sessionId: this.id, cwd: this.runtime.cwd });
    const result = await this.runtime.newSession();
    if (result.cancelled) return result;
    await this.bindCurrentSession();
    this.emit({ type: "session_replaced", reason: "new", cwd: this.runtime.cwd, sessionFilePath: this.getSessionFilePath() });
    this.reportDiagnostics();
    this.emit({ type: "status", status: "completed", summary: "New session started", noTurnRan: true, preserveSessionState: true });
    return result;
  }

  async answerExtensionUi(requestId: string, value: unknown, options?: AnswerExtensionUiOptions): Promise<void> {
    this.pendingExtensionUiRequestIds.delete(requestId);
    const delivered = this.uiBridge.answer(requestId, normalizeAnswer(value));
    if (delivered) return;
    if (options?.ignoreUnknown) {
      logAgentd("pi runtime answerExtensionUi ignored unknown request", { sessionId: this.id, requestId });
      return;
    }
    throw new Error(`Unknown extension UI request: ${requestId}`);
  }

  setThinkingLevel(level: ThinkingLevel): void {
    if (!piTrySetThinkingLevel(this.runtime.session, this.id, level)) {
      this.emit({ type: "log", line: "pi thinking level change skipped: active session does not support setThinkingLevel" });
      return;
    }
    this.configuredThinkingLevel = level;
    logAgentd("pi thinking level set", { sessionId: this.id, level });
  }

  setHostPendingExtensionUiPresent(present: () => boolean): void {
    this.hostPendingExtensionUiPresent = present;
  }

  getAssistantRunMetadata(): RuntimeAssistantRunMetadata | undefined {
    return this.currentAssistantRunMetadata();
  }

  cycleThinkingLevel(): RuntimeAssistantRunMetadata | undefined {
    const level = piTryCycleThinkingLevel(this.runtime.session, this.id);
    if (level === undefined) {
      // Distinguish "capability missing" from "current model does not support thinking" via the
      // logged warning trail in pi-capabilities (warnOnceForAbsence). The user-facing log line
      // intentionally stays the same so we don't reveal which fallback fired.
      this.emit({ type: "log", line: "pi thinking level cycle skipped: capability unavailable or current model does not support thinking" });
      return this.currentAssistantRunMetadata();
    }
    this.configuredThinkingLevel = level;
    logAgentd("pi thinking level cycled", { sessionId: this.id, level });
    return this.currentAssistantRunMetadata();
  }

  async setModel(pattern?: string): Promise<RuntimeAssistantRunMetadata | undefined> {
    const normalized = normalizeModelPattern(pattern);
    const services = this.runtime.services;
    if (normalized) {
      const model = await modelFromServices(services, normalized);
      if (!model) throw new Error(`No Pi model matched pattern: ${normalized}`);
      const scopedModel: ScopedModelOption = { model, ...(this.configuredThinkingLevel ? { thinkingLevel: this.configuredThinkingLevel } : {}) };
      applyScopedModelsForCycling(this.runtime.session, [scopedModel]);
      await this.runtime.session.setModel(scopedModel.model);
    } else {
      const scopedModels = await scopedModelsFromServices(services);
      applyScopedModelsForCycling(this.runtime.session, scopedModels);
      const automaticModel = await automaticModelFromServices(services, scopedModels);
      if (automaticModel) await this.runtime.session.setModel(automaticModel);
    }
    const metadata = this.currentAssistantRunMetadata();
    logAgentd("pi model set", { sessionId: this.id, modelPattern: normalized, model: metadata?.model, thinkingLevel: metadata?.thinkingLevel });
    return metadata;
  }

  async cycleModel(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined> {
    const result = await piTryCycleModel(this.runtime.session, this.id, direction);
    if (!result) {
      this.emit({ type: "log", line: "pi model cycle skipped: capability unavailable or only one model available" });
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

  getAutocompleteCapabilities(): RuntimeAutocompleteCapabilities {
    return this.uiBridge.autocompleteCapabilities();
  }

  async queryAutocomplete(query: RuntimeAutocompleteQuery): Promise<RuntimeAutocompleteSuggestions> {
    this.assertAutocompleteGeneration(query.generation);
    this.autocompleteQueryController?.abort();
    const controller = new AbortController();
    this.autocompleteQueryController = controller;
    const bridge = this.uiBridge;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const cancelled = new Promise<null>((resolve) => {
      controller.signal.addEventListener("abort", () => resolve(null), { once: true });
      timeout = setTimeout(() => {
        controller.abort();
        resolve(null);
      }, AUTOCOMPLETE_QUERY_TIMEOUT_MS);
    });
    try {
      const suggestions = await Promise.race([
        bridge.getAutocompleteSuggestions({
          lines: query.lines,
          cursorLine: query.cursorLine,
          cursorCol: query.cursorCol,
          force: query.force,
          signal: controller.signal,
        }),
        cancelled,
      ]);
      if (controller.signal.aborted || bridge !== this.uiBridge) {
        return { generation: query.generation, items: [] };
      }
      return {
        generation: query.generation,
        ...(suggestions?.prefix !== undefined ? { prefix: suggestions.prefix } : {}),
        items: (suggestions?.items ?? []).slice(0, AUTOCOMPLETE_MAX_ITEMS),
      };
    } finally {
      if (timeout) clearTimeout(timeout);
      if (this.autocompleteQueryController === controller) this.autocompleteQueryController = undefined;
    }
  }

  applyAutocomplete(request: RuntimeAutocompleteApplyRequest): RuntimeAutocompleteCompletion {
    this.assertAutocompleteGeneration(request.generation);
    const completion = this.uiBridge.applyAutocompleteCompletion(
      request.lines,
      request.cursorLine,
      request.cursorCol,
      request.item,
      request.prefix,
    );
    return { generation: request.generation, ...completion };
  }

  async listSlashCommands(): Promise<RuntimeSlashCommand[]> {
    const commands: RuntimeSlashCommand[] = [
      ...PICKY_BUILTIN_SLASH_COMMANDS.map((command) => ({ ...command, source: "builtin" as const })),
    ];
    // Trade-off: we expose every extension command in autocomplete instead of trying to
    // filter out ones that depend on Pi TUI surfaces Picky does not implement.
    //
    // Why we don't filter:
    //   - Pi SDK assigns the agentDir itself (e.g. ~/.pi/agent) as the baseDir for every
    //     auto-discovered local extension under ~/.pi/agent/extensions/*. A directory-level
    //     `ui.custom` scan therefore flags ALL local extensions if any single sibling uses it,
    //     producing false positives for clean extensions like /github:pr-merge.
    //   - ExtensionUiBridge implements the common surfaces (notify/confirm/select/input/
    //     editor/askUserQuestion/setStatus/setTitle) and composes addAutocompleteProvider
    //     over Pi's built-in slash/path provider. Terminal-component surfaces such as
    //     setWidget/setHeader/setFooter/setEditorComponent remain no-ops.
    //   - The only hard failure is `ui.custom`, which throws PickyOverlayUnsupportedError.
    //     extension-crash-guard.ts swallows that (and any extension TypeError such as a missing
    //     `theme.fg`) so daemon stays alive; the user just sees the command no-op or error.
    //
    // Cost we accept: a few overlay-heavy commands (e.g. /widgets, /sub:peek, /subagents) show
    // up in autocomplete but produce only an error or empty effect when invoked.
    for (const command of this.runtime.session.extensionRunner.getRegisteredCommands()) {
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
    const cleared = this.runtime.session.clearQueue();
    // Drop cached slash-command expansion mappings whose Pi-side entries were just cleared.
    // Without this the mapping would leak indefinitely whenever the user discards a queued
    // slash command before Pi delivers its role="custom" echo.
    for (const entry of [...cleared.steering, ...cleared.followUp]) this.slashExpansions.delete(this.normalizedSlashExpansionKey(entry));
    return cleared;
  }

  listRewindTargets(): RewindTarget[] {
    return this.runtime.session.getUserMessagesForForking().map((target) => {
      const entry = this.runtime.session.sessionManager.getEntry(target.entryId) as { timestamp?: unknown } | undefined;
      const timestamp = typeof entry?.timestamp === "number"
        ? new Date(entry.timestamp).toISOString()
        : typeof entry?.timestamp === "string"
          ? entry.timestamp
          : undefined;
      return {
        entryId: target.entryId,
        text: target.text,
        ...(timestamp ? { createdAt: timestamp } : {}),
      };
    });
  }

  async rewindToEntry(entryId: string): Promise<RewindResult> {
    if (this.runtime.session.isStreaming) throw new Error("Cannot rewind while Pi session is streaming");
    const result = await this.runtime.session.navigateTree(entryId);
    return {
      ...(result.editorText !== undefined ? { editorText: result.editorText } : {}),
      cancelled: result.cancelled,
    };
  }

  // Pi returns root->leaf; never reverse because supervisor reconciliation anchors on the newest last entry.
  getActiveBranchTranscript(): RewindBranchMessage[] { return branchTranscriptFromEntries(this.runtime.session.sessionManager.getBranch()); }
  getTodoStateResolution() { return resolveTodoStateFromPiSessionEntries(this.runtime.session.sessionManager.getBranch()); }

  getSteeringMessages(): readonly string[] {
    return this.runtime.session.getSteeringMessages().map((entry) => this.translateQueueEntry(entry));
  }

  getFollowUpMessages(): readonly string[] {
    return this.runtime.session.getFollowUpMessages().map((entry) => this.translateQueueEntry(entry));
  }

  private translateQueueEntry(text: string): string {
    return this.slashExpansions.get(this.normalizedSlashExpansionKey(text))?.raw ?? text;
  }

  private normalizedSlashExpansionKey(text: string): string {
    return text.trim();
  }

  private registerSlashExpansion(expansion: string, rawText: string): void {
    const expansionKey = this.normalizedSlashExpansionKey(expansion);
    const raw = rawText.trim();
    if (!expansionKey || !raw || expansionKey === raw) return;
    const existing = this.slashExpansions.get(expansionKey);
    if (existing) {
      existing.count += 1;
      return;
    }
    // Bound the map: if it grows past the cap, drop the oldest entries so a long-lived
    // session that repeatedly invokes slash commands without ever receiving custom echoes
    // (e.g. extensions that don't echo, or unrelated cleanup paths) cannot leak memory.
    while (this.slashExpansions.size >= SLASH_EXPANSION_MAP_CAP) {
      const oldestKey = this.slashExpansions.keys().next().value;
      if (oldestKey === undefined) break;
      this.slashExpansions.delete(oldestKey);
    }
    this.slashExpansions.set(expansionKey, { raw, count: 1 });
    logAgentd("pi slash expansion captured", {
      sessionId: this.id,
      rawChars: raw.length,
      expansionChars: expansionKey.length,
    });
  }

  private consumeSlashExpansion(expansion: string): boolean {
    const expansionKey = this.normalizedSlashExpansionKey(expansion);
    const existing = this.slashExpansions.get(expansionKey);
    if (!existing) return false;
    existing.count -= 1;
    if (existing.count <= 0) this.slashExpansions.delete(expansionKey);
    return true;
  }

  private removePendingSlashSubmission(pending: { raw: string; beforeQueue?: ReadonlyMap<string, number> } | undefined): void {
    if (!pending) return;
    const index = this.pendingSlashSubmissions.indexOf(pending);
    if (index >= 0) this.pendingSlashSubmissions.splice(index, 1);
  }

  // Snapshot Pi's queues right before submitting a slash-prefixed prompt so we can diff after
  // acceptance to learn which queue entry Pi created from our raw text. The before-set keeps us
  // from re-mapping entries that were already queued by an earlier prompt.
  private snapshotQueueForSlashExpansion(rawText: string): ReadonlyMap<string, number> | undefined {
    if (!rawText.trim().startsWith("/")) return undefined;
    const counts = new Map<string, number>();
    for (const entry of [...this.runtime.session.getSteeringMessages(), ...this.runtime.session.getFollowUpMessages()]) {
      const key = this.normalizedSlashExpansionKey(entry);
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    return counts;
  }

  private rememberSlashExpansionFromQueue(beforeQueue: ReadonlyMap<string, number> | undefined, rawText: string): void {
    if (!beforeQueue) return;
    const after = [
      ...this.runtime.session.getSteeringMessages(),
      ...this.runtime.session.getFollowUpMessages(),
    ];
    const raw = rawText.trim();
    const hasPendingRaw = this.pendingSlashSubmissions.some((submission) => submission.raw === raw);
    const seen = new Map<string, number>();
    for (const entry of after) {
      const entryKey = this.normalizedSlashExpansionKey(entry);
      const occurrence = (seen.get(entryKey) ?? 0) + 1;
      seen.set(entryKey, occurrence);
      if (entryKey === raw) continue;
      if (occurrence <= (beforeQueue.get(entryKey) ?? 0)) continue;
      if (this.slashExpansions.has(entryKey) && !hasPendingRaw) continue;
      this.registerSlashExpansion(entry, raw);
    }
  }

  private rememberPendingSlashExpansionsFromQueueUpdate(entries: readonly string[]): void {
    const seen = new Map<string, number>();
    for (const entry of entries) {
      const entryKey = this.normalizedSlashExpansionKey(entry);
      const occurrence = (seen.get(entryKey) ?? 0) + 1;
      seen.set(entryKey, occurrence);
      if (!entryKey || this.slashExpansions.has(entryKey)) continue;
      const pending = this.pendingSlashSubmissions.find((submission) => submission.raw !== entryKey && occurrence > (submission.beforeQueue?.get(entryKey) ?? 0));
      if (!pending) continue;
      this.registerSlashExpansion(entry, pending.raw);
      this.removePendingSlashSubmission(pending);
    }
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

  get isCompacting(): boolean {
    return piIsCompacting(this.runtime.session);
  }

  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    const existing = (this.runtime.session.state.messages ?? []) as unknown[];
    if (existing.length > 0) {
      logAgentd("pi inject bootstrap skipped", { sessionId: this.id, reason: "non-empty session", existingCount: existing.length });
      return;
    }
    await this.appendSyntheticMessages("bootstrap", messages, existing);
  }

  async injectResumeGuidance(messages: { user: string; assistant: string }): Promise<void> {
    const existing = (this.runtime.session.state.messages ?? []) as unknown[];
    if (existing.length === 0) {
      logAgentd("pi inject resume guidance skipped", { sessionId: this.id, reason: "empty session" });
      return;
    }
    await this.appendSyntheticMessages("resume guidance", messages, existing);
  }

  private async appendSyntheticMessages(kind: "bootstrap" | "resume guidance", messages: { user: string; assistant: string }, existing: unknown[]): Promise<void> {
    const session = this.runtime.session;
    const modelMetadata = piReadModelMetadata(session);
    if (!modelMetadata?.api || !modelMetadata.provider || !modelMetadata.modelId) {
      logAgentd(`pi inject ${kind} skipped`, { sessionId: this.id, reason: "model metadata missing" });
      return;
    }
    const { api, provider, modelId } = modelMetadata;

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
      logAgentd(`pi inject ${kind}`, {
        sessionId: this.id,
        userChars: messages.user.length,
        assistantChars: messages.assistant.length,
        provider,
        model: modelId,
      });
    } catch (error) {
      logAgentd(`pi inject ${kind} failed`, { sessionId: this.id, error: messageOf(error) });
      throw error;
    }
  }

  async bindCurrentSession(): Promise<void> {
    logAgentd("pi bind session", { sessionId: this.id });
    this.unsubscribe?.();
    // Mark "no current subscription" before the await so a concurrent re-entrant caller can
    // detect a race and abandon its late path. Without this, a `bindCurrentSession()` invoked
    // by `setRebindSession` (fired by Pi internals) while an initial bind is still awaiting
    // `session.bindExtensions` would leak both subscribers into Pi's `_eventListeners`,
    // causing every text_delta / turn_end / agent_end to fire twice — accumulating `mainDraft`
    // to 2x the assistant text and producing a single full-doubled TTS playback that matches
    // the user-reported "풀로 두 번 발화" symptom.
    this.unsubscribe = undefined;
    this.uiBridge.cancelAll();
    this.uiBridge = this.createBridge();
    const session = this.runtime.session;
    await session.bindExtensions({ uiContext: this.uiBridge.createContext(), onError: (error) => this.emit({ type: "log", line: `extension error: ${messageOf(error)}` }) });
    if (this.unsubscribe) {
      // Another `bindCurrentSession()` won the race during the `await`. Yield ownership to it
      // instead of stacking a second subscriber on the same Pi session — a second subscriber
      // would be unreachable to the next unsubscribe (we only keep one cleanup handle).
      logAgentd("pi bind session reentry detected; abandoning late path", { sessionId: this.id });
      return;
    }
    this.unsubscribe = session.subscribe((event: unknown) => {
      const runtimeEvent = this.runtimeEventFromPiEvent(event);
      if (runtimeEvent) this.emit(runtimeEvent);
      // General pi's footer recomputes context usage on every render. It therefore advances at
      // intermediate transcript boundaries (assistant/tool-result message_end), not only when the
      // whole agent run becomes terminal. Mirror those stable boundaries here so Picky's HUD keeps
      // pace during multi-turn/tool-heavy Pickles without sampling every text delta.
      if (shouldEmitContextUsageSnapshotAfterPiEvent(event, runtimeEvent)) {
        this.emitContextUsageSnapshot();
      }
    });
  }

  private emitContextUsageSnapshot(options: { resetAfterCompaction?: boolean } = {}): void {
    let usage;
    try {
      usage = piTryGetContextUsage(this.runtime.session, this.id);
    } catch (error) {
      logAgentd("context usage read failed", { sessionId: this.id, error: messageOf(error) });
      if (options.resetAfterCompaction) this.emit({ type: "context_usage", usage: undefined });
      return;
    }
    if (usage === undefined) {
      if (options.resetAfterCompaction) this.emit({ type: "context_usage", usage: undefined });
      return;
    }
    this.emit({
      type: "context_usage",
      usage: options.resetAfterCompaction ? { ...usage, tokens: null, percent: null } : usage,
    });
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
    // A new agent cycle starts: stop absorbing aborted drains from prior abort cycles so a
    // real cancellation of the freshly-started turn still surfaces as `cancelled`.
    if (record.type === "agent_start") this.pendingAbortAcknowledgements = 0;
    if (record.type === "queue_update") {
      const rawSteering = Array.isArray(record.steering) ? (record.steering as readonly string[]) : [];
      const rawFollowUp = Array.isArray(record.followUp) ? (record.followUp as readonly string[]) : [];
      this.rememberPendingSlashExpansionsFromQueueUpdate([...rawSteering, ...rawFollowUp]);
      // Translate Pi-side queue entries back to the raw text the user typed so downstream code
      // sees the raw slash command instead of its server-side expansion. We intentionally do NOT
      // drop expansion mappings here even when Pi dequeues the entry, because the matching
      // role="custom" message_start typically arrives just after the queue_update and still
      // needs the mapping to suppress its duplicate echo. Cleanup happens on custom-echo
      // consumption, clearQueue, and an upper size cap.
      const steering = rawSteering.map((entry) => this.translateQueueEntry(entry));
      const followUp = rawFollowUp.map((entry) => this.translateQueueEntry(entry));
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
      // Let the supervisor veto a runtime-only "pending" signal so an
      // unanswered request that Pi revives during resume (before the host had
      // a chance to subscribe to extension_ui events) does not park the
      // session on a ghost waiting_for_input with no question bubble.
      hostHasPendingExtensionUiRequest: this.hostPendingExtensionUiPresent?.() ?? true,
      currentModel: currentModelId(this.runtime.session),
      currentThinkingLevel: currentThinkingLevel(this.runtime.session) ?? this.configuredThinkingLevel,
    });

    if (runtimeEvent?.type === "extension_ui" && runtimeEvent.waitsForInput) {
      const requestId = typeof runtimeEvent.request.id === "string" ? runtimeEvent.request.id : undefined;
      if (requestId) this.pendingExtensionUiRequestIds.add(requestId);
    }

    if (runtimeEvent?.type === "status") {
      // The aborted turn's natural terminal events from Pi are redundant with the synthetic
      // cancelled we already emitted from abort(); drop every aborted terminal that arrives
      // before the next agent_start so they cannot land after a follow-up/steer revived the
      // session and stamp a second "Cancelled by user" bubble. Pi can emit both turn_end and
      // agent_end for a single abort, hence the counter rather than a once-only flag.
      if (runtimeEvent.status === "cancelled" && this.pendingAbortAcknowledgements > 0 && isAbortedTerminalPiEvent(record)) {
        return undefined;
      }
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
      if (expected.suppress !== false) {
        return {
          type: "input_delivery",
          role,
          text: expected.text,
          originatedBy: expected.originatedBy,
          ...(expected.queueKind ? { queueKind: expected.queueKind } : {}),
        };
      }
      return { type: "input_message", role, text, originatedBy: expected.originatedBy };
    }

    // Pi extensions emit role="custom" messages to surface the expansion of slash commands
    // like `/skill:<name>` (the SKILL.md body) into the conversation. The user already sees
    // their raw `/skill:...` text as a user bubble via the supervisor's pendingQueueDeliveries
    // drain, so this echo is a duplicate. Suppress it when we have evidence (queue diff) that
    // this custom text is the expansion of a recently-submitted slash command.
    if (this.consumeSlashExpansion(text)) return undefined;

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

  private expectInputDelivery(
    text: string,
    originatedBy: "user" | "main_agent" | "internal" = "internal",
    suppress = true,
    queueKind?: "steering" | "followUp",
  ): ExpectedInputDelivery {
    const delivery = { id: randomUUID(), text, originatedBy, suppress, ...(queueKind ? { queueKind } : {}) };
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
    // Use the translated views so slash-command expansions resolve back to the raw text we
    // submitted; otherwise the lookup never matches and the expected delivery gets cancelled
    // prematurely, which strands the role="user" message_start without its suppression target.
    return this.getSteeringMessages().includes(text) || this.getFollowUpMessages().includes(text);
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
      return { type: "status", status: "running", summary: reason === "overflow" ? "Compacting after context overflow…" : "Compacting session…", compactionStarted: true, ...(reason ? { compactionReason: reason } : {}) };
    }
    if (event.type === "compaction_end") {
      const reason = stringValue(event.reason);
      const errorMessage = stringValue(event.errorMessage);
      if (!errorMessage && event.aborted !== true && event.result != null) {
        piTryRefreshSystemPromptFromActiveTools(this.runtime.session, this.id);
      }
      if (event.willRetry === true) {
        this.cancelDeferredTerminalError();
        return { type: "status", status: "running", summary: "Compaction completed; retrying…", compactionCompleted: true, ...(reason ? { compactionReason: reason } : {}) };
      }
      if (reason === "overflow" && errorMessage) {
        this.cancelDeferredTerminalError();
        return { type: "status", status: "failed", summary: errorMessage, compactionFailed: true, ...(reason ? { compactionReason: reason } : {}) };
      }
      if (errorMessage) {
        this.cancelDeferredTerminalError();
        return { type: "status", status: "completed", summary: errorMessage, noTurnRan: true, compactionFailed: true, ...(reason ? { compactionReason: reason } : {}) };
      }
      if (event.aborted === true) {
        return { type: "status", status: "completed", summary: "Compaction cancelled", noTurnRan: true, ...(reason ? { compactionReason: reason } : {}) };
      }
      return { type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, ...(reason ? { compactionReason: reason } : {}) };
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

  // Pi exposes session.setSessionName(), runtime.newSession(), and session.compact() as public
  // APIs but only its TUI interactive-mode wires them to /name, /new, and /compact slash commands.
  // Picky doesn't run that mode, so we intercept the built-in slash commands here before they would otherwise be
  // forwarded to the LLM as ordinary user text. The synthetic completed/noTurnRan status keeps
  // higher layers from treating the call as a real agent turn (no Pickle-completion notification,
  // no artifact materialization).
  private async handleBuiltinSlashCommand(text: string): Promise<boolean> {
    const trimmed = text.trim();
    if (trimmed === "/new") {
      try {
        const result = await this.newSession();
        if (result.cancelled) {
          this.emit({ type: "log", line: "/new cancelled by extension" });
          this.emit({ type: "status", status: "completed", summary: "/new cancelled", noTurnRan: true, preserveSessionState: true });
        }
      } catch (error) {
        const message = messageOf(error);
        logAgentd("slash /new failed", { sessionId: this.id, error: message });
        this.emit({ type: "status", status: "failed", summary: `/new failed: ${message}`, noTurnRan: true });
      }
      return true;
    }
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
      await this.compact(instructions);
      return true;
    }
    if (trimmed === "/reload") {
      if (this.runtime.session.isStreaming) {
        this.emit({ type: "log", line: "/reload rejected: wait for the current response to finish" });
        this.emit({ type: "status", status: "completed", summary: "/reload is unavailable while the agent is running", noTurnRan: true, preserveSessionState: true });
        return true;
      }
      if (piIsCompacting(this.runtime.session)) {
        this.emit({ type: "log", line: "/reload rejected: wait for compaction to finish" });
        this.emit({ type: "status", status: "completed", summary: "/reload is unavailable while the session is compacting", noTurnRan: true, preserveSessionState: true });
        return true;
      }
      this.pendingExtensionUiRequestIds.clear();
      this.emit({ type: "status", status: "running", summary: "Reloading Pi resources…" });
      try {
        const outcome = await piTryReload(this.runtime.session, this.id);
        if (!outcome.supported) {
          this.emit({ type: "status", status: "failed", summary: "/reload is not supported by this Pi runtime", noTurnRan: true });
          return true;
        }
        this.emit({ type: "log", line: "pi resources reloaded" });
        this.emit({ type: "status", status: "completed", summary: "Pi resources reloaded", noTurnRan: true });
      } catch (error) {
        const message = messageOf(error);
        logAgentd("slash /reload failed", { sessionId: this.id, error: message });
        this.emit({ type: "status", status: "failed", summary: `/reload failed: ${message}`, noTurnRan: true });
      }
      return true;
    }
    return false;
  }

  private async runCompact(instructions?: string): Promise<void> {
    // Pi TUI delegates directly to AgentSession.compact(), whose public contract aborts an active
    // agent operation before starting manual compaction. Do not pre-reject streaming sessions here.
    // Pi's own compaction_start/end events remain the single source of lifecycle status.
    try {
      const outcome = await piTryCompact(this.runtime.session, this.id, instructions);
      if (!outcome.supported) {
        this.emit({ type: "status", status: "failed", summary: "/compact is not supported by this Pi runtime", noTurnRan: true });
        return;
      }
      this.emitContextUsageSnapshot({ resetAfterCompaction: true });
      this.emit({ type: "log", line: instructions ? `compact completed with instructions: ${instructions}` : "compact completed" });
    } catch (error) {
      const message = messageOf(error);
      logAgentd("slash /compact failed", { sessionId: this.id, error: message });
      this.emit({ type: "status", status: "failed", summary: `/compact failed: ${message}`, noTurnRan: true });
    }
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

    const expected = this.expectInputDelivery(text, "internal", true, queueKindFromStreamingBehavior(options.streamingBehavior));
    const queueBeforeSlashExpansion = this.snapshotQueueForSlashExpansion(text);
    const pendingSlashSubmission = queueBeforeSlashExpansion ? { raw: text.trim(), beforeQueue: queueBeforeSlashExpansion } : undefined;
    if (pendingSlashSubmission) this.pendingSlashSubmissions.push(pendingSlashSubmission);
    const promptPromise = this.runtime.session.prompt(text, {
      ...options,
      preflightResult: (success: boolean) => {
        if (!success) {
          this.cancelExpectedInputDelivery(expected.id);
          this.removePendingSlashSubmission(pendingSlashSubmission);
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
        this.removePendingSlashSubmission(pendingSlashSubmission);
        if (accepted) {
          this.emitPromptFailureStatus(error);
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
    // Pi has accepted/queued the prompt by now. Diff Pi's queue against the pre-prompt snapshot
    // to learn whether Pi expanded our raw slash command into a different queue entry. The
    // resulting map is what lets the rest of this class translate Pi's queue snapshot back to
    // the raw text the user typed.
    this.rememberSlashExpansionFromQueue(queueBeforeSlashExpansion, text);
    this.removePendingSlashSubmission(pendingSlashSubmission);
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
  // running terminal side effects (notifying Picky, re-materializing artifacts), since
  // no real agent turn produced any new state to report.
  private maybeEmitImmediateCompletion(wasStreaming: boolean): boolean {
    if (wasStreaming) return false;
    if (this.runtime.session.isStreaming) return false;
    this.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
    return true;
  }

  private assertAutocompleteGeneration(generation: number): void {
    if (generation !== this.autocompleteGeneration) {
      throw new Error(`Stale autocomplete generation for session ${this.id}: expected ${this.autocompleteGeneration}, received ${generation}`);
    }
  }

  private createBaseAutocompleteProvider(): CombinedAutocompleteProvider {
    const commands: SlashCommand[] = [
      ...PICKY_BUILTIN_SLASH_COMMANDS,
      ...(this.getSessionFilePath() ? [{ name: "tree", description: "Rewind to an earlier message" }] : []),
      ...this.runtime.session.extensionRunner.getRegisteredCommands().map((command) => ({
        name: command.invocationName,
        description: command.description,
        getArgumentCompletions: command.getArgumentCompletions,
      })),
      ...this.runtime.session.promptTemplates.map((template) => ({
        name: template.name,
        description: template.description,
      })),
      ...this.runtime.session.resourceLoader.getSkills().skills.map((skill) => ({
        name: `skill:${skill.name}`,
        description: skill.description,
      })),
    ];
    return new CombinedAutocompleteProvider(
      commands,
      this.runtime.session.sessionManager.getCwd(),
      resolveAutocompleteFdPath(),
    );
  }

  private createBridge(): ExtensionUiBridge {
    this.autocompleteQueryController?.abort();
    this.autocompleteQueryController = undefined;
    const generation = ++this.autocompleteGeneration;
    const bridge = new ExtensionUiBridge(this.id, {
      disableBlockingDialogs: this.bridgeOptions.disableBlockingDialogs ?? false,
      autocompleteGeneration: generation,
      createBaseAutocompleteProvider: () => this.createBaseAutocompleteProvider(),
    });
    bridge.on("request", (request, waitsForInput) => {
      const waits = Boolean(waitsForInput);
      if (bridge !== this.uiBridge) {
        if (waits) bridge.answer(request.id, { cancelled: true });
        return;
      }
      if (waits) this.pendingExtensionUiRequestIds.add(request.id);
      this.emit({ type: "extension_ui", request, waitsForInput: waits });
    });
    bridge.on("cancelled", (requestId) => {
      if (bridge !== this.uiBridge) return;
      if (typeof requestId !== "string") return;
      this.pendingExtensionUiRequestIds.delete(requestId);
      this.emit({ type: "extension_ui_cancelled", requestId });
    });
    return bridge;
  }

  private emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}
