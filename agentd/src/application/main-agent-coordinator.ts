import { stat } from "node:fs/promises";
import { PickleCompletionCoordinator, type ExternalPickleCompletionRequest } from "./pickle-completion-coordinator.js";
import type { SessionSupervisorOptions } from "./session-supervisor-options.js";
import type { MainTurnOverlayContext } from "./overlay-context-resolver.js";
import { MainVisualNarrationCoordinator } from "./main-visual-narration-coordinator.js";
import { mapExtensionUiRequest } from "./extension-ui-request-mapper.js";
import { buildMainAgentBootstrapPair, buildMainAgentPrompt, type BuiltPrompt } from "../prompt-builder.js";
import type { PickyAgentSession, PickyContextPacket, PickyExtensionUiRequest, PickyMainActivity, PickyMainAgentMessage, PickyMainAgentModelOption, PickyMainAgentState } from "../protocol.js";
import type { SessionStore } from "../session-store.js";
import type { RuntimeEvent, RuntimeSessionHandle, ThinkingLevel } from "../runtime/types.js";
import { buildAppendedMainMessageState, projectMainAgentSessionInfo, projectMainReplyMetadata, projectMainRolloverPickleSessions } from "../domain/session-supervisor-projection-policy.js";
import { normalizeDslWhitespace } from "../domain/session-text-policy.js";
import { cleanFinalAnswer } from "../domain/session-summary.js";
import { piSessionFilePathFromLogLine } from "../domain/pi-session-files.js";
import { buildMainAgentRolloverSummary, MAIN_AGENT_COMPACT_IDLE_MS, MAIN_AGENT_MESSAGE_LIMIT, MAIN_AGENT_RESTART_TEARDOWN_SESSION_BYTES, MAIN_AGENT_SUMMARY_PICKLE_SESSION_LIMIT, mainRolloverReason, normalizeMainAgentState, RETIRED_PICKLE_CLI_CAPABILITIES, type QuickReplyMetadata } from "../domain/main-agent-policy.js";
import { logAgentd } from "../local-log.js";

export interface MainAgentCoordinatorDependencies {
  options: SessionSupervisorOptions;
  store: Pick<SessionStore, "loadMainAgentState" | "saveMainAgentState">;
  emit: (event: string, ...args: unknown[]) => void;
  /** Live session records, used for rollover summaries and completion admission. */
  sessions: () => Iterable<PickyAgentSession>;
  getSession: (sessionId: string) => PickyAgentSession | undefined;
  pickleSessionIds: ReadonlySet<string>;
}

/**
 * Owner of the always-on Picky main agent: runtime handle lifecycle (prewarm,
 * resume, interrupt, reset), turn generation and interrupted-turn suppression,
 * streamed reply assembly with duplicate quick-reply guards, idle compaction
 * with input buffering, live activity/extension UI state, and Pickle
 * completion delivery into the main conversation. SessionSupervisor delegates
 * every main-agent operation here and keeps only Pickle session ownership.
 */
export class MainAgentCoordinator {
  private disabledBuiltinTools: Set<string> = new Set();
  // Mirrors Picky's TTS setting for main-agent runtimes.
  // Defaults to true so fresh installs keep audio responses enabled.
  private ttsEnabled = true;
  private readonly ttsEnabledListeners = new Set<(enabled: boolean) => void>();
  private mainHandle?: RuntimeSessionHandle;
  private mainHandlePromise?: Promise<RuntimeSessionHandle>;
  private mainHandleUnsubscribe?: () => void;
  // Handle disposal invalidates this generation. PTT interruption keeps the same
  // handle, so user-route and event generations are intentionally separate.
  private mainHandleGeneration = 0;
  private mainInteractionGeneration = 0;
  private mainHandleEventGeneration = 0;
  private mainHandleAwaitingPostAbortInput = false;
  // Unlike event suppression, this barrier is visible to supported Pi extensions.
  // It keeps external delivery out of the gap between PTT abort and accepted speech.
  private mainExternalDeliveryPaused = false;
  private mainReuseBarrier: Promise<void> = Promise.resolve();
  private mainThinkingLevel?: ThinkingLevel;
  private mainDraft = "";
  private mainAssistantDeltaSeen = false;
  private mainFirstAssistantDeltaLogged = false;
  private mainPromptDeliveredAt?: number;
  private mainVisualNarrationTurnToken = "main-turn-0";
  private readonly mainVisualNarration: MainVisualNarrationCoordinator;
  private mainContext?: PickyContextPacket;
  private mainContextGeneration = 0;
  // DSL tags must resolve against the screenshot context the streaming turn saw,
  // never against a newer context that replaced it while the turn was in flight.
  private mainTurnOverlayContext?: MainTurnOverlayContext;
  private mainState: PickyMainAgentState = { messages: [] };
  private mainReplyContextId = "main";
  private mainIsProcessing = false;
  private mainPendingExtensionUiRequest?: PickyExtensionUiRequest;
  private mainThinkingBuffer = "";
  private mainActivityVisible = false;
  // Retained while visible so newly connected app sockets can restore the live main-agent strip.
  private mainActivity?: PickyMainActivity;
  private mainThinkingLastEmittedAt?: number;
  private mainThinkingTimer?: ReturnType<typeof setTimeout>;
  // Idle-triggered in-place compaction: timer (re)armed on turn settle when a threshold is met,
  // cancelled on fresh activity, so compaction only runs after the idle window of quiet.
  private mainCompactionIdleTimer?: ReturnType<typeof setTimeout>;
  // True while `handle.compact()` is in flight; input that arrives is buffered (FIFO) and
  // delivered once compaction settles, so a compaction never swallows a user message.
  private mainInFlightCompaction = false;
  private mainPendingCompactionContexts: PickyContextPacket[] = [];
  // Pi emits both `turn_end` and `agent_end` for a single agent run, both of which
  // normalize to `status:"completed"` (see pi-event-normalizer.ts). They arrive
  // back-to-back through the same fire-and-forget subscriber, and the first call's
  // sync work yields at `await appendMainMessage` before reaching `mainDraft = ""`.
  // Without this guard, the second terminal event reads the still-populated draft
  // and re-emits both `mainMessage` and `quickReply`, producing duplicate menu-bar
  // messages and overlapping TTS playback. Reset on each `running` and on every new
  // `assistant_delta` so a follow-up turn re-arms.
  private mainTerminalProcessed = false;
  // Defense-in-depth dedup for the main quick reply emit. A user-reported bug showed TTS
  // playing the full assistant reply twice while the persisted Pi session JSONL recorded
  // exactly one assistant message (stopReason:"stop"), proving the duplication happens at
  // `applyMainRuntimeEvent` emit time. Guard A (`mainTerminalProcessed`) covers the documented
  // `turn_end`+`agent_end` synchronous pair, but cannot stop a duplicate emit caused by an
  // upstream listener leak (e.g. a re-entrant `bindCurrentSession` stacking two Pi subscribers)
  // or an out-of-band `assistant_delta` replay between two terminal events. Track the last
  // emitted `(contextId, text)` and the timestamp so we can drop an identical second emit
  // within a short window. Cleared implicitly by a new `contextId` or by a different reply
  // text, so legitimate sequential same-text replies on different contexts (e.g. "OK" / "OK"
  // across two voice turns) are unaffected.
  private lastMainQuickReplyText?: string;
  private lastMainQuickReplyContextId?: string;
  private lastMainQuickReplyAt?: number;
  // Monotonic supervisor-side generation for main-agent turns. When a runtime can tag streamed
  // events with this id, interrupted-turn terminal events can be dropped by exact id instead of by
  // broad counters that may also match the replacement turn.
  private mainTurnId = 0;
  private activeMainRuntimeInputId?: string;
  private interruptedMainInputIds = new Set<string>();
  // Session ids that this supervisor does NOT host locally but that should still be tagged as
  // Pickle-completion contexts when the main agent's reply turn ends. The completion
  // coordinator owns admission and delivery state; this set only projects reply metadata.
  private externalPickleReplyContexts = new Set<string>();
  private readonly pickleCompletionCoordinator: PickleCompletionCoordinator;
  private mainStateWriteChain = Promise.resolve();

  constructor(private readonly deps: MainAgentCoordinatorDependencies) {
    this.mainVisualNarration = new MainVisualNarrationCoordinator({
      currentTurn: () => ({
        contextId: this.mainReplyContextId,
        turnId: this.mainTurnId,
        turnToken: this.mainVisualNarrationTurnToken,
        context: this.mainContext,
        overlayContext: this.mainTurnOverlayContext,
        screenOverlayDisabled: this.disabledBuiltinTools.has("picky_screen_overlay"),
      }),
      narrationMetadata: () => this.mainNarrationMetadata(),
      emit: (event, payload) => this.deps.emit(event, payload),
      log: (message, data) => logAgentd(message, data),
    });
    this.pickleCompletionCoordinator = this.createPickleCompletionCoordinator(this.deps.options);
  }

  async load(): Promise<void> {
    this.mainState = normalizeMainAgentState(await this.deps.store.loadMainAgentState());
  }

  get currentContext(): PickyContextPacket | undefined {
    return this.mainContext;
  }

  get currentContextGeneration(): number {
    return this.mainContextGeneration;
  }

  get currentHandle(): RuntimeSessionHandle | undefined {
    return this.mainHandle;
  }

  get pendingHandlePromise(): Promise<RuntimeSessionHandle> | undefined {
    return this.mainHandlePromise;
  }

  get currentDisabledBuiltinTools(): ReadonlySet<string> {
    return this.disabledBuiltinTools;
  }

  notifyLocalPickleCompletion(sessionId: string, committedSession?: PickyAgentSession): Promise<void> {
    return this.pickleCompletionCoordinator.notifyLocalCompletion(sessionId, committedSession);
  }

  clearLocalPickleTracking(sessionId: string): void {
    this.pickleCompletionCoordinator.clearLocalTracking(sessionId);
    this.externalPickleReplyContexts.delete(sessionId);
  }

  private emitQuickReply(contextId: string, text: string, metadata: Partial<QuickReplyMetadata> = {}): void {
    this.deps.emit("quickReply", contextId, text, metadata);
  }

  private createPickleCompletionCoordinator(options: SessionSupervisorOptions): PickleCompletionCoordinator {
    return new PickleCompletionCoordinator({
      session: (sessionId) => this.deps.getSession(sessionId),
      isMainProcessing: () => this.mainIsProcessing,
      hasMainRuntime: () => this.deps.options.mainRuntime !== undefined,
      forwardCompletion: options.forwardPickleCompletionToPrimary,
      prepareMainDelivery: (prompt, cwd) => this.preparePickyCompletionDelivery(prompt, cwd),
      activateLocalReplyContext: (sessionId) => this.activateLocalPickleCompletionContext(sessionId),
      activateExternalReplyContext: (sessionId) => this.activateExternalPickleCompletionContext(sessionId),
      deactivateExternalReplyContext: (sessionId) => this.externalPickleReplyContexts.delete(sessionId),
      setMainProcessing: (processing) => { this.mainIsProcessing = processing; },
      resetMainTerminal: () => { this.mainTerminalProcessed = false; },
      log: (message, fields) => logAgentd(message, fields),
    });
  }

  async prewarmMainAgent(cwd = process.cwd()): Promise<void> {
    if (!this.deps.options.mainRuntime || this.mainHandle) return;
    if (!this.deps.options.mainRuntime.prewarm && !this.deps.options.mainRuntime.resume) return;
    logAgentd("main prewarm requested", { cwd });
    await this.ensurePrewarmedMainHandle(cwd);
  }

  listMainMessages(): PickyMainAgentMessage[] {
    return [...this.mainState.messages];
  }

  mainPendingExtensionUi(): PickyExtensionUiRequest | undefined {
    return this.mainPendingExtensionUiRequest;
  }

  /** Current live main-agent activity, if any, for app socket reconnect replay. */
  mainActiveActivity(): PickyMainActivity | undefined {
    return this.mainActivity;
  }

  /// Public snapshot of the always-on Picky main agent's Pi session location.
  /// The Picky app uses this to expose "Open in Pi" / "Copy resume command"
  /// escape hatches in the Messages tab so users can drop into a real Pi TUI
  /// against the same session file the daemon is driving.
  mainAgentSessionInfo(): { sessionFilePath?: string; cwd?: string } {
    return projectMainAgentSessionInfo(this.mainState);
  }

  async answerMainExtensionUi(requestId: string, value: unknown): Promise<void> {
    const handle = this.mainHandle;
    if (!handle?.answerExtensionUi) throw new Error("Main runtime cannot answer extension UI requests");
    await handle.answerExtensionUi(requestId, value);
    if (this.mainPendingExtensionUiRequest?.id === requestId) this.mainPendingExtensionUiRequest = undefined;
  }

  async resetMainAgent(): Promise<void> {
    logAgentd("main reset requested", { messages: this.mainState.messages.length, hadHandle: this.mainHandle ? 1 : 0 });
    await this.cancelMainPendingExtensionUi();
    this.clearMainActivity();
    const currentHandle = this.mainHandle;
    const pendingHandlePromise = this.mainHandlePromise;
    this.detachMainHandleForInterruption();
    await this.patchMainState({ messages: [], sessionFilePath: undefined, cwd: undefined, compactSummary: undefined, epochStartedAt: undefined, epochTurnCount: undefined, lastRolloverAt: undefined, lastRolloverReason: undefined, contextUsage: undefined });

    // Pi emits session_shutdown during disposal. Cron intentionally keeps any
    // session lease draining until a genuine successor starts or agentd exits,
    // so due session jobs defer instead of running against a hidden owner.
    if (currentHandle) await this.disposeMainHandle(currentHandle, "current");
    if (pendingHandlePromise) {
      void pendingHandlePromise
        .then(async (pendingHandle) => {
          if (pendingHandle === currentHandle) return;
          await this.disposeMainHandle(pendingHandle, "pending");
        })
        .catch((error) => {
          logAgentd("main reset pending handle failed", { error: error instanceof Error ? error.message : String(error) });
        });
    }
  }

  async abortMainAgent(): Promise<void> {
    logAgentd("main abort requested", { messages: this.mainState.messages.length, hadHandle: this.mainHandle ? 1 : 0, hadPendingHandle: this.mainHandlePromise ? 1 : 0, wasProcessing: this.mainIsProcessing ? 1 : 0 });
    await this.cancelMainPendingExtensionUi();
    const currentHandle = this.mainHandle;
    const pendingHandlePromise = this.mainHandlePromise;
    const cwd = this.mainState.cwd?.trim() || process.cwd();
    // Close the extension delivery gate before Pi starts draining the interrupted
    // turn. A cron follow-up accepted in this window can otherwise run unseen and
    // become the next voice turn's reply context.
    this.setMainExternalDeliveryPaused(true, currentHandle);
    this.prepareMainInteractionForAbort(Boolean(currentHandle || pendingHandlePromise));

    if (currentHandle) {
      // PTT interrupts only the running turn. Rebinding this same handle gives
      // queued old callbacks an obsolete event generation while preserving the
      // Pi session and its cron bridge for the next spoken input.
      this.bindMainHandleEvents(currentHandle);
      await this.abortMainHandle(currentHandle, "voice-input");
      return;
    }

    if (pendingHandlePromise) {
      const pendingAbort = pendingHandlePromise
        .then(async (pendingHandle) => {
          this.setMainExternalDeliveryPaused(true, pendingHandle);
          await this.abortMainHandle(pendingHandle, "voice-input-pending");
        })
        .catch((error) => {
          logAgentd("main abort pending handle failed", { error: error instanceof Error ? error.message : String(error) });
        });
      this.mainReuseBarrier = pendingAbort;
      return;
    }

    // There is no live session to preserve, for example immediately after a
    // daemon restart. Prewarm the persisted transcript normally.
    void this.ensurePrewarmedMainHandle(cwd).catch((error) => {
      logAgentd("main resume prewarm after abort failed", { error: error instanceof Error ? error.message : String(error) });
    });
  }

  async setMainAgentThinkingLevel(level: ThinkingLevel): Promise<void> {
    this.mainThinkingLevel = level;
    this.deps.options.mainRuntime?.setThinkingLevel?.(level);
    logAgentd("main thinking level configured", { level, hadHandle: this.mainHandle ? 1 : 0, hadPendingHandle: this.mainHandlePromise ? 1 : 0 });
    this.applyMainThinkingLevel(this.mainHandle, level);
  }

  async listMainAgentModels(): Promise<PickyMainAgentModelOption[]> {
    const models = await this.deps.options.mainRuntime?.listAvailableModels?.({ cwd: this.mainState.cwd ?? process.cwd() }) ?? [];
    return models;
  }

  async setMainAgentModel(pattern: string): Promise<void> {
    const normalized = pattern.trim();
    const modelPattern = normalized || undefined;
    const changed = this.deps.options.mainRuntime?.setModelPattern?.(modelPattern) ?? false;
    logAgentd("main model configured", { patternChars: normalized.length, changed: changed ? 1 : 0, hadHandle: this.mainHandle ? 1 : 0, hadPendingHandle: this.mainHandlePromise ? 1 : 0 });
    if (!changed) return;

    const applyToHandle = async (handle: RuntimeSessionHandle, source: "active" | "pending"): Promise<void> => {
      if (!handle.setModel) {
        logAgentd("main model live switch skipped", { reason: "runtime handle does not support setModel", source });
        return;
      }
      const currentAssistantRun = await handle.setModel(modelPattern);
      logAgentd("main model live switch applied", { source, model: currentAssistantRun?.model, thinkingLevel: currentAssistantRun?.thinkingLevel });
    };

    if (this.mainHandle) {
      await applyToHandle(this.mainHandle, "active");
      return;
    }

    const pendingHandlePromise = this.mainHandlePromise;
    if (pendingHandlePromise) {
      const generation = this.mainHandleGeneration;
      void pendingHandlePromise
        .then(async (handle) => {
          if (generation !== this.mainHandleGeneration) return;
          await applyToHandle(handle, "pending");
        })
        .catch((error) => {
          logAgentd("main model pending live switch failed", { error: error instanceof Error ? error.message : String(error) });
        });
    }
  }

  async setDisabledBuiltinTools(names: readonly string[]): Promise<void> {
    const disabled = new Set(names.filter((name) => !RETIRED_PICKLE_CLI_CAPABILITIES.has(name)));
    const previous = this.disabledBuiltinTools;
    const same = previous.size === disabled.size && [...disabled].every((name) => previous.has(name));
    this.disabledBuiltinTools = disabled;
    logAgentd("disabled builtin tools configured", { count: disabled.size, changed: same ? 0 : 1 });
    if (same) return;
    // The runtime reads this on the next turn to rebuild its system-prompt contract, so
    // prompt-gated identifiers take effect without discarding the live session.
    this.deps.options.onDisabledBuiltinToolsChanged?.(disabled);
    const customToolsChanged = this.applyMainCustomTools(previous, disabled);
    if (!customToolsChanged) return;
    // Pi resolves the custom-tool registry when a handle is created, so a changed tool set is
    // only observable on a fresh handle. Prompt-only identifiers skip this teardown.
    const currentHandle = this.mainHandle;
    this.detachMainHandleForInterruption();
    // As with reset, do not revive a detached session just to clear cron's
    // draining lease. Deferred session jobs wait for a real Pi successor.
    if (currentHandle) await this.disposeMainHandle(currentHandle, "builtin-tools-switch");
    await this.patchMainState({ sessionFilePath: undefined });
  }

  /** Pushes the refreshed custom-tool list and reports whether the registry actually changed. */
  private applyMainCustomTools(previous: ReadonlySet<string>, disabled: ReadonlySet<string>): boolean {
    const builder = this.deps.options.mainCustomToolsBuilder;
    if (!builder) return false;
    const nameKey = (tools: ReturnType<typeof builder>): string => tools.map((tool) => tool.name).sort().join("\u0000");
    const nextTools = builder(disabled);
    const changed = nameKey(nextTools) !== nameKey(builder(previous));
    if (this.deps.options.mainRuntime?.setCustomTools) this.deps.options.mainRuntime.setCustomTools(nextTools);
    return changed;
  }

  /** Current value of Picky's TTS toggle for main-agent audio-producing runtimes. */
  getTTSEnabled(): boolean {
    return this.ttsEnabled;
  }

  /**
   * Update the TTS toggle. Idempotent: setting the same value does not fire
   * change listeners again.
   */
  setTTSEnabled(enabled: boolean): void {
    if (this.ttsEnabled === enabled) return;
    this.ttsEnabled = enabled;
    // Narration events also drive sentence-complete cursor bubbles, so toggling
    // audio must not discard their parser state or streamed-reply bookkeeping.
    logAgentd("tts enabled changed", { enabled });
    this.deps.options.mainRuntime?.setMainAgentTTSEnabled?.(enabled);
    for (const listener of this.ttsEnabledListeners) {
      try {
        listener(enabled);
      } catch (error) {
        logAgentd("tts enabled listener error", { error: error instanceof Error ? error.message : String(error) });
      }
    }
  }

  /** Subscribe to TTS toggle changes. Returns an unsubscribe function. */
  onTTSEnabledChange(listener: (enabled: boolean) => void): () => void {
    this.ttsEnabledListeners.add(listener);
    return () => this.ttsEnabledListeners.delete(listener);
  }

  private detachMainHandleForInterruption(): void {
    this.mainHandleGeneration += 1;
    this.mainInteractionGeneration += 1;
    this.mainHandleEventGeneration += 1;
    this.mainHandleUnsubscribe?.();
    this.mainHandleUnsubscribe = undefined;
    this.mainHandle = undefined;
    this.mainHandlePromise = undefined;
    this.mainReuseBarrier = Promise.resolve();
    this.mainHandleAwaitingPostAbortInput = false;
    this.mainExternalDeliveryPaused = false;
    this.resetMainInteractionState();
  }

  private setMainExternalDeliveryPaused(paused: boolean, handle = this.mainHandle): void {
    this.mainExternalDeliveryPaused = paused;
    handle?.setExternalDeliveryPaused?.(paused);
  }

  private releaseMainExternalDeliveryAfterPrompt(handle: RuntimeSessionHandle): void {
    // A second PTT abort may have arrived while the prompt was being accepted.
    // It owns the pause, so the older acceptance must never reopen the gate.
    if (this.mainHandle !== handle || this.mainHandleAwaitingPostAbortInput) return;
    this.setMainExternalDeliveryPaused(false, handle);
  }

  /** Clears UI turn state without invalidating a reusable Pi handle. */
  private prepareMainInteractionForAbort(awaitingReplacementInput: boolean): void {
    this.mainInteractionGeneration += 1;
    this.resetMainInteractionState();
    this.mainHandleAwaitingPostAbortInput = awaitingReplacementInput;
  }

  private resetMainInteractionState(): void {
    this.clearMainActivity();
    this.mainDraft = "";
    this.mainAssistantDeltaSeen = false;
    this.mainVisualNarration.reset();
    this.mainContext = undefined;
    this.mainTurnOverlayContext = undefined;
    this.mainReplyContextId = "main";
    this.mainIsProcessing = false;
    this.mainTerminalProcessed = false;
    this.mainTurnId += 1;
    this.mainVisualNarrationTurnToken = `main-turn-${this.mainTurnId}`;
    this.activeMainRuntimeInputId = undefined;
    this.interruptedMainInputIds.clear();
    this.pickleCompletionCoordinator.reset();
    this.cancelMainIdleCompaction();
    this.mainInFlightCompaction = false;
    this.mainPendingCompactionContexts = [];
  }

  private discardQueuedMainThinkingActivity(): void {
    if (this.mainThinkingTimer) clearTimeout(this.mainThinkingTimer);
    this.mainThinkingTimer = undefined;
    this.mainThinkingBuffer = "";
    this.mainThinkingLastEmittedAt = undefined;
  }

  private clearMainActivity(): void {
    this.discardQueuedMainThinkingActivity();
    const wasVisible = this.mainActivityVisible || this.mainActivity !== undefined;
    this.mainActivityVisible = false;
    this.mainActivity = undefined;
    if (wasVisible) this.deps.emit("mainActivity", undefined);
  }

  private showMainActivity(activity: PickyMainActivity): void {
    this.mainActivityVisible = true;
    this.mainActivity = activity;
    this.deps.emit("mainActivity", activity);
  }

  private emitMainThinkingActivity(): void {
    this.mainThinkingTimer = undefined;
    const thinkingPreview = this.mainThinkingBuffer.slice(-200).replace(/\s+/g, " ").trim();
    if (!thinkingPreview) return;
    this.mainThinkingLastEmittedAt = Date.now();
    this.showMainActivity({ kind: "thinking", thinkingPreview });
  }

  private queueMainThinkingActivity(delta: string): void {
    this.mainThinkingBuffer += delta;
    const elapsed = Date.now() - (this.mainThinkingLastEmittedAt ?? 0);
    if (this.mainThinkingLastEmittedAt === undefined || elapsed >= 400) {
      this.emitMainThinkingActivity();
      return;
    }
    if (!this.mainThinkingTimer) {
      this.mainThinkingTimer = setTimeout(() => this.emitMainThinkingActivity(), 400 - elapsed);
    }
  }

  async cancelMainPendingExtensionUi(): Promise<void> {
    const pending = this.mainPendingExtensionUiRequest;
    if (!pending) return;
    const handle = this.mainHandle;
    if (handle?.answerExtensionUi) {
      await handle.answerExtensionUi(pending.id, { cancelled: true }, { ignoreUnknown: true });
    }
    if (this.mainPendingExtensionUiRequest?.id === pending.id) {
      this.mainPendingExtensionUiRequest = undefined;
      this.deps.emit("mainExtensionUiCancelled", pending.id);
    }
  }

  private async abortMainHandle(handle: RuntimeSessionHandle, label: string): Promise<void> {
    try {
      await handle.abort();
    } catch (error) {
      logAgentd("main abort failed", { label, error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async disposeMainHandle(handle: RuntimeSessionHandle, label: string): Promise<void> {
    if (!handle.dispose) {
      await this.abortMainHandle(handle, `${label}-legacy`);
      return;
    }
    try {
      await handle.dispose();
    } catch (error) {
      logAgentd("main runtime dispose failed", { label, error: error instanceof Error ? error.message : String(error) });
    }
  }

  async routeThroughMainAgent(context: PickyContextPacket): Promise<void> {
    logAgentd("main route requested", { contextId: context.id, source: context.source, transcriptChars: context.transcript?.length });
    // Fresh activity cancels any pending idle compaction; input during an in-flight compaction is
    // buffered and delivered once it settles (drainMainPendingInput) instead of interrupting it.
    this.cancelMainIdleCompaction();
    if (this.mainInFlightCompaction || this.mainHandle?.isCompacting === true) {
      this.mainPendingCompactionContexts.push(context);
      logAgentd("main input buffered during compaction", { contextId: context.id, queued: this.mainPendingCompactionContexts.length });
      return;
    }
    const interactionGeneration = this.mainInteractionGeneration;
    this.mainContext = context;
    this.mainContextGeneration += 1;
    this.beginMainTurn(context.id, { context, generation: this.mainContextGeneration });
    const prompt = buildMainAgentPrompt(context);
    // Append the user message to mainState.messages AFTER deliverMainPrompt
    // resolves. finally{} guarantees the message is still recorded if deliver
    // throws, so the next turn's context still has the user's earlier line.
    const transcript = context.transcript?.trim();
    try {
      if (this.mainHandlePromise && !this.mainHandle) {
        const handle = await this.mainHandlePromise;
        if (interactionGeneration !== this.mainInteractionGeneration) return;
        await this.mainReuseBarrier;
        if (interactionGeneration !== this.mainInteractionGeneration) return;
        await this.deliverMainPrompt(handle, prompt);
        return;
      }
      if (!this.mainHandle) {
        const initial = this.createInitialMainHandle(prompt, context.cwd, this.mainHandleGeneration);
        const trackedPromise = initial.then(({ handle }) => handle).finally(() => {
          if (this.mainHandlePromise === trackedPromise) this.mainHandlePromise = undefined;
        });
        this.mainHandlePromise = trackedPromise;
        const handle = await initial;
        if (interactionGeneration !== this.mainInteractionGeneration) return;
        await this.mainReuseBarrier;
        if (interactionGeneration !== this.mainInteractionGeneration) return;
        if (!handle.initialPromptAlreadySent) await this.deliverMainPrompt(handle.handle, prompt);
        return;
      }
      await this.mainReuseBarrier;
      if (interactionGeneration !== this.mainInteractionGeneration) return;
      await this.deliverMainPrompt(this.mainHandle, prompt);
    } finally {
      if (transcript) await this.appendMainMessage("user", transcript);
    }
  }

  // Threshold-triggered in-place compaction. `handle.compact()` keeps the same Pi session/process
  // alive (no session_shutdown), so extension in-memory state such as scheduled `delay` timers
  // survives. Only fires from the idle timer, never mid-turn, so active use is never interrupted.
  private async runMainIdleCompaction(): Promise<void> {
    this.mainCompactionIdleTimer = undefined;
    if (!this.deps.options.mainRuntime || this.mainIsProcessing || this.mainInFlightCompaction) return;
    const reason = mainRolloverReason(this.mainState);
    if (!reason) return;
    const handle = this.mainHandle;
    // No live compact-capable handle: skip; restart teardown still bounds disk growth.
    if (!handle?.compact || handle.isCompacting === true) return;
    const summary = buildMainAgentRolloverSummary(reason, this.mainState, this.mainRolloverPickleSessions());
    const now = new Date().toISOString();
    logAgentd("main idle compaction", { reason, messages: this.mainState.messages.length, turns: this.mainState.epochTurnCount ?? 0 });
    this.mainInFlightCompaction = true;
    try {
      await handle.compact();
      // Reset only epoch counters so the threshold does not immediately re-fire; the Pi session,
      // its file, and the message mirror stay intact. contextUsage is cleared by compactionCompleted.
      await this.patchMainState({
        compactSummary: summary,
        epochStartedAt: now,
        epochTurnCount: 0,
        lastRolloverAt: now,
        lastRolloverReason: reason,
      });
    } catch (error) {
      logAgentd("main idle compaction failed", { reason, error: error instanceof Error ? error.message : String(error) });
    } finally {
      this.mainInFlightCompaction = false;
      this.drainMainPendingInput();
    }
  }

  private scheduleMainIdleCompaction(): void {
    this.cancelMainIdleCompaction();
    if (!this.deps.options.mainRuntime || this.mainInFlightCompaction || this.mainIsProcessing) return;
    if (!mainRolloverReason(this.mainState)) return;
    const idleMs = this.deps.options.mainCompactionIdleMs ?? MAIN_AGENT_COMPACT_IDLE_MS;
    this.mainCompactionIdleTimer = setTimeout(() => {
      void this.runMainIdleCompaction();
    }, idleMs);
  }

  private cancelMainIdleCompaction(): void {
    if (!this.mainCompactionIdleTimer) return;
    clearTimeout(this.mainCompactionIdleTimer);
    this.mainCompactionIdleTimer = undefined;
  }

  // Deliver one buffered input that arrived during a compaction; the next drains on turn settle.
  private drainMainPendingInput(): void {
    if (this.mainInFlightCompaction || this.mainIsProcessing || this.mainHandle?.isCompacting === true) return;
    const next = this.mainPendingCompactionContexts.shift();
    if (!next) return;
    logAgentd("main buffered input drained", { contextId: next.id, remaining: this.mainPendingCompactionContexts.length });
    void this.routeThroughMainAgent(next).catch((error) => {
      logAgentd("main buffered input route failed", { contextId: next.id, error: error instanceof Error ? error.message : String(error) });
    });
  }

  // On restart, tear down a bloated main Pi session file (clear sessionFilePath so the next handle
  // starts fresh, carry a summary memo) to bound disk growth; short sessions resume normally.
  async rolloverMainAgentForRestart(): Promise<void> {
    const sessionFilePath = this.mainState.sessionFilePath?.trim();
    if (!this.deps.options.mainRuntime || !sessionFilePath) return;
    let sessionFileBytes: number;
    try {
      sessionFileBytes = (await stat(sessionFilePath)).size;
    } catch {
      return; // Missing/unreadable file: nothing to bound; the resume path handles it.
    }
    if (sessionFileBytes < MAIN_AGENT_RESTART_TEARDOWN_SESSION_BYTES) return;
    const reason = "restart";
    const summary = buildMainAgentRolloverSummary(reason, this.mainState, this.mainRolloverPickleSessions());
    const now = new Date().toISOString();
    logAgentd("main restart teardown", { previousSessionFilePath: this.mainState.sessionFilePath, turns: this.mainState.epochTurnCount ?? 0, summaryChars: summary.length });
    await this.patchMainState({
      sessionFilePath: undefined,
      compactSummary: summary,
      epochStartedAt: now,
      epochTurnCount: 0,
      lastRolloverAt: now,
      lastRolloverReason: reason,
      contextUsage: undefined,
    });
  }

  private mainRolloverPickleSessions() {
    return projectMainRolloverPickleSessions(
      this.deps.sessions(),
      this.deps.pickleSessionIds,
      MAIN_AGENT_SUMMARY_PICKLE_SESSION_LIMIT,
    );
  }

  private async deliverMainPrompt(handle: RuntimeSessionHandle, prompt: ReturnType<typeof buildMainAgentPrompt>): Promise<void> {
    // The next user prompt is the explicit boundary that lets post-abort events
    // flow again. PiSdkRuntime separately filters the old abort drain until its
    // next agent_start, so both untagged SDK events and queued callbacks are safe.
    this.mainHandleAwaitingPostAbortInput = false;
    this.recordMainPromptDelivery();
    if (this.mainIsProcessing && handle.interrupt) {
      logAgentd("main interrupt", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, inputId: this.activeMainRuntimeInputId });
      if (this.activeMainRuntimeInputId) this.interruptedMainInputIds.add(this.activeMainRuntimeInputId);
      this.mainTerminalProcessed = false;
      this.mainDraft = "";
      await handle.interrupt(prompt);
      this.mainIsProcessing = true;
      this.releaseMainExternalDeliveryAfterPrompt(handle);
      return;
    }
    this.mainIsProcessing = true;
    await handle.followUp(prompt);
    this.releaseMainExternalDeliveryAfterPrompt(handle);
  }

  private recordMainPromptDelivery(): void {
    this.mainPromptDeliveredAt = Date.now();
    logAgentd("main prompt delivered", { contextId: this.mainReplyContextId, turnId: this.mainTurnId });
  }

  private beginMainTurn(contextId: string, overlayContext: MainTurnOverlayContext): void {
    this.mainTurnId += 1;
    this.mainVisualNarrationTurnToken = `main-turn-${this.mainTurnId}`;
    this.mainVisualNarration.beginTurn();
    this.mainReplyContextId = contextId;
    this.mainTurnOverlayContext = overlayContext;
    this.mainPromptDeliveredAt = undefined;
    this.activeMainRuntimeInputId = `main-turn-${this.mainTurnId}`;
    this.mainDraft = "";
    this.mainAssistantDeltaSeen = false;
    this.mainFirstAssistantDeltaLogged = false;
    this.mainTerminalProcessed = false;
  }

  async ensurePrewarmedMainHandle(cwd: string): Promise<RuntimeSessionHandle> {
    if (this.mainHandle) return this.mainHandle;
    if (!this.mainHandlePromise) {
      const generation = this.mainHandleGeneration;
      const promise = this.createPrewarmedMainHandle(cwd, generation);
      const trackedPromise = promise.finally(() => {
        if (this.mainHandlePromise === trackedPromise) this.mainHandlePromise = undefined;
      });
      this.mainHandlePromise = trackedPromise;
    }
    return this.mainHandlePromise;
  }

  private async createPrewarmedMainHandle(cwd: string, generation = this.mainHandleGeneration): Promise<RuntimeSessionHandle> {
    const resumed = await this.tryResumeMainHandle(cwd, generation);
    if (resumed) return resumed;
    if (!this.deps.options.mainRuntime?.prewarm) throw new Error("Main runtime cannot prewarm");
    const handle = await this.deps.options.mainRuntime.prewarm({ cwd, sessionId: "picky" });
    logAgentd("main prewarmed", { cwd });
    if (generation !== this.mainHandleGeneration) {
      await this.disposeMainHandle(handle, "stale-prewarm");
      return handle;
    }
    // Attach BEFORE the patchMainState file I/O so the runtime's setTimeout(0) for
    // reportDiagnostics (which emits "pi session: <path>" via the runtime event channel)
    // arrives at a subscribed listener instead of being dropped on the floor.
    const attached = this.attachMainHandle(handle, generation);
    await this.patchMainState({ cwd });
    await this.injectMainBootstrap(attached);
    return attached;
  }

  private async createInitialMainHandle(prompt: ReturnType<typeof buildMainAgentPrompt>, cwd?: string, generation = this.mainHandleGeneration): Promise<{ handle: RuntimeSessionHandle; initialPromptAlreadySent: boolean }> {
    const resumed = await this.tryResumeMainHandle(cwd ?? process.cwd(), generation);
    if (resumed) return { handle: resumed, initialPromptAlreadySent: false };
    this.recordMainPromptDelivery();
    const handle = await this.deps.options.mainRuntime!.create(prompt, { cwd, sessionId: "picky" });
    if (generation !== this.mainHandleGeneration) {
      await this.disposeMainHandle(handle, "stale-initial");
      return { handle, initialPromptAlreadySent: true };
    }
    // Attach BEFORE the patchMainState file I/O. mainRuntime.create() schedules the
    // initial prompt + reportDiagnostics via setTimeout(0); without subscribing first the
    // resulting "pi session: <path>" log event is lost (see createPrewarmedMainHandle).
    const attached = this.attachMainHandle(handle, generation);
    await this.patchMainState({ cwd });
    await this.injectMainBootstrap(attached);
    return { handle: attached, initialPromptAlreadySent: true };
  }

  private async injectMainBootstrap(handle: RuntimeSessionHandle): Promise<void> {
    if (!handle.injectInitialBootstrap) return;
    try {
      await handle.injectInitialBootstrap(buildMainAgentBootstrapPair({
        compactSummary: this.mainState.compactSummary,
      }));
    } catch (error) {
      logAgentd("main bootstrap inject failed", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async tryResumeMainHandle(cwd: string, generation = this.mainHandleGeneration): Promise<RuntimeSessionHandle | undefined> {
    const sessionFilePath = this.mainState.sessionFilePath?.trim();
    if (!sessionFilePath || !this.deps.options.mainRuntime?.resume) return undefined;
    try {
      logAgentd("main resume requested", { sessionFilePath, cwd });
      const handle = await this.deps.options.mainRuntime.resume(sessionFilePath, { cwd, sessionId: "picky" });
      logAgentd("main resumed", { sessionFilePath, cwd });
      if (generation !== this.mainHandleGeneration) {
        await this.disposeMainHandle(handle, "stale-resume");
        return handle;
      }
      // Attach BEFORE the patchMainState file I/O so the resume-path setTimeout(0) for
      // reportDiagnostics finds a subscribed listener (matches createPrewarmedMainHandle).
      const attached = this.attachMainHandle(handle, generation);
      await this.patchMainState({ cwd });
      return attached;
    } catch (error) {
      logAgentd("main resume failed", { sessionFilePath, error: error instanceof Error ? error.message : String(error) });
      return undefined;
    }
  }

  private attachMainHandle(handle: RuntimeSessionHandle, generation = this.mainHandleGeneration): RuntimeSessionHandle {
    if (generation !== this.mainHandleGeneration) {
      void this.disposeMainHandle(handle, "stale-attach");
      return handle;
    }
    this.mainHandle = handle;
    this.mainHandleAwaitingPostAbortInput = this.mainExternalDeliveryPaused;
    handle.setExternalDeliveryPaused?.(this.mainExternalDeliveryPaused);
    this.applyMainThinkingLevel(handle);
    this.bindMainHandleEvents(handle);
    return handle;
  }

  /** Rebind the same reusable handle after PTT abort so queued callbacks go stale. */
  private bindMainHandleEvents(handle: RuntimeSessionHandle): void {
    this.mainHandleUnsubscribe?.();
    const eventGeneration = ++this.mainHandleEventGeneration;
    this.mainHandleUnsubscribe = handle.subscribe((event) => {
      if (eventGeneration !== this.mainHandleEventGeneration) return;
      void this.applyMainRuntimeEvent(event, eventGeneration);
    });
  }

  private applyMainThinkingLevel(handle: RuntimeSessionHandle | undefined, level = this.mainThinkingLevel): void {
    if (!handle || !level) return;
    if (!handle.setThinkingLevel) {
      logAgentd("main thinking level skipped", { level, reason: "runtime handle does not support setThinkingLevel" });
      return;
    }
    handle.setThinkingLevel(level);
  }

  private async appendMainMessage(role: PickyMainAgentMessage["role"], text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;
    const { message, patch } = buildAppendedMainMessageState(
      this.mainState,
      role,
      trimmed,
      new Date().toISOString(),
      MAIN_AGENT_MESSAGE_LIMIT,
    );
    await this.patchMainState(patch);
    this.deps.emit("mainMessage", message);
  }

  private async patchMainState(patch: Partial<PickyMainAgentState>): Promise<void> {
    const previousSessionFilePath = this.mainState.sessionFilePath;
    const previousCwd = this.mainState.cwd;
    this.mainState = normalizeMainAgentState({ ...this.mainState, ...patch });
    if (previousSessionFilePath !== this.mainState.sessionFilePath || previousCwd !== this.mainState.cwd) {
      this.deps.emit("mainAgentSessionInfo", this.mainAgentSessionInfo());
    }
    const snapshot = this.mainState;
    const write = this.mainStateWriteChain.catch(() => undefined).then(() => this.deps.store.saveMainAgentState(snapshot));
    this.mainStateWriteChain = write.catch(() => undefined);
    await write;
  }

  // eslint-disable-next-line complexity, max-lines-per-function -- Main-turn streaming and terminal guards share one ordered state owner to prevent duplicate replies.
  private async applyMainRuntimeEvent(event: RuntimeEvent, eventGeneration: number): Promise<void> {
    if (eventGeneration !== this.mainHandleEventGeneration || this.mainHandleAwaitingPostAbortInput) return;
    if (event.type === "log") {
      const sessionFilePath = piSessionFilePathFromLogLine(event.line);
      if (sessionFilePath) await this.patchMainState({ sessionFilePath });
      return;
    }
    if (event.type === "context_usage") {
      await this.patchMainState({ contextUsage: event.usage });
      // Arm the idle timer if usage just crossed the threshold; no-ops mid-turn, re-armed on settle.
      this.scheduleMainIdleCompaction();
      return;
    }
    if (event.type === "tool") {
      // A queued thinking update must not replace the more actionable tool
      // activity after its throttle window expires.
      this.discardQueuedMainThinkingActivity();
      this.showMainActivity({
        kind: "tool",
        toolCallId: event.toolCallId,
        toolName: event.name,
        status: event.status,
        argsPreview: event.argsPreview ?? event.preview,
      });
      return;
    }
    if (event.type === "thinking_delta") {
      this.queueMainThinkingActivity(event.delta);
      return;
    }
    if (event.type === "extension_ui") {
      if (!event.waitsForInput) return;
      const sessionId = typeof event.request.sessionId === "string" && event.request.sessionId.trim()
        ? event.request.sessionId
        : "picky-main";
      const request = mapExtensionUiRequest({ ...event.request, sessionId });
      this.mainPendingExtensionUiRequest = request;
      this.deps.emit("mainExtensionUiRequest", request);
      return;
    }
    if (event.type === "extension_ui_cancelled") {
      if (this.mainPendingExtensionUiRequest?.id === event.requestId) {
        this.mainPendingExtensionUiRequest = undefined;
        this.deps.emit("mainExtensionUiCancelled", event.requestId);
      }
      return;
    }
    if (event.type === "input_delivery") {
      // Pi emits this when a queued followUp begins, which is the first safe
      // point to transfer a completion reply context away from the active turn.
      this.pickleCompletionCoordinator.handleExternalInputDelivery(event);
      return;
    }
    if (event.type === "assistant_delta") {
      if (event.inputId && this.interruptedMainInputIds.has(event.inputId)) {
        logAgentd("main interrupted delta suppressed", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, inputId: event.inputId, deltaChars: event.delta.length, pending: this.interruptedMainInputIds.size });
        return;
      }
      // A new delta means a new turn has started. Re-arm the terminal guard even
      // if the runtime did not emit an explicit `status:"running"` between turns
      // (Pi normally does, but follow-up flows that immediately stream content can
      // skip it). Without this, a Pickle-completion follow-up turn whose `running`
      // is omitted would be silently swallowed by the prior turn's guard.
      this.mainTerminalProcessed = false;
      if (!this.mainFirstAssistantDeltaLogged) {
        const msSincePrompt = this.mainPromptDeliveredAt === undefined
          ? undefined
          : Date.now() - this.mainPromptDeliveredAt;
        logAgentd("main first delta", {
          contextId: this.mainReplyContextId,
          turnId: this.mainTurnId,
          msSincePrompt,
        });
        this.mainFirstAssistantDeltaLogged = true;
      }
      this.mainAssistantDeltaSeen = true;
      this.mainDraft += this.mainVisualNarration.consume(event.delta);
      return;
    }
    if (event.type === "turn_text_complete") {
      // A turn ended with both assistant text and tool calls. Flush the text-so-far
      // as its own quickReply so TTS speaks it before the tool runs, then clear the
      // draft so the next turn's deltas accumulate cleanly. We deliberately do NOT
      // flip `mainIsProcessing` / `mainTerminalProcessed` here — the agent run is
      // not yet done, and the eventual agent_end terminal status still has to flow
      // through the regular terminal handler below.
      if (event.inputId && this.interruptedMainInputIds.has(event.inputId)) {
        logAgentd("main interrupted turn text suppressed", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, inputId: event.inputId, pending: this.interruptedMainInputIds.size });
        return;
      }
      this.mainVisualNarration.finishAssistantDsl();
      let draftSnapshot = this.mainDraft;
      this.mainDraft = "";
      // Prefer the streamed draft so any deltas that the normalizer trimmed
      // out of the final assistant message are preserved, but parse the event
      // payload when a runtime delivers the whole turn without deltas.
      if (!draftSnapshot && !this.mainAssistantDeltaSeen) {
        draftSnapshot = this.mainVisualNarration.consume(event.text);
        this.mainVisualNarration.finishAssistantDsl();
      }
      // Flush any buffered sentence and compute the streamed-narration flag AFTER
      // the no-delta fallback consume, so a whole-turn `turn_text_complete` that
      // emitted chunks via the fallback is not also re-spoken by the final reply.
      this.mainVisualNarration.flushNarrationSentences();
      const didStreamNarration = this.mainVisualNarration.didStreamNarration;
      const reply = cleanFinalAnswer(this.mainVisualNarration.hasAnnotationDslTag ? normalizeDslWhitespace(draftSnapshot) : draftSnapshot);
      if (!reply) {
        logAgentd("main turn text complete with empty draft", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, eventTextChars: event.text.length });
        this.deps.emit("mainTurnSettled", this.mainReplyContextId);
        this.mainVisualNarration.reset();
        this.mainAssistantDeltaSeen = false;
        return;
      }
      logAgentd("main turn text flush", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, textChars: reply.length });
      await this.appendMainMessage("assistant", reply);
      const replyContextId = this.mainReplyContextId;
      if (replyContextId) {
        this.emitQuickReply(replyContextId, reply, projectMainReplyMetadata(replyContextId, this.mainContext, this.deps.pickleSessionIds, this.externalPickleReplyContexts, didStreamNarration));
      }
      this.mainVisualNarration.reset();
      this.mainAssistantDeltaSeen = false;
      return;
    }
    if (event.type === "status") {
      if (event.status === "running") {
        if (event.inputId && this.interruptedMainInputIds.has(event.inputId)) {
          logAgentd("main interrupted running suppressed", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, inputId: event.inputId, pending: this.interruptedMainInputIds.size });
          return;
        }
        this.mainIsProcessing = true;
        this.mainTerminalProcessed = false;
      }
      if (event.compactionCompleted) {
        await this.patchMainState({ contextUsage: undefined });
      }
      if (["completed", "failed", "cancelled"].includes(event.status)) {
        if (event.inputId && this.interruptedMainInputIds.delete(event.inputId)) {
          this.mainTerminalProcessed = false;
          this.mainIsProcessing = true;
          logAgentd("main interrupted terminal suppressed", { status: event.status, contextId: this.mainReplyContextId, turnId: this.mainTurnId, inputId: event.inputId, pending: this.interruptedMainInputIds.size });
          return;
        }
        this.mainIsProcessing = false;
        // Guard A: drop any subsequent terminal events for the same turn (e.g. the
        // `agent_end` that follows `turn_end`). The first one wins.
        if (this.mainTerminalProcessed) return;
        this.mainTerminalProcessed = true;
        this.clearMainActivity();
        // Guard B: snapshot and clear `mainDraft` synchronously before any await,
        // so a racing terminal event that slipped past Guard A (e.g. via a custom
        // runtime that does not flip `mainTerminalProcessed`) cannot read the
        // still-populated draft and double-emit the reply.
        this.mainVisualNarration.finishAssistantDsl();
        this.mainVisualNarration.flushNarrationSentences();
        const didStreamNarration = this.mainVisualNarration.didStreamNarration;
        const draftSnapshot = this.mainDraft;
        this.mainDraft = "";
        logAgentd("main status", { status: event.status, contextId: this.mainReplyContextId, draftChars: draftSnapshot.length });
        const rawReply = cleanFinalAnswer(this.mainVisualNarration.hasAnnotationDslTag ? normalizeDslWhitespace(draftSnapshot) : draftSnapshot) ?? (event.status === "failed" ? event.summary : undefined);
        if (rawReply) {
          const reply = cleanFinalAnswer(rawReply);
          if (reply) {
            // Guard C (defense-in-depth): drop a second emit of the same (contextId, text)
            // within 2s. Guard A already covers `turn_end`+`agent_end`; this covers any path
            // that re-arms `mainTerminalProcessed` between two terminal events for the same
            // turn (listener-leak / out-of-band `assistant_delta` replay). Logged so a
            // regression that genuinely needs to re-emit identical text on the same context
            // within 2s is visible.
            const now = Date.now();
            if (
              this.lastMainQuickReplyText === reply
              && this.lastMainQuickReplyContextId === this.mainReplyContextId
              && now - (this.lastMainQuickReplyAt ?? 0) < 2000
            ) {
              logAgentd("main quick reply suppressed as duplicate within 2s", { contextId: this.mainReplyContextId, textChars: reply.length });
            } else {
              this.lastMainQuickReplyText = reply;
              this.lastMainQuickReplyContextId = this.mainReplyContextId;
              this.lastMainQuickReplyAt = now;
              logAgentd("main quick reply", { contextId: this.mainReplyContextId, textChars: reply.length });
              await this.appendMainMessage("assistant", reply);
              this.emitQuickReply(this.mainReplyContextId, reply, projectMainReplyMetadata(this.mainReplyContextId, this.mainContext, this.deps.pickleSessionIds, this.externalPickleReplyContexts, didStreamNarration));
              this.externalPickleReplyContexts.delete(this.mainReplyContextId);
            }
          }
        } else {
          this.deps.emit("mainTurnSettled", this.mainReplyContextId);
        }
        this.pickleCompletionCoordinator.scheduleLocalDrain();
        this.mainVisualNarration.reset();
        this.mainAssistantDeltaSeen = false;
        // Drain input buffered during a compaction, then re-arm the idle timer if a threshold is met.
        this.drainMainPendingInput();
        this.scheduleMainIdleCompaction();
      }
    }
  }

  private mainNarrationMetadata() {
    return projectMainReplyMetadata(this.mainReplyContextId, this.mainContext, this.deps.pickleSessionIds, this.externalPickleReplyContexts);
  }

  /**
   * Primary-daemon entrypoint for a child completion accepted by the app. The
   * child is the sole bell owner: reaching this method already means the
   * durable completed generation had its bell enabled.
   */
  deliverMainAgentPickleCompletion(
    requestOrSessionId: ExternalPickleCompletionRequest | string,
    legacyPrompt?: string,
    legacyCwd?: string,
  ): Promise<void> {
    return this.pickleCompletionCoordinator.deliverExternalCompletion(requestOrSessionId, legacyPrompt, legacyCwd);
  }

  private activateLocalPickleCompletionContext(sessionId: string): void {
    this.mainReplyContextId = sessionId;
    this.mainTurnOverlayContext = undefined;
    this.mainDraft = "";
    this.mainAssistantDeltaSeen = false;
    this.mainVisualNarration.reset();
  }

  private activateExternalPickleCompletionContext(sessionId: string): void {
    this.activateLocalPickleCompletionContext(sessionId);
    this.externalPickleReplyContexts.add(sessionId);
  }

  private async preparePickyCompletionDelivery(prompt: BuiltPrompt, cwd?: string): Promise<{ handle: RuntimeSessionHandle; sendAsFollowUp: boolean } | undefined> {
    if (this.mainHandle) return { handle: this.mainHandle, sendAsFollowUp: true };
    if (!this.deps.options.mainRuntime) return undefined;
    if (this.mainHandlePromise) return { handle: await this.mainHandlePromise, sendAsFollowUp: true };
    if (this.deps.options.mainRuntime.prewarm) return { handle: await this.ensurePrewarmedMainHandle(cwd ?? process.cwd()), sendAsFollowUp: true };

    const handle = await this.deps.options.mainRuntime.create(prompt, { cwd, sessionId: "picky" });
    this.attachMainHandle(handle);
    return { handle, sendAsFollowUp: false };
  }
}
