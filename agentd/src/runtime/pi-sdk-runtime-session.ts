import { AsyncCompletionDeliverySchema } from "../domain/async-task-contract.js";
import type { AsyncTaskHostBridge } from "./async-task-host-bridge.js";
import type { AsyncTaskModelFence } from "./async-task-model-fence.js";
import type { RuntimeAsyncTaskEvent } from "./async-task-types.js";
import { randomUUID } from "node:crypto";
import {
type AgentSession,
type AgentSessionRuntime
} from "@earendil-works/pi-coding-agent";
import type { AssistantMessage,UserMessage } from "@earendil-works/pi-ai";
import type { BuiltPrompt } from "../prompt-builder.js";
import { ExtensionUiBridge,type DialogMethod } from "../runtime/extension-ui-bridge.js";
import { runtimeEventFromPiEvent } from "../domain/pi-event-normalizer.js";
import { resolveTodoStateFromPiSessionEntries } from "../domain/todo-state.js";
import { subagentGroupRunUpdatesFromCustomMessage,subagentRunUpdateFromCustomMessage } from "../domain/subagent-run-state.js";
import { isTransientAgentBusyError } from "../domain/transient-runtime-error.js";
import type { AnswerExtensionUiOptions,RewindBranchMessage,RewindResult,RewindTarget,RuntimeAssistantRunMetadata,RuntimeAutocompleteApplyRequest,RuntimeAutocompleteCapabilities,RuntimeAutocompleteCompletion,RuntimeAutocompleteQuery,RuntimeAutocompleteSuggestions,RuntimeBashExecutionResult,RuntimeEvent,RuntimeExtensionCommandResult,RuntimeExtensionToolResult,RuntimeFastModeState,RuntimeResourceReloadHost,RuntimeResourceReloadOutcome,RuntimeSessionHandle,RuntimeSessionOptions,RuntimeSlashCommand,RuntimeSteerResult,ThinkingLevel } from "./types.js";
import type { ModelCycleDirection,PickyQueueMode } from "../protocol.js";
import { expectedInputDeliveryIndex,PiInputRewriteObserver } from "./pi-input-rewrite-observer.js";
import { SubagentInvocationTracker } from "./subagent-invocation-tracker.js";
import { logAgentd,logLifecycleEvent } from "../local-log.js";
import { autoRetryStatus } from "../domain/provider-error-summary.js";
import {
type ScopedModelOption,
applyScopedModelsForCycling,
automaticModelFromServices,
availableModelsFromServices,
currentAssistantRunMetadata,
currentModelId,
currentThinkingLevel,
modelFromServices,
normalizeModelPattern,
runtimeModelOptionFromModel,
runtimeModelScopesFromServices,
scopedModelsFromServices
} from "./pi-model-resolution.js";
import {
isCompacting as piIsCompacting,
readModelMetadata as piReadModelMetadata,
reloadModelRuntimeCredentials as piReloadModelRuntimeCredentials,
tryCompact as piTryCompact,
tryCycleModel as piTryCycleModel,
tryCycleThinkingLevel as piTryCycleThinkingLevel,
availableThinkingLevels as piAvailableThinkingLevels,
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
shouldEmitContextUsageSnapshotAfterPiEvent,
SkillEchoSuppressionTracker,
sliceUtf16,
stringValue,
textFromPiMessageContent,
} from "./pi-sdk-runtime-helpers.js";
import { createBaseAutocompleteProvider,listSessionSlashCommands } from "./pi-autocomplete-provider.js";
import { isRegisteredExtensionCommand,PiPromptQueue,type PiQueueSnapshot } from "./pi-prompt-queue.js";
import { movePiFollowUpToSteering,removePiQueuedMessage,replacePiQueuedFollowUpText } from "./pi-queue-mutation.js";
import { dropExpectedInputs, retargetExpectedInput, syncedQueueEdit, type ExpectedInputDelivery } from "./pi-expected-input-sync.js";
import { PiExtensionInvoker } from "./pi-extension-invocation.js";
import { WriteFileMetadataTracker } from "./write-file-path.js";
import { ReadImageTracker } from "./read-image-tracker.js";
import { ResourceReloadScheduler } from "./pi-resource-reload.js";
import { handlePiBuiltinSlashCommand } from "./pi-builtin-slash-commands.js";
import { compactionResultFromPiEvent } from "./pi-compaction-result.js";
import { PickyFastModeSwitch } from "./picky-fast-mode-extension.js";

// Soft cap for the per-session `slashExpansions` map. A long-lived Pi session can submit many
// slash commands; in pathological cases Pi may never emit the matching role="custom" echo (e.g.
// extension changes mid-session), which would leak the mapping. The cap is generous enough to
// cover realistic concurrent in-flight slash commands while keeping memory bounded.
const SLASH_EXPANSION_MAP_CAP = 64;
const AUTOCOMPLETE_MAX_ITEMS = 20;
const AUTOCOMPLETE_QUERY_TIMEOUT_MS = 2_000;

export class PiSdkRuntimeSession implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  private unsubscribe?: () => void;
  private uiBridge: ExtensionUiBridge;
  /** Nonzero while Picky runs a background plugin reload; see `reloadPiResourcesQuietly`. */
  private quietReloadDepth = 0;
  private readonly transcriptRepairLogLine?: string;
  private queuedSteeringCount = 0;
  private queuedFollowUpCount = 0;
  private readonly promptQueue: PiPromptQueue;
  private pendingExtensionUiRequestIds = new Set<string>();
  private hostPendingExtensionUiPresent?: () => boolean;
  private pendingTerminalError?: Extract<RuntimeEvent, { type: "status" }>;
  private pendingTerminalErrorTimer?: ReturnType<typeof setTimeout>;
  private initialPromptTimer?: ReturnType<typeof setTimeout>;
  private expectedInputDeliveries: ExpectedInputDelivery[] = [];
  private pendingPromptPreflightDeliveryIds = new Set<string>();
  private readonly skillEchoSuppressions = new SkillEchoSuppressionTracker(SLASH_EXPANSION_MAP_CAP);
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
  // Counts Pi agent_start events so prompt paths can tell whether an awaited `session.prompt()`
  // actually ran a turn before it resolved. The initial prompt resolves only after the whole run
  // settles, when `isStreaming` is already false again.
  private agentStartCount = 0;
  private autocompleteGeneration = 0;
  private autocompleteQueryController: AbortController | undefined;
  private readonly extensionInvoker = new PiExtensionInvoker(() => this.runtime.session, () => this.uiBridge);
  private readonly subagentInvocationTracker = new SubagentInvocationTracker();
  private readonly writeFileMetadata = new WriteFileMetadataTracker();
  private readonly readImages = new ReadImageTracker();
  private asyncSettled = true;
  private disposed = false;
  private disposePromise?: Promise<void>;
  private readonly resourceReload: ResourceReloadScheduler;

  constructor(
    readonly id: string,
    private readonly runtime: AgentSessionRuntime,
    private configuredThinkingLevel?: ThinkingLevel,
    private readonly bridgeOptions: { disableBlockingDialogs?: boolean; allowedBlockingDialogMethods?: readonly DialogMethod[] } = {},
    private readonly inputRewriteObserver: PiInputRewriteObserver = new PiInputRewriteObserver(() => {}),
    private readonly setExternalDeliveryPausedState: (paused: boolean) => void = () => {},
    readonly asyncTasks?: AsyncTaskHostBridge,
    private readonly asyncFence?: AsyncTaskModelFence,
    private readonly fastMode: PickyFastModeSwitch = new PickyFastModeSwitch(),
  ) {
    this.promptQueue = new PiPromptQueue(id, SLASH_EXPANSION_MAP_CAP);
    this.resourceReload = this.createResourceReloadScheduler();
    this.uiBridge = this.createBridge();
    this.transcriptRepairLogLine = repairDanglingToolCalls(runtime.session);
    this.runtime.setRebindSession(async () => this.bindCurrentSession());
    if (asyncTasks) {
      const retry = asyncTasks.retryPersistence;
      asyncTasks.retryPersistence = async () => {
        await retry();
        // A failed settled-hook save leaves the idle latch closed. Recovery must
        // refresh it without waiting for another model turn to emit agent_settled.
        if (!this.disposed) { this.asyncSettled = this.runtime.session.isIdle; this.emit({ type: "async_task_idle" }); this.resourceReload.schedule(); }
      };
    }
  }

  /**
   * Persists the host-chosen title as Pi's session name before the first prompt. Without it the
   * session stays unnamed whenever the first auto-name attempt fails, and every later idle prompt
   * re-runs name generation and overwrites the Pickle title.
   */
  setInitialSessionName(name: string): void {
    try {
      this.runtime.session.setSessionName(name);
    } catch (error) {
      logAgentd("initial session name failed", { sessionId: this.id, error: messageOf(error) });
    }
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
    this.assertNotDisposed();
    logAgentd("pi prompt", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    if (await this.handleBuiltinSlashCommand(prompt.text)) return;
    if (await this.holdWhileReloading(prompt)) return;
    const wasStreaming = this.runtime.session.isStreaming;
    const agentStartsBefore = this.agentStartCount;
    const expected = this.expectInputDelivery(prompt.text);
    const skillEchoSuppression = this.skillEchoSuppressions.register(prompt.text);
    try {
      const images = await imageOptions(prompt.imagePaths);
      await this.inputRewriteObserver.runWithDelivery(expected.id, () => this.runAuthorizedPrompt(() => this.runtime.session.prompt(
        prompt.text,
        { images, source: "rpc" },
      )));
    } catch (error) {
      this.cancelExpectedInputDelivery(expected.id);
      this.skillEchoSuppressions.remove(skillEchoSuppression);
      this.emitPromptFailureStatus(error);
      return;
    }
    if (this.maybeEmitImmediateCompletion(wasStreaming, agentStartsBefore)) this.cancelExpectedInputDelivery(expected.id);
  }

  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.assertNotDisposed();
    logAgentd("pi follow-up", { sessionId: this.id, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    try {
      await this.promptWithOptions(prompt, "followUp");
    } catch (error) {
      this.emitPromptFailureStatus(error);
      throw error;
    }
  }

  async interrupt(prompt: BuiltPrompt): Promise<void> {
    this.assertNotDisposed();
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
    this.assertNotDisposed();
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
    this.assertNotDisposed();
    logAgentd("pi compact", {
      sessionId: this.id,
      wasStreaming: this.runtime.session.isStreaming,
      instructionChars: customInstructions?.length ?? 0,
    });
    await this.runCompact(customInstructions);
  }

  async abort(): Promise<void> {
    if (this.disposed) return;
    const hadActiveTurn = this.runtime.session.isStreaming || piIsCompacting(this.runtime.session) || this.initialPromptTimer !== undefined;
    logAgentd("pi abort", { sessionId: this.id });
    if (this.initialPromptTimer) {
      clearTimeout(this.initialPromptTimer);
      this.initialPromptTimer = undefined;
    }
    if (hadActiveTurn) this.pendingAbortAcknowledgements += 1;
    // A full abort also cancels input held for a plugin reload or compaction (main agent PTT abort).
    if (this.promptQueue.discardCompactionPrompts()) this.emitCombinedQueueUpdate();
    this.uiBridge.cancelAll();
    this.runtime.session.abortCompaction();
    await this.runtime.session.abort();
    if (hadActiveTurn) this.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
  }

  async dispose(): Promise<void> {
    if (!this.disposePromise) {
      this.disposed = true;
      this.disposePromise = this.disposeRuntime();
    }
    await this.disposePromise;
  }

  private async disposeRuntime(): Promise<void> {
    logAgentd("pi runtime dispose", { sessionId: this.id });
    if (this.initialPromptTimer) clearTimeout(this.initialPromptTimer);
    this.initialPromptTimer = undefined;
    this.resourceReload.dispose();
    this.autocompleteQueryController?.abort();
    this.autocompleteQueryController = undefined;
    this.cancelDeferredTerminalError();
    this.pendingExtensionUiRequestIds.clear();
    this.expectedInputDeliveries = [];
    this.pendingPromptPreflightDeliveryIds.clear();
    this.skillEchoSuppressions.clear();
    this.uiBridge.cancelAll();

    try {
      // Match Pi's documented replacement lifecycle: settle an in-flight turn
      // before emitting session_shutdown and invalidating extension state.
      await this.runtime.session.abort();
      await this.runtime.session.waitForIdle();
    } catch (error) {
      logAgentd("pi runtime dispose abort failed", { sessionId: this.id, error: messageOf(error) });
    } finally {
      this.unsubscribe?.();
      this.unsubscribe = undefined;
      this.listeners.clear();
      try { await this.runtime.dispose(); }
      finally {
        try { await this.asyncFence?.drain(); }
        finally { await this.asyncTasks?.dispose(); }
      }
    }
  }

  async reloadAuthentication(): Promise<void> {
    this.assertNotDisposed();
    logAgentd("pi authentication reload", { sessionId: this.id });
    await piReloadModelRuntimeCredentials(this.runtime.session.modelRuntime, this.id);
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
      const resultPreview = bashResultPreview(result);
      this.emit({
        type: "tool",
        toolCallId,
        name: "bash",
        status: result.exitCode && result.exitCode !== 0 ? "failed" : "succeeded",
        preview: trimmedCommand,
        resultPreview: resultPreview.text,
        ...(resultPreview.jsonText ? { resultJSONPreview: resultPreview.jsonText } : {}),
        ...(resultPreview.truncated ? { resultPreviewTruncated: true } : {}),
        ...(resultPreview.repaired ? { resultPreviewRepaired: true } : {}),
      });
      return result;
    } catch (error) {
      const message = messageOf(error);
      this.emit({ type: "tool", toolCallId, name: "bash", status: "failed", preview: trimmedCommand, resultPreview: message });
      throw error;
    }
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    if (this.asyncTasks && (this.isStreaming || this.isCompacting)) throw new Error("Cannot replace a busy async runtime");
    await this.asyncTasks?.prepareReplacement();
    logAgentd("pi new session", { sessionId: this.id, cwd: this.runtime.cwd });
    const result = await this.runtime.newSession();
    if (result.cancelled) return result;
    this.subagentInvocationTracker.reset();
    await this.bindCurrentSession();
    // session_start enqueues provider discovery and snapshots. Finish that durable
    // handshake before callers can reconcile admission for the first new input.
    await this.asyncTasks?.drain();
    this.emit({ type: "session_replaced", reason: "new", cwd: this.runtime.cwd, sessionFilePath: this.getSessionFilePath() });
    this.reportDiagnostics();
    this.emit({ type: "status", status: "completed", summary: "New session started", noTurnRan: true, preserveSessionState: true });
    await this.asyncTasks?.owner.beforeModelRequest?.();
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

  setExternalDeliveryPaused(paused: boolean): void {
    if (this.disposed) return;
    this.setExternalDeliveryPausedState(paused);
  }

  getAssistantRunMetadata(): RuntimeAssistantRunMetadata | undefined {
    return this.currentAssistantRunMetadata();
  }

  setFastMode(enabled: boolean): void {
    this.fastMode.setEnabled(enabled, this.id);
  }

  getFastModeState(): RuntimeFastModeState {
    return this.fastMode.state(piReadModelMetadata(this.runtime.session));
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

  async listRuntimeOptions(): Promise<RuntimeSessionOptions> {
    const services = this.runtime.services;
    // Test and compatibility runtimes may predate the services bridge. Preserve
    // their scoped-model picker behavior while production Pi sessions always
    // take the authoritative settings-manager path below.
    if (!services?.modelRuntime) {
      const scopedModels = (this.runtime.session as unknown as { scopedModels?: ScopedModelOption[] }).scopedModels ?? [];
      const current = piReadModelMetadata(this.runtime.session);
      return {
        models: scopedModels.map((entry) => runtimeModelOptionFromModel(entry.model)),
        thinkingLevels: piAvailableThinkingLevels(this.runtime.session, this.id),
        ...(current?.provider && current.modelId ? { currentModel: { provider: current.provider, modelId: current.modelId } } : {}),
      };
    }
    const scopes = await runtimeModelScopesFromServices(services, this.runtime.session);
    const current = piReadModelMetadata(this.runtime.session);
    return {
      ...scopes,
      thinkingLevels: piAvailableThinkingLevels(this.runtime.session, this.id),
      ...(current?.provider && current.modelId ? { currentModel: { provider: current.provider, modelId: current.modelId } } : {}),
    };
  }

  async setExactModel(provider: string, modelId: string): Promise<RuntimeAssistantRunMetadata | undefined> {
    // A direct selection must not rewrite the current cycle scope. The picker
    // refresh has already synchronized it before the user can select a row.
    const scopedModels = (this.runtime.session as unknown as { scopedModels?: ScopedModelOption[] }).scopedModels ?? [];
    const available = await availableModelsFromServices(this.runtime.services);
    const candidates = scopedModels.length > 0 ? scopedModels.map((entry) => entry.model) : available;
    const selected = candidates.find((model) => model.provider === provider && model.id === modelId);
    if (!selected) throw new Error(`Model is not available in this session: ${provider}/${modelId}`);
    const model = available.find((candidate) => candidate.provider === provider && candidate.id === modelId);
    if (!model) throw new Error(`Model is no longer available: ${provider}/${modelId}`);
    await this.runtime.session.setModel(model);
    const metadata = this.currentAssistantRunMetadata();
    logAgentd("pi model directly selected", { sessionId: this.id, provider, modelId, model: metadata?.model, thinkingLevel: metadata?.thinkingLevel });
    return metadata;
  }

  async cycleModel(direction: ModelCycleDirection): Promise<RuntimeAssistantRunMetadata | undefined> {
    const options = await this.listRuntimeOptions();
    const current = options.currentModel;
    const currentIsInScope = current && options.models.some((model) => model.provider === current.provider && model.modelId === current.modelId);
    if (options.effectiveScope?.mode === "exact" && !currentIsInScope && options.models.length > 0) {
      const target = direction === "backward" ? options.models[options.models.length - 1]! : options.models[0]!;
      return await this.setExactModel(target.provider, target.modelId);
    }
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
    return currentAssistantRunMetadata(this.runtime.session, this.configuredThinkingLevel);
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

  async listSlashCommands(): Promise<RuntimeSlashCommand[]> { return listSessionSlashCommands(this.runtime.session); }

  clearQueue(): { steering: string[]; followUp: string[] } {
    const cleared = this.runtime.session.clearQueue();
    for (const entry of [...cleared.steering, ...cleared.followUp]) this.skillEchoSuppressions.consume(entry);
    dropExpectedInputs(this.expectedInputDeliveries, cleared.steering, "steering");
    dropExpectedInputs(this.expectedInputDeliveries, cleared.followUp, "followUp");
    const result = this.promptQueue.clear(cleared);
    this.emitCombinedQueueUpdate();
    return result;
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
    await this.asyncTasks?.prepareReplacement();
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

  getSteeringMessages(): readonly string[] { return this.combinedQueueSnapshot().steering; }
  getFollowUpMessages(): readonly string[] { return this.combinedQueueSnapshot().followUp; }

  getPiSessionId(): string | undefined { return this.extensionInvoker.sessionId(); }
  hasExtensionCommand(name: string): boolean { return this.extensionInvoker.hasCommand(name); }
  hasExtensionTool(name: string): boolean { return this.extensionInvoker.hasTool(name); }
  runExtensionCommandSilently(name: string, args: string): Promise<RuntimeExtensionCommandResult> { return this.extensionInvoker.runCommand(name, args); }
  runExtensionToolSilently(name: string, params: Record<string, unknown>): Promise<RuntimeExtensionToolResult> { return this.extensionInvoker.runTool(name, params); }

  // Per-item edits address Pi's own queue positions, so an entry Picky is still holding for a
  // compaction flush is out of range and reports as "already gone" rather than editing a neighbour.
  private readonly onQueueMutated = (): void => this.emitCombinedQueueUpdate();
  removeQueuedMessage(kind: "steering" | "followUp", index: number): boolean { return syncedQueueEdit(this.expectedInputDeliveries, this.piQueueSnapshot()[kind][index], () => removePiQueuedMessage(this.runtime.session, kind, index, this.onQueueMutated), (list, text) => dropExpectedInputs(list, [text], kind)); }
  replaceQueuedFollowUpText(index: number, text: string): boolean { return syncedQueueEdit(this.expectedInputDeliveries, this.piQueueSnapshot().followUp[index], () => replacePiQueuedFollowUpText(this.runtime.session, index, text, this.onQueueMutated), (list, previous) => retargetExpectedInput(list, previous, "followUp", { text })); }
  moveFollowUpToSteering(index: number): boolean { return syncedQueueEdit(this.expectedInputDeliveries, this.piQueueSnapshot().followUp[index], () => movePiFollowUpToSteering(this.runtime.session, index, this.onQueueMutated), (list, moved) => retargetExpectedInput(list, moved, "followUp", { queueKind: "steering" })); }

  private piQueueSnapshot(): PiQueueSnapshot {
    return {
      steering: this.runtime.session.getSteeringMessages(),
      followUp: this.runtime.session.getFollowUpMessages(),
    };
  }

  private combinedQueueSnapshot(): { steering: string[]; followUp: string[] } {
    return this.promptQueue.combinedSnapshot(this.piQueueSnapshot());
  }

  private emitCombinedQueueUpdate(): void {
    const { steering, followUp } = this.combinedQueueSnapshot();
    this.queuedSteeringCount = steering.length;
    this.queuedFollowUpCount = followUp.length;
    this.emit({ type: "queue_update", steering, followUp });
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

  get hasPendingAsyncWork(): boolean {
    return this.asyncFence !== undefined && (this.initialPromptTimer !== undefined || !this.asyncSettled || !this.runtime.session.isIdle || this.pendingPromptPreflightDeliveryIds.size > 0);
  }

  get isCompacting(): boolean {
    return piIsCompacting(this.runtime.session);
  }

  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    const existing = this.runtime.session.messages ?? this.runtime.session.state.messages;
    if (existing.length > 0) {
      logAgentd("pi inject bootstrap skipped", { sessionId: this.id, reason: "non-empty session", existingCount: existing.length });
      return;
    }
    await this.appendSyntheticMessages(messages, existing);
  }

  private async appendSyntheticMessages(messages: { user: string; assistant: string }, existing: AgentSession["messages"]): Promise<void> {
    const session = this.runtime.session;
    const modelMetadata = piReadModelMetadata(session);
    if (!modelMetadata?.api || !modelMetadata.provider || !modelMetadata.modelId) {
      logAgentd("pi inject bootstrap skipped", { sessionId: this.id, reason: "model metadata missing" });
      return;
    }
    const { api, provider, modelId } = modelMetadata;

    const now = Date.now();
    const userMessage: UserMessage = {
      role: "user",
      content: messages.user,
      timestamp: now,
    };
    const assistantMessage: AssistantMessage = {
      role: "assistant",
      content: [{ type: "text", text: messages.assistant }],
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
      stopReason: "stop",
      timestamp: now,
    };

    try {
      session.sessionManager.appendMessage(userMessage);
      session.sessionManager.appendMessage(assistantMessage);
      // Pi 0.87+ treats SessionManager as the canonical source for provider context; the
      // appendMessage calls above record raw history and refreshContext() rebuilds agent.state
      // from the session projection. Manually assigning session.state.messages would be ignored
      // for future provider requests on this version.
      session.refreshContext();
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
    // A Pi rebind replaces the active session just as the TUI's renderCurrentSessionState()
    // boundary does. Adapter-owned compaction input belongs to the prior session and must not
    // survive into the replacement session or be replayed by a later compaction_end event.
    if (this.promptQueue.discardCompactionPrompts()) this.emitCombinedQueueUpdate();
    this.skillEchoSuppressions.clear();
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
    await this.bindAsyncTasks(session);
    await session.bindExtensions({ uiContext: this.uiBridge.createContext(), onError: (error) => this.emit({ type: "log", line: `extension error: ${messageOf(error)}` }) });
    if (this.unsubscribe) {
      // Another `bindCurrentSession()` won the race during the `await`. Yield ownership to it
      // instead of stacking a second subscriber on the same Pi session — a second subscriber
      // would be unreachable to the next unsubscribe (we only keep one cleanup handle).
      logAgentd("pi bind session reentry detected; abandoning late path", { sessionId: this.id });
      return;
    }
    this.unsubscribe = session.subscribe((event: unknown) => {
      const record = asRecord(event);
      if (record.type === "agent_start" || record.type === "compaction_start") this.asyncSettled = false;
      const cycleId = this.asyncFence?.currentCycleId;
      this.asyncFence?.onEvent({ type: String(record.type), ...(record.message ? { message: record.message } : {}), ...(Array.isArray(record.messages) ? { messages: record.messages } : {}), ...(record.willRetry === true ? { willRetry: true } : {}) });
      const runtimeEvent = this.runtimeEventFromPiEvent(event);
      if (runtimeEvent) this.emit(runtimeEvent.type === "status" && cycleId ? { ...runtimeEvent, cycleId } : runtimeEvent);
      if ((record.type === "agent_settled" || record.type === "compaction_end") && this.asyncFence) {
        // Settled hooks have returned, but deferred actions may still be in preflight.
        // Their tickets and the SDK/host queues remain completion obligations.
        void this.asyncFence.drain().then(() => {
          if (!this.disposed && this.runtime.session === session) { this.asyncSettled = session.isIdle; this.emit({ type: "async_task_idle" }); this.resourceReload.schedule(); }
        }).catch((error) => this.emit({ type: "log", line: `Async task idle persistence blocked: ${messageOf(error)}` }));
      }
      if (record.type === "agent_settled" || record.type === "compaction_end") this.resourceReload.schedule();
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

  private async bindAsyncTasks(session: AgentSession): Promise<void> {
    if (this.asyncTasks) {
      await this.asyncTasks.bind(session.sessionManager.getSessionId(), [...session.getAllTools().map((tool) => tool.name), ...session.extensionRunner.getRegisteredCommands().map((command) => command.invocationName)], session.resourceLoader.getExtensions());
      this.asyncFence?.bind(session);
      this.asyncTasks.onState = (state) => {
        for (const invocation of this.subagentInvocationTracker.applyTrackedTasks(state.tasks)) this.emit({ type: "subagent_invocation", invocation });
      };
    }
  }

  private runAuthorizedPrompt<T>(work: () => T): T { return this.asyncFence ? this.asyncFence.runAuthorized(work) : work(); }

  emitAsyncTaskEvent(event: RuntimeAsyncTaskEvent | { type: "log"; line: string }): void { this.emit(event); }

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
    if (this.disposed) return () => {};
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private assertNotDisposed(): void {
    if (this.disposed) throw new Error(`Pi runtime session ${this.id} has been disposed`);
  }

  private lifecycleFields(): Record<string, boolean | number> {
    return {
      isStreaming: this.runtime.session.isStreaming,
      isCompacting: piIsCompacting(this.runtime.session),
      queuedSteeringCount: this.queuedSteeringCount,
      queuedFollowUpCount: this.queuedFollowUpCount,
      expectedInputDeliveryCount: this.expectedInputDeliveries.length,
      pendingPromptPreflightCount: this.pendingPromptPreflightDeliveryIds.size,
    };
  }

  // eslint-disable-next-line complexity -- Queue translation, recovery interception, and terminal de-duplication must run in one ordered adapter pipeline.
  private runtimeEventFromPiEvent(event: unknown): RuntimeEvent | undefined {
    const record = asRecord(event);
    const eventType = stringValue(record.type);
    if (eventType && ["agent_start", "agent_end", "agent_settled", "compaction_start", "compaction_end"].includes(eventType)) {
      logLifecycleEvent("piRuntimeEvent", { sessionId: this.id, piEvent: eventType, ...this.lifecycleFields() });
    }
    // A new agent cycle starts: stop absorbing aborted drains from prior abort cycles so a
    // real cancellation of the freshly-started turn still surfaces as `cancelled`.
    if (record.type === "agent_start") {
      this.agentStartCount += 1;
      this.pendingAbortAcknowledgements = 0;
    }
    // `abort()` emits a synthetic cancellation immediately. Pi may still flush arbitrary
    // old-turn events while it settles, and none may be attributed to the next prompt. Do
    // not leak those deltas, tool updates, or terminals into a handle Picky is about to reuse.
    // The next documented agent_start reopens the event stream for the replacement input.
    if (this.pendingAbortAcknowledgements > 0) return undefined;
    if (record.type === "queue_update") {
      const rawSteering = Array.isArray(record.steering) ? (record.steering as readonly string[]) : [];
      const rawFollowUp = Array.isArray(record.followUp) ? (record.followUp as readonly string[]) : [];
      this.promptQueue.rememberQueueUpdate([...rawSteering, ...rawFollowUp]);
      // Translate Pi-side queue entries back to the raw text the user typed so downstream code
      // sees the raw slash command instead of its server-side expansion. We intentionally do NOT
      // drop expansion mappings here even when Pi dequeues the entry, because the matching
      // role="custom" message_start typically arrives just after the queue_update and still
      // needs the mapping to suppress its duplicate echo. Cleanup happens on custom-echo
      // consumption, clearQueue, and an upper size cap.
      const { steering, followUp } = this.promptQueue.combinedSnapshot({ steering: rawSteering, followUp: rawFollowUp });
      this.queuedSteeringCount = steering.length;
      this.queuedFollowUpCount = followUp.length;
      logLifecycleEvent("piRuntimeEvent", { sessionId: this.id, piEvent: "queue_update", ...this.lifecycleFields() });
      return { type: "queue_update", steering, followUp };
    }

    const startedInvocation = this.subagentInvocationTracker.captureLaunchIntent(record);
    if (startedInvocation) this.emit({ type: "subagent_invocation", invocation: startedInvocation });
    const completedInvocation = this.subagentInvocationTracker.closeInvocationIfSettled(record);
    if (completedInvocation) this.emit({ type: "subagent_invocation", invocation: completedInvocation });
    for (const update of this.subagentInvocationTracker.toolResultRunUpdates(record)) {
      this.emit({ type: "subagent_run_update", update });
    }
    const diagnosticRunUpdate = this.subagentInvocationTracker.diagnosticRunUpdateFromPiEvent(record);
    if (diagnosticRunUpdate) this.emit({ type: "subagent_run_update", update: diagnosticRunUpdate });

    const inputMessageEvent = this.runtimeEventFromInputMessagePiEvent(record);
    if (inputMessageEvent) {
      const message = asRecord(record.message);
      const update = subagentRunUpdateFromCustomMessage(message.customType, message.details, message.content);
      if (update) {
        if (!this.subagentInvocationTracker.isTrackedRun(update.runId)) this.emit({ type: "subagent_run_update", update: this.subagentInvocationTracker.attachRunUpdate(update) });
      } else {
        for (const groupUpdate of subagentGroupRunUpdatesFromCustomMessage(
          message.customType,
          message.details,
          message.content,
          this.subagentInvocationTracker.knownTasksByRunId(),
        )) {
          if (this.subagentInvocationTracker.isTrackedRun(groupUpdate.runId)) continue;
          const run = this.subagentInvocationTracker.attachGroupRunUpdate(groupUpdate);
          if (run) this.emit({ type: "subagent_run_update", update: run });
        }
      }
      return inputMessageEvent;
    }

    // Async tool results can continue a completed response without another user/custom
    // input or agent_start. A streaming assistant message is authoritative new work;
    // the supervisor still protects cancelled/failed sessions from late events.
    if (record.type === "message_start" && asRecord(record.message).role === "assistant" && this.runtime.session.isStreaming) {
      return { type: "assistant_turn_start" };
    }

    const recoveryEvent = this.runtimeEventFromRecoveryPiEvent(record);
    if (recoveryEvent) return recoveryEvent;

    let runtimeEvent = runtimeEventFromPiEvent(event, {
      hasQueuedSteering: this.queuedSteeringCount > 0,
      // Extension follow-ups sent mid-run (bash_async at turn_end) skip queue_update; ask the agent.
      hasQueuedFollowUp: this.queuedFollowUpCount > 0 || (this.runtime.session as { agent?: { hasQueuedMessages?: () => boolean } }).agent?.hasQueuedMessages?.() === true,
      hasPendingExtensionUiRequest: this.pendingExtensionUiRequestIds.size > 0,
      // Let the supervisor veto a runtime-only "pending" signal so an
      // unanswered request that Pi revives during resume (before the host had
      // a chance to subscribe to extension_ui events) does not park the
      // session on a ghost waiting_for_input with no question bubble.
      hostHasPendingExtensionUiRequest: this.hostPendingExtensionUiPresent?.() ?? true,
      currentModel: currentModelId(this.runtime.session),
      currentThinkingLevel: currentThinkingLevel(this.runtime.session) ?? this.configuredThinkingLevel,
    });

    if (runtimeEvent?.type === "tool") {
      const writeFileMetadata = this.writeFileMetadata.forToolEvent(record, runtimeEvent, this.runtime.cwd);
      if (writeFileMetadata) runtimeEvent = { ...runtimeEvent, ...writeFileMetadata };
      const readImage = this.readImages.forToolEvent(record, runtimeEvent, this.runtime.cwd);
      if (readImage) runtimeEvent = { ...runtimeEvent, ...readImage };
    }

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
        this.deferTerminalError({ ...runtimeEvent, ...(this.asyncFence?.currentCycleId ? { cycleId: this.asyncFence.currentCycleId } : {}) });
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
        // This delivery already accounts for the /skill: expansion echo (matched via the
        // observed RPC rewrite alias), so retire any structurally matching pending
        // suppression — otherwise it would swallow a later identical, genuinely
        // external skill message from the Pi terminal.
        this.skillEchoSuppressions.consume(text);
        return {
          type: "input_delivery",
          role,
          text: expected.text,
          originatedBy: expected.originatedBy,
          ...(expected.queueKind ? { queueKind: expected.queueKind } : {}),
        };
      }
      // Pi can persist a /skill: expansion as a role="user" message instead of a
      // role="custom" extension message. This is still the same server-side echo of
      // Picky's raw slash command, so when it matches no expected delivery, consume a
      // structurally matching pending invocation instead of surfacing a duplicate
      // pi_extension bubble. Checked only after the expected-delivery path so a normal
      // queued delivery still consumes its expectation and emits input_delivery.
      if (this.skillEchoSuppressions.consume(text)) return undefined;
      return { type: "input_message", role, text, originatedBy: expected.originatedBy };
    }

    // Pi extensions emit role="custom" messages to surface the expansion of slash commands
    // like `/skill:<name>` (the SKILL.md body) into the conversation. The user already sees
    // their raw `/skill:...` text as a user bubble, so this echo is a duplicate. Suppress it
    // when we have evidence that this custom text is the expansion of a recently-submitted
    // slash command: either via the queue diff (streaming submits) or via structural matching
    // against remembered /skill: invocations (idle submits, which never touch Pi's queue).
    // Consume both trackers so neither leaks when the other matches first.
    const suppressedAsQueuedExpansion = this.promptQueue.consumeExpansion(text);
    const suppressedAsSkillEcho = this.skillEchoSuppressions.consume(text);
    if (suppressedAsQueuedExpansion || suppressedAsSkillEcho) return undefined;

    const asyncDelivery = AsyncCompletionDeliverySchema.safeParse(asRecord(message.details).asyncTasks);
    const display = message.display;
    return {
      type: "input_message",
      role,
      text,
      originatedBy: "pi_extension",
      ...(typeof display === "boolean" ? { display } : {}),
      ...(typeof message.customType === "string" ? { customType: message.customType } : {}),
      // Pi emits custom messages for both passive extension output and messages delivered
      // during a running turn. Preserve the authoritative session activity snapshot so the
      // supervisor never mistakes an idle status update for a new user turn.
      turnActive: this.runtime.session.isStreaming,
      ...(asyncDelivery.success ? { asyncTasks: asyncDelivery.data } : {}),
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
    const matchedIndex = expectedInputDeliveryIndex(
      this.expectedInputDeliveries,
      text,
      (candidate) => this.promptQueue.translate(candidate),
    );
    if (matchedIndex >= 0) return this.expectedInputDeliveries.splice(matchedIndex, 1)[0]!;

    // Never consume an unmatched delivery by FIFO order. A genuine extension
    // role=user event can interleave before Pi echoes Picky's transformed RPC
    // prompt; treating that event as the echo would hide user-visible input and
    // poison terminal reverse-expansion mapping.
    return { id: "pi-extension", text, originatedBy: "pi_extension", suppress: false };
  }

  recordExpectedInputAlias(deliveryID: string, finalText: string): void {
    const delivery = this.expectedInputDeliveries.find((candidate) => candidate.id === deliveryID);
    if (!delivery) return;
    const alias = finalText.trim();
    const raw = delivery.text.trim();
    if (!alias || alias === raw) return;
    delivery.aliases ??= new Set<string>();
    delivery.aliases.add(alias);
    this.promptQueue.registerAlias(alias, raw);
  }

  // Public view of the runtime's learned expansion mappings so the terminal-sync dedup can
  // reverse Pi's server-side rewrite on an imported JSONL line back to the raw text Picky
  // already recorded. Identity when nothing was learned.
  reverseInputExpansion(text: string): string {
    return this.promptQueue.translate(text);
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

  // eslint-disable-next-line complexity -- Recovery events form one ordered state machine whose cancellation and compaction side effects must stay atomic.
  private runtimeEventFromRecoveryPiEvent(event: Record<string, unknown>): RuntimeEvent | undefined {
    if (event.type === "auto_retry_start") {
      this.cancelDeferredTerminalError();
      const attempt = numberValue(event.attempt);
      const maxAttempts = numberValue(event.maxAttempts);
      const summary = attempt && maxAttempts ? `Retrying after transient Pi error (${attempt}/${maxAttempts})…` : "Retrying after transient Pi error…";
      const autoRetry = autoRetryStatus(attempt, maxAttempts, stringValue(event.errorMessage));
      return { type: "status", status: "running", summary, ...(autoRetry ? { autoRetry } : {}) };
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
      const compaction = compactionResultFromPiEvent(event.result);
      const errorMessage = stringValue(event.errorMessage);
      const hasQueuedCompactionPrompts = this.promptQueue.hasCompactionPrompts;
      if (!errorMessage && event.aborted !== true && event.result != null) {
        piTryRefreshSystemPromptFromActiveTools(this.runtime.session, this.id);
      }
      if (hasQueuedCompactionPrompts) {
        // Pi's TUI flushes its compaction queue for every compaction_end outcome. Schedule after
        // forwarding this event so the supervisor keeps pending bubbles active as they transition
        // into Pi's normal queue, including after a failed or cancelled compaction.
        queueMicrotask(() => void this.flushCompactionQueue(event.willRetry === true));
        if (errorMessage) {
          this.cancelDeferredTerminalError();
          return { type: "status", status: "running", summary: errorMessage, compactionFailed: true, ...(reason ? { compactionReason: reason } : {}) };
        }
        if (event.aborted === true) {
          return { type: "status", status: "running", summary: "Compaction cancelled; continuing queued messages…", ...(reason ? { compactionReason: reason } : {}) };
        }
      }
      if (event.willRetry === true) {
        this.cancelDeferredTerminalError();
        return { type: "status", status: "running", summary: "Compaction completed; retrying…", compactionCompleted: true, ...(compaction ? { compaction } : {}), ...(reason ? { compactionReason: reason } : {}) };
      }
      // Pi can compact before accepting a newly submitted prompt or midway through an active
      // ReAct turn after a tool result. The latter continues emitting assistant deltas without a
      // second agent_start, so a terminal noTurnRan marker here would make the supervisor drop the
      // final answer. Expected input deliveries can outlive their turn when Pi omits the matching
      // role=user echo, so use the prompt-specific preflight ledger rather than that stale queue.
      const activeTurnContinues = this.runtime.session.isStreaming
        || this.pendingPromptPreflightDeliveryIds.size > 0
        || hasQueuedCompactionPrompts;
      if (!errorMessage && event.aborted !== true && activeTurnContinues) {
        return { type: "status", status: "running", summary: "Session compacted; continuing…", compactionCompleted: true, ...(compaction ? { compaction } : {}), ...(reason ? { compactionReason: reason } : {}) };
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
      return { type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, ...(compaction ? { compaction } : {}), ...(reason ? { compactionReason: reason } : {}) };
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

  private async promptWithOptions(prompt: BuiltPrompt, streamingBehavior?: "steer" | "followUp", options: { fromHeldQueue?: boolean } = {}): Promise<boolean> {
    if (await this.handleBuiltinSlashCommand(prompt.text)) return true;
    if (!options.fromHeldQueue && await this.holdWhileReloading(prompt)) return false;
    const extensionCommands = this.runtime.session.extensionRunner.getRegisteredCommands();
    if (streamingBehavior && piIsCompacting(this.runtime.session) && !isRegisteredExtensionCommand(prompt.text, extensionCommands)) {
      this.promptQueue.enqueueDuringCompaction(prompt, streamingBehavior);
      this.emitCombinedQueueUpdate();
      return false;
    }
    if (!options.fromHeldQueue && this.shouldHoldForResourceReload(prompt, streamingBehavior, extensionCommands)) {
      return !this.holdForReload(prompt, "before"); // Pi expands /skill: at enqueue and drains its queue in-turn.
    }
    return this.promptUntilAccepted(prompt.text, {
      images: await imageOptions(prompt.imagePaths),
      source: "rpc",
      streamingBehavior,
    });
  }

  private async queuePromptForActiveTurn(prompt: BuiltPrompt, streamingBehavior: "steer" | "followUp"): Promise<void> {
    const expected = this.expectInputDelivery(prompt.text, "internal", true, queueKindFromStreamingBehavior(streamingBehavior));
    const pendingSlashSubmission = this.promptQueue.beginSlashSubmission(prompt.text, this.piQueueSnapshot());
    const skillEchoSuppression = this.skillEchoSuppressions.register(prompt.text);
    try {
      const images = await imageOptions(prompt.imagePaths);
      await this.inputRewriteObserver.runWithDelivery(expected.id, () => streamingBehavior === "steer"
        ? this.runtime.session.steer(prompt.text, images)
        : this.runtime.session.followUp(prompt.text, images));
      this.promptQueue.completeSlashSubmission(pendingSlashSubmission, this.piQueueSnapshot());
    } catch (error) {
      this.cancelExpectedInputDelivery(expected.id);
      this.promptQueue.cancelSlashSubmission(pendingSlashSubmission);
      this.skillEchoSuppressions.remove(skillEchoSuppression);
      throw error;
    }
  }

  private async flushCompactionQueue(willRetry: boolean): Promise<void> {
    if (this.resourceReload.pending) {
      // Idle: reload, then the drain delivers held prompts. Busy: steering stays in this turn.
      if (!this.runtime.session.isStreaming && !piIsCompacting(this.runtime.session)) await this.resourceReload.run();
      await this.flushHeldPromptQueue(willRetry, (behavior) => behavior === "followUp");
      return;
    }
    await this.flushHeldPromptQueue(willRetry);
  }

  private async flushHeldPromptQueue(willRetry: boolean, retain?: (behavior: "steer" | "followUp") => boolean): Promise<void> {
    await this.promptQueue.flushCompactionQueue({
      willRetry,
      isCompacting: () => piIsCompacting(this.runtime.session),
      startPrompt: async (prompt, behavior) => { await this.promptWithOptions(prompt, behavior, { fromHeldQueue: true }); },
      queuePrompt: (prompt, behavior) => this.queuePromptForActiveTurn(prompt, behavior),
      onQueueChanged: () => this.emitCombinedQueueUpdate(),
      onError: (error) => this.emitPromptFailureStatus(error),
      ...(retain ? { retain } : {}),
    });
  }

  get hasPendingResourceReload(): boolean { return this.resourceReload.pending; }
  setResourceReloadHost(host: RuntimeResourceReloadHost): void { this.resourceReload.setHost(host); }
  requestResourceReload(): Promise<RuntimeResourceReloadOutcome> { return this.resourceReload.request(); }
  settleResourceReload(): Promise<RuntimeResourceReloadOutcome> { return this.resourceReload.finishBeforeInput(); }

  private createResourceReloadScheduler(): ResourceReloadScheduler {
    return new ResourceReloadScheduler({
      sessionId: this.id, isDisposed: () => this.disposed,
      isBusy: () => this.runtime.session.isStreaming || piIsCompacting(this.runtime.session),
      isAdapterIdle: () => this.initialPromptTimer === undefined && this.pendingPromptPreflightDeliveryIds.size === 0
        && this.pendingExtensionUiRequestIds.size === 0 && !this.promptQueue.isFlushing,
      hasPendingExtensionUi: () => this.pendingExtensionUiRequestIds.size > 0, reload: () => this.reloadPiResourcesQuietly(),
      prepareReplacement: async () => { await this.asyncTasks?.prepareReplacement(); }, waitForReadiness: () => this.waitForAsyncReloadReadiness(),
      hasHeldPrompts: () => this.promptQueue.hasCompactionPrompts, flushHeldPrompts: () => this.flushHeldPromptQueue(false), log: (line) => this.emit({ type: "log", line }), emitReloaded: () => this.emit({ type: "resources_reloaded" }),
    });
  }

  private shouldHoldForResourceReload(prompt: BuiltPrompt, streamingBehavior: "steer" | "followUp" | undefined, extensionCommands: readonly { invocationName: string }[]): boolean {
    // Steering keeps its meaning only inside the current turn; extension commands run immediately.
    return streamingBehavior === "followUp" && this.resourceReload.pending && this.runtime.session.isStreaming
      && !isRegisteredExtensionCommand(prompt.text, extensionCommands);
  }

  // Reload before idle input (async hosts do it before reopening admission); hold input mid-reload.
  private async holdWhileReloading(prompt: BuiltPrompt): Promise<boolean> {
    if (!this.asyncTasks) await this.resourceReload.finishBeforeInput();
    // Keep submission order: idle input queues behind held prompts or a drain delivering them.
    const idle = !this.runtime.session.isStreaming && !piIsCompacting(this.runtime.session);
    if (!this.resourceReload.reloading && !(idle && (this.resourceReload.draining || this.promptQueue.hasCompactionPrompts))) return false;
    this.holdForReload(prompt, "during");
    this.resourceReload.schedule();
    return true;
  }

  private holdForReload(prompt: BuiltPrompt, phase: "before" | "during"): true {
    this.promptQueue.enqueueDuringCompaction(prompt, "followUp");
    this.emitCombinedQueueUpdate();
    logAgentd("pi input held for plugin reload", { sessionId: this.id, phase, promptChars: prompt.text.length });
    return true;
  }

  /** Background plugin reloads drop extension info greetings; warnings and a typed `/reload` still show. */
  private async reloadPiResourcesQuietly(): Promise<{ supported: boolean }> {
    this.quietReloadDepth += 1;
    try {
      return await this.reloadPiResources();
    } finally {
      this.quietReloadDepth -= 1;
    }
  }

  private reloadPiResources(): Promise<{ supported: boolean }> {
    this.pendingExtensionUiRequestIds.clear();
    return piTryReload(this.runtime.session, this.id, this.asyncTasks ? { beforeSessionStart: () => this.bindAsyncTasks(this.runtime.session) } : undefined);
  }

  private handleBuiltinSlashCommand(text: string): Promise<boolean> {
    return handlePiBuiltinSlashCommand(text, {
      sessionId: this.id,
      emit: (event) => this.emit(event),
      newSession: () => this.newSession(),
      setSessionName: (name) => this.runtime.session.setSessionName(name),
      compact: (instructions) => this.compact(instructions),
      isStreaming: () => this.runtime.session.isStreaming,
      isCompacting: () => piIsCompacting(this.runtime.session),
      prepareReplacement: async () => { await this.asyncTasks?.prepareReplacement(); },
      reloadGeneration: () => this.resourceReload.currentGeneration,
      reload: () => this.reloadPiResources(),
      markReloadApplied: (generation) => this.resourceReload.markApplied(generation),
      waitForReloadReadiness: () => this.waitForAsyncReloadReadiness(),
    });
  }

  private async waitForAsyncReloadReadiness(): Promise<void> {
    // Finish provider snapshots and their projection before immediate input can reopen admission.
    await this.asyncTasks?.drain();
    await this.asyncTasks?.owner.beforeModelRequest?.();
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
    const agentStartsBefore = this.agentStartCount;
    logLifecycleEvent("piPromptPreflight", {
      sessionId: this.id,
      wasStreaming,
      streamingBehavior: options.streamingBehavior ?? "none",
      textChars: text.length,
      ...this.lifecycleFields(),
    });
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
    this.pendingPromptPreflightDeliveryIds.add(expected.id);
    const pendingSlashSubmission = this.promptQueue.beginSlashSubmission(text, this.piQueueSnapshot());
    const skillEchoSuppression = this.skillEchoSuppressions.register(text);
    const promptPromise = this.inputRewriteObserver.runWithDelivery(expected.id, () => this.runAuthorizedPrompt(() => this.runtime.session.prompt(text, {
      ...options,
      preflightResult: (disposition) => {
        this.pendingPromptPreflightDeliveryIds.delete(expected.id);
        accepted = true;
        logLifecycleEvent("piPromptPreflightAccepted", { sessionId: this.id, disposition, ...this.lifecycleFields() });
        resolveOnce();
      },
    })));

    void promptPromise
      .then(() => {
        this.pendingPromptPreflightDeliveryIds.delete(expected.id);
        promptResolved = true;
        logLifecycleEvent("piPromptResolved", { sessionId: this.id, accepted, ...this.lifecycleFields() });
        resolveOnce();
      })
      .catch((error) => {
        this.pendingPromptPreflightDeliveryIds.delete(expected.id);
        promptResolved = true;
        logLifecycleEvent("piPromptRejected", { sessionId: this.id, accepted, ...this.lifecycleFields() });
        this.cancelExpectedInputDelivery(expected.id);
        this.promptQueue.cancelSlashSubmission(pendingSlashSubmission);
        this.skillEchoSuppressions.remove(skillEchoSuppression);
        if (accepted) {
          this.emitPromptFailureStatus(error);
          return;
        }
        rejectOnce(error);
      });

    await acceptedPromise;
    // Microtask ordering race: when Pi handles `/slash` extension commands, `session.prompt()`
    // suspends at its internal `await _tryExecuteExtensionCommand` and then synchronously runs
    // `preflightResult("handled")` -> `return` upon resume. That order schedules our awaiting
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
    this.promptQueue.completeSlashSubmission(pendingSlashSubmission, this.piQueueSnapshot());
    const handledSynchronously = promptResolved ? this.maybeEmitImmediateCompletion(wasStreaming, agentStartsBefore) : false;
    if (handledSynchronously || (promptResolved && !this.isExpectedInputQueued(text))) this.cancelExpectedInputDelivery(expected.id);
    logLifecycleEvent("piPromptAccepted", {
      sessionId: this.id,
      accepted,
      promptResolved,
      handledSynchronously,
      ...this.lifecycleFields(),
    });
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
  // A prompt that started a turn (agent_start observed since `agentStartsBefore`) already owns its
  // real terminal status; a synthetic marker there would overwrite the committed summary.
  private maybeEmitImmediateCompletion(wasStreaming: boolean, agentStartsBefore: number): boolean {
    if (wasStreaming) return false;
    if (this.agentStartCount !== agentStartsBefore) return false;
    if (this.runtime.session.isStreaming) return false;
    this.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
    return true;
  }

  private assertAutocompleteGeneration(generation: number): void {
    if (generation !== this.autocompleteGeneration) {
      throw new Error(`Stale autocomplete generation for session ${this.id}: expected ${this.autocompleteGeneration}, received ${generation}`);
    }
  }

  private createBridge(): ExtensionUiBridge {
    this.autocompleteQueryController?.abort();
    this.autocompleteQueryController = undefined;
    const generation = ++this.autocompleteGeneration;
    const bridge = new ExtensionUiBridge(this.id, {
      disableBlockingDialogs: this.bridgeOptions.disableBlockingDialogs ?? false,
      allowedBlockingDialogMethods: this.bridgeOptions.allowedBlockingDialogMethods,
      autocompleteGeneration: generation,
      createBaseAutocompleteProvider: () => createBaseAutocompleteProvider(this.runtime, Boolean(this.getSessionFilePath())),
    });
    bridge.on("request", (request, waitsForInput) => {
      const waits = Boolean(waitsForInput);
      if (bridge !== this.uiBridge) {
        if (waits) bridge.answer(request.id, { cancelled: true });
        return;
      }
      // Checked here rather than on the bridge: a reload can swap the bridge mid-way.
      if (!waits && this.quietReloadDepth > 0 && request.method === "notify" && (request.notifyType ?? "info") === "info") return;
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

