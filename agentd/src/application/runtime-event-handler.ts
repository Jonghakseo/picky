import { shouldIgnoreAsyncCycleTerminal } from "../domain/async-work-aggregate.js";
import { extractChangedFilesFromExplicitText, extractSessionLinkArtifacts } from "../artifact-store.js";
import { mergeArtifacts } from "../domain/artifacts.js";
import { fileArtifactFromWrite } from "./file-artifacts.js";
import { mergeChangedFiles, mergeToolFileMutation } from "../domain/changed-files.js";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";
import { isTerminalStatus } from "../domain/session-status.js";
import { cleanFinalAnswer, summaryFromFinalAnswer } from "../domain/session-summary.js";
import { isTransientAgentBusyError } from "../domain/transient-runtime-error.js";
import { settleActiveTools } from "../domain/tool-activity.js";
import { categorizeTool, type ToolCategory } from "../domain/tool-categorizer.js";
import { logAgentd } from "../local-log.js";
import type { PickyActivitySummary, PickyAgentSession, PickyAssistantRunMetadata, PickyCompactionResult, PickyExtensionUiRequest, PickyMessagePresentation, PickySubagentInvocation, PickyToolActivity, PickyToolImage } from "../protocol.js";
import type { RuntimeAutoRetry, RuntimeEvent } from "../runtime/types.js";
import { extensionUiLogLine, extensionUiWaitingSummary, mapExtensionUiRequest } from "./extension-ui-request-mapper.js";

interface RuntimeMessageJournal {
  recordExtensionQuestion(sessionId: string, request: PickyExtensionUiRequest): Promise<void>;
  recordExtensionNotification(sessionId: string, request: PickyExtensionUiRequest): Promise<void>;
  cancelExtensionQuestion(sessionId: string, requestId: string): Promise<void>;
  recordError(sessionId: string, errorMessage: string, options?: { errorContext?: string; presentation?: PickyMessagePresentation }): Promise<void>;
  recordSystemMessage(sessionId: string, text: string, options?: { compaction?: PickyCompactionResult; presentation?: PickyMessagePresentation }): Promise<void>;
  recordExtensionText(sessionId: string, text: string, customType?: string): Promise<void>;
  recordUserText(sessionId: string, text: string, originatedBy: "user" | "main_agent" | "pi_extension"): Promise<void>;
  appendAssistantDelta(sessionId: string, delta: string): void;
  flushAssistantText(sessionId: string, assistantRun?: PickyAssistantRunMetadata): Promise<void>;
  appendThinkingDelta(sessionId: string, delta: string, patch?: { thinkingPreview: string }): Promise<void>;
  runOperation?(sessionId: string, operation: () => Promise<void>): Promise<void>;
  appendThinkingDeltaInOperation?(sessionId: string, delta: string, patch?: { thinkingPreview: string }): Promise<void>;
  flushThinking(sessionId: string): Promise<void>;
  clearAllThinking(sessionId: string): Promise<void>;
  recordActivitySnapshot(sessionId: string, activitySnapshot: PickyActivitySummary): Promise<void>;
  recordSubagentInvocation?(sessionId: string, invocation: PickySubagentInvocation): Promise<void>;
  recordToolImage?(sessionId: string, toolImage: PickyToolImage): Promise<void>;
}

type LiveOutput = "idle" | "writing" | "preparing_tool";
export type LiveOutputSignal = "replyWriting" | "toolCallPreparing";

interface RuntimeEventHandlerDependencies {
  reconcileAsyncWork?(sessionId: string): Promise<void>;
  getSession(sessionId: string): PickyAgentSession;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>, options?: { emitSession?: boolean }): Promise<void>;
  emitToolActivityUpdated(sessionId: string, tool: PickyToolActivity): void;
  emitArtifactUpdated?(sessionId: string, artifact: PickyAgentSession["artifacts"][number]): void;
  updateTodoState(sessionId: string, todoState: PickyAgentSession["todoState"]): Promise<void>;
  updateSubagentRuns?(sessionId: string, update: Extract<RuntimeEvent, { type: "subagent_run_update" }>["update"]): Promise<void>;
  consumeNoTurnRanSessionStateRestore?(sessionId: string): Partial<PickyAgentSession> | undefined;
  appendLog(sessionId: string, line: string): Promise<void>;
  materializeTerminalArtifacts(sessionId: string): Promise<void>;
  /** SessionSupervisor supplies this durable terminal path; unit harnesses may exercise legacy status logic without it. */
  finalizeTerminal?(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): Promise<void>;
  applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void>;
  incrementActivity(sessionId: string, category: ToolCategory): Promise<void>;
  commitTurnActivity(sessionId: string): Promise<void>;
  notifyPickleCompletion(sessionId: string): Promise<void>;
  isPickleSession(sessionId: string): boolean;
  emitExtensionUiRequest(request: PickyExtensionUiRequest): void;
  onInputMessage?(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void>;
  onAssistantTurnStart?(sessionId: string): Promise<void>;
  transformAssistantDelta?(sessionId: string, delta: string): string;
  sanitizeAssistantText?(sessionId: string, text: string): string;
  finishAssistantMessage?(sessionId: string): void;
  finishAssistantRun?(sessionId: string, finalAnswer?: string): void;
  /**
   * Broadcasts a live streaming transition: "replyWriting" while the model streams
   * reply text, "toolCallPreparing" while it streams a tool call's arguments.
   * Never persisted.
   */
  setLiveOutput?(sessionId: string, signal: LiveOutputSignal, active: boolean): void;
  /**
   * Broadcasts Pi's auto-retry wait for a failed model request, or undefined
   * once the model makes progress again or the turn ends. Never persisted.
   */
  setAutoRetry?(sessionId: string, retry: RuntimeAutoRetry | undefined): void;
  messageBuilder: RuntimeMessageJournal;
}

const THINKING_PREVIEW_CHAR_LIMIT = 240;
const THINKING_DRAFT_CHAR_LIMIT = THINKING_PREVIEW_CHAR_LIMIT * 4;
const THINKING_DELTA_FLUSH_INTERVAL_MS = 150;

interface PendingThinkingFlush {
  delta: string;
  preview?: string;
  timer?: ReturnType<typeof setTimeout>;
}

/**
 * Detached runtime-owned transient data required to stage a terminal transaction.
 * It contains no mutable Map/Set references and observing it has no flush or persistence effect.
 */
export interface RuntimeTerminalSnapshot {
  readonly assistantDraft: string;
  readonly thinkingDraft: string;
  readonly thinkingActive: boolean;
  readonly pendingThinkingDelta: string;
  readonly pendingThinkingPreview?: string;
  readonly seenToolCallIds: readonly string[];
  readonly processedTerminalRun: boolean;
}

export class RuntimeEventHandler {
  private readonly assistantDrafts = new Map<string, string>();
  private readonly thinkingDrafts = new Map<string, string>();
  private readonly thinkingActive = new Map<string, boolean>();
  /** Live streaming output per session (reply text or tool-call arguments); never persisted. */
  private readonly liveOutput = new Map<string, LiveOutput>();
  /** Pi's pending auto-retry per session; live only, like `liveOutput`. */
  private readonly autoRetry = new Map<string, RuntimeAutoRetry>();
  private readonly pendingThinkingFlushes = new Map<string, PendingThinkingFlush>();
  private readonly activeThinkingFlushes = new Map<string, Promise<void>>();
  private readonly seenToolCallIds = new Map<string, Set<string>>();
  private readonly failedTerminalEvents = new Map<string, Extract<RuntimeEvent, { type: "status" }>>();
  private readonly processedTerminalRuns = new Set<string>();
  /** First drop per session/status/event type since the last status event; keeps late delta floods to one line. */
  private readonly loggedTerminalDrops = new Map<string, Set<string>>();
  private readonly manualTerminalCompactionStatuses = new Map<string, "cancelled" | "failed">();
  private readonly suppressedManualTerminalCompactions = new Set<string>();

  constructor(private readonly dependencies: RuntimeEventHandlerDependencies) {}

  assertTerminalPersistenceReady(sessionId: string): void {
    if (this.failedTerminalEvents.has(sessionId)) throw new Error("Response persistence blocked; retryAsyncWorkPersistence required");
  }

  async retryTerminalPersistence(sessionId: string, apply: (event: Extract<RuntimeEvent, { type: "status" }>) => Promise<void> = (event) => this.handle(sessionId, event)): Promise<void> {
    const event = this.failedTerminalEvents.get(sessionId);
    if (event) await apply(event);
  }

  resetAssistantDraft(sessionId: string): void {
    this.assertTerminalPersistenceReady(sessionId);
    this.setLiveOutput(sessionId, "idle");
    this.assistantDrafts.set(sessionId, "");
    this.processedTerminalRuns.delete(sessionId);
    this.loggedTerminalDrops.delete(sessionId);
    this.thinkingDrafts.set(sessionId, "");
    this.thinkingActive.set(sessionId, false);
    this.clearPendingThinkingFlush(sessionId);
    this.seenToolCallIds.delete(sessionId);
  }

  /**
   * Reads runtime transients for the dormant W5 terminal planner. This never drains a pending
   * thinking flush, changes duplicate guards, persists a session, or emits a v1 projection.
   */
  terminalSnapshot(sessionId: string): RuntimeTerminalSnapshot {
    const pending = this.pendingThinkingFlushes.get(sessionId);
    return {
      assistantDraft: this.assistantDrafts.get(sessionId) ?? "",
      thinkingDraft: this.thinkingDrafts.get(sessionId) ?? "",
      thinkingActive: this.thinkingActive.get(sessionId) ?? false,
      pendingThinkingDelta: pending?.delta ?? "",
      ...(pending?.preview ? { pendingThinkingPreview: pending.preview } : {}),
      seenToolCallIds: [...(this.seenToolCallIds.get(sessionId) ?? [])],
      processedTerminalRun: this.processedTerminalRuns.has(sessionId),
    };
  }

  /** Individual post-commit reset hooks map one-for-one to the transient ownership manifest. */
  resetTerminalAssistantDraft(sessionId: string): void { this.setLiveOutput(sessionId, "idle"); this.assistantDrafts.set(sessionId, ""); }
  resetTerminalThinkingDraft(sessionId: string): void { this.thinkingDrafts.set(sessionId, ""); }
  resetTerminalThinkingActive(sessionId: string): void { this.thinkingActive.set(sessionId, false); }
  clearTerminalPendingThinkingFlush(sessionId: string): void { this.clearPendingThinkingFlush(sessionId); }
  markTerminalRunProcessed(sessionId: string): void { this.processedTerminalRuns.add(sessionId); }

  beginManualTerminalCompaction(sessionId: string, status: "cancelled" | "failed"): void {
    this.manualTerminalCompactionStatuses.set(sessionId, status);
  }

  clearManualTerminalCompaction(sessionId: string): void {
    this.manualTerminalCompactionStatuses.delete(sessionId);
  }

  suppressManualTerminalCompaction(sessionId: string): void {
    this.suppressedManualTerminalCompactions.add(sessionId);
    this.manualTerminalCompactionStatuses.delete(sessionId);
  }

  finishManualTerminalCompaction(sessionId: string): void {
    this.manualTerminalCompactionStatuses.delete(sessionId);
    this.suppressedManualTerminalCompactions.delete(sessionId);
  }

  // eslint-disable-next-line complexity -- This is the exhaustive runtime-event router; splitting it would duplicate ordering and terminal-state guards.
  async handle(sessionId: string, event: RuntimeEvent): Promise<void> {
    // Async obligations are already committed by their durable owner, including after turn abort.
    if (event.type === "async_task_state" || event.type === "async_task_coverage" || event.type === "async_task_cycle" || event.type === "async_task_idle") return this.dependencies.reconcileAsyncWork?.(sessionId);
    if (event.type === "log") return this.dependencies.appendLog(sessionId, event.line);
    if (event.type === "todo_state") return this.dependencies.updateTodoState(sessionId, event.todoState);
    if (event.type === "subagent_invocation") return this.dependencies.messageBuilder.recordSubagentInvocation?.(sessionId, event.invocation);
    if (event.type === "subagent_run_update") return this.dependencies.updateSubagentRuns?.(sessionId, event.update);
    if (event.type === "status") this.loggedTerminalDrops.delete(sessionId);
    if (event.type === "assistant_turn_start") {
      const session = this.dependencies.getSession(sessionId);
      if (session.status !== "completed" && !(session.asyncWorkSummary && this.processedTerminalRuns.has(sessionId))) return this.logTerminalDrop(sessionId, event.type, session.status);
      if (session.status === "completed") await this.dependencies.onAssistantTurnStart?.(sessionId);
      this.resetAssistantDraft(sessionId);
      return this.dependencies.patchSession(sessionId, { status: "running", lastSummary: "Assistant turn started", finalAnswer: undefined, thinkingPreview: undefined });
    }
    if (event.type === "input_message") {
      const session = this.dependencies.getSession(sessionId);
      if (isTerminalStatus(session.status) && session.status !== "completed" && !hasUnsettledAsyncWork(session)) return this.logTerminalDrop(sessionId, event.type, session.status);
      await this.drainPendingThinkingFlush(sessionId);
      return this.applyInputMessageEvent(sessionId, event);
    }
    // The Pi session name is persisted metadata, not turn output. `/name` and extension renames
    // run without a turn, and async-task Pickles aggregate that no-turn follow-up straight back
    // to a terminal status, so the late-turn-event guard below must not drop it.
    if (event.type === "session_info") return this.applySessionInfoEvent(sessionId, event.name);
    // Context usage is a snapshot of Pi's current transcript, not turn output. Pi emits it right
    // after the terminal status and after no-turn work such as `!bash`, so the late-turn guard
    // below would otherwise freeze the header on a stale value.
    if (event.type === "context_usage") return this.applyContextUsageEvent(sessionId, event.usage);
    const current = this.dependencies.getSession(sessionId);
    // Extension UI is not turn output. A no-turn extension command (e.g. `/delay-list`) on an
    // async-task Pickle runs while the session is aggregated back to `completed`; dropping its
    // dialog would leave the command awaiting an answer the HUD never shows. Late UI after an
    // abort or failure still belongs to the dead turn and stays ignored.
    const acceptsIdleExtensionUi = current.status === "completed" && (event.type === "extension_ui" || event.type === "extension_ui_cancelled");
    if (event.type !== "status" && !acceptsIdleExtensionUi && isTerminalStatus(current.status) && !hasUnsettledAsyncWork(current)) return this.logTerminalDrop(sessionId, event.type, current.status);
    if (event.type === "extension_ui") {
      if (isIgnoredFireAndForgetExtensionUi(event)) return;
      await this.drainPendingThinkingFlush(sessionId);
      this.thinkingActive.set(sessionId, false);
      this.setLiveOutput(sessionId, "idle");
      logAgentd("extension ui event", { sessionId, waitsForInput: event.waitsForInput, method: typeof event.request.method === "string" ? event.request.method : undefined });
      return this.applyExtensionUiEvent(sessionId, event.request, event.waitsForInput);
    }
    if (event.type === "extension_ui_cancelled") return this.applyExtensionUiCancelledEvent(sessionId, event.requestId);
    if (event.type === "assistant_delta") {
      await this.drainPendingThinkingFlush(sessionId);
      this.thinkingActive.set(sessionId, false);
      const delta = this.dependencies.transformAssistantDelta?.(sessionId, event.delta) ?? event.delta;
      if (delta) {
        this.dependencies.messageBuilder.appendAssistantDelta(sessionId, delta);
        this.assistantDrafts.set(sessionId, `${this.assistantDrafts.get(sessionId) ?? ""}${delta}`);
        this.setLiveOutput(sessionId, "writing");
      }
      return;
    }
    if (event.type === "thinking_delta") {
      if (event.delta) this.setAutoRetry(sessionId, undefined);
      return this.applyThinkingEvent(sessionId, event);
    }
    if (event.type === "tool_call_preparing") return this.setLiveOutput(sessionId, "preparing_tool");
    if (event.type === "queue_update") return this.dependencies.applyQueueUpdate(sessionId, event.steering, event.followUp);
    if (event.type === "status") {
      const terminal = ["completed", "failed", "cancelled"].includes(event.status);
      // A terminal event owns its entire staged operation. Draining or clearing drafts before
      // SessionSupervisor saves would leak transient state when that sole save rejects.
      this.setLiveOutput(sessionId, "idle");
      // A retry stays on screen through the next attempt's start; it ends with
      // model progress, a question for the user, or the end of the turn.
      if (event.autoRetry) this.setAutoRetry(sessionId, event.autoRetry);
      else if (event.status !== "running") this.setAutoRetry(sessionId, undefined);
      if (!terminal) {
        await this.drainPendingThinkingFlush(sessionId);
        this.thinkingActive.set(sessionId, false);
      }
      const ignoredTransientBusy = this.isIgnoredTransientBusyStatus(sessionId, event);
      if (!ignoredTransientBusy && event.status === "waiting_for_input") this.dependencies.finishAssistantMessage?.(sessionId);
      const finalizedBefore = this.dependencies.getSession(sessionId).asyncWorkSummary?.episode?.finalizedCycleId;
      try {
        await this.applyStatusEvent(sessionId, event);
        const retained = this.failedTerminalEvents.get(sessionId);
        if (terminal && !event.noTurnRan && retained?.cycleId === event.cycleId) this.failedTerminalEvents.delete(sessionId);
      } catch (error) {
        if (terminal && !event.noTurnRan && this.dependencies.getSession(sessionId).asyncWorkSummary) this.failedTerminalEvents.set(sessionId, event);
        throw error;
      }
      const sessionAfter = this.dependencies.getSession(sessionId);
      const finalizedCycle = event.cycleId !== undefined && event.cycleId !== finalizedBefore
        && sessionAfter.asyncWorkSummary?.episode?.finalizedCycleId === event.cycleId;
      if (!ignoredTransientBusy && terminal && !event.noTurnRan && (finalizedCycle || (!sessionAfter.asyncWorkSummary && isTerminalStatus(sessionAfter.status)))) {
        this.dependencies.finishAssistantMessage?.(sessionId);
        this.dependencies.finishAssistantRun?.(sessionId, event.finalAnswer);
      }
      return;
    }
    if (event.type === "session_replaced") return;
    if (event.type === "input_delivery") return;
    // turn_text_complete is a main-runtime-only signal used by SessionSupervisor.applyMainRuntimeEvent
    // to flush per-turn assistant text as a separate quickReply for TTS playback. Pickle session
    // runtimes already flush assistant text via assistant_delta + terminal status, so this event
    // has no meaning here and must be ignored before falling through to applyToolEvent.
    if (event.type === "turn_text_complete") return;
    // The supervisor turns this into a resourcesReloaded broadcast before delegating here.
    if (event.type === "resources_reloaded" || event.type === "resource_reload_fence_released") return;
    await this.drainPendingThinkingFlush(sessionId);
    this.setAutoRetry(sessionId, undefined);
    return this.applyToolEvent(sessionId, event);
  }

  private async applyInputMessageEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void> {
    if (event.originatedBy === "internal") return;

    // Pi extensions use custom messages for displayable context (such as subagent status) as
    // well as turn-triggering input. Unlike role=user, custom messages start a turn only when
    // the adapter observed authoritative Pi runtime activity. Preserve terminal state and
    // completion tracking for idle custom messages while still showing them in the journal.
    const startsTurn = event.role === "user" || event.turnActive === true;
    if (!startsTurn) {
      await this.recordVisibleInputMessage(sessionId, event);
      return;
    }

    await this.dependencies.onInputMessage?.(sessionId, event);
    this.dependencies.finishAssistantMessage?.(sessionId);
    await this.dependencies.messageBuilder.flushAssistantText(sessionId);
    await this.dependencies.messageBuilder.flushThinking(sessionId);
    await this.dependencies.commitTurnActivity(sessionId);
    await this.recordVisibleInputMessage(sessionId, event);
    this.resetAssistantDraft(sessionId);
    await this.dependencies.patchSession(sessionId, { status: "running", lastSummary: event.role === "custom" ? "Pi extension message started" : "Pi extension follow-up started", finalAnswer: undefined, thinkingPreview: undefined });
  }

  private async recordVisibleInputMessage(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void> {
    if (event.display === false || event.originatedBy === "internal") return;
    if (event.role === "custom") {
      await this.dependencies.messageBuilder.recordExtensionText(sessionId, event.text, event.customType);
      return;
    }
    await this.dependencies.messageBuilder.recordUserText(
      sessionId,
      event.text,
      event.originatedBy === "pi_extension" ? "pi_extension" : event.originatedBy,
    );
  }

  /**
   * Terminal guards drop late turn output on purpose, but a wrong guard is otherwise invisible
   * (see the /delay-list dialog that never reached the HUD). Record what was dropped so a missing
   * UI can be traced from agentd.stdout.log.
   */
  private logTerminalDrop(sessionId: string, eventType: string, status: string): void {
    const logged = this.loggedTerminalDrops.get(sessionId) ?? new Set<string>();
    const key = `${status}:${eventType}`;
    if (logged.has(key)) return;
    logged.add(key);
    this.loggedTerminalDrops.set(sessionId, logged);
    logAgentd("runtime event dropped after terminal", { sessionId, eventType, status });
  }

  /** Journals the compaction outcome once per compaction, in Picky's own voice. */
  private async recordCompactionOutcomeMessages(
    sessionId: string,
    currentSession: PickyAgentSession,
    event: Extract<RuntimeEvent, { type: "status" }>,
  ): Promise<void> {
    if (event.compactionCompleted && !hasLatestCompactCompletionMessage(currentSession)) {
      const overflow = event.compactionReason === "overflow";
      await this.dependencies.messageBuilder.recordSystemMessage(
        sessionId,
        overflow ? "Session compacted after context overflow" : "Session compacted",
        {
          ...(event.compaction ? { compaction: event.compaction } : {}),
          presentation: { code: overflow ? "sessionCompactedAfterOverflow" : "sessionCompacted" },
        },
      );
    }
    if (event.compactionFailed && !hasLatestCompactFailureMessage(currentSession)) {
      await this.dependencies.messageBuilder.recordSystemMessage(
        sessionId,
        compactFailureMessage(event.summary, currentSession.contextUsage),
        { presentation: compactFailurePresentation(event.summary, currentSession.contextUsage) },
      );
    }
  }

  /** Closing journal entry for a turn that failed or was cancelled. */
  private async recordTerminalOutcomeMessage(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): Promise<void> {
    if (event.status === "failed" && !event.compactionFailed) {
      // A runtime summary is the agent's own wording and stays verbatim; only the no-detail
      // fallback is Picky's sentence to localize.
      await this.dependencies.messageBuilder.recordError(
        sessionId,
        event.summary ?? "Agent failed",
        event.summary ? {} : { presentation: { code: "agentFailedWithoutDetail" } },
      );
    }
    if (event.status === "cancelled") {
      await this.dependencies.messageBuilder.recordSystemMessage(sessionId, "Cancelled by user", { presentation: { code: "sessionCancelledByUser" } });
    }
  }

  private async applyContextUsageEvent(sessionId: string, usage: { tokens: number | null; contextWindow: number; percent: number | null } | undefined): Promise<void> {
    const current = this.dependencies.getSession(sessionId).contextUsage;
    if (sameContextUsage(current, usage)) return;
    await this.dependencies.patchSession(sessionId, { contextUsage: usage });
  }

  private async applySessionInfoEvent(sessionId: string, name: string): Promise<void> {
    const trimmed = name.trim();
    if (!trimmed) return;
    const session = this.dependencies.getSession(sessionId);
    if (session.title === trimmed) return;
    logAgentd("session info name", { sessionId, previousTitle: session.title, name: trimmed });
    await this.dependencies.patchSession(sessionId, { title: trimmed });
  }

  // eslint-disable-next-line complexity -- Status transitions intentionally stay with their single session-state owner to preserve terminal and compaction invariants.
  private async applyStatusEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): Promise<void> {
    logAgentd("session status", { sessionId, status: event.status, summaryChars: event.summary?.length });
    const terminal = ["completed", "failed", "cancelled"].includes(event.status);
    // Prefer the final assistant message carried by the runtime event (Pi turn_end/agent_end)
    // over the streamed assistant_delta accumulator, which would otherwise concatenate every
    // intermediate message in a multi-turn ReAct loop. Failed runtime events often carry only a
    // diagnostic summary while the draft is merely partial output, so do not promote the draft to
    // finalAnswer for failures unless Pi explicitly provides event.finalAnswer.
    const sanitizedFinalAnswer = event.finalAnswer === undefined
      ? undefined
      : this.dependencies.sanitizeAssistantText?.(sessionId, event.finalAnswer) ?? event.finalAnswer;
    const explicitFinalAnswer = cleanFinalAnswer(sanitizedFinalAnswer);
    const finalAnswer = explicitFinalAnswer ?? (terminal ? (event.status === "failed" ? undefined : cleanFinalAnswer(this.assistantDrafts.get(sessionId))) : undefined);
    const currentSession = this.dependencies.getSession(sessionId);
    const manualTerminalCompactionStatus = this.manualTerminalCompactionStatuses.get(sessionId);
    const isReasonlessManualCompactionFailure = event.status === "failed"
      && event.noTurnRan === true
      && /^\/compact (is not supported|failed:)/.test(event.summary ?? "");
    const isManualTerminalCompactionEvent = manualTerminalCompactionStatus !== undefined
      && ((event.compactionReason === "manual" && (event.compactionStarted || event.compactionCompleted || event.compactionFailed || (event.noTurnRan && terminal)))
        || isReasonlessManualCompactionFailure);
    if (this.suppressedManualTerminalCompactions.has(sessionId) && (event.compactionReason === "manual" || isReasonlessManualCompactionFailure)) {
      logAgentd("manual compaction status ignored after abort", { sessionId, status: event.status });
      return;
    }
    if (manualTerminalCompactionStatus !== undefined && !isManualTerminalCompactionEvent) {
      logAgentd("non-manual status ignored while terminal manual compaction is active", { sessionId, status: event.status, compactionReason: event.compactionReason });
      return;
    }
    if (this.isIgnoredTransientBusyStatus(sessionId, event)) {
      logAgentd("session transient busy status ignored", { sessionId, summary: event.summary });
      await this.dependencies.appendLog(sessionId, `runtime busy ignored: ${event.summary ?? "Agent is already processing"}`);
      return;
    }
    // Once a session has reached a terminal status, ignore any subsequent runtime status
    // events. Stragglers (delayed agent_start emitting `running` after abort, late
    // `waiting_for_input` from a now-cancelled extension dialog, etc.) would otherwise
    // resurrect the session out of `cancelled`/`failed`/`completed` and re-open the HUD
    // loading state. Completed sessions are the exception: Pi may auto-compact immediately after a
    // successful terminal agent_end (threshold compaction), and the HUD should still show that brief state.
    // A manual compaction explicitly requested from a cancelled/failed session is also surfaced,
    // then restored to its original terminal state when it finishes.
    const terminalCompactionUpdate = (currentSession.status === "completed" && (event.compactionStarted || event.compactionCompleted || event.compactionFailed))
      || isManualTerminalCompactionEvent;
    // The optional Pi terminal tail can observe the assistant JSONL entry a few milliseconds
    // before the runtime emits its terminal status and pre-patch this session to completed. That
    // status is observational only: the runtime event still owns assistant-draft flush, finalAnswer,
    // artifacts, and completion notification. Process the first matching completed runtime event
    // even when the tail won the race, while continuing to ignore the duplicate turn_end/agent_end
    // terminal event and any late completion after cancellation/failure.
    const precompletedRuntimeTerminal = currentSession.status === "completed"
      && event.status === "completed"
      && !this.processedTerminalRuns.has(sessionId);
    if (terminal && shouldIgnoreAsyncCycleTerminal(currentSession, event.cycleId)) return;
    if (isTerminalStatus(currentSession.status) && !hasUnsettledAsyncWork(currentSession) && !terminalCompactionUpdate && !precompletedRuntimeTerminal) {
      if (event.noTurnRan) this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
      return this.logTerminalDrop(sessionId, `status:${event.status}`, currentSession.status);
    }
    if (event.noTurnRan && event.preserveSessionState) {
      const restore = this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
      if (restore) await this.dependencies.patchSession(sessionId, restore);
      return;
    }
    // Compaction terminal markers restore the active turn rather than finalizing it; preserve
    // their established running-state path until compaction has actually completed its retry.
    if (terminal && !event.noTurnRan && !event.compactionCompleted && !event.compactionFailed && this.dependencies.finalizeTerminal) {
      await this.dependencies.finalizeTerminal(sessionId, {
        ...event,
        ...(sanitizedFinalAnswer === undefined ? {} : { finalAnswer: sanitizedFinalAnswer }),
      });
      return;
    }

    if (terminal) this.processedTerminalRuns.add(sessionId);

    await this.recordCompactionOutcomeMessages(sessionId, currentSession, event);

    const finishesManualTerminalCompaction = isManualTerminalCompactionEvent
      && (event.compactionCompleted || event.compactionFailed || (event.noTurnRan && terminal));
    // A running compaction_end means Pi already has queued input to continue. The old terminal
    // status belongs to the pre-compaction turn and must not overwrite that new turn. Still clear
    // the restoration guard below so the following agent_start status can reach the HUD.
    const restoreManualTerminalStatus = finishesManualTerminalCompaction && event.status !== "running";
    const patch: Partial<PickyAgentSession> = {
      status: restoreManualTerminalStatus ? manualTerminalCompactionStatus : event.status,
      lastSummary: finalAnswer ? summaryFromFinalAnswer(finalAnswer) : event.summary,
    };
    if (event.assistantRun) patch.currentAssistantRun = event.assistantRun;
    // Post-compaction token count is unknown until the next model response. Mirror the
    // main agent runtime (session-supervisor.ts applyMainRuntimeEvent on compactionCompleted)
    // so the Pickle header context bar drops to "?%" rather than staying pinned on the
    // pre-compaction value. We rely on a follow-up runtime context_usage event from
    // pi-sdk-runtime's emitContextUsageSnapshot, but that can be stale if a session_compact
    // extension hook appended assistant-like entries between appendCompaction and
    // compaction_end, so reset defensively here. compactionFailed intentionally preserves
    // the existing usage (see the auto-compaction failure test in session-supervisor.test.ts).
    if (event.compactionCompleted && currentSession.contextUsage) {
      patch.contextUsage = { ...currentSession.contextUsage, tokens: null, percent: null };
    }
    if (terminal || event.status === "waiting_for_input" || finalAnswer) {
      await this.dependencies.messageBuilder.flushAssistantText(sessionId, event.assistantRun);
      if (terminal) {
        await this.dependencies.messageBuilder.clearAllThinking(sessionId);
      } else {
        await this.dependencies.messageBuilder.flushThinking(sessionId);
      }
      await this.dependencies.commitTurnActivity(sessionId);
    }
    if (terminal) {
      if (!event.noTurnRan) await this.recordTerminalOutcomeMessage(sessionId, event);
      if (currentSession.pendingExtensionUiRequest) {
        await this.dependencies.messageBuilder.cancelExtensionQuestion(sessionId, currentSession.pendingExtensionUiRequest.id);
        patch.pendingExtensionUiRequest = undefined;
      }
      patch.thinkingPreview = undefined;
      patch.tools = settleActiveTools(currentSession.tools, terminalToolPreview(event.status));
    }
    if (finalAnswer) {
      patch.finalAnswer = finalAnswer;
      patch.changedFiles = mergeChangedFiles(currentSession.changedFiles, extractChangedFilesFromExplicitText(finalAnswer));
    }
    const flushedAssistantText = finalAnswer ?? cleanFinalAnswer(this.assistantDrafts.get(sessionId));
    // Surface PR/GitHub/Slack/etc. link badges in the HUD as soon as the assistant message that
    // contains the URL is committed for a non-terminal status. Previously `materializeTerminalArtifacts`
    // only ran on completed/failed/cancelled, so a `/skill:create-pr` follow-up that left the
    // session at `waiting_for_input` showed the PR URL in the bubble but no badge in the Links
    // row until either a new patch refreshed the `gh pr view` cache or the session eventually
    // terminated. Terminal events still flow through materializeTerminalArtifacts below so the
    // `artifact` listener fires there.
    if (!terminal && event.status === "waiting_for_input" && flushedAssistantText) {
      const existingArtifacts = patch.artifacts ?? currentSession.artifacts;
      const linkArtifacts = extractSessionLinkArtifacts(flushedAssistantText).filter((artifact) => !existingArtifacts.some((existing) => existing.url === artifact.url));
      if (linkArtifacts.length > 0) patch.artifacts = mergeArtifacts(existingArtifacts, linkArtifacts);
    }
    await this.dependencies.patchSession(sessionId, patch);
    if (finishesManualTerminalCompaction) this.manualTerminalCompactionStatuses.delete(sessionId);
    if (terminal) {
      this.assistantDrafts.set(sessionId, "");
      this.thinkingDrafts.set(sessionId, "");
      this.thinkingActive.set(sessionId, false);
      // Synthetic completions (Pi `/slash` handlers, `input` handlers returning `handled`) flip
      // the session out of the loading state but did not run any agent turn. Re-materializing
      // terminal artifacts would overwrite the previous session report with empty content, and
      // notifying Picky would deliver a bogus "Pickle session finished" message even
      // though nothing actually completed. Skip both for `noTurnRan` events.
      if (event.noTurnRan) {
        this.dependencies.consumeNoTurnRanSessionStateRestore?.(sessionId);
        return;
      }
      await this.dependencies.materializeTerminalArtifacts(sessionId);
      if (this.dependencies.isPickleSession(sessionId)) await this.dependencies.notifyPickleCompletion(sessionId);
    }
  }

  private isIgnoredTransientBusyStatus(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): boolean {
    return this.dependencies.getSession(sessionId).status === "running"
      && event.status === "failed"
      && !event.compactionFailed
      && isTransientAgentBusyError(event.summary);
  }

  /**
   * Reports what the model is streaming, the only thing that separates "writing
   * a reply" and "preparing a tool call" from "thinking" in the HUD presence
   * line: assistant deltas are buffered and journaled only when the segment
   * ends, and tool-call arguments stream for seconds before the tool runs.
   *
   * These are live broadcasts, not session patches. Streaming must stay free
   * of durable session writes (see the terminal durability contract), and a
   * finished turn's streaming state means nothing after a reconnect. The two
   * states are mutually exclusive, and only transitions are reported, never one
   * notification per delta.
   */
  private setLiveOutput(sessionId: string, next: LiveOutput): void {
    const previous = this.liveOutput.get(sessionId) ?? "idle";
    if (previous === next) return;
    this.liveOutput.set(sessionId, next);
    // Clear the outgoing signal before raising the incoming one so the app never
    // holds both at once.
    if (previous !== "idle") this.dependencies.setLiveOutput?.(sessionId, previous === "writing" ? "replyWriting" : "toolCallPreparing", false);
    if (next !== "idle") this.dependencies.setLiveOutput?.(sessionId, next === "writing" ? "replyWriting" : "toolCallPreparing", true);
    if (next !== "idle") this.setAutoRetry(sessionId, undefined);
  }

  /** Reports only changes, like `setLiveOutput`. */
  private setAutoRetry(sessionId: string, next: RuntimeAutoRetry | undefined): void {
    const previous = this.autoRetry.get(sessionId);
    if (!previous && !next) return;
    if (previous && next && JSON.stringify(previous) === JSON.stringify(next)) return;
    if (next) this.autoRetry.set(sessionId, next); else this.autoRetry.delete(sessionId);
    this.dependencies.setAutoRetry?.(sessionId, next);
  }

  private async applyThinkingEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "thinking_delta" }>): Promise<void> {
    if (!event.delta) return;
    this.setLiveOutput(sessionId, "idle");

    const shouldIncrementThinking = this.thinkingActive.get(sessionId) !== true;
    if (shouldIncrementThinking) this.thinkingActive.set(sessionId, true);

    const previousDraft = this.thinkingDrafts.get(sessionId) ?? "";
    if (previousDraft.length >= THINKING_DRAFT_CHAR_LIMIT) {
      if (shouldIncrementThinking) await this.dependencies.incrementActivity(sessionId, "thinking");
      return;
    }

    const nextDraft = sliceUtf16Safe(`${previousDraft}${event.delta}`, THINKING_DRAFT_CHAR_LIMIT);
    const acceptedDelta = nextDraft.slice(previousDraft.length);
    this.thinkingDrafts.set(sessionId, nextDraft);

    if (acceptedDelta) this.queueThinkingDeltaFlush(sessionId, acceptedDelta, compactThinkingPreview(nextDraft));
    if (shouldIncrementThinking) await this.dependencies.incrementActivity(sessionId, "thinking");
  }

  private queueThinkingDeltaFlush(sessionId: string, delta: string, preview: string | undefined): void {
    const pending = this.pendingThinkingFlushes.get(sessionId) ?? { delta: "" };
    pending.delta += delta;
    pending.preview = preview;
    if (!pending.timer) {
      pending.timer = setTimeout(() => {
        const current = this.pendingThinkingFlushes.get(sessionId);
        if (current) current.timer = undefined;
        void this.flushPendingThinking(sessionId).catch((error) => {
          logAgentd("thinking delta flush failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
        });
      }, THINKING_DELTA_FLUSH_INTERVAL_MS);
      pending.timer.unref?.();
    }
    this.pendingThinkingFlushes.set(sessionId, pending);
  }

  private async drainPendingThinkingFlush(sessionId: string): Promise<void> {
    do {
      await this.flushPendingThinking(sessionId);
      await (this.activeThinkingFlushes.get(sessionId) ?? Promise.resolve());
    } while (this.pendingThinkingFlushes.has(sessionId));
  }

  private async flushPendingThinking(sessionId: string): Promise<void> {
    // The terminal transaction occupies this same builder chain. Deferring pending consumption
    // until this operation owns its slot prevents a timer that fires during terminal save from
    // capturing the pre-terminal journal and persisting it after the terminal projection.
    const operation = async () => this.flushPendingThinkingInOperation(sessionId);
    const flush = this.dependencies.messageBuilder.runOperation
      ? this.dependencies.messageBuilder.runOperation(sessionId, operation)
      : operation();
    this.activeThinkingFlushes.set(sessionId, flush);
    try {
      await flush;
    } finally {
      if (this.activeThinkingFlushes.get(sessionId) === flush) this.activeThinkingFlushes.delete(sessionId);
    }
  }

  private async flushPendingThinkingInOperation(sessionId: string): Promise<void> {
    const pending = this.pendingThinkingFlushes.get(sessionId);
    if (!pending) return;

    if (pending.timer) clearTimeout(pending.timer);
    this.pendingThinkingFlushes.delete(sessionId);
    const currentPreview = this.dependencies.getSession(sessionId).thinkingPreview;
    // Preserve the previous truthy-preview semantics: whitespace-only thinking deltas still
    // journal their text but must not create or clear the reconnect preview.
    const thinkingPreview = pending.preview && pending.preview !== currentPreview ? pending.preview : undefined;
    if (pending.delta) {
      // Persist the thinking message and reconnect preview in one full-session save. The
      // message builder emits its granular append/replace event only after that save succeeds.
      const patch = thinkingPreview ? { thinkingPreview } : undefined;
      if (this.dependencies.messageBuilder.appendThinkingDeltaInOperation) {
        await this.dependencies.messageBuilder.appendThinkingDeltaInOperation(sessionId, pending.delta, patch);
      } else {
        await this.dependencies.messageBuilder.appendThinkingDelta(sessionId, pending.delta, patch);
      }
    } else if (thinkingPreview) {
      // Defensive fallback for a preview-only pending flush. Normal queueing always supplies
      // an accepted delta, so this path intentionally keeps the existing write-through patch.
      await this.dependencies.patchSession(sessionId, { thinkingPreview }, { emitSession: false });
    }
  }

  private clearPendingThinkingFlush(sessionId: string): void {
    const pending = this.pendingThinkingFlushes.get(sessionId);
    if (pending?.timer) clearTimeout(pending.timer);
    this.pendingThinkingFlushes.delete(sessionId);
  }

  private async applyExtensionUiEvent(sessionId: string, rawRequest: Record<string, unknown>, waitsForInput: boolean): Promise<void> {
    const request = mapExtensionUiRequest(rawRequest);
    if (this.dependencies.getSession(sessionId).asyncWorkSummary && request.sessionId !== sessionId) return;
    if (!waitsForInput) {
      if (request.method === "setWidget") return;
      await this.dependencies.appendLog(sessionId, extensionUiLogLine(request));
      if (request.method === "notify") {
        // Do NOT flush the in-flight assistant draft here. notify is a background
        // extension event (e.g. observational memory hook) that runs in parallel
        // with the streamed answer; flushing would commit whatever has streamed so
        // far as an agent_text bubble and force the remaining deltas into a fresh
        // bubble, visibly cutting the response in half (see Picky bug: notify
        // bisects assistant reply). The notify message is appended at its own
        // timestamp, and the assistant draft keeps accumulating until the next
        // real boundary (tool call / terminal status) flushes it as a single
        // agent_text bubble below the notification.
        await this.dependencies.messageBuilder.recordExtensionNotification(sessionId, request);
      }
      if (request.method === "set_editor_text") this.dependencies.emitExtensionUiRequest(request);
      return;
    }
    this.dependencies.finishAssistantMessage?.(sessionId);
    await this.dependencies.messageBuilder.flushAssistantText(sessionId);
    await this.dependencies.messageBuilder.flushThinking(sessionId);
    await this.dependencies.commitTurnActivity(sessionId);
    await this.dependencies.patchSession(sessionId, { status: "waiting_for_input", pendingExtensionUiRequest: request, lastSummary: extensionUiWaitingSummary(request) });
    await this.dependencies.messageBuilder.recordExtensionQuestion(sessionId, request);
    this.dependencies.emitExtensionUiRequest(request);
  }

  private async applyExtensionUiCancelledEvent(sessionId: string, requestId: string): Promise<void> {
    const current = this.dependencies.getSession(sessionId);
    if (current.pendingExtensionUiRequest?.id !== requestId) return;
    await this.dependencies.messageBuilder.cancelExtensionQuestion(sessionId, requestId);
    this.setLiveOutput(sessionId, "idle");
    const patch: Partial<PickyAgentSession> = { pendingExtensionUiRequest: undefined, thinkingPreview: undefined };
    if (current.status === "waiting_for_input") {
      patch.status = "running";
      patch.lastSummary = "Extension UI cancelled";
    }
    await this.dependencies.patchSession(sessionId, patch);
  }

  // eslint-disable-next-line complexity -- Tool lifecycle ordering is kept atomic so late-event and activity accounting guards cannot drift apart.
  private async applyToolEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "tool" }>): Promise<void> {
    this.thinkingActive.set(sessionId, false);
    this.setLiveOutput(sessionId, "idle");
    const seen = this.seenToolCallIds.get(sessionId) ?? new Set<string>();
    const shouldIncrementActivity = event.status === "running" && !seen.has(event.toolCallId);
    if (shouldIncrementActivity) {
      seen.add(event.toolCallId);
      this.seenToolCallIds.set(sessionId, seen);
    }
    if (event.status === "running") {
      this.dependencies.finishAssistantMessage?.(sessionId);
      await this.dependencies.messageBuilder.flushAssistantText(sessionId);
      await this.dependencies.messageBuilder.flushThinking(sessionId);
    }
    if (shouldIncrementActivity) await this.dependencies.incrementActivity(sessionId, categorizeTool(event.name));

    const session = this.dependencies.getSession(sessionId);
    const previous = session.tools.find((tool) => tool.toolCallId === event.toolCallId);
    // Defensive: a late `running` event for an already-settled tool would otherwise downgrade
    // the terminal status back to `running`, where settleActiveTools later flips it to `failed`.
    // The runtime chain in session-supervisor serializes events so this should not happen, but
    // keep the guard for resumed sessions or other replay paths.
    if (event.status === "running" && previous && (previous.status === "succeeded" || previous.status === "failed")) {
      logAgentd("tool activity (late running ignored)", { sessionId, tool: event.name, previousStatus: previous.status });
      return;
    }
    const tools = session.tools.filter((tool) => tool.toolCallId !== event.toolCallId);
    const subagentSummary = event.subagentSummary ?? previous?.subagentSummary;
    const nextTool: PickyToolActivity = {
      ...previous,
      toolCallId: event.toolCallId,
      name: event.name,
      status: event.status,
      preview: event.preview,
      argsPreview: event.argsPreview ?? previous?.argsPreview,
      resultPreview: event.resultPreview ?? previous?.resultPreview,
      resultJSONPreview: event.resultJSONPreview ?? previous?.resultJSONPreview,
      ...(event.resultPreviewTruncated || previous?.resultPreviewTruncated ? { resultPreviewTruncated: true } : {}),
      ...(event.resultPreviewRepaired || previous?.resultPreviewRepaired ? { resultPreviewRepaired: true } : {}),
      ...(subagentSummary ? { subagentSummary } : {}),
      startedAt: previous?.startedAt ?? new Date().toISOString(),
      endedAt: event.status === "running" ? previous?.endedAt : new Date().toISOString(),
    };
    tools.push(nextTool);
    logAgentd("tool activity", { sessionId, tool: event.name, status: event.status, previewChars: event.preview?.length });
    await this.dependencies.patchSession(sessionId, { tools }, { emitSession: false });
    this.dependencies.emitToolActivityUpdated(sessionId, nextTool);
    if (event.status === "succeeded" && event.imagePath) {
      await this.dependencies.messageBuilder.recordToolImage?.(sessionId, {
        toolCallId: event.toolCallId,
        toolName: event.name,
        path: event.imagePath,
        ...(event.imageMimeType ? { mimeType: event.imageMimeType } : {}),
      });
    }
    if (event.status !== "succeeded" || !event.filePath) return;
    if (event.name === "write" || event.name === "edit") {
      const current = this.dependencies.getSession(sessionId);
      const changedFiles = mergeToolFileMutation(current.changedFiles, { filePath: event.filePath, fileExistedBefore: event.fileExistedBefore }, current.cwd);
      if (changedFiles !== current.changedFiles) await this.dependencies.patchSession(sessionId, { changedFiles });
    }
    if (event.name !== "write") return;
    const currentArtifacts = this.dependencies.getSession(sessionId).artifacts;
    const existingUpdatedAt = currentArtifacts.find((existing) => existing.kind === "file" && existing.path === event.filePath)?.updatedAt;
    const artifact = fileArtifactFromWrite({
      filePath: event.filePath,
      fileExistedBefore: event.fileExistedBefore,
      now: new Date().toISOString(),
      existingUpdatedAt,
    });
    if (!artifact) return;
    await this.dependencies.patchSession(sessionId, { artifacts: mergeArtifacts(currentArtifacts, [artifact]) });
    this.dependencies.emitArtifactUpdated?.(sessionId, artifact);
  }
}

function isIgnoredFireAndForgetExtensionUi(event: Extract<RuntimeEvent, { type: "extension_ui" }>): boolean {
  return !event.waitsForInput && event.request.method === "setWidget";
}

function sameContextUsage(
  a: { tokens: number | null; contextWindow: number; percent: number | null } | undefined,
  b: { tokens: number | null; contextWindow: number; percent: number | null } | undefined,
): boolean {
  if (a === b) return true;
  if (!a || !b) return false;
  return a.tokens === b.tokens && a.contextWindow === b.contextWindow && a.percent === b.percent;
}

function compactThinkingPreview(value: string): string {
  const compact = value.replace(/\s+/g, " ").trim();
  if (compact.length <= THINKING_PREVIEW_CHAR_LIMIT) return compact;
  return `${sliceUtf16Safe(compact, THINKING_PREVIEW_CHAR_LIMIT - 1)}…`;
}

function hasLatestCompactCompletionMessage(session: PickyAgentSession): boolean {
  const messages = session.messages ?? [];
  const message = messages[messages.length - 1];
  if (message?.kind !== "system") return false;
  const normalized = message.text?.trim().toLowerCase();
  return normalized === "session compacted" || normalized === "session compacted after context overflow";
}

function hasLatestCompactFailureMessage(session: PickyAgentSession): boolean {
  const messages = session.messages ?? [];
  const message = messages[messages.length - 1];
  if (message?.kind !== "system") return false;
  return message.text?.trim().toLowerCase().startsWith("auto-compaction failed") === true;
}

function compactFailureMessage(summary: string | undefined, usage: PickyAgentSession["contextUsage"]): string {
  const detail = compactFailureDetail(summary);
  const usageText = usage ? ` Current usage remains ${formatTokenCount(usage.tokens)}/${formatTokenCount(usage.contextWindow)} tokens.` : "";
  return `Auto-compaction failed\n\n${detail}\n\nContext was not reduced.${usageText}`;
}

/** Same failure as `compactFailureMessage`, as parts the app can render in its own language. */
function compactFailurePresentation(summary: string | undefined, usage: PickyAgentSession["contextUsage"]): PickyMessagePresentation {
  return {
    code: "sessionCompactionFailed",
    params: {
      detail: compactFailureDetail(summary),
      ...(usage ? { contextTokens: usage.tokens, contextWindowTokens: usage.contextWindow } : {}),
    },
  };
}

function compactFailureDetail(summary: string | undefined): string {
  const trimmed = summary?.trim() || "Summarization failed.";
  const withoutPrefix = trimmed.replace(/^auto-compaction failed:\s*/i, "").trim();
  return sliceUtf16Safe(withoutPrefix || trimmed, 500);
}

function formatTokenCount(value: number | null | undefined): string {
  return typeof value === "number" ? Math.round(value).toLocaleString("en-US") : "unknown";
}

function terminalToolPreview(status: string): string {
  if (status === "cancelled") return "Tool stopped because the session was cancelled.";
  if (status === "failed") return "Tool stopped because the session failed.";
  return "Tool stopped when the session ended.";
}

/** Tracked blocked work may still have a live response or a result-consumption cycle. */
function hasUnsettledAsyncWork(session: PickyAgentSession): boolean {
  return session.asyncWorkSummary !== undefined && session.asyncWorkSummary.episode?.settled !== true;
}
