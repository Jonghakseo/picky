/* eslint-disable max-lines -- SessionSupervisor remains the single mutable session owner; scripts/check-architecture-rules.js enforces its no-growth ratchet. */
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { extractSessionLinkArtifacts } from "./artifact-store.js";
import { ArtifactMaterializer } from "./application/artifact-materializer.js";
import { MainAgentCoordinator } from "./application/main-agent-coordinator.js";
import { FollowUpLifecycleDiagnostics } from "./application/follow-up-lifecycle-diagnostics.js";
import { disposeRuntimeHandle } from "./application/runtime-handle-disposal.js";
import type { ExternalPickleCompletionRequest } from "./application/pickle-completion-coordinator.js";
import type { ReloadPluginsSummary, SessionSupervisorOptions } from "./application/session-supervisor-options.js";
import { RuntimeEventHandler } from "./application/runtime-event-handler.js";
import { emitTerminalV1Compatibility, finalizeTerminalOperation, projectionCommitRevision, publishSessionProjectionCommit, sessionProjectionCommitMutations, type SessionCommit, type TerminalDurableCommitDependencies } from "./application/terminal-durable-commit.js";
import { SubagentRunUpdater } from "./application/subagent-run-updater.js";
import { TerminalManualCompactionCoordinator } from "./application/terminal-manual-compaction.js";
import { makeAnnotationOverlayRequestForContext, makePointerOverlayRequestForContext, type MainTurnOverlayContext } from "./application/overlay-context-resolver.js";
import { awaitPendingRuntimeHandle, createPendingRuntimeHandle } from "./application/pending-runtime-handle.js";
import { readRecentPinnedSourceState, snapshotPiSessionFile } from "./application/pinned-session-source.js";
import { TerminalSessionCoordinator } from "./application/terminal-session-coordinator.js";
import { summarizeExtensionUiAnswer } from "./application/extension-ui-request-mapper.js";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildPicklePrompt, buildSteerPrompt, type BuiltPrompt } from "./prompt-builder.js";
import type { ModelCycleDirection, PickyActivitySummary, PickyAgentSession, PickyAnnotationOverlayRequest, PickyContextPacket, PickyExtensionUiRequest, PickyMainActivity, PickyMainAgentMessage, PickyMainAgentModelOption, PickyQueueItem, PickyQueueMode, PickySessionMessage } from "./protocol.js";
import { makePointerOverlayRequest, type PickyShowPointerRequest, type PickyShowPointerResult } from "./application/pointer-overlay-request.js";
import type { PickyShowAnnotationsRequest, PickyShowAnnotationsResult } from "./application/annotation-overlay-request.js";
import { PickleVisualDslCoordinator, type PickleVisualDslLease } from "./application/pickle-visual-dsl-coordinator.js";
import { PickleSessionTitleRefresher } from "./application/pickle-session-title-refresher.js";
import { ORPHANED_CHILD_SESSION_RECOVERY_LOG, ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY, type SessionStore } from "./session-store.js";
import { sessionWithAppendedLog } from "./session-log-append.js";
import type { AgentRuntime, RewindTarget, RuntimeAutocompleteApplyRequest, RuntimeAutocompleteCapabilities, RuntimeAutocompleteCompletion, RuntimeAutocompleteQuery, RuntimeAutocompleteSuggestions, RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, RuntimeSteerResult, ThinkingLevel } from "./runtime/types.js";
import { readSessionDiff, type SessionDiffResult } from "./application/session-diff.js";
import { KeyedSerialQueue } from "./domain/keyed-serial-queue.js";
import { executeUserBash as runUserBash, type UserBashDeps } from "./application/user-bash-execution.js";
import { listRewindTargets as rewindListTargets, rewindToEntry as runRewindToEntry, type RewindDeps } from "./application/session-rewind.js";
import {
  cycleModel as cycleRuntimeModel,
  cycleThinkingLevel as cycleRuntimeThinkingLevel,
  listRuntimeOptions as listRuntimeControlOptions,
  setModel as setRuntimeModel,
  setThinkingLevel as setRuntimeThinkingLevel,
  type RuntimeControlDeps,
} from "./application/session-runtime-controls.js";
import type { SessionDiffView } from "./domain/git-diff.js";
import { hasActivity, zeroActivitySummary } from "./domain/activity-summary.js";
import { diffQueueRemovedItems, dropAlreadyMaterializedQueueEntries, extractPickyPromptUserInstruction, queueItems, queueSubmissionSummary, queueTextMatchesUserText, sameQueueItems, type PendingQueueDelivery } from "./domain/queue-policy.js";
import { isTerminalStatus } from "./domain/session-status.js";
import { countSystemMessages, sameTodoState, shouldReattachBlockedSessionOnStartup } from "./domain/session-state-policy.js";
import { isSemanticNoOpPatch } from "./domain/session-patch-policy.js";
import { nextRevision } from "./domain/session-revision-policy.js";
import { ARCHIVED_SESSION_RETENTION_DAYS, buildArchivedSessionRestartCancellation, buildDuplicatedPickleSession, buildEmptyPickleSession, buildInterruptedRuntimeLiveStatePatch, buildOrphanedChildRecoverySession, buildPinnedPickleSession, buildResumedHandoffPickleSession, buildRuntimeReattachPatch, buildRuntimeSessionReplacementPatch, buildUnattachedRuntimeBlock, buildVisibleSession, shouldPurgeArchivedSession } from "./domain/session-supervisor-projection-policy.js";
import { HANDOFF_PREFIX, FOLLOWUP_PREFIX, STEER_PREFIX, EXTENSION_ANSWER_PREFIX } from "./domain/log-prefixes.js";
import { settleActiveTools } from "./domain/tool-activity.js";
import { titleFromContext } from "./domain/session-title.js";
import { normalizeOptionalString } from "./domain/strings.js";
import { appendLiveBashOutput, formatUserBashFailureSystemMessage, formatUserBashRunningSystemMessage, formatUserBashSystemMessage, parseUserBashInput, userBashSummary, type UserBashInput } from "./domain/user-bash-format.js";
import { isNonSkillSlashCommand, isNoTurnStateRestoringSlashCommand, isReloadSlashCommand, normalizeSlashCommands } from "./domain/slash-commands.js";
import { hasPickleSessionMarkerLog, piSessionFilePathForSession, piSessionFilePathFromLogLine, withPiSessionFileFromLogs } from "./domain/pi-session-files.js";
import { buildPinnedPickleSessionLogs, piSessionFilePathFromHandoffTranscript, titleForEmptyPickleSession } from "./domain/pickle-handoff-context.js";
import { quickReplyOriginFromContextSource, type QuickReplyMetadata } from "./domain/main-agent-policy.js";
import type { ToolCategory } from "./domain/tool-categorizer.js";
import { logAgentd } from "./local-log.js";
import { SessionMessageBuilder, type SessionMessageSyncPatch } from "./session-message-builder.js";
export class SessionSupervisor extends EventEmitter {
  private sessions = new Map<string, PickyAgentSession>();
  private runtimeHandles = new Map<string, RuntimeSessionHandle>();
  private runtimeHandleUnsubscribes = new Map<string, () => void>();
  private readonly artifactMaterializer: ArtifactMaterializer;
  private readonly mainAgent: MainAgentCoordinator;
  private readonly runtimeEventHandler: RuntimeEventHandler;
  private readonly subagentRunUpdater: SubagentRunUpdater;
  private readonly pickleSessionTitleRefresher: PickleSessionTitleRefresher;
  private readonly pickleSessionIds = new Set<string>();
  private sessionContexts = new Map<string, PickyContextPacket>();
  private pendingRuntimeHandles = new Map<string, Promise<RuntimeSessionHandle>>();
  private pendingRuntimeAbortControllers = new Map<string, AbortController>();
  private pendingAbortOperations = new Map<string, Promise<PickyAgentSession>>();
  private sessionSeq = new Map<string, number>();
  private readonly sessionProjectionEpoch = randomUUID();
  private queueUpdateChains = new Map<string, Promise<void>>();
  private activityUpdateChains = new Map<string, Promise<void>>();
  private runtimeControlQueue = new KeyedSerialQueue();
  private turnActivity = new Map<string, PickyActivitySummary>();
  private runtimeEventChains = new Map<string, Promise<void>>();
  private emitChains = new Map<string, Promise<void>>();
  private readonly messageBuilder: SessionMessageBuilder;
  private readonly sessionIdFactory: () => string;
  private noTurnRanSessionStateRestores = new Map<string, Partial<PickyAgentSession>>();
  private pendingResourceReloadSessionIDs = new Set<string>();
  /**
   * Pickle sessions that were compacting when the user clicked Reload in
   * Picky's plugin manager. The runtime event handler drains this set the
   * moment a session leaves the compacting state, by dispatching `/reload`
   * through the normal follow-up path. Cleared on session removal too.
   */
  private pendingPostCompactionReloadIds = new Set<string>();
  private lastEmittedSteeringMode = new Map<string, PickyQueueMode>();
  private lastEmittedFollowUpMode = new Map<string, PickyQueueMode>();
  // Track follow-up/steer prompts that Pi has queued but not yet started processing. We defer the
  // user_text journal write until Pi actually dequeues the prompt, so the HUD can render queued
  // items as pending bubbles instead of (incorrectly) hiding them behind a duplicate user bubble.
  private pendingQueueDeliveries = new Map<string, PendingQueueDelivery[]>();
  private materializedQueueDeliveries = new Map<string, PendingQueueDelivery[]>();
  private readonly pendingPickleVisualDslLeases = new Map<string, PickleVisualDslLease>();
  private readonly pickleVisualDslCoordinator: PickleVisualDslCoordinator;
  // Serialize all session-state writes per session id. Without this, concurrent patch/sync calls
  // capture stale snapshots in their `{ ...mustGet(), ...patch }` spread and overwrite each
  // other's in-memory cache + persisted state. The status:running patch and the synthetic
  // status:completed (from /name interception) racing against session_info/log patches was
  // observed to revert the session back to 'running' after a /name slash command.
  private patchChains = new KeyedSerialQueue();
  private readonly terminalSessionCoordinator: TerminalSessionCoordinator;
  private readonly terminalManualCompactionCoordinator: TerminalManualCompactionCoordinator;
  private readonly followUpLifecycleDiagnostics: FollowUpLifecycleDiagnostics;
  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore, private readonly options: SessionSupervisorOptions = {}) {
    super();
    this.followUpLifecycleDiagnostics = new FollowUpLifecycleDiagnostics({
      getSession: (sessionId) => this.sessions.get(sessionId),
      getSessionOrThrow: (sessionId) => this.mustGet(sessionId),
      getRuntimeHandle: (sessionId) => this.runtimeHandles.get(sessionId),
      getPendingQueueDeliveries: (sessionId) => this.pendingQueueDeliveries.get(sessionId),
      waitForRuntimeEvents: (sessionId) => this.waitForRuntimeEvents(sessionId),
      waitForQueuedStateToSettle: (sessionId) => this.waitForQueuedStateToSettle(sessionId),
      drainPendingTextOnce: (sessionId, text) => this.drainPendingTextOnce(sessionId, text),
      discardPendingTextOnce: (sessionId, text) => this.discardPendingTextOnce(sessionId, text),
      markCommandReceiptFailed: (sessionId, commandReceiptId, message) => this.messageBuilder.markCommandReceiptFailed(sessionId, commandReceiptId, message),
      appendLog: (sessionId, line) => this.appendLog(sessionId, line),
      patchSession: (sessionId, patch) => this.patch(sessionId, patch),
      lifecycleEventLogger: options.lifecycleEventLogger,
      followUpStallDelayMs: options.followUpStallDelayMs,
      scheduleFollowUpStall: options.scheduleFollowUpStall,
      clearFollowUpStall: options.clearFollowUpStall,
    });
    this.mainAgent = new MainAgentCoordinator({
      options,
      store,
      emit: (event, ...args) => { this.emit(event, ...args); },
      sessions: () => this.sessions.values(),
      getSession: (sessionId) => this.sessions.get(sessionId),
      pickleSessionIds: this.pickleSessionIds,
    });
    this.sessionIdFactory = options.sessionIdFactory ?? (() => `session-${randomUUID()}`);
    this.pickleSessionTitleRefresher = new PickleSessionTitleRefresher({ isPickleSession: (sessionId) => this.isPickleSession(sessionId), getSession: (sessionId) => this.sessions.get(sessionId), patchSession: (sessionId, patch) => this.patch(sessionId, patch) });
    this.artifactMaterializer = new ArtifactMaterializer();
    this.pickleVisualDslCoordinator = new PickleVisualDslCoordinator((event) => {
      if (event.type === "quickReply") {
        this.emitQuickReply(event.contextId, event.text, {
          originSource: event.originSource,
          replyKind: event.replyKind,
          sessionId: event.sessionId,
          inputId: event.inputId,
          didStreamNarration: event.didStreamNarration,
        });
        return;
      }
      const { type, ...payload } = event;
      this.emit(type, payload);
    });
    this.messageBuilder = new SessionMessageBuilder({
      emitAppended: async (sessionId, message, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageAppended", sessionId, message, seq); }); },
      emitImported: async (sessionId, messages, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messagesImported", sessionId, messages, seq); }); },
      emitReplaced: async (sessionId, messageId, message, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageReplaced", sessionId, messageId, message, seq); }); },
      emitRemoved: async (sessionId, messageId, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageRemoved", sessionId, messageId, seq); }); },
      nextSeq: (sessionId) => this.nextSeq(sessionId),
      now: () => new Date().toISOString(),
      syncSessionMessages: async (sessionId, messages, patch) => { await this.syncSessionMessages(sessionId, messages, patch); },
    });
    this.terminalSessionCoordinator = new TerminalSessionCoordinator({
      getSession: (sessionId) => this.sessions.get(sessionId),
      getSessionOrThrow: (sessionId) => this.mustGet(sessionId),
      hasRuntimeHandle: (sessionId) => this.runtimeHandles.has(sessionId),
      isRuntimeStreaming: (sessionId) => this.runtimeHandles.get(sessionId)?.isStreaming === true,
      detachRuntimeHandle: (sessionId) => this.detachRuntimeHandle(sessionId),
      patchSession: (sessionId, patch) => this.patch(sessionId, patch),
      updateTodoState: (sessionId, todoState) => this.updateTodoState(sessionId, todoState),
      messageRecorder: this.messageBuilder,
      emitSyncOutcome: (sessionId, outcome) => this.emit("terminalSessionSyncOutcome", sessionId, outcome),
      reverseInputExpansion: (sessionId, text) => this.runtimeHandles.get(sessionId)?.reverseInputExpansion?.(text) ?? text,
    });
    this.subagentRunUpdater = new SubagentRunUpdater({
      currentRuns: (sessionId) => this.mustGet(sessionId).subagentRuns ?? [],
      patchSession: (sessionId, patch, options) => this.patch(sessionId, patch, options),
      nextSeq: (sessionId) => this.nextSeq(sessionId),
      emitUpdated: (sessionId, runs, seq) => this.chainEmit(sessionId, async () => { this.emit("subagentRunsUpdated", sessionId, runs, seq); }),
    });
    this.runtimeEventHandler = new RuntimeEventHandler({
      getSession: (sessionId) => this.mustGet(sessionId),
      patchSession: (sessionId, patch, options) => this.patch(sessionId, patch, options),
      emitToolActivityUpdated: (sessionId, tool) => this.emit("toolActivityUpdated", sessionId, tool),
      emitArtifactUpdated: (sessionId, artifact) => this.emit("artifact", sessionId, artifact),
      updateTodoState: (sessionId, todoState) => this.updateTodoState(sessionId, todoState),
      updateSubagentRuns: (sessionId, update) => this.subagentRunUpdater.update(sessionId, update),
      consumeNoTurnRanSessionStateRestore: (sessionId) => this.consumeNoTurnRanSessionStateRestore(sessionId),
      appendLog: (sessionId, line) => this.appendLog(sessionId, line),
      materializeTerminalArtifacts: (sessionId) => this.materializeTerminalArtifacts(sessionId),
      finalizeTerminal: (sessionId, event) => this.finalizeTerminal(sessionId, event),
      applyQueueUpdate: (sessionId, steering, followUp) => this.applyQueueUpdate(sessionId, steering, followUp),
      incrementActivity: (sessionId, category) => this.incrementActivity(sessionId, category),
      commitTurnActivity: (sessionId) => this.commitTurnActivity(sessionId),
      notifyPickleCompletion: (sessionId) => this.mainAgent.notifyLocalPickleCompletion(sessionId),
      isPickleSession: (sessionId) => this.pickleSessionIds.has(sessionId),
      emitExtensionUiRequest: (request) => this.emit("extensionUiRequest", request),
      onInputMessage: (sessionId, event) => this.handleRuntimeInputMessage(sessionId, event),
      transformAssistantDelta: (sessionId, delta) => this.pickleVisualDslCoordinator.consumeAssistantDelta(sessionId, delta),
      sanitizeAssistantText: (sessionId, text) => this.pickleVisualDslCoordinator.sanitizeCompleteText(sessionId, text),
      finishAssistantMessage: (sessionId) => this.pickleVisualDslCoordinator.finishAssistantMessage(sessionId),
      finishAssistantRun: (sessionId, finalAnswer) => {
        this.pickleVisualDslCoordinator.completeAssistantRun(sessionId, finalAnswer);
        this.pickleVisualDslCoordinator.deactivate(sessionId, "runtime terminal");
      },
      messageBuilder: this.messageBuilder,
    });
    this.terminalManualCompactionCoordinator = new TerminalManualCompactionCoordinator({
      sessionStatus: (sessionId) => this.mustGet(sessionId).status,
      cancelPendingExtensionUi: (sessionId, handle) => this.cancelPendingExtensionUiForUserInput(sessionId, handle),
      resetAssistantDraft: (sessionId) => this.runtimeEventHandler.resetAssistantDraft(sessionId),
      beginTerminalManualCompaction: (sessionId, status) => this.runtimeEventHandler.beginManualTerminalCompaction(sessionId, status),
      clearTerminalManualCompaction: (sessionId) => this.runtimeEventHandler.clearManualTerminalCompaction(sessionId), finishTerminalManualCompaction: (sessionId) => this.runtimeEventHandler.finishManualTerminalCompaction(sessionId),
      waitForRuntimeEvents: (sessionId) => this.waitForRuntimeEvents(sessionId),
      logLifecycle: (event, sessionId, handle, fields) => this.followUpLifecycleDiagnostics.logLifecycle(event, sessionId, handle, fields),
    });
  }
  async load(): Promise<void> {
    await this.mainAgent.load();
    const persisted = await this.store.loadAll();
    logAgentd("sessions loading", { count: persisted.length });
    for (const persistedSession of persisted) {
      const migratedSession = withPiSessionFileFromLogs(persistedSession);
      const isPickleSession = hasPickleSessionMarkerLog(migratedSession);
      if (isPickleSession) this.pickleSessionIds.add(migratedSession.id);
      const session = isPickleSession
        ? {
            ...migratedSession,
            notifyMainOnCompletion: migratedSession.notifyMainOnCompletion ?? false,
            notifyMacOSOnCompletion: migratedSession.notifyMacOSOnCompletion ?? false,
          }
        : migratedSession;
      if (session.piSessionFilePath !== persistedSession.piSessionFilePath
          || session.notifyMainOnCompletion !== persistedSession.notifyMainOnCompletion
          || session.notifyMacOSOnCompletion !== persistedSession.notifyMacOSOnCompletion) await this.commitSession(session);
      else this.sessions.set(session.id, session);
      this.messageBuilder.hydrateSession(session.id, session.messages);
      if (this.pickleSessionIds.has(session.id)) void this.pickleSessionTitleRefresher.refresh(session.id);

      if (session.logs.includes(ORPHANED_CHILD_SESSION_RECOVERY_LOG)) {
        const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
        const current = this.mustGet(session.id);
        // Strip the ORPHANED marker from the persisted logs after we surface the recovery summary
        // once. Without this the marker stays in logs forever and every subsequent restart re-enters
        // this branch, leaving the dock icon permanently in the blocked/help state even when the Pi
        // session file is still alive and reattachable.
        const restored = buildOrphanedChildRecoverySession(
          current,
          interrupted.patch,
          new Date().toISOString(),
          ORPHANED_CHILD_SESSION_RECOVERY_LOG,
          ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY,
        );
        await this.commitSession(session.id, () => restored);
        continue;
      }

      if (!isTerminalStatus(session.status)) {
        if (session.archived === true) {
          const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
          const current = this.mustGet(session.id);
          const restored = buildArchivedSessionRestartCancellation(
            current,
            interrupted.patch,
            new Date().toISOString(),
          );
          await this.commitSession(session.id, () => restored);
          continue;
        }

        const resumedHandle = await this.tryResumeRuntimeHandle(session);
        if (!resumedHandle) {
          const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
          const current = this.mustGet(session.id);
          const restored = buildUnattachedRuntimeBlock(
            current,
            interrupted.patch,
            new Date().toISOString(),
            "Runtime not attached after daemon restart; start a new task or resume support is required",
          );
          await this.commitSession(session.id, () => restored);
        }
      } else if (shouldReattachBlockedSessionOnStartup(session, Boolean(piSessionFilePathForSession(session)))) {
        await this.tryResumeRuntimeHandle(session);
      }
    }
    // Run after Pickle sessions are hydrated so the carried summary can reference them.
    await this.mainAgent.rolloverMainAgentForRestart();
    await this.purgeStaleArchivedSessions();
  }

  private async purgeStaleArchivedSessions(now: number = Date.now()): Promise<void> {
    const removed: string[] = [];
    for (const session of [...this.sessions.values()]) {
      if (!shouldPurgeArchivedSession(session, now, this.runtimeHandles.has(session.id))) continue;
      try {
        await this.store.deleteSession(session.id);
        this.sessions.delete(session.id);
        this.messageBuilder.onSessionRemoved(session.id);
        this.pickleSessionIds.delete(session.id);
        removed.push(session.id);
      } catch (error) {
        logAgentd("archived session purge failed", {
          sessionId: session.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
    if (removed.length > 0) {
      logAgentd("archived sessions purged", {
        count: removed.length,
        retentionDays: ARCHIVED_SESSION_RETENTION_DAYS,
        sampleIds: removed.slice(0, 10).join(","),
      });
    }
  }

  list(): PickyAgentSession[] {
    return [...this.sessions.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  listPickleSessions(): PickyAgentSession[] {
    return this.list().filter((session) => this.pickleSessionIds.has(session.id));
  }
  isPickleSession(sessionId: string): boolean {
    return this.pickleSessionIds.has(sessionId);
  }

  get(id: string): PickyAgentSession | undefined {
    return this.sessions.get(id);
  }
  projectionEpoch(): string {
    return this.sessionProjectionEpoch;
  }
  async withSessionProjectionBarrier(sessionId: string, work: (snapshot: { session: PickyAgentSession; epoch: string }) => Promise<void>): Promise<void> { await this.runSessionWrite(sessionId, async () => { await this.chainEmit(sessionId, async () => { await work({ session: this.mustGet(sessionId), epoch: this.sessionProjectionEpoch }); }); }); }
  currentMainContext(): PickyContextPacket | undefined {
    return this.mainAgent.currentContext;
  }
  async prewarmMainAgent(cwd = process.cwd()): Promise<void> { await this.mainAgent.prewarmMainAgent(cwd); }
  listMainMessages(): PickyMainAgentMessage[] { return this.mainAgent.listMainMessages(); }
  mainPendingExtensionUi(): PickyExtensionUiRequest | undefined { return this.mainAgent.mainPendingExtensionUi(); }
  mainActiveActivity(): PickyMainActivity | undefined { return this.mainAgent.mainActiveActivity(); }
  mainAgentSessionInfo(): { sessionFilePath?: string; cwd?: string } { return this.mainAgent.mainAgentSessionInfo(); }
  async answerMainExtensionUi(requestId: string, value: unknown): Promise<void> { await this.mainAgent.answerMainExtensionUi(requestId, value); }
  async resetMainAgent(): Promise<void> { await this.mainAgent.resetMainAgent(); }
  async abortMainAgent(): Promise<void> { await this.mainAgent.abortMainAgent(); }
  async setMainAgentThinkingLevel(level: ThinkingLevel): Promise<void> { await this.mainAgent.setMainAgentThinkingLevel(level); }
  async listMainAgentModels(): Promise<PickyMainAgentModelOption[]> { return this.mainAgent.listMainAgentModels(); }
  async setMainAgentModel(pattern: string): Promise<void> { await this.mainAgent.setMainAgentModel(pattern); }
  async setDisabledBuiltinTools(names: readonly string[]): Promise<void> { await this.mainAgent.setDisabledBuiltinTools(names); }
  getTTSEnabled(): boolean { return this.mainAgent.getTTSEnabled(); }
  setTTSEnabled(enabled: boolean): void { this.mainAgent.setTTSEnabled(enabled); }
  onTTSEnabledChange(listener: (enabled: boolean) => void): () => void { return this.mainAgent.onTTSEnabledChange(listener); }
  deliverMainAgentPickleCompletion(requestOrSessionId: ExternalPickleCompletionRequest | string, legacyPrompt?: string, legacyCwd?: string): Promise<void> {
    return this.mainAgent.deliverMainAgentPickleCompletion(requestOrSessionId, legacyPrompt, legacyCwd);
  }
  async listSlashCommands(sessionId: string): Promise<RuntimeSlashCommand[]> {
    const session = this.mustGet(sessionId);
    const attachedCommands = await this.listSlashCommandsFromHandle(sessionId, this.runtimeHandles.get(sessionId), "attached");
    if (attachedCommands) return attachedCommands;

    const pendingHandle = await this.pendingRuntimeHandle(sessionId);
    const pendingCommands = await this.listSlashCommandsFromHandle(sessionId, pendingHandle, "pending");
    if (pendingCommands) return pendingCommands;

    const resumedHandle = await this.tryResumeRuntimeHandle(session);
    const resumedCommands = await this.listSlashCommandsFromHandle(sessionId, resumedHandle, "resumed");
    if (resumedCommands) return resumedCommands;

    const fallbackHandle = await this.slashCommandFallbackHandle(session);
    const fallbackCommands = await this.listSlashCommandsFromHandle(sessionId, fallbackHandle, "main");
    return fallbackCommands ?? [];
  }

  async getAutocompleteCapabilities(sessionId: string): Promise<RuntimeAutocompleteCapabilities> {
    const handle = await this.autocompleteRuntimeHandle(sessionId);
    return handle?.getAutocompleteCapabilities?.() ?? { generation: 0, triggerCharacters: [] };
  }

  async queryAutocomplete(sessionId: string, query: RuntimeAutocompleteQuery): Promise<RuntimeAutocompleteSuggestions> {
    const handle = await this.autocompleteRuntimeHandle(sessionId);
    if (!handle?.queryAutocomplete) throw new Error(`Autocomplete is unavailable for session: ${sessionId}`);
    return handle.queryAutocomplete(query);
  }

  async applyAutocomplete(sessionId: string, request: RuntimeAutocompleteApplyRequest): Promise<RuntimeAutocompleteCompletion> {
    const handle = await this.autocompleteRuntimeHandle(sessionId);
    if (!handle?.applyAutocomplete) throw new Error(`Autocomplete is unavailable for session: ${sessionId}`);
    return handle.applyAutocomplete(request);
  }

  private async autocompleteRuntimeHandle(sessionId: string): Promise<RuntimeSessionHandle | undefined> {
    const session = this.mustGet(sessionId);
    const attached = this.runtimeHandles.get(sessionId);
    if (attached) return attached;
    const pending = await this.pendingRuntimeHandle(sessionId, "autocomplete");
    if (pending) return pending;
    const resumed = await this.tryResumeRuntimeHandle(session);
    if (resumed) return resumed;
    return this.slashCommandFallbackHandle(session);
  }

  private async listSlashCommandsFromHandle(sessionId: string, handle: RuntimeSessionHandle | undefined, source: "attached" | "pending" | "resumed" | "main"): Promise<RuntimeSlashCommand[] | undefined> {
    if (!handle?.listSlashCommands) {
      logAgentd("slash commands unavailable", { sessionId, source, reason: handle ? "runtime handle unsupported" : "runtime handle missing" });
      return undefined;
    }
    try {
      return normalizeSlashCommands(await handle.listSlashCommands());
    } catch (error) {
      logAgentd("slash commands failed", { sessionId, source, error: error instanceof Error ? error.message : String(error) });
      return undefined;
    }
  }

  private async pendingRuntimeHandle(sessionId: string, action = "pending runtime"): Promise<RuntimeSessionHandle | undefined> {
    const pending = this.pendingRuntimeHandles.get(sessionId);
    if (!pending) return undefined;
    const signal = this.pendingRuntimeAbortControllers.get(sessionId)?.signal;
    try {
      return await awaitPendingRuntimeHandle(pending, signal);
    } catch (error) {
      logAgentd(`${action} pending runtime failed`, { sessionId, error: error instanceof Error ? error.message : String(error) });
      return undefined;
    }
  }

  private async runtimeHandleForUserInput(session: PickyAgentSession, action: string): Promise<RuntimeSessionHandle | undefined> {
    const attached = this.runtimeHandles.get(session.id);
    if (attached) return attached;
    const hadPending = this.pendingRuntimeHandles.has(session.id);
    const pending = await this.pendingRuntimeHandle(session.id, action);
    if (pending) return pending;
    if (hadPending && ["cancelled", "failed"].includes(this.mustGet(session.id).status)) return undefined;
    return await this.tryResumeRuntimeHandle(session);
  }

  private async assertNotTerminalForUserInput(sessionId: string, action: string): Promise<PickyAgentSession | undefined> {
    const current = this.mustGet(sessionId);
    if (!["cancelled", "failed"].includes(current.status)) return undefined;
    await this.appendLog(sessionId, `${action} ignored: session is ${current.status}`);
    return current;
  }

  private async slashCommandFallbackHandle(session: PickyAgentSession): Promise<RuntimeSessionHandle | undefined> {
    if (!this.options.mainRuntime) return undefined;
    try {
      if (this.mainAgent.currentHandle) return this.mainAgent.currentHandle;
      if (this.mainAgent.pendingHandlePromise) return await this.mainAgent.pendingHandlePromise;
      return await this.mainAgent.ensurePrewarmedMainHandle(session.cwd?.trim() || process.cwd());
    } catch (error) {
      logAgentd("slash commands fallback failed", { sessionId: session.id, error: error instanceof Error ? error.message : String(error) });
      return undefined;
    }
  }

  async requestPointerOverlay(request: PickyShowPointerRequest): Promise<PickyShowPointerResult> {
    const captured = this.contextForPointerRequest();
    if (!captured) throw new Error("No captured Picky context is available for pointer overlay validation.");
    return this.requestPointerOverlayForContext(captured, request);
  }

  private requestPointerOverlayForContext(captured: MainTurnOverlayContext, request: PickyShowPointerRequest): PickyShowPointerResult {
    const overlayRequest = makePointerOverlayRequestForContext(captured.context, request, captured.generation);
    this.emit("pointerOverlayRequested", overlayRequest);
    return { request: overlayRequest };
  }

  async requestAnnotationOverlay(request: PickyShowAnnotationsRequest): Promise<PickyShowAnnotationsResult> {
    if (request.mode === "clear") {
      const overlayRequest: PickyAnnotationOverlayRequest = {
        id: `annotations-${randomUUID()}`,
        mode: "clear",
        annotations: [],
      };
      this.emit("annotationOverlayRequested", overlayRequest);
      return { request: overlayRequest };
    }

    const captured = this.contextForPointerRequest();
    if (!captured) throw new Error("No captured Picky context is available for annotation overlay validation.");
    return this.requestAnnotationOverlayForContext(captured, request);
  }

  private requestAnnotationOverlayForContext(captured: MainTurnOverlayContext, request: PickyShowAnnotationsRequest): PickyShowAnnotationsResult {
    const overlayRequest = makeAnnotationOverlayRequestForContext(captured.context, request, captured.generation);
    this.emit("annotationOverlayRequested", overlayRequest);
    return { request: overlayRequest };
  }

  private contextForPointerRequest(): { context: PickyContextPacket; generation: number } | undefined {
    const mainContext = this.mainAgent.currentContext;
    if (mainContext) return { context: mainContext, generation: this.mainAgent.currentContextGeneration };
    const context = [...this.sessionContexts.values()].at(-1);
    return context ? { context, generation: 0 } : undefined;
  }

  async reloadPlugins(): Promise<ReloadPluginsSummary> {
    let pickyReloaded = false;
    let pickleReloadedCount = 0;
    let pickleAbortedCount = 0;
    let pickleDeferredCount = 0;

    // Pickle sessions. Iterate a snapshot because abort() mutates session state.
    const pickles = this.listPickleSessions();
    for (const session of pickles) {
      if (isTerminalStatus(session.status)) continue;
      const handle = this.runtimeHandles.get(session.id);
      if (!handle) continue;

      if (handle.isCompacting === true) {
        // Compaction can't be cleanly aborted on the Pi side. Defer the reload
        // until the runtime emits the compaction-completed status; the runtime
        // event handler drains `pendingPostCompactionReloadIds` at that point.
        this.pendingPostCompactionReloadIds.add(session.id);
        pickleDeferredCount += 1;
        await this.appendLog(session.id, "plugins reload deferred until compaction completes");
        continue;
      }

      if (handle.isStreaming) {
        try {
          await this.abort(session.id);
          pickleAbortedCount += 1;
          await this.appendLog(session.id, "plugins reload aborted streaming session; new plugins apply on next session");
        } catch (error) {
          logAgentd("plugins reload pickle abort failed", { sessionId: session.id, error: error instanceof Error ? error.message : String(error) });
        }
        continue;
      }

      // Idle: hand /reload to the runtime through the normal followUp path so
      // the existing slash-command pipeline (receipt, resourcesReloaded emit,
      // pendingResourceReloadSessionIDs) keeps working unchanged.
      try {
        await this.followUp(session.id, "/reload");
        pickleReloadedCount += 1;
      } catch (error) {
        logAgentd("plugins reload pickle followUp failed", { sessionId: session.id, error: error instanceof Error ? error.message : String(error) });
      }
    }

    logAgentd("plugins reloaded", { pickyReloaded: pickyReloaded ? 1 : 0, pickleReloadedCount, pickleAbortedCount, pickleDeferredCount });
    return { pickyReloaded, pickleReloadedCount, pickleAbortedCount, pickleDeferredCount };
  }

  async reloadPiAuthentication(): Promise<number> {
    const handles = new Set<RuntimeSessionHandle>();
    if (this.mainAgent.currentHandle) handles.add(this.mainAgent.currentHandle);
    if (this.mainAgent.pendingHandlePromise) {
      try {
        handles.add(await this.mainAgent.pendingHandlePromise);
      } catch (error) {
        logAgentd("pending main authentication reload skipped", { error: error instanceof Error ? error.message : String(error) });
      }
    }
    for (const handle of this.runtimeHandles.values()) handles.add(handle);
    for (const [sessionId, pendingHandle] of [...this.pendingRuntimeHandles]) {
      try {
        handles.add(await pendingHandle);
      } catch (error) {
        logAgentd("pending pickle authentication reload skipped", { sessionId, error: error instanceof Error ? error.message : String(error) });
      }
    }

    let reloaded = 0;
    const failures: string[] = [];
    for (const handle of handles) {
      if (!handle.reloadAuthentication) continue;
      try {
        await handle.reloadAuthentication();
        reloaded += 1;
      } catch (error) {
        failures.push(error instanceof Error ? error.message : String(error));
      }
    }
    logAgentd("pi authentication reloaded", { handles: reloaded, failures: failures.length });
    if (failures.length > 0) {
      throw new Error(`Failed to reload Pi authentication on ${failures.length} runtime handle(s): ${failures.join("; ")}`);
    }
    return reloaded;
  }

  // ----- Pickle inspection -----
  //
  // `picky pickle-list` is a list. When the user asks "how's that pickle
  // going?" the model needs a deeper but still bounded summary of one
  // specific session without spawning another Pickle (which would recursively
  // delegate). We surface the SessionSupervisor's in-memory PickyAgentSession
  // — already up to date because the supervisor is the source of truth — and
  // trim it to a short text-friendly shape.

  inspectPickleSession(sessionId: string): PickyAgentSession | undefined {
    return this.sessions.get(sessionId);
  }

  async route(context: PickyContextPacket): Promise<PickyAgentSession | undefined> {
    logAgentd("route requested", { contextId: context.id, source: context.source, transcriptChars: context.transcript?.length, screenshots: context.screenshots.length });
    if (this.options.mainRuntime) {
      await this.mainAgent.cancelMainPendingExtensionUi();
      await this.mainAgent.routeThroughMainAgent(context);
      return undefined;
    }
    if (!this.options.taskRouter) return this.create(context);
    const decision = await this.options.taskRouter.route(context);
    if (decision.route === "quick_reply") {
      logAgentd("quick reply routed", { contextId: context.id, textChars: decision.reply.length });
      this.emitQuickReply(context.id, decision.reply, { originSource: quickReplyOriginFromContextSource(context.source), replyKind: "router" });
      return undefined;
    }
    return this.create(context);
  }

  async create(context: PickyContextPacket): Promise<PickyAgentSession> {
    return this.createVisibleSession(context, titleFromContext(context), buildInitialTaskPrompt(context));
  }

  private emitQuickReply(contextId: string, text: string, metadata: Partial<QuickReplyMetadata> = {}): void {
    this.emit("quickReply", contextId, text, metadata);
  }

  async createPickleFromHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string; cwd?: string; notifyMainOnCompletion?: boolean; notifyMacOSOnCompletion?: boolean }): Promise<PickyAgentSession> {
    const cwd = normalizeOptionalString(handoff.cwd) ?? context.cwd;
    const handoffContext = cwd ? { ...context, cwd } : context;
    const sourceSessionFilePath = piSessionFilePathFromHandoffTranscript(handoffContext.transcript);
    logAgentd("pickle session create requested", { contextId: context.id, titleChars: handoff.title.length, instructionChars: handoff.instructions.length, cwd: handoffContext.cwd, sourceSessionFilePath });
    if (sourceSessionFilePath && this.runtime.resume) {
      return this.createPickleFromResumedHandoff(handoffContext, handoff, sourceSessionFilePath);
    }
    const session = await this.createVisibleSession(handoffContext, handoff.title.trim() || titleFromContext(context), buildPicklePrompt(handoffContext, handoff), {
      notifyMainOnCompletion: handoff.notifyMainOnCompletion ?? false,
      notifyMacOSOnCompletion: handoff.notifyMacOSOnCompletion ?? false,
    });
    this.pickleSessionIds.add(session.id);
    await this.appendLog(session.id, `${HANDOFF_PREFIX}${handoff.instructions}`);
    if (handoffContext.cwd) await this.appendLog(session.id, `Picky handoff cwd: ${handoffContext.cwd}`);
    return this.mustGet(session.id);
  }

  private async createPickleFromResumedHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string; cwd?: string; notifyMainOnCompletion?: boolean; notifyMacOSOnCompletion?: boolean }, sourceSessionFilePath: string): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const cwd = normalizeOptionalString(context.cwd);
    const newFilePath = await snapshotPiSessionFile(sourceSessionFilePath, id);
    const title = handoff.title.trim() || titleFromContext(context);
    const session = buildResumedHandoffPickleSession({
      id,
      title,
      cwd,
      now,
      sessionFilePath: newFilePath,
      sourceSessionFilePath,
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
      notifyMainOnCompletion: handoff.notifyMainOnCompletion ?? false,
      notifyMacOSOnCompletion: handoff.notifyMacOSOnCompletion ?? false,
    });
    this.pickleSessionIds.add(id);
    this.sessionContexts.set(id, context);
    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(id, pendingHandle.promise);
    this.pendingRuntimeAbortControllers.set(id, new AbortController());
    try {
      await this.upsert(session);
      logAgentd("pickle handoff resume queued", { sessionId: id, sourceSessionFilePath, sessionFilePath: newFilePath, cwd });
      const resume = this.runtime.resume?.bind(this.runtime);
      if (!resume) throw new Error("Runtime cannot resume handoff sessions");
      const handle = await resume(newFilePath, { cwd, sessionId: id });
      if (this.mustGet(id).status === "cancelled") {
        await disposeRuntimeHandle(handle, "cancelled-handoff-resume");
        logAgentd("pickle handoff resume resolved after session was cancelled", { sessionId: id });
        return this.mustGet(id);
      }
      await this.attachRuntimeHandle(id, handle);
      await this.patch(id, { status: "running", lastSummary: "Started", thinkingPreview: undefined, piSessionFilePath: newFilePath });
      pendingHandle.resolve(handle);
      await handle.followUp({ text: handoff.instructions, imagePaths: [] });
      await this.appendLog(id, `${HANDOFF_PREFIX}${handoff.instructions}`);
      if (cwd) await this.appendLog(id, `Picky handoff cwd: ${cwd}`);
      void this.pickleSessionTitleRefresher.refresh(id);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("pickle handoff resume failed", { sessionId: id, sourceSessionFilePath, sessionFilePath: newFilePath, error: message });
      if (this.sessions.has(id) && this.mustGet(id).status !== "cancelled") {
        await this.patch(id, {
          status: "failed",
          lastSummary: `Failed to resume handoff: ${message}`,
          logs: [...this.mustGet(id).logs, `Failed to resume handoff: ${message}`],
        });
      }
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
      this.pendingRuntimeAbortControllers.delete(id);
    }
  }

  async createEmptyPickleSession(context: PickyContextPacket, notifyMainOnCompletion = false, notifyMacOSOnCompletion = false): Promise<PickyAgentSession> {
    if (!this.runtime.prewarm) throw new Error("Runtime cannot prewarm empty Pickle sessions");
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const cwd = normalizeOptionalString(context.cwd);
    const pickleContext: PickyContextPacket = { ...context, cwd, transcript: undefined, screenshots: [] };
    const session = buildEmptyPickleSession({
      id,
      title: titleForEmptyPickleSession(pickleContext),
      cwd: pickleContext.cwd,
      now,
      notifyMainOnCompletion,
      notifyMacOSOnCompletion,
    });
    this.pickleSessionIds.add(id);
    this.sessionContexts.set(id, pickleContext);
    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(id, pendingHandle.promise);
    this.pendingRuntimeAbortControllers.set(id, new AbortController());
    try {
      await this.upsert(session);
      logAgentd("empty pickle session queued", { sessionId: id, cwd: pickleContext.cwd, contextId: context.id });
      const handle = await this.runtime.prewarm({ cwd: pickleContext.cwd, sessionId: id });
      if (this.mustGet(id).status === "cancelled") {
        await disposeRuntimeHandle(handle, "cancelled-empty-pickle-prewarm");
        logAgentd("empty pickle prewarm resolved after session was cancelled", { sessionId: id });
        return this.mustGet(id);
      }
      await this.attachRuntimeHandle(id, handle);
      await this.appendLog(id, "manual pickle: waiting for first instruction");
      if (pickleContext.cwd) await this.appendLog(id, `manual pickle cwd: ${pickleContext.cwd}`);
      pendingHandle.resolve(handle);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("empty pickle session prewarm failed", { sessionId: id, error: message });
      if (!this.sessions.has(id)) { pendingHandle.reject(error); throw error; }
      if (this.mustGet(id).status === "cancelled") {
        pendingHandle.reject(error);
        return this.mustGet(id);
      }
      await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to start runtime: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to start runtime: ${message}`],
      });
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
      this.pendingRuntimeAbortControllers.delete(id);
    }
  }

  /**
   * Fork an existing Pickle session into a brand-new sibling session that resumes from a snapshot
   * of the source's Pi JSONL transcript. The new session inherits cwd, message history, and
   * notification preference, but starts with empty activity counters / artifacts / changed-files
   * (per-session usage telemetry should not double-count). Forking is allowed regardless of the
   * source's status: a running source's JSONL is trimmed to the last complete
   * line and receives a fresh Pi session-header UUID, so the runtime resumes a
   * non-corrupt independent branch even mid-turn.
   *
   * The new title is `(copy) <source title>`; Pi will rename the underlying session as soon as
   * the user runs `/name` (existing `refreshPickleSessionTitleFromPi` flow handles the resync).
   */

  async duplicatePickleSession(sourceSessionId: string): Promise<PickyAgentSession> {
    if (!this.runtime.resume) throw new Error("Runtime cannot duplicate sessions");
    const source = this.mustGet(sourceSessionId);
    const sourceFilePath = this.resolveSourcePiSessionFile(source);
    if (!sourceFilePath) throw new Error(`Session has no Pi session file to duplicate: ${sourceSessionId}`);

    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const cwd = normalizeOptionalString(source.cwd);
    const newFilePath = await snapshotPiSessionFile(sourceFilePath, id);
    const session = buildDuplicatedPickleSession({
      id,
      source,
      cwd,
      now,
      sessionFilePath: newFilePath,
    });

    this.pickleSessionIds.add(id);
    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(id, pendingHandle.promise);
    this.pendingRuntimeAbortControllers.set(id, new AbortController());
    try {
      await this.upsert(session);
      // hydrate AFTER upsert so the in-memory journal exists before the resumed runtime emits
      // any tool/assistant deltas. Without hydration, the first appendInternal would build a
      // fresh empty journal and overwrite the persisted message history via syncSessionMessages.
      this.messageBuilder.hydrateSession(id, session.messages);
      logAgentd("pickle session duplicate queued", {
        sourceSessionId,
        newSessionId: id,
        sourceFilePath,
        newFilePath,
        messages: session.messages?.length ?? 0,
        cwd,
      });
      const handle = await this.runtime.resume(newFilePath, { cwd, sessionId: id });
      await this.attachRuntimeHandle(id, handle);
      pendingHandle.resolve(handle);
      logAgentd("pickle session duplicate ready", { sourceSessionId, newSessionId: id });
      // Pull the freshly-resumed Pi session_info name (when present) so the (copy) prefix is
      // applied on top of Pi's own name rather than a stale Picky default.
      void this.pickleSessionTitleRefresher.refresh(id);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("pickle session duplicate failed", { sourceSessionId, newSessionId: id, error: message });
      if (this.sessions.has(id)) await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to duplicate session: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to duplicate session: ${message}`],
      });
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
      this.pendingRuntimeAbortControllers.delete(id);
    }
  }

  private resolveSourcePiSessionFile(session: PickyAgentSession): string | undefined {
    const fromSession = piSessionFilePathForSession(session);
    if (fromSession) return fromSession;
    const handle = this.runtimeHandles.get(session.id);
    return handle?.getSessionFilePath?.();
  }

  async pinPickleSession(context: PickyContextPacket, title?: string): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const session = buildPinnedPickleSession({
      id,
      title: title?.trim() || titleFromContext(context),
      context,
      now,
      logs: buildPinnedPickleSessionLogs(context),
      sessionFilePath: piSessionFilePathFromHandoffTranscript(context.transcript),
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
    });
    this.pickleSessionIds.add(id);
    logAgentd("pickle session pinned", { sessionId: id, titleChars: session.title.length, cwd: context.cwd, contextId: context.id });
    await this.upsert(session);

    const sourceState = await readRecentPinnedSourceState(session.piSessionFilePath);
    const sourceMessages = sourceState?.messages ?? [];
    if (sourceMessages.length > 0) {
      await this.messageBuilder.recordTerminalSessionMessages(id, sourceMessages);
      const latestAssistantText = [...sourceMessages].reverse().find((message) => message.kind === "agent_text")?.text?.trim();
      if (latestAssistantText) await this.patch(id, { lastSummary: latestAssistantText, finalAnswer: latestAssistantText });
    } else {
      await this.messageBuilder.seedPinnedSession(id, context.transcript, session.finalAnswer, session.title);
    }
    if (sourceState?.todoState) await this.patch(id, { todoState: sourceState.todoState });

    await this.materializeTerminalArtifacts(id);
    return this.mustGet(id);
  }

  private async createVisibleSession(context: PickyContextPacket, title: string, prompt = buildInitialTaskPrompt(context), options: { notifyMainOnCompletion?: boolean; notifyMacOSOnCompletion?: boolean } = {}): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const session = buildVisibleSession({
      id,
      title,
      cwd: context.cwd,
      now,
      notifyMainOnCompletion: options.notifyMainOnCompletion,
      notifyMacOSOnCompletion: options.notifyMacOSOnCompletion,
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
    });
    this.sessionContexts.set(id, context);
    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(id, pendingHandle.promise);
    this.pendingRuntimeAbortControllers.set(id, new AbortController());
    try {
      await this.upsert(session);
      logAgentd("session queued", { sessionId: id, titleChars: title.length, cwd: context.cwd });
      this.runtimeEventHandler.resetAssistantDraft(id);
      const handle = await this.runtime.create(prompt, { cwd: context.cwd, sessionId: id });
      if (this.mustGet(id).status === "cancelled") {
        await disposeRuntimeHandle(handle, "cancelled-runtime-create");
        logAgentd("runtime create resolved after session was cancelled", { sessionId: id });
        return this.mustGet(id);
      }
      await this.attachRuntimeHandle(id, handle);
      logAgentd("runtime attached", { sessionId: id });
      await this.patch(id, { status: "running", lastSummary: "Started", thinkingPreview: undefined });
      pendingHandle.resolve(handle);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("runtime start failed", { sessionId: id, error: message });
      if (!this.sessions.has(id)) { pendingHandle.reject(error); throw error; }
      if (this.mustGet(id).status === "cancelled") {
        pendingHandle.reject(error);
        return this.mustGet(id);
      }
      await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to start runtime: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to start runtime: ${message}`],
      });
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
      this.pendingRuntimeAbortControllers.delete(id);
    }
  }

  async setNotifyMainOnCompletion(sessionId: string, enabled: boolean): Promise<PickyAgentSession> {
    if (!this.isPickleSession(sessionId)) throw new Error(`Session is not a Pickle: ${sessionId}`);
    await this.patch(sessionId, { notifyMainOnCompletion: enabled });
    return this.mustGet(sessionId);
  }

  async setNotifyMacOSOnCompletion(sessionId: string, enabled: boolean): Promise<PickyAgentSession> {
    if (!this.isPickleSession(sessionId)) throw new Error(`Session is not a Pickle: ${sessionId}`);
    await this.patch(sessionId, { notifyMacOSOnCompletion: enabled });
    return this.mustGet(sessionId);
  }

  /**
   * Permanent purge of a single archived session triggered by the user from
   * Settings → Pickle. Mirrors the inner body of `purgeStaleArchivedSessions`
   * but operates on one session id and refuses to act on anything still
   * running so the user cannot accidentally rip a live runtime handle out
   * from under itself. Caller is expected to broadcast a fresh
   * `sessionSnapshot` so clients prune their local arrays.
   */
  async deleteSession(sessionId: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      logAgentd("deleteSession skipped: unknown session", { sessionId });
      return;
    }
    if (!isTerminalStatus(session.status)) {
      throw new Error(`Cannot delete a session that is not in a terminal state: ${sessionId} (${session.status})`);
    }
    if (session.archived !== true) {
      throw new Error(`Cannot delete a session that is not archived: ${sessionId}`);
    }
    await this.detachRuntimeHandle(sessionId, true);
    await this.setTerminalSessionTailEnabled(sessionId, false);
    await this.store.deleteSession(sessionId);
    this.sessions.delete(sessionId);
    this.messageBuilder.onSessionRemoved(sessionId);
    this.pickleSessionIds.delete(sessionId);
    this.sessionContexts.delete(sessionId);
    this.sessionSeq.delete(sessionId);
    this.clearPendingQueueDeliveries(sessionId);
    this.pickleVisualDslCoordinator.deactivate(sessionId, "session deleted");
    this.materializedQueueDeliveries.delete(sessionId);
    this.turnActivity.delete(sessionId);
    this.noTurnRanSessionStateRestores.delete(sessionId);
    this.pendingResourceReloadSessionIDs.delete(sessionId);
    this.pendingPostCompactionReloadIds.delete(sessionId);
    this.lastEmittedSteeringMode.delete(sessionId);
    this.lastEmittedFollowUpMode.delete(sessionId);
    this.mainAgent.clearLocalPickleTracking(sessionId);
    logAgentd("session deleted", { sessionId });
  }

  async setSessionArchived(sessionId: string, archived: boolean): Promise<PickyAgentSession> {
    const patch: Partial<PickyAgentSession> = archived
      ? { archived: true, archivedAt: new Date().toISOString() }
      : { archived: false, archivedAt: undefined };
    await this.patch(sessionId, patch);
    // Emit a dedicated event in addition to the patch-driven sessionMetaUpdated
    // so the client knows this archive-state change is authoritative (rather than
    // a stale `archived` field on an unrelated update). Picky's view model
    // mirrors this into its local manuallyArchivedSessionIDs UserDefaults so
    // tool-initiated unarchive (picky_unarchive_pickle) actually pops the
    // dock card back — the local intent set is the source of truth for dock
    // placement and is otherwise never touched by remote sessionUpdated/sessionMetaUpdated.
    this.emit("sessionArchivedAuthoritative", sessionId, archived);
    return this.mustGet(sessionId);
  }

  async listSessionRuntimeOptions(sessionId: string) {
    return listRuntimeControlOptions(this.runtimeControlDeps(), sessionId);
  }

  async setSessionModel(sessionId: string, provider: string, modelId: string): Promise<PickyAgentSession> {
    return this.runRuntimeControlMutation(sessionId, () => setRuntimeModel(this.runtimeControlDeps(), sessionId, provider, modelId));
  }

  async setGlobalModelScope(mode: "all" | "exact", patterns: string[] | undefined, expectedRevision: string): Promise<void> {
    if (!this.runtime.setGlobalModelScope) throw new Error("Runtime does not support global model scope changes");
    await this.runtime.setGlobalModelScope({ mode, patterns, expectedRevision });
  }

  async setSessionThinkingLevel(sessionId: string, thinkingLevel: ThinkingLevel): Promise<PickyAgentSession> {
    return this.runRuntimeControlMutation(sessionId, () => setRuntimeThinkingLevel(this.runtimeControlDeps(), sessionId, thinkingLevel));
  }

  async cycleSessionThinkingLevel(sessionId: string): Promise<PickyAgentSession> {
    return this.runRuntimeControlMutation(sessionId, () => cycleRuntimeThinkingLevel(this.runtimeControlDeps(), sessionId));
  }

  async cycleSessionModel(sessionId: string, direction: ModelCycleDirection): Promise<PickyAgentSession> {
    return this.runRuntimeControlMutation(sessionId, () => cycleRuntimeModel(this.runtimeControlDeps(), sessionId, direction));
  }

  private runtimeControlDeps(): RuntimeControlDeps {
    return {
      handle: (id, action) => this.runtimeHandleForSessionCommand(id, action),
      session: (id) => this.mustGet(id),
      patch: (id, patch) => this.patch(id, patch),
      commit: (id, work) => this.runSessionWrite(id, work),
      applyAssistantRun: async (id, currentAssistantRun) => {
        const before = this.mustGet(id);
        const proposed = { ...before, currentAssistantRun, updatedAt: new Date().toISOString() };
        const mutations = sessionProjectionCommitMutations(before, proposed);
        const after = { ...proposed, revision: projectionCommitRevision(before.revision ?? 0, mutations) };
        await this.store.save(after);
        this.sessions.set(id, after);
        publishSessionProjectionCommit(this, before, after, mutations, this.sessionProjectionEpoch);
        this.emit("sessionMeta", after);
      },
    };
  }

  private runRuntimeControlMutation<T>(sessionId: string, work: () => Promise<T>): Promise<T> {
    return this.runtimeControlQueue.run(sessionId, work);
  }

  async listRewindTargets(sessionId: string): Promise<RewindTarget[]> {
    return rewindListTargets(this.rewindDeps(), sessionId);
  }

  async getSessionDiff(sessionId: string, view: SessionDiffView): Promise<SessionDiffResult> {
    return readSessionDiff(this.mustGet(sessionId).cwd, view);
  }

  async rewindToEntry(sessionId: string, entryId: string): Promise<PickyAgentSession> {
    return runRewindToEntry(this.rewindDeps(), sessionId, entryId);
  }

  private rewindDeps(): RewindDeps {
    return {
      handle: (id, action) => this.runtimeHandleForSessionCommand(id, action),
      session: (id) => this.mustGet(id),
      removeMessages: (id, ids) => this.messageBuilder.removeMessages(id, ids),
      drainQueue: async (id, handle) => { this.clearPendingQueueDeliveries(id); this.materializedQueueDeliveries.delete(id); handle.clearQueue(); await this.applyQueueUpdate(id, [], []); },
      patch: (id, patch) => this.patch(id, patch),
      updateTodoState: (id, todoState) => this.updateTodoState(id, todoState),
      emitRewound: (id, editorText, removedIds) => this.emit("sessionRewound", id, editorText, removedIds),
      waitSettled: (id) => this.waitForRuntimeEvents(id),
    };
  }

  private async runtimeHandleForSessionCommand(sessionId: string, action: string): Promise<RuntimeSessionHandle> {
    const session = this.mustGet(sessionId);
    const handle = this.runtimeHandles.get(sessionId)
      ?? await this.pendingRuntimeHandle(sessionId, action)
      ?? await this.tryResumeRuntimeHandle(session);
    if (!handle) {
      const reason = "Runtime session is not attached";
      await this.appendLog(sessionId, `${action} rejected: ${reason}`);
      throw new Error(reason);
    }
    return handle;
  }

  async steerPickleSession(sessionId: string, text: string): Promise<PickyAgentSession> {
    if (!this.isPickleSession(sessionId)) throw new Error(`Session is not a Pickle: ${sessionId}`);
    return this.steer(sessionId, text);
  }

  private async preparePickleSessionForUserInput(sessionId: string): Promise<void> {
    if (!this.isPickleSession(sessionId)) return;
    this.mainAgent.clearLocalPickleTracking(sessionId);
    if (this.mustGet(sessionId).pinned) await this.patch(sessionId, { pinned: false });
  }

  async setTerminalSessionTailEnabled(sessionId: string, enabled: boolean): Promise<void> {
    await this.terminalSessionCoordinator.setTailEnabled(sessionId, enabled);
  }

  private invalidateRuntimeHandleAfterTerminalSync(
    sessionId: string,
    outcome: { activeLastMessageId?: string; baselinePiMessageId?: string; importedMessageCount: number },
  ): void {
    this.terminalSessionCoordinator.invalidateRuntimeHandleAfterSync(sessionId, outcome);
  }

  async syncTerminalSession(sessionId: string, baselinePiMessageId?: string): Promise<PickyAgentSession> {
    return this.terminalSessionCoordinator.sync(sessionId, baselinePiMessageId);
  }

  private async routeTerminalFollowUp(sessionId: string, text: string, context?: PickyContextPacket, visualDslEnabled = false): Promise<PickyAgentSession | undefined> {
    if (context?.source === "voice-follow-up") {
      const pendingAbort = this.pendingAbortOperations.get(sessionId);
      if (pendingAbort) {
        logAgentd("voice follow-up waiting for abort", { sessionId, textChars: text.length });
        await pendingAbort;
      }
    }
    const session = this.mustGet(sessionId);
    if (session.archived === true) throw new Error("Cannot follow up an archived session");
    if (this.isPickleSession(sessionId) && session.status === "cancelled" && context?.source === "voice-follow-up") {
      return this.steer(sessionId, text, context, visualDslEnabled);
    }
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);
    return undefined;
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket, visualDslEnabled = false): Promise<PickyAgentSession> {
    const terminalFollowUp = await this.routeTerminalFollowUp(sessionId, text, context, visualDslEnabled);
    if (terminalFollowUp) return terminalFollowUp;
    const session = this.mustGet(sessionId);

    const userBash = parseUserBashInput(text);
    if (userBash) return this.executeUserBash(sessionId, userBash, context);
    await this.preparePickleSessionForUserInput(sessionId);
    const awaitedPendingHandle = this.pendingRuntimeHandles.has(sessionId);
    const handle = await this.runtimeHandleForUserInput(session, "follow-up");
    const terminalAfterHandle = awaitedPendingHandle ? await this.assertNotTerminalForUserInput(sessionId, "follow-up") : undefined;
    if (terminalAfterHandle) return terminalAfterHandle;
    const terminalAfterMissingHandle = !handle ? await this.assertNotTerminalForUserInput(sessionId, "follow-up") : undefined;
    if (terminalAfterMissingHandle) return terminalAfterMissingHandle;
    if (!handle) {
      const hasPiSessionFile = Boolean(piSessionFilePathForSession(session));
      const reason = this.runtime.resume
        ? hasPiSessionFile
          ? "Runtime session is not attached after daemon restart and automatic Pi session reattach failed; start a new task or open the Pi terminal overlay"
          : "Runtime session is not attached after daemon restart and no Pi session file is available to resume; start a new task"
        : "Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay";
      await this.patch(sessionId, {
        status: "blocked",
        lastSummary: reason,
      });
      await this.appendLog(sessionId, `follow-up rejected: ${reason}`);
      throw new Error(reason);
    }
    if (await this.executeCompactCommandIfSupported(sessionId, text, handle)) return this.mustGet(sessionId);
    await this.cancelPendingExtensionUiForUserInput(sessionId, handle);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    if (isNoTurnStateRestoringSlashCommand(text)) this.rememberNoTurnRanSessionState(sessionId);
    if (isReloadSlashCommand(text)) this.pendingResourceReloadSessionIDs.add(sessionId);
    const visualDslLease = this.makePickleVisualDslLease(sessionId, text, context, visualDslEnabled);
    const prompt: BuiltPrompt = buildFollowUpPrompt(text, context, { visualDslEnabled: visualDslLease !== undefined });
    const runtimeActiveWhileTerminal = this.followUpLifecycleDiagnostics.logFollowUpRouting(
      sessionId,
      handle,
      text.length,
      prompt.imagePaths.length,
      context?.source,
    );
    logAgentd("follow-up requested", { sessionId, textChars: text.length, contextId: context?.id, images: prompt.imagePaths.length, visualDsl: visualDslLease ? 1 : 0 });
    await this.appendLog(sessionId, `${FOLLOWUP_PREFIX}${text}`);
    const commandReceiptId = await this.recordNonSkillSlashCommandReceipt(sessionId, text);
    await this.patch(sessionId, { status: "running", lastSummary: queueSubmissionSummary(handle.isCompacting, "Follow-up queued"), finalAnswer: undefined, thinkingPreview: undefined });
    const delivery = this.pushPendingQueueDelivery(sessionId, text, "user", {
      kind: "followUp",
      queueText: prompt.text,
      attachedImagesCount: prompt.imagePaths.length,
      visualDslLease,
    });
    this.activateImmediatePickleVisualDslDelivery(sessionId, delivery, visualDslLease, handle.isStreaming);
    this.followUpLifecycleDiagnostics.queueDelivery(sessionId, handle, prompt, text, commandReceiptId, runtimeActiveWhileTerminal);
    return this.mustGet(sessionId);
  }

  private async executeUserBash(sessionId: string, input: UserBashInput, context?: PickyContextPacket): Promise<PickyAgentSession> {
    return runUserBash(this.userBashDeps(), sessionId, input, context);
  }

  private userBashDeps(): UserBashDeps {
    return {
      session: (id) => this.mustGet(id),
      prepareForUserInput: (id) => this.preparePickleSessionForUserInput(id),
      hasPendingRuntimeHandle: (id) => this.pendingRuntimeHandles.has(id),
      handleForUserInput: (session, action) => this.runtimeHandleForUserInput(session, action),
      terminalSessionForUserInput: (id, kind) => this.assertNotTerminalForUserInput(id, kind),
      appendLog: (id, line) => this.appendLog(id, line),
      flushPendingAssistantOutput: async (id) => { await this.messageBuilder.flushAssistantText(id); await this.messageBuilder.flushThinking(id); },
      upsertSystemMessage: (id, messageId, text) => this.messageBuilder.upsertSystemMessage(id, messageId, text),
      recordError: (id, message) => this.messageBuilder.recordError(id, message),
      patch: (id, patch) => this.patch(id, patch),
      liveUpdateIntervalMs: this.options.userBashLiveUpdateIntervalMs ?? 1000,
    };
  }

  private async executeCompactCommandIfSupported(sessionId: string, text: string, handle: RuntimeSessionHandle): Promise<boolean> {
    return await this.terminalManualCompactionCoordinator.execute(sessionId, text, handle);
  }

  private async cancelPendingExtensionUiForUserInput(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    const pending = this.mustGet(sessionId).pendingExtensionUiRequest;
    if (!pending) return;
    // Best-effort cancel of the runtime-side dialog. The bridge may have already
    // discarded this id (turn completed, runtime resume, timeout, etc.) and would
    // throw "Unknown extension UI request"; previously that failure propagated out
    // of supervisor.followUp and got reported to the HUD as `command failed`,
    // which made the user's next message look like it had been silently dropped.
    // Use ignoreUnknown so stale cleanup never blocks new user input, and always
    // run the supervisor-side state reconciliation below.
    if (handle.answerExtensionUi) {
      await handle.answerExtensionUi(pending.id, { cancelled: true }, { ignoreUnknown: true });
    }
    await this.messageBuilder.cancelExtensionQuestion(sessionId, pending.id);
    const current = this.mustGet(sessionId);
    if (current.pendingExtensionUiRequest?.id === pending.id) {
      await this.patch(sessionId, { pendingExtensionUiRequest: undefined, thinkingPreview: undefined });
    }
  }

  private clearPendingQueueDeliveries(sessionId: string): void {
    this.followUpLifecycleDiagnostics.clearFollowUpStalls(sessionId);
    const pending = this.pendingQueueDeliveries.get(sessionId) ?? [];
    for (const delivery of pending) {
      if (delivery.visualDslLeaseId) this.pendingPickleVisualDslLeases.delete(delivery.visualDslLeaseId);
    }
    this.pendingQueueDeliveries.delete(sessionId);
  }

  async clearQueue(sessionId: string, _kind: "steering" | "followUp" | "all"): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle) throw new Error(`Session has no attached runtime: ${sessionId}`);
    // Drop pending deliveries BEFORE applyQueueUpdate so the [] -> [] transition is not
    // mis-interpreted as Pi delivering the prompts; user explicitly discarded them.
    this.clearPendingQueueDeliveries(sessionId);
    this.materializedQueueDeliveries.delete(sessionId);
    handle.clearQueue();
    await this.applyQueueUpdate(sessionId, [], []);
  }

  private async recordNonSkillSlashCommandReceipt(sessionId: string, text: string): Promise<string | undefined> {
    if (!isNonSkillSlashCommand(text)) return undefined;
    return this.messageBuilder.recordCommandReceipt(sessionId, text);
  }

  private async drainPendingTextOnce(sessionId: string, text: string): Promise<void> {
    await this.drainPendingQueueDeliveryOnce(sessionId, (entry) => entry.text === text);
  }

  private async drainPendingQueueDeliveryOnce(
    sessionId: string,
    matches: (entry: PendingQueueDelivery) => boolean,
    options: { activateVisualDsl?: boolean } = {},
  ): Promise<PendingQueueDelivery | undefined> {
    const pending = this.pendingQueueDeliveries.get(sessionId);
    if (!pending || pending.length === 0) return undefined;
    const index = pending.findIndex(matches);
    if (index < 0) return undefined;
    const [entry] = pending.splice(index, 1);
    if (!entry) return undefined;
    this.followUpLifecycleDiagnostics.clearFollowUpStall(entry.id);
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
    if (options.activateVisualDsl) this.activatePickleVisualDslDelivery(sessionId, entry);
    this.rememberMaterializedQueueDelivery(sessionId, entry);
    await this.removeMaterializedQueueItem(sessionId, entry);
    await this.messageBuilder.recordUserText(sessionId, entry.text, entry.originatedBy, {
      attachedImagesCount: entry.attachedImagesCount,
    });
    return entry;
  }

  private discardPendingTextOnce(sessionId: string, text: string): void {
    const pending = this.pendingQueueDeliveries.get(sessionId);
    if (!pending || pending.length === 0) return;
    const index = pending.findIndex((entry) => entry.text === text);
    if (index < 0) return;
    const [entry] = pending.splice(index, 1);
    this.followUpLifecycleDiagnostics.clearFollowUpStall(entry?.id ?? "");
    this.discardPickleVisualDslLease(sessionId, entry);
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
  }

  private async removeMaterializedQueueItem(sessionId: string, delivery: PendingQueueDelivery): Promise<boolean> {
    const current = this.sessions.get(sessionId);
    if (!current) return false;

    const removeOne = (items: readonly PickyQueueItem[]): { items: PickyQueueItem[]; changed: boolean } => {
      const indexById = items.findIndex((item) => item.id === delivery.id);
      const index = indexById >= 0 ? indexById : items.findIndex((item) => queueTextMatchesUserText(item.text, delivery.text));
      if (index < 0) return { items: [...items], changed: false };
      const next = [...items];
      next.splice(index, 1);
      return { items: next, changed: true };
    };

    const steers = current.queuedSteers ?? [];
    const followUps = current.queuedFollowUps ?? [];
    const removed = delivery.kind === "steering" ? removeOne(steers) : removeOne(followUps);
    if (!removed.changed) return false;

    const queuedSteers = delivery.kind === "steering" ? removed.items : steers;
    const queuedFollowUps = delivery.kind === "followUp" ? removed.items : followUps;
    await this.patch(sessionId, { queuedSteers, queuedFollowUps });
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => {
      this.emit("queueUpdated", sessionId, queuedSteers, queuedFollowUps, undefined, undefined, seq);
    });
    return true;
  }

  private rememberMaterializedQueueDelivery(sessionId: string, delivery: PendingQueueDelivery): void {
    const list = this.materializedQueueDeliveries.get(sessionId) ?? [];
    if (!list.some((entry) => entry.id === delivery.id)) list.push(delivery);
    this.materializedQueueDeliveries.set(sessionId, list);
  }

  private rememberNoTurnRanSessionState(sessionId: string, session = this.mustGet(sessionId)): void {
    this.noTurnRanSessionStateRestores.set(sessionId, {
      status: session.status,
      lastSummary: session.lastSummary,
      finalAnswer: session.finalAnswer,
      thinkingPreview: session.thinkingPreview,
    });
  }

  private consumeNoTurnRanSessionStateRestore(sessionId: string): Partial<PickyAgentSession> | undefined {
    const restore = this.noTurnRanSessionStateRestores.get(sessionId);
    this.noTurnRanSessionStateRestores.delete(sessionId);
    return restore;
  }

  private makePickleVisualDslLease(
    sessionId: string,
    text: string,
    context: PickyContextPacket | undefined,
    requested: boolean,
  ): PickleVisualDslLease | undefined {
    if (!requested || !this.pickleSessionIds.has(sessionId) || !context || context.screenshots.length === 0) return undefined;
    if (isNonSkillSlashCommand(text) || this.mainAgent.currentDisabledBuiltinTools.has("picky_screen_overlay")) return undefined;
    return this.pickleVisualDslCoordinator.createLease(sessionId, context);
  }

  private activateImmediatePickleVisualDslDelivery(
    sessionId: string,
    delivery: PendingQueueDelivery | undefined,
    lease: PickleVisualDslLease | undefined,
    isStreaming: boolean,
  ): void {
    if (delivery && !isStreaming) this.activatePickleVisualDslDelivery(sessionId, delivery);
    if (!delivery && lease) this.pickleVisualDslCoordinator.deactivate(sessionId, "visual DSL delivery unavailable", lease.id);
  }

  private activatePickleVisualDslDelivery(sessionId: string, delivery: PendingQueueDelivery): void {
    const leaseId = delivery.visualDslLeaseId;
    if (!leaseId) {
      this.pickleVisualDslCoordinator.deactivate(sessionId, "non-visual input delivered");
      return;
    }
    const lease = this.pendingPickleVisualDslLeases.get(leaseId);
    if (!lease) return;
    this.pendingPickleVisualDslLeases.delete(leaseId);
    this.pickleVisualDslCoordinator.activate(lease);
  }

  private discardPickleVisualDslLease(sessionId: string, delivery: PendingQueueDelivery | undefined): void {
    if (!delivery?.visualDslLeaseId) return;
    this.pendingPickleVisualDslLeases.delete(delivery.visualDslLeaseId);
    this.pickleVisualDslCoordinator.deactivate(sessionId, "delivery discarded", delivery.visualDslLeaseId);
  }

  private pushPendingQueueDelivery(
    sessionId: string,
    text: string,
    originatedBy: "user" | "main_agent",
    options: { kind: "steering" | "followUp"; queueText?: string; attachedImagesCount?: number; visualDslLease?: PickleVisualDslLease },
  ): PendingQueueDelivery | undefined {
    // Slash commands like /diff, /fix-tests, /name, /compact are not really chat input — they
    // either run an extension overlay, fire a prompt template, or trigger a Picky-intercepted
    // built-in. Recording them as user_text adds a misleading bubble to the conversation card.
    // Skills (/skill:<name>) ARE recorded because they expand into a real prompt and the user
    // expects to see what they invoked. The strict identifier match also exempts path-like
    // inputs (/Users/foo) which contain a second '/' before whitespace.
    //
    // For skills, Pi expands the slash command server-side and the queue snapshot carries the
    // expansion (e.g. SKILL.md body). The pi-sdk-runtime translates those entries back to this
    // raw text before they reach the supervisor, so `isPromptInRuntimeQueue` and
    // `drainDeliveredQueueItems` both see the raw text and exactly one user_text gets recorded
    // per submission.
    if (isNonSkillSlashCommand(text)) return undefined;
    const list = this.pendingQueueDeliveries.get(sessionId) ?? [];
    const entry: PendingQueueDelivery = {
      id: randomUUID(),
      kind: options.kind,
      text,
      originatedBy,
      ...(options.queueText && options.queueText !== text ? { queueText: options.queueText } : {}),
      ...(options.attachedImagesCount && options.attachedImagesCount > 0
        ? { attachedImagesCount: options.attachedImagesCount }
        : {}),
      ...(options.visualDslLease ? { visualDslLeaseId: options.visualDslLease.id } : {}),
    };
    list.push(entry);
    if (options.visualDslLease) this.pendingPickleVisualDslLeases.set(options.visualDslLease.id, options.visualDslLease);
    this.pendingQueueDeliveries.set(sessionId, list);
    return entry;
  }

  private async drainDeliveredQueueItems(sessionId: string, removedItems: readonly PickyQueueItem[]): Promise<void> {
    const pending = this.pendingQueueDeliveries.get(sessionId);
    if (!pending || pending.length === 0) return;
    for (const item of removedItems) {
      const indexById = item.id ? pending.findIndex((entry) => entry.id === item.id) : -1;
      const index = indexById >= 0 ? indexById : pending.findIndex((entry) => queueTextMatchesUserText(item.text, entry.text));
      if (index < 0) continue;
      const [entry] = pending.splice(index, 1);
      if (!entry) continue;
      this.followUpLifecycleDiagnostics.clearFollowUpStall(entry.id);
      this.activatePickleVisualDslDelivery(sessionId, entry);
      await this.messageBuilder.recordUserText(sessionId, entry.text, entry.originatedBy, {
        attachedImagesCount: entry.attachedImagesCount,
      });
    }
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
  }

  async applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle || !this.sessions.has(sessionId)) return;
    await this.applyQueueUpdateWithModes(sessionId, steering, followUp, handle.steeringMode, handle.followUpMode);
  }

  private async applyQueueUpdateWithModes(sessionId: string, steering: readonly string[], followUp: readonly string[], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode): Promise<void> {
    const previous = this.queueUpdateChains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(() => this.applyQueueUpdateNow(sessionId, steering, followUp, steeringMode, followUpMode));
    this.queueUpdateChains.set(sessionId, next.catch(() => undefined));
    await next;
  }

  private async waitForQueuedStateToSettle(sessionId: string): Promise<void> {
    await (this.queueUpdateChains.get(sessionId) ?? Promise.resolve());
  }

  // eslint-disable-next-line complexity -- Queue reconciliation is atomic so persisted items, delivery drains, modes, and emitted sequence numbers stay consistent.
  private async applyQueueUpdateNow(sessionId: string, steering: readonly string[], followUp: readonly string[], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode): Promise<void> {
    if (!this.sessions.has(sessionId)) return;
    const enqueuedAt = new Date().toISOString();
    const current = this.mustGet(sessionId);
    const pendingDeliveries = this.pendingQueueDeliveries.get(sessionId) ?? [];
    const reconciliation = dropAlreadyMaterializedQueueEntries(
      { steering, followUp },
      pendingDeliveries,
      this.materializedQueueDeliveries.get(sessionId) ?? [],
    );
    const nextRuntimeQueues = reconciliation.queues;
    if (reconciliation.remainingMaterialized.length > 0) {
      this.materializedQueueDeliveries.set(sessionId, reconciliation.remainingMaterialized);
    } else {
      this.materializedQueueDeliveries.delete(sessionId);
    }
    const queuedSteers = queueItems(nextRuntimeQueues.steering, enqueuedAt, current.queuedSteers, pendingDeliveries.filter((entry) => entry.kind === "steering"), randomUUID);
    const queuedFollowUps = queueItems(nextRuntimeQueues.followUp, enqueuedAt, current.queuedFollowUps, pendingDeliveries.filter((entry) => entry.kind === "followUp"), randomUUID);
    const previousSteeringMode = this.lastEmittedSteeringMode.get(sessionId) ?? current.steeringMode ?? "one-at-a-time";
    const previousFollowUpMode = this.lastEmittedFollowUpMode.get(sessionId) ?? current.followUpMode ?? "one-at-a-time";
    const queueChanged = !sameQueueItems(current.queuedSteers ?? [], queuedSteers) || !sameQueueItems(current.queuedFollowUps ?? [], queuedFollowUps);
    const modeChanged = steeringMode !== (current.steeringMode ?? "one-at-a-time") || followUpMode !== (current.followUpMode ?? "one-at-a-time");
    const removedItems = diffQueueRemovedItems(current.queuedSteers ?? [], current.queuedFollowUps ?? [], nextRuntimeQueues.steering, nextRuntimeQueues.followUp);
    for (const item of removedItems) this.followUpLifecycleDiagnostics.clearFollowUpStallForQueueItem(sessionId, item);
    await this.patch(sessionId, { queuedSteers, queuedFollowUps, steeringMode, followUpMode });
    this.followUpLifecycleDiagnostics.logLifecycle("queueUpdateReconciled", sessionId, this.runtimeHandles.get(sessionId), {
      steeringCount: nextRuntimeQueues.steering.length,
      followUpCount: nextRuntimeQueues.followUp.length,
      removedCount: removedItems.length,
    });
    if (removedItems.length > 0 && !isTerminalStatus(current.status)) {
      await this.drainDeliveredQueueItems(sessionId, removedItems);
    }

    const emittedSteeringMode = steeringMode === previousSteeringMode ? undefined : steeringMode;
    const emittedFollowUpMode = followUpMode === previousFollowUpMode ? undefined : followUpMode;
    this.lastEmittedSteeringMode.set(sessionId, steeringMode);
    this.lastEmittedFollowUpMode.set(sessionId, followUpMode);
    if (!queueChanged && !modeChanged) return;
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("queueUpdated", sessionId, queuedSteers, queuedFollowUps, emittedSteeringMode, emittedFollowUpMode, seq); });
  }

  private async handleRuntimeInputDelivery(sessionId: string, event: Extract<RuntimeEvent, { type: "input_delivery" }>): Promise<void> {
    if (!this.sessions.has(sessionId)) return;
    const deliveredText = extractPickyPromptUserInstruction(event.text) ?? event.text;
    this.followUpLifecycleDiagnostics.logLifecycle("runtimeInputDelivery", sessionId, this.runtimeHandles.get(sessionId), {
      queueKind: event.queueKind ?? "none",
      originatedBy: event.originatedBy,
      textChars: deliveredText.length,
    });
    const exactMatch = await this.drainPendingQueueDeliveryOnce(sessionId, (entry) => {
      if (event.queueKind && entry.kind !== event.queueKind) return false;
      return entry.text === deliveredText || entry.text === event.text;
    }, { activateVisualDsl: true });
    if (exactMatch || !event.queueKind) return;

    // Some Pi SDK paths can surface the built prompt as the message_start text while Picky tracks
    // the raw user instruction in pendingQueueDeliveries. If there is exactly one pending item of
    // the delivered queue kind, the message_start is still authoritative evidence that Pi consumed
    // that pending input even when no trailing queue_update [] is emitted.
    const sameKindPending = (this.pendingQueueDeliveries.get(sessionId) ?? []).filter((entry) => entry.kind === event.queueKind);
    if (sameKindPending.length === 1) {
      await this.drainPendingQueueDeliveryOnce(sessionId, (entry) => entry.id === sameKindPending[0]!.id, { activateVisualDsl: true });
    }
  }

  private async handleRuntimeInputMessage(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void> {
    if (event.originatedBy !== "pi_extension") return;
    // Idle custom extension messages are display-only context. They must not unpin a completed
    // Pickle or clear its completion notification tracking; RuntimeEventHandler journals them.
    if (event.role === "custom" && event.turnActive !== true) return;
    await this.preparePickleSessionForUserInput(sessionId);
  }

  private async incrementActivity(sessionId: string, category: ToolCategory): Promise<void> {
    const previous = this.activityUpdateChains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(() => this.incrementActivityNow(sessionId, category));
    this.activityUpdateChains.set(sessionId, next.catch(() => undefined));
    await next;
  }

  private async incrementActivityNow(sessionId: string, category: ToolCategory): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    // activitySummary mirrors the in-progress turn so the HUD live strip resets on each
    // turn boundary. Per-turn snapshots are committed as agent_activity messages by
    // commitTurnActivityNow when the turn ends.
    const currentTurn = this.turnActivity.get(sessionId) ?? zeroActivitySummary();
    const nextTurn = { ...currentTurn, [category]: (currentTurn[category] ?? 0) + 1 };
    this.turnActivity.set(sessionId, nextTurn);
    // activitySummary is broadcast via the dedicated `sessionActivityUpdated` event; suppress the
    // accompanying full `sessionUpdated` so streaming tool/thinking turns do not flood the HUD
    // with redundant whole-session snapshots. Disk persistence still happens inside patch().
    await this.patch(sessionId, { activitySummary: nextTurn }, { emitSession: false });
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("activityUpdated", sessionId, nextTurn, seq); });
  }

  private async commitTurnActivity(sessionId: string): Promise<void> {
    const previous = this.activityUpdateChains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(() => this.commitTurnActivityNow(sessionId));
    this.activityUpdateChains.set(sessionId, next.catch(() => undefined));
    await next;
  }

  private async commitTurnActivityNow(sessionId: string): Promise<void> {
    const snapshot = this.turnActivity.get(sessionId);
    if (!snapshot || !hasActivity(snapshot)) return;
    await this.messageBuilder.recordActivitySnapshot(sessionId, snapshot);
    this.turnActivity.delete(sessionId);
    const reset = zeroActivitySummary();
    // Same rationale as incrementActivityNow: the live update is carried by `sessionActivityUpdated`,
    // so we suppress the accompanying full `sessionUpdated` here too.
    await this.patch(sessionId, { activitySummary: reset }, { emitSession: false });
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("activityUpdated", sessionId, reset, seq); });
  }

  private async interruptedRuntimeLiveStatePatch(sessionId: string): Promise<{ patch: Partial<PickyAgentSession>; hadPendingExtensionUiRequest: boolean }> {
    let current = this.mustGet(sessionId);
    const pendingRequestId = current.pendingExtensionUiRequest?.id;
    if (pendingRequestId) {
      await this.messageBuilder.cancelExtensionQuestion(sessionId, pendingRequestId);
      current = this.mustGet(sessionId);
    }
    return {
      hadPendingExtensionUiRequest: Boolean(pendingRequestId),
      patch: buildInterruptedRuntimeLiveStatePatch(current),
    };
  }

  private async tryResumeRuntimeHandle(session: PickyAgentSession): Promise<RuntimeSessionHandle | undefined> {
    const attached = this.runtimeHandles.get(session.id);
    if (attached) return attached;
    const pending = await this.pendingRuntimeHandle(session.id, "resume runtime");
    if (pending) return pending;
    if (!this.runtime.resume) return undefined;
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) return undefined;

    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(session.id, pendingHandle.promise);
    this.pendingRuntimeAbortControllers.set(session.id, new AbortController());

    try {
      logAgentd("runtime resume requested", { sessionId: session.id, sessionFilePath });
      const handle = await this.runtime.resume(sessionFilePath, { cwd: session.cwd, sessionId: session.id });
      const currentBeforeAttach = this.mustGet(session.id);
      if (["failed", "cancelled"].includes(currentBeforeAttach.status) && currentBeforeAttach.status !== session.status) {
        await disposeRuntimeHandle(handle, "discarded-terminal-runtime-resume");
        pendingHandle.reject(new Error(`Runtime resume discarded because session is ${currentBeforeAttach.status}`));
        return undefined;
      }
      await this.attachRuntimeHandle(session.id, handle);
      pendingHandle.resolve(handle);
      await this.appendLog(session.id, `runtime reattached from pi session: ${sessionFilePath}`);
      const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
      const current = this.mustGet(session.id);
      await this.patch(session.id, buildRuntimeReattachPatch(
        current,
        interrupted.patch,
        interrupted.hadPendingExtensionUiRequest,
      ));
      return handle;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      pendingHandle.reject(error);
      logAgentd("runtime resume failed", { sessionId: session.id, sessionFilePath, error: message });
      await this.appendLog(session.id, `runtime reattach failed: ${message}`);
      return undefined;
    } finally {
      if (this.pendingRuntimeHandles.get(session.id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(session.id);
      this.pendingRuntimeAbortControllers.delete(session.id);
    }
  }

  // eslint-disable-next-line complexity -- Steer owns one transactional flow across runtime attachment, rollback, queue journaling, and synchronous slash handling.
  async steer(sessionId: string, text: string, context?: PickyContextPacket, visualDslEnabled = false): Promise<PickyAgentSession> {
    const pendingAbort = this.pendingAbortOperations.get(sessionId);
    if (pendingAbort) {
      logAgentd("steer waiting for abort", { sessionId, textChars: text.length });
      await pendingAbort;
    }
    const session = this.mustGet(sessionId);
    if (session.archived === true) throw new Error("Cannot steer an archived session");

    const userBash = parseUserBashInput(text);
    if (userBash) return this.executeUserBash(sessionId, userBash, context);
    await this.preparePickleSessionForUserInput(sessionId);
    const awaitedPendingHandle = this.pendingRuntimeHandles.has(sessionId);
    const handle = await this.runtimeHandleForUserInput(session, "steer");
    const terminalAfterHandle = awaitedPendingHandle ? await this.assertNotTerminalForUserInput(sessionId, "steer") : undefined;
    if (terminalAfterHandle) return terminalAfterHandle;
    const terminalAfterMissingHandle = !handle ? await this.assertNotTerminalForUserInput(sessionId, "steer") : undefined;
    if (terminalAfterMissingHandle) return terminalAfterMissingHandle;
    if (!handle) {
      const reason = "Runtime session is not attached";
      await this.appendLog(sessionId, `steer rejected: ${reason}`);
      throw new Error(reason);
    }
    if (await this.executeCompactCommandIfSupported(sessionId, text, handle)) return this.mustGet(sessionId);
    await this.cancelPendingExtensionUiForUserInput(sessionId, handle);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    const visualDslLease = this.makePickleVisualDslLease(sessionId, text, context, visualDslEnabled);
    const prompt = buildSteerPrompt(text, context, { visualDslEnabled: visualDslLease !== undefined });
    const previousSession = this.mustGet(sessionId);
    if (isNoTurnStateRestoringSlashCommand(text)) this.rememberNoTurnRanSessionState(sessionId, previousSession);
    const revivedTerminalSession = isTerminalStatus(previousSession.status);
    if (revivedTerminalSession) {
      await this.patch(sessionId, { status: "running", lastSummary: "Steering message sent", thinkingPreview: undefined });
    }
    logAgentd("steer requested", { sessionId, textChars: text.length, contextId: context?.id, images: prompt.imagePaths.length, isStreaming: handle.isStreaming, visualDsl: visualDslLease ? 1 : 0 });
    const commandReceiptId = await this.recordNonSkillSlashCommandReceipt(sessionId, text);
    const delivery = this.pushPendingQueueDelivery(sessionId, text, "user", {
      kind: "steering",
      queueText: prompt.text,
      attachedImagesCount: prompt.imagePaths.length,
      visualDslLease,
    });
    this.activateImmediatePickleVisualDslDelivery(sessionId, delivery, visualDslLease, handle.isStreaming);
    let outcome: RuntimeSteerResult | undefined;
    try {
      outcome = await handle.steer(prompt);
    } catch (error) {
      await this.messageBuilder.markCommandReceiptFailed(sessionId, commandReceiptId, error instanceof Error ? error.message : String(error));
      this.discardPendingTextOnce(sessionId, text);
      if (revivedTerminalSession && this.mustGet(sessionId).status === "running") {
        await this.patch(sessionId, {
          status: previousSession.status,
          lastSummary: previousSession.lastSummary,
          finalAnswer: previousSession.finalAnswer,
          thinkingPreview: previousSession.thinkingPreview,
        });
      }
      throw error;
    }
    await this.appendLog(sessionId, `${STEER_PREFIX}${text}`);
    // Pi accepted the prompt: either it queued the steer (queue_update will eventually drain the
    // pending entry) or it executed inline. For the inline case the prompt is no longer in either
    // Pi queue, so drain immediately so the user_text journal entry surfaces without waiting for a
    // queue_update that will never fire.
    await this.waitForRuntimeEvents(sessionId);
    await this.waitForQueuedStateToSettle(sessionId);
    if (outcome?.handledSynchronously || !this.followUpLifecycleDiagnostics.isPromptInRuntimeQueue(handle, text)) {
      await this.drainPendingTextOnce(sessionId, text);
    }
    // Pi handles `/slash` extension commands and `input` handlers that return `handled` synchronously
    // inside `session.prompt()` without starting an agent turn. PiSdkRuntimeSession synthesizes a
    // `completed` runtime status for those and surfaces `handledSynchronously: true` here. Do not
    // leave the HUD card running if no synthetic status arrived after the pre-prompt revival patch.
    // Normal text steers still flip to `running` immediately so the existing UX contract is preserved.
    if (outcome?.handledSynchronously) {
      const current = this.mustGet(sessionId);
      if (revivedTerminalSession && current.status === "running") {
        await this.patch(sessionId, { status: previousSession.status, lastSummary: previousSession.lastSummary, thinkingPreview: previousSession.thinkingPreview });
      }
    } else {
      await this.patch(sessionId, { status: "running", lastSummary: queueSubmissionSummary(handle.isCompacting, "Steering message sent"), finalAnswer: undefined, thinkingPreview: undefined });
    }
    return this.mustGet(sessionId);
  }

  async abort(sessionId: string): Promise<PickyAgentSession> {
    const existing = this.pendingAbortOperations.get(sessionId);
    if (existing) return existing;

    const operation = this.performAbort(sessionId);
    this.pendingAbortOperations.set(sessionId, operation);
    try {
      return await operation;
    } finally {
      if (this.pendingAbortOperations.get(sessionId) === operation) this.pendingAbortOperations.delete(sessionId);
    }
  }

  private async performAbort(sessionId: string): Promise<PickyAgentSession> {
    const beforeAbort = this.mustGet(sessionId);
    if (beforeAbort.archived === true) throw new Error("Cannot abort an archived session");
    if (this.terminalManualCompactionCoordinator.hasPending(sessionId)) this.runtimeEventHandler.suppressManualTerminalCompaction(sessionId);
    else this.runtimeEventHandler.clearManualTerminalCompaction(sessionId);
    const handle = this.runtimeHandles.get(sessionId);
    const cancellationMessagesBefore = countSystemMessages(beforeAbort, "Cancelled by user");
    logAgentd("abort requested", { sessionId, hasHandle: Boolean(handle) });
    if (handle) {
      // Match Pi TUI full-abort semantics by discarding queued input before terminal events.
      await this.clearQueue(sessionId, "all");
      await handle.abort();
      await this.waitForRuntimeEvents(sessionId);
    }
    // Abort succeeded or no runtime handle remains, so no deferred plugin reload can drain later.
    this.pendingPostCompactionReloadIds.delete(sessionId);
    if (beforeAbort.status !== "cancelled" && countSystemMessages(this.mustGet(sessionId), "Cancelled by user") === cancellationMessagesBefore) {
      await this.messageBuilder.recordSystemMessage(sessionId, "Cancelled by user");
    }
    // Pending follow-up/steer prompts that were waiting for Pi to dequeue them will never be
    // processed after an abort, so drop their journal placeholders too.
    this.clearPendingQueueDeliveries(sessionId);
    this.pickleVisualDslCoordinator.deactivate(sessionId, "session aborted");
    this.materializedQueueDeliveries.delete(sessionId);
    const current = this.mustGet(sessionId);
    if (current.pendingExtensionUiRequest) await this.messageBuilder.cancelExtensionQuestion(sessionId, current.pendingExtensionUiRequest.id);
    await this.patch(sessionId, { status: "cancelled", lastSummary: "Cancelled", tools: settleActiveTools(current.tools, "Tool stopped because the session was cancelled."), pendingExtensionUiRequest: undefined, thinkingPreview: undefined });
    this.pendingRuntimeAbortControllers.get(sessionId)?.abort(new Error("Session cancelled while runtime was starting"));
    await this.materializeTerminalArtifacts(sessionId);
    return this.mustGet(sessionId);
  }

  async answerExtensionUi(sessionId: string, requestId: string, value: unknown): Promise<PickyAgentSession> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle?.answerExtensionUi) throw new Error("Runtime session cannot answer extension UI requests");
    const pendingBeforeAnswer = this.mustGet(sessionId).pendingExtensionUiRequest;
    await handle.answerExtensionUi(requestId, value);
    const pendingAfterAnswer = this.mustGet(sessionId).pendingExtensionUiRequest;
    const answered = pendingBeforeAnswer?.id === requestId
      ? pendingBeforeAnswer
      : pendingAfterAnswer?.id === requestId ? pendingAfterAnswer : undefined;
    const summary = answered ? summarizeExtensionUiAnswer(answered, value) : undefined;
    if (summary) await this.appendLog(sessionId, `${EXTENSION_ANSWER_PREFIX}${summary}`);
    // The extension may open a follow-up dialog immediately after receiving this
    // answer (e.g. /delay-list picks an entry, then asks what to do with it). That
    // dialog patches pendingExtensionUiRequest concurrently, so the clear below
    // must re-check inside the serialized session write or it would clobber the
    // new dialog and leave its question card permanently unanswerable.
    const commit = await this.commitSession(sessionId, (current) => {
      if (current.pendingExtensionUiRequest?.id !== requestId) return current;
      return {
        ...current,
        pendingExtensionUiRequest: undefined,
        status: "running",
        lastSummary: "Extension UI answered",
        thinkingPreview: undefined,
        updatedAt: new Date().toISOString(),
      };
    });
    if (commit.changed) this.emit("session", commit.after);
    return this.mustGet(sessionId);
  }

  private async detachRuntimeHandle(sessionId: string, abort = false): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    this.followUpLifecycleDiagnostics.clearFollowUpStalls(sessionId);
    // Detach before teardown so terminal events emitted while Pi settles cannot
    // mutate a session whose external transcript just became authoritative.
    this.runtimeHandleUnsubscribes.get(sessionId)?.();
    this.runtimeHandleUnsubscribes.delete(sessionId);
    this.runtimeHandles.delete(sessionId);
    if (handle) await disposeRuntimeHandle(handle, abort ? "detached-terminal-runtime" : "detached-runtime");
  }

  private async attachRuntimeHandle(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    this.runtimeHandles.set(sessionId, handle);
    this.runtimeHandleUnsubscribes.set(sessionId, handle.subscribe((event) => void this.applyRuntimeEvent(sessionId, event)));
    // Teach the runtime adapter what the host currently surfaces, so it can
    // skip a runtime-only "pending extension UI" signal that the supervisor
    // never accepted (e.g. Pi resume revived a stale request before the
    // supervisor subscribed). Without this, an unanswered askUserQuestion that
    // survives an agentd restart parks the next turn on waiting_for_input with
    // no question bubble for the user to answer.
    handle.setHostPendingExtensionUiPresent?.(() => Boolean(this.sessions.get(sessionId)?.pendingExtensionUiRequest));
    const todoResolution = handle.getTodoStateResolution?.();
    if (todoResolution?.resolved) await this.updateTodoState(sessionId, todoResolution.todoState);
    const currentAssistantRun = handle.getAssistantRunMetadata?.();
    if (currentAssistantRun) await this.patch(sessionId, { currentAssistantRun });
    await this.applyQueueUpdate(sessionId, handle.getSteeringMessages(), handle.getFollowUpMessages());
  }

  private async applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void> {
    const queueModes = event.type === "queue_update"
      ? { steeringMode: this.runtimeHandles.get(sessionId)?.steeringMode ?? "one-at-a-time", followUpMode: this.runtimeHandles.get(sessionId)?.followUpMode ?? "one-at-a-time" }
      : undefined;
    const previous = this.runtimeEventChains.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(async () => {
      if (event.type === "session_replaced") {
        await this.applyRuntimeSessionReplacement(sessionId, event);
        return;
      }
      if (event.type === "queue_update") {
        if (!this.sessions.has(sessionId) || isTerminalStatus(this.mustGet(sessionId).status)) return;
        await this.applyQueueUpdateWithModes(sessionId, event.steering, event.followUp, queueModes!.steeringMode, queueModes!.followUpMode);
        return;
      }
      if (event.type === "input_delivery") {
        await this.handleRuntimeInputDelivery(sessionId, event);
        return;
      }
      await this.runtimeEventHandler.handle(sessionId, event);
      if (event.type === "status") await this.applyRuntimeStatusSideEffects(sessionId, event);
      this.maybeDrainPostCompactionReload(sessionId);
    });
    const tracked = next.catch(() => undefined);
    this.runtimeEventChains.set(sessionId, tracked);
    await next;
    if (this.runtimeEventChains.get(sessionId) === tracked) this.runtimeEventChains.delete(sessionId);
  }

  private async applyRuntimeStatusSideEffects(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): Promise<void> {
    if (["failed", "cancelled"].includes(event.status)) this.followUpLifecycleDiagnostics.clearFollowUpStalls(sessionId);
    // `agent_start` normalizes to this status event; once Pi starts a new agent cycle the
    // queued follow-up is no longer the stalled state this detector tracks.
    if (event.status === "running" && event.summary === "Agent started") this.followUpLifecycleDiagnostics.clearFollowUpStalls(sessionId);
    if (event.noTurnRan && ["completed", "failed", "cancelled"].includes(event.status)) {
      const wasPendingReload = this.pendingResourceReloadSessionIDs.delete(sessionId);
      if (wasPendingReload && event.status === "completed" && !event.preserveSessionState) {
        this.emit("resourcesReloaded", sessionId);
      }
    }
  }

  private async waitForRuntimeEvents(sessionId: string): Promise<void> {
    await (this.runtimeEventChains.get(sessionId) ?? Promise.resolve());
  }

  /**
   * Drain a deferred plugin reload as soon as the session leaves the compacting
   * state. Called on every runtime event so we react to the first event that
   * lands after compaction settles, without polling. Idempotent: the followUp
   * path silently no-ops if the session is terminal by the time we reach it.
   */
  private maybeDrainPostCompactionReload(sessionId: string): void {
    if (!this.pendingPostCompactionReloadIds.has(sessionId)) return;
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle) return;
    if (handle.isCompacting === true) return;
    if (handle.isStreaming) return;
    const session = this.sessions.get(sessionId);
    if (!session || isTerminalStatus(session.status)) {
      this.pendingPostCompactionReloadIds.delete(sessionId);
      return;
    }
    this.pendingPostCompactionReloadIds.delete(sessionId);
    void this.followUp(sessionId, "/reload").catch((error) => {
      logAgentd("plugins reload deferred followUp failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
    });
  }

  private async applyRuntimeSessionReplacement(sessionId: string, event: Extract<RuntimeEvent, { type: "session_replaced" }>): Promise<void> {
    const current = this.mustGet(sessionId);
    const cwd = normalizeOptionalString(event.cwd) ?? current.cwd;
    const context = this.sessionContexts.get(sessionId);
    const nextContext = context ? { ...context, cwd, transcript: undefined, screenshots: [] } : undefined;
    if (nextContext) this.sessionContexts.set(sessionId, nextContext);
    this.clearPendingQueueDeliveries(sessionId);
    this.pickleVisualDslCoordinator.deactivate(sessionId, "runtime session replaced");
    this.materializedQueueDeliveries.delete(sessionId);
    this.queueUpdateChains.delete(sessionId);
    this.turnActivity.delete(sessionId);
    this.noTurnRanSessionStateRestores.delete(sessionId);
    this.pendingResourceReloadSessionIDs.delete(sessionId);
    this.pendingPostCompactionReloadIds.delete(sessionId);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    this.messageBuilder.onSessionRemoved(sessionId);
    if (this.isPickleSession(sessionId)) this.mainAgent.clearLocalPickleTracking(sessionId);
    await this.patch(sessionId, buildRuntimeSessionReplacementPatch({
      cwd,
      title: this.isPickleSession(sessionId)
        ? titleForEmptyPickleSession({ ...(nextContext ?? {}), cwd } as PickyContextPacket)
        : current.title,
      sessionFilePath: event.sessionFilePath,
    }), { emitFullSession: true, forceCollectionReplacements: true });
    logAgentd("runtime session replaced", { sessionId, reason: event.reason, cwd, sessionFilePath: event.sessionFilePath });
  }

  private async chainEmit(sessionId: string, fn: () => Promise<void>): Promise<void> {
    const previous = this.emitChains.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(fn);
    this.emitChains.set(sessionId, next);
    await next;
    if (this.emitChains.get(sessionId) === next) this.emitChains.delete(sessionId);
  }

  private async appendLog(sessionId: string, line: string): Promise<void> {
    const piSessionFilePath = piSessionFilePathFromLogLine(line);
    await this.commitSession(sessionId, (current) => sessionWithAppendedLog(current, line));
    this.emit("log", sessionId, line);
    // STEER_PREFIX and FOLLOWUP_PREFIX user_text writes are intentionally NOT recorded here. The
    // supervisor decides per-call whether to recordUserText immediately (Pi will execute inline)
    // or defer until the prompt is actually dequeued by Pi (so queued items render as pending
    // bubbles in the HUD instead of being hidden behind a duplicate user bubble).
    if (line.startsWith(EXTENSION_ANSWER_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(EXTENSION_ANSWER_PREFIX.length), "user");
    } else if (line.startsWith(HANDOFF_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(HANDOFF_PREFIX.length), "main_agent");
    }
    if (piSessionFilePath) {
      void this.pickleSessionTitleRefresher.refresh(sessionId);
    }
  }

  private async materializeTerminalArtifacts(sessionId: string): Promise<void> { const materialized = await this.artifactMaterializer.materializeTerminalArtifacts(this.mustGet(sessionId)); if (!materialized) return; await this.patch(sessionId, { artifacts: materialized.artifacts }, { emitSession: false }); for (const artifact of materialized.emittedArtifacts) this.emit("artifact", sessionId, artifact); }
  private terminalDurableCommitDependencies(): TerminalDurableCommitDependencies {
    return {
      runExclusiveMessageOperation: this.messageBuilder.runExclusiveTerminalOperation.bind(this.messageBuilder), runSessionWrite: this.runSessionWrite.bind(this), getSession: this.mustGet.bind(this),
      messageSnapshot: this.messageBuilder.terminalSnapshot.bind(this.messageBuilder), runtimeSnapshot: this.runtimeEventHandler.terminalSnapshot.bind(this.runtimeEventHandler), turnActivity: this.turnActivity.get.bind(this.turnActivity),
      materialize: this.artifactMaterializer.materializeTerminalArtifacts.bind(this.artifactMaterializer), save: this.store.save.bind(this.store), setSession: this.sessions.set.bind(this.sessions),
      rehydrateMessageSession: this.messageBuilder.commitTerminalSession.bind(this.messageBuilder), resetTerminalAssistantDraft: this.runtimeEventHandler.resetTerminalAssistantDraft.bind(this.runtimeEventHandler), resetTerminalThinkingDraft: this.runtimeEventHandler.resetTerminalThinkingDraft.bind(this.runtimeEventHandler), resetTerminalThinkingActive: this.runtimeEventHandler.resetTerminalThinkingActive.bind(this.runtimeEventHandler), clearTerminalPendingThinkingFlush: this.runtimeEventHandler.clearTerminalPendingThinkingFlush.bind(this.runtimeEventHandler), markTerminalRunProcessed: this.runtimeEventHandler.markTerminalRunProcessed.bind(this.runtimeEventHandler), clearTurnActivity: this.turnActivity.delete.bind(this.turnActivity),
      publish: async (id, publication, activity, artifacts) => { if (publication.mutations.length > 0) this.emit("sessionProjectionTransaction", id, publication.before, publication.after, publication.mutations, this.sessionProjectionEpoch); await emitTerminalV1Compatibility({ nextSeq: this.nextSeq.bind(this), chainEmit: this.chainEmit.bind(this), emitMessageAppended: (session, message, seq) => this.emit("messageAppended", session, message, seq), emitMessageRemoved: (session, messageId, seq) => this.emit("messageRemoved", session, messageId, seq), emitMessageReplaced: (session, messageId, message, seq) => this.emit("messageReplaced", session, messageId, message, seq), emitActivityUpdated: (session, value, seq) => this.emit("activityUpdated", session, value, seq), emitSessionMeta: (value) => this.emit("sessionMeta", value), emitArtifact: (session, artifact) => this.emit("artifact", session, artifact) }, id, publication.before, publication.after, activity, artifacts); },
      isPickleSession: this.isPickleSession.bind(this), notifyPickleCompletion: (sessionId, committedSession) => this.mainAgent.notifyLocalPickleCompletion(sessionId, committedSession),
      logNotificationFailure: (id, error) => { logAgentd("Pickle completion notification failed after terminal commit", { sessionId: id, error: error instanceof Error ? error.message : String(error) }); },
    };
  }
  private async finalizeTerminal(sessionId: string, event: Extract<RuntimeEvent, { type: "status" }>): Promise<void> { await finalizeTerminalOperation(this.terminalDurableCommitDependencies(), sessionId, event); }
  private async patch(sessionId: string, patch: Partial<PickyAgentSession>, options: { emitSession?: boolean; emitFullSession?: boolean; forceCollectionReplacements?: boolean } = {}): Promise<void> {
    const commit = await this.commitSession(sessionId, (current) => isSemanticNoOpPatch(current, patch) ? current : { ...current, ...patch, updatedAt: new Date().toISOString() }, options);
    if (commit.changed && (options.emitSession ?? true)) this.emit(options.emitFullSession ? "session" : "sessionMeta", commit.after);
  }
  private async updateTodoState(sessionId: string, todoState: PickyAgentSession["todoState"]): Promise<void> {
    if (sameTodoState(this.mustGet(sessionId).todoState, todoState)) return;
    await this.patch(sessionId, { todoState }, { emitSession: false });
    const seq = this.nextSeq(sessionId); await this.chainEmit(sessionId, async () => { this.emit("todoStateUpdated", sessionId, todoState, seq); });
  }
  private async syncSessionMessages(sessionId: string, messages: readonly PickySessionMessage[], patch?: SessionMessageSyncPatch): Promise<void> {
    await this.commitSession(sessionId, (current) => ({ ...current, ...patch, messages: [...messages], updatedAt: new Date().toISOString() }));
  }
  private async commitSession(session: PickyAgentSession): Promise<SessionCommit>;
  private async commitSession(sessionId: string, build: (current: PickyAgentSession) => PickyAgentSession, options?: { forceCollectionReplacements?: boolean }): Promise<SessionCommit>;
  private async commitSession(sessionOrId: PickyAgentSession | string, build?: (current: PickyAgentSession) => PickyAgentSession, options: { forceCollectionReplacements?: boolean } = {}): Promise<SessionCommit> {
    const sessionId = typeof sessionOrId === "string" ? sessionOrId : sessionOrId.id; let result: SessionCommit | undefined;
    await this.runSessionWrite(sessionId, async () => {
      const before = this.sessions.get(sessionId); const proposed = typeof sessionOrId === "string" ? build!(this.mustGet(sessionId)) : sessionOrId;
      const changed = proposed !== before;
      const mutations = changed && before ? sessionProjectionCommitMutations(before, proposed, options) : [];
      const after = changed && before ? { ...proposed, revision: projectionCommitRevision(before.revision ?? 0, mutations) } : proposed;
      if (changed) {
        await this.store.save(after); this.sessions.set(sessionId, after);
        publishSessionProjectionCommit(this, before, after, mutations, this.sessionProjectionEpoch);
      }
      result = { before, after, changed };
    });
    return result!;
  }
  private async runSessionWrite(sessionId: string, work: () => Promise<void>): Promise<void> {
    await this.patchChains.run(sessionId, work);
  }
  private nextSeq(sessionId: string): number {
    const next = (this.sessionSeq.get(sessionId) ?? 0) + 1;
    this.sessionSeq.set(sessionId, next);
    return next;
  }
  private async upsert(session: PickyAgentSession, options: { emitSession?: boolean } = {}): Promise<void> {
    const commit = await this.commitSession(session);
    if (options.emitSession ?? true) this.emit("session", commit.after);
  }
  private mustGet(sessionId: string): PickyAgentSession {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error(`Unknown session: ${sessionId}`);
    return session;
  }
}
