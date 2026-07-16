import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { extractChangedFilesFromExplicitText, extractSessionLinkArtifacts } from "./artifact-store.js";
import { ArtifactMaterializer } from "./application/artifact-materializer.js";
import { RuntimeEventHandler } from "./application/runtime-event-handler.js";
import { summarizeExtensionUiAnswer } from "./application/extension-ui-request-mapper.js";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentBootstrapPair, buildMainAgentPrompt, buildMainAgentPickleCompletionPrompt, buildPicklePrompt, buildSteerPrompt, type BuiltPrompt } from "./prompt-builder.js";
import type { ModelCycleDirection, PickyActivitySummary, PickyAgentSession, PickyContextPacket, PickyMainAgentMessage, PickyMainAgentModelOption, PickyMainAgentState, PickyQueueItem, PickyQueueMode, PickySessionMessage } from "./protocol.js";
import { makePointerOverlayRequest, type PickyShowPointerRequest, type PickyShowPointerResult } from "./application/pointer-tool.js";
import { readPiSessionInfoName, readPiTerminalSessionMessages } from "./application/pi-session-syncer.js";
import { PiSessionTailWatcher, type PiSessionTailEntry } from "./application/pi-session-tail-watcher.js";
import { inferTerminalStatusFromEntries } from "./application/terminal-tail-status.js";
import { ORPHANED_CHILD_SESSION_RECOVERY_LOG, ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY, SessionStore } from "./session-store.js";
import type { TaskRouter } from "./task-router.js";
import type { AgentRuntime, RewindTarget, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, RuntimeSteerResult, ThinkingLevel } from "./runtime/types.js";
import { listRewindTargets as rewindListTargets, rewindToEntry as runRewindToEntry, type RewindDeps } from "./application/session-rewind.js";
import { hasActivity, zeroActivitySummary } from "./domain/activity-summary.js";
import { mergeArtifacts } from "./domain/artifacts.js";
import { mergeChangedFiles } from "./domain/changed-files.js";
import { readImageSizeFromBuffer } from "./domain/image-size.js";
import { clampPointerCoordinates, screenshotSizeFromMetadata, selectPointerScreenshot } from "./domain/pointer-validation.js";
import { diffQueueRemovedItems, queueItems, sameQueueItems } from "./domain/queue-policy.js";
import { isTerminalStatus } from "./domain/session-status.js";
import { HANDOFF_PREFIX, FOLLOWUP_PREFIX, STEER_PREFIX, EXTENSION_ANSWER_PREFIX } from "./domain/log-prefixes.js";
import { cleanFinalAnswer } from "./domain/session-summary.js";
import { settleActiveTools } from "./domain/tool-activity.js";
import { isTransientAgentBusyError } from "./domain/transient-runtime-error.js";
import { titleFromContext } from "./domain/session-title.js";
import { normalizeOptionalString } from "./domain/strings.js";
import { appendLiveBashOutput, formatUserBashFailureSystemMessage, formatUserBashRunningSystemMessage, formatUserBashSystemMessage, parseUserBashInput, userBashSummary, type UserBashInput } from "./domain/user-bash-format.js";
import { isCompactSlashCommand, isNonSkillSlashCommand, isNoTurnStateRestoringSlashCommand, isReloadSlashCommand, normalizeSlashCommands } from "./domain/slash-commands.js";
import { appendUniqueLog, hasPickleSessionMarkerLog, piSessionFilePathForSession, piSessionFilePathFromLogLine, withPiSessionFileFromLogs } from "./domain/pi-session-files.js";
import { buildPinnedPickleSessionLogs, isPickyHandoffCommandMessage, lastTurns, PINNED_SOURCE_TURN_COUNT, piSessionFilePathFromHandoffTranscript, titleForEmptyPickleSession } from "./domain/pickle-handoff-context.js";
import { extractPickyPromptUserInstruction, queueTextMatchesUserText } from "./domain/queue-policy.js";
import { MAIN_AGENT_COMPACT_SUMMARY_LIMIT, MAIN_AGENT_MESSAGE_LIMIT, MAIN_AGENT_ROLLOVER_CONTEXT_PERCENT, MAIN_AGENT_ROLLOVER_TURN_LIMIT, MAIN_AGENT_SUMMARY_MESSAGE_LIMIT, MAIN_AGENT_SUMMARY_PICKLE_SESSION_LIMIT, normalizeMainAgentState, quickReplyOriginFromContextSource, truncateMainSummaryText, type QuickReplyMetadata } from "./domain/main-agent-policy.js";
import type { ToolCategory } from "./domain/tool-categorizer.js";
import { logAgentd } from "./local-log.js";
import { SessionMessageBuilder } from "./session-message-builder.js";

type PendingQueueDelivery = {
  id: string;
  kind: "steering" | "followUp";
  text: string;
  originatedBy: "user" | "main_agent";
  attachedImagesCount?: number;
};

export interface ReloadPluginsSummary {
  pickyReloaded: boolean;
  pickleReloadedCount: number;
  pickleAbortedCount: number;
  pickleDeferredCount: number;
}

interface SessionSupervisorOptions {
  taskRouter?: TaskRouter;
  mainRuntime?: AgentRuntime;
  // Optional factory used to mint new session ids. Defaults to a random UUID generator. Child
  // daemons (per-Pickle agentd plan §3.2) override this with a single-use factory that returns
  // the env-supplied PICKY_AGENTD_SESSION_ID so the scoped SessionStore accepts the first save.
  sessionIdFactory?: () => string;
  // Defaults to 1s; tests may lower it to avoid waiting on real-time intervals.
  userBashLiveUpdateIntervalMs?: number;
  // Child daemons have no `mainRuntime` of their own, so they cannot followUp the main Picky
  // agent directly. When set, `deliverPickleCompletionToMain` falls back to this callback to
  // forward the prebuilt prompt through the Picky app to the primary daemon, which owns the
  // main agent. Returning successfully marks the Pickle as notified.
  forwardPickleCompletionToPrimary?: (request: { sessionId: string; prompt: string; cwd?: string }) => Promise<void>;
  // Builds the customTools array to apply to the main runtime after the user
  // toggles built-in tool availability. Called with the current disabled set;
  // returns the filtered ToolDefinition[] that should be active. bootstrap.ts
  // owns the tool registry; supervisor only stores the disabled set and asks
  // for a refreshed list when it changes.
  mainCustomToolsBuilder?: (disabled: ReadonlySet<string>) => import("@earendil-works/pi-coding-agent").ToolDefinition[];
}

const ARCHIVED_SESSION_RETENTION_DAYS = 7;
const ARCHIVED_SESSION_RETENTION_MS = ARCHIVED_SESSION_RETENTION_DAYS * 24 * 60 * 60 * 1000;

export class SessionSupervisor extends EventEmitter {
  private sessions = new Map<string, PickyAgentSession>();
  private runtimeHandles = new Map<string, RuntimeSessionHandle>();
  private runtimeHandleUnsubscribes = new Map<string, () => void>();
  private disabledBuiltinTools: Set<string> = new Set();
  // Mirrors Picky's TTS setting for main-agent runtimes.
  // Defaults to true so fresh installs keep audio responses enabled.
  private ttsEnabled = true;
  private readonly ttsEnabledListeners = new Set<(enabled: boolean) => void>();
  private readonly artifactMaterializer: ArtifactMaterializer;
  private readonly runtimeEventHandler: RuntimeEventHandler;
  private mainHandle?: RuntimeSessionHandle;
  private mainHandlePromise?: Promise<RuntimeSessionHandle>;
  private mainHandleUnsubscribe?: () => void;
  private mainHandleGeneration = 0;
  private mainThinkingLevel?: ThinkingLevel;
  private mainDraft = "";
  private mainContext?: PickyContextPacket;
  private mainState: PickyMainAgentState = { messages: [] };
  private mainReplyContextId = "main";
  private mainIsProcessing = false;
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
  private suppressNextMainReply = false;
  // Monotonic supervisor-side generation for main-agent turns. When a runtime can tag streamed
  // events with this id, interrupted-turn terminal events can be dropped by exact id instead of by
  // broad counters that may also match the replacement turn.
  private mainTurnId = 0;
  private activeMainRuntimeInputId?: string;
  private interruptedMainInputIds = new Set<string>();
  private pickleSessionIds = new Set<string>();
  // Session ids that this supervisor does NOT host locally but that should still be tagged as
  // Pickle-completion contexts when the main agent's reply turn ends. Populated by
  // `deliverMainAgentPickleCompletion` (primary daemon entrypoint for child-forwarded Pickle
  // completions) and consumed by the quickReply emit in `applyMainRuntimeEvent`. Tracked
  // separately from `pickleSessionIds` because the latter doubles as a "this supervisor owns the
  // session" hint for routing/filter paths that must not match foreign session ids.
  private externalPickleReplyContexts = new Set<string>();
  private pickleCompletionNotified = new Set<string>();
  private pickleCompletionInFlight = new Set<string>();
  private pendingPickleCompletions: string[] = [];
  private sessionContexts = new Map<string, PickyContextPacket>();
  private pendingRuntimeHandles = new Map<string, Promise<RuntimeSessionHandle>>();
  private pendingRuntimeAbortControllers = new Map<string, AbortController>();
  private pendingAbortOperations = new Map<string, Promise<PickyAgentSession>>();
  private sessionSeq = new Map<string, number>();
  private queueUpdateChains = new Map<string, Promise<void>>();
  private activityUpdateChains = new Map<string, Promise<void>>();
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
  // Serialize all session-state writes per session id. Without this, concurrent patch/sync calls
  // capture stale snapshots in their `{ ...mustGet(), ...patch }` spread and overwrite each
  // other's in-memory cache + persisted state. The status:running patch and the synthetic
  // status:completed (from /name interception) racing against session_info/log patches was
  // observed to revert the session back to 'running' after a /name slash command.
  private patchChains = new Map<string, Promise<void>>();
  private mainStateWriteChain = Promise.resolve();
  // Active JSONL tail watchers for Pickle sessions whose inline TUI / Pi terminal overlay is
  // currently driving the conversation. The watcher emits new JSONL entries into
  // `handleTerminalTailEntries`, which infers status transitions (running <-> completed) and
  // patches the session so the HUD dock icon keeps animating even while the agentd-driven
  // runtime is idle. Keyed by session id; entries are added/removed via
  // `setTerminalSessionTailEnabled`.
  private readonly terminalTailWatchers = new Map<string, PiSessionTailWatcher>();

  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore, private readonly options: SessionSupervisorOptions = {}) {
    super();
    this.sessionIdFactory = options.sessionIdFactory ?? (() => `session-${randomUUID()}`);
    this.artifactMaterializer = new ArtifactMaterializer();
    this.messageBuilder = new SessionMessageBuilder({
      emitAppended: async (sessionId, message, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageAppended", sessionId, message, seq); }); },
      emitImported: async (sessionId, messages, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messagesImported", sessionId, messages, seq); }); },
      emitReplaced: async (sessionId, messageId, message, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageReplaced", sessionId, messageId, message, seq); }); },
      emitRemoved: async (sessionId, messageId, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageRemoved", sessionId, messageId, seq); }); },
      nextSeq: (sessionId) => this.nextSeq(sessionId),
      now: () => new Date().toISOString(),
      syncSessionMessages: async (sessionId, messages) => { await this.syncSessionMessages(sessionId, messages); },
    });
    this.runtimeEventHandler = new RuntimeEventHandler({
      getSession: (sessionId) => this.mustGet(sessionId),
      patchSession: (sessionId, patch, options) => this.patch(sessionId, patch, options),
      emitToolActivityUpdated: (sessionId, tool) => this.emit("toolActivityUpdated", sessionId, tool),
      updateTodoState: (sessionId, todoState) => this.updateTodoState(sessionId, todoState),
      consumeNoTurnRanSessionStateRestore: (sessionId) => this.consumeNoTurnRanSessionStateRestore(sessionId),
      appendLog: (sessionId, line) => this.appendLog(sessionId, line),
      materializeTerminalArtifacts: (sessionId) => this.materializeTerminalArtifacts(sessionId),
      applyQueueUpdate: (sessionId, steering, followUp) => this.applyQueueUpdate(sessionId, steering, followUp),
      incrementActivity: (sessionId, category) => this.incrementActivity(sessionId, category),
      commitTurnActivity: (sessionId) => this.commitTurnActivity(sessionId),
      notifyPickleCompletion: (sessionId) => this.notifyPickyOfPickleCompletion(sessionId),
      isPickleSession: (sessionId) => this.pickleSessionIds.has(sessionId),
      emitExtensionUiRequest: (request) => this.emit("extensionUiRequest", request),
      onInputMessage: (sessionId, event) => this.handleRuntimeInputMessage(sessionId, event),
      messageBuilder: this.messageBuilder,
    });
  }

  async load(): Promise<void> {
    this.mainState = normalizeMainAgentState(await this.store.loadMainAgentState());
    const persisted = await this.store.loadAll();
    logAgentd("sessions loading", { count: persisted.length });
    for (const persistedSession of persisted) {
      const migratedSession = withPiSessionFileFromLogs(persistedSession);
      const isPickleSession = hasPickleSessionMarkerLog(migratedSession);
      if (isPickleSession) this.pickleSessionIds.add(migratedSession.id);
      const session = isPickleSession && migratedSession.notifyMainOnCompletion === undefined
        ? { ...migratedSession, notifyMainOnCompletion: true }
        : migratedSession;
      this.sessions.set(session.id, session);
      this.messageBuilder.hydrateSession(session.id, session.messages);
      if (session.piSessionFilePath !== persistedSession.piSessionFilePath || session.notifyMainOnCompletion !== persistedSession.notifyMainOnCompletion) await this.store.save(session);
      if (this.pickleSessionIds.has(session.id)) void this.refreshPickleSessionTitleFromPi(session.id);

      if (isOrphanedChildSessionRecovery(session)) {
        const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
        const current = this.mustGet(session.id);
        // Strip the ORPHANED marker from the persisted logs after we surface the recovery summary
        // once. Without this the marker stays in logs forever and every subsequent restart re-enters
        // this branch, leaving the dock icon permanently in the blocked/help state even when the Pi
        // session file is still alive and reattachable.
        const restored = {
          ...current,
          ...interrupted.patch,
          status: "blocked" as const,
          lastSummary: ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY,
          logs: current.logs.filter((line) => line !== ORPHANED_CHILD_SESSION_RECOVERY_LOG),
          updatedAt: new Date().toISOString(),
        };
        this.sessions.set(restored.id, restored);
        await this.store.save(restored);
        continue;
      }

      if (!isTerminalStatus(session.status)) {
        if (session.archived === true) {
          const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
          const current = this.mustGet(session.id);
          const restored = {
            ...current,
            ...interrupted.patch,
            status: "cancelled" as const,
            lastSummary: "Archived session was not resumed after daemon restart",
            updatedAt: new Date().toISOString(),
          };
          this.sessions.set(restored.id, restored);
          await this.store.save(restored);
          continue;
        }

        const resumedHandle = await this.tryResumeRuntimeHandle(session);
        if (!resumedHandle) {
          const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
          const current = this.mustGet(session.id);
          const restored = {
            ...current,
            ...interrupted.patch,
            status: "blocked" as const,
            lastSummary: "Runtime not attached after daemon restart; start a new task or resume support is required",
            logs: appendUniqueLog(current.logs, "Runtime not attached after daemon restart; start a new task or resume support is required"),
            updatedAt: new Date().toISOString(),
          };
          this.sessions.set(restored.id, restored);
          await this.store.save(restored);
        }
      } else if (shouldReattachBlockedSessionOnStartup(session)) {
        await this.tryResumeRuntimeHandle(session);
      }
    }
    await this.purgeStaleArchivedSessions();
  }

  private async purgeStaleArchivedSessions(now: number = Date.now()): Promise<void> {
    const removed: string[] = [];
    for (const session of [...this.sessions.values()]) {
      if (session.archived !== true) continue;
      if (!isTerminalStatus(session.status)) continue;
      if (this.runtimeHandles.has(session.id)) continue;
      const ageSource = session.archivedAt ?? session.updatedAt;
      if (now - new Date(ageSource).getTime() < ARCHIVED_SESSION_RETENTION_MS) continue;
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

  currentMainContext(): PickyContextPacket | undefined {
    return this.mainContext;
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
      if (this.mainHandle) return this.mainHandle;
      if (this.mainHandlePromise) return await this.mainHandlePromise;
      return await this.ensurePrewarmedMainHandle(session.cwd?.trim() || process.cwd());
    } catch (error) {
      logAgentd("slash commands fallback failed", { sessionId: session.id, error: error instanceof Error ? error.message : String(error) });
      return undefined;
    }
  }

  async requestPointerOverlay(request: PickyShowPointerRequest): Promise<PickyShowPointerResult> {
    const context = this.contextForPointerRequest();
    if (!context) throw new Error("No captured Picky context is available for pointer overlay validation.");
    const overlayRequest = makePointerOverlayRequestForContext(context, request);
    this.emit("pointerOverlayRequested", overlayRequest);
    return { request: overlayRequest };
  }

  private contextForPointerRequest(): PickyContextPacket | undefined {
    return this.mainContext ?? [...this.sessionContexts.values()].at(-1);
  }

  async prewarmMainAgent(cwd = process.cwd()): Promise<void> {
    if (!this.options.mainRuntime || this.mainHandle) return;
    if (!this.options.mainRuntime.prewarm && !this.options.mainRuntime.resume) return;
    logAgentd("main prewarm requested", { cwd });
    await this.ensurePrewarmedMainHandle(cwd);
  }

  listMainMessages(): PickyMainAgentMessage[] {
    return [...this.mainState.messages];
  }

  /// Public snapshot of the always-on Picky main agent's Pi session location.
  /// The Picky app uses this to expose "Open in Pi" / "Copy resume command"
  /// escape hatches in the Messages tab so users can drop into a real Pi TUI
  /// against the same session file the daemon is driving.
  mainAgentSessionInfo(): { sessionFilePath?: string; cwd?: string } {
    const sessionFilePath = this.mainState.sessionFilePath?.trim();
    const cwd = this.mainState.cwd?.trim();
    return {
      ...(sessionFilePath ? { sessionFilePath } : {}),
      ...(cwd ? { cwd } : {}),
    };
  }

  async resetMainAgent(): Promise<void> {
    logAgentd("main reset requested", { messages: this.mainState.messages.length, hadHandle: this.mainHandle ? 1 : 0 });
    const currentHandle = this.mainHandle;
    const pendingHandlePromise = this.mainHandlePromise;
    this.detachMainHandleForInterruption();
    await this.patchMainState({ messages: [], sessionFilePath: undefined, cwd: undefined, compactSummary: undefined, epochStartedAt: undefined, epochTurnCount: undefined, lastRolloverAt: undefined, lastRolloverReason: undefined, contextUsage: undefined });

    if (currentHandle) await this.abortResetMainHandle(currentHandle, "current");
    if (pendingHandlePromise) {
      void pendingHandlePromise
        .then(async (pendingHandle) => {
          if (pendingHandle !== currentHandle) await this.abortResetMainHandle(pendingHandle, "pending");
          if (this.mainHandle === pendingHandle) {
            this.detachMainHandleForInterruption();
            await this.patchMainState({ sessionFilePath: undefined, cwd: undefined, compactSummary: undefined, epochStartedAt: undefined, epochTurnCount: undefined, lastRolloverAt: undefined, lastRolloverReason: undefined, contextUsage: undefined });
          }
        })
        .catch((error) => {
          logAgentd("main reset pending handle failed", { error: error instanceof Error ? error.message : String(error) });
        });
    }
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

  async abortMainAgent(): Promise<void> {
    logAgentd("main abort requested", { messages: this.mainState.messages.length, hadHandle: this.mainHandle ? 1 : 0, hadPendingHandle: this.mainHandlePromise ? 1 : 0, wasProcessing: this.mainIsProcessing ? 1 : 0 });
    const currentHandle = this.mainHandle;
    const pendingHandlePromise = this.mainHandlePromise;
    this.detachMainHandleForInterruption();

    if (currentHandle) await this.abortResetMainHandle(currentHandle, "voice-input");
    if (pendingHandlePromise) {
      void pendingHandlePromise.catch((error) => {
        logAgentd("main abort pending handle failed", { error: error instanceof Error ? error.message : String(error) });
      });
    }
  }

  async setMainAgentThinkingLevel(level: ThinkingLevel): Promise<void> {
    this.mainThinkingLevel = level;
    this.options.mainRuntime?.setThinkingLevel?.(level);
    logAgentd("main thinking level configured", { level, hadHandle: this.mainHandle ? 1 : 0, hadPendingHandle: this.mainHandlePromise ? 1 : 0 });
    this.applyMainThinkingLevel(this.mainHandle, level);
  }

  async listMainAgentModels(): Promise<PickyMainAgentModelOption[]> {
    const models = await this.options.mainRuntime?.listAvailableModels?.({ cwd: this.mainState.cwd ?? process.cwd() }) ?? [];
    return models;
  }

  async setMainAgentModel(pattern: string): Promise<void> {
    const normalized = pattern.trim();
    const modelPattern = normalized || undefined;
    const changed = this.options.mainRuntime?.setModelPattern?.(modelPattern) ?? false;
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
    const disabled = new Set(names);
    const previous = this.disabledBuiltinTools;
    const same = previous.size === disabled.size && [...disabled].every((name) => previous.has(name));
    this.disabledBuiltinTools = disabled;
    logAgentd("disabled builtin tools configured", { count: disabled.size, changed: same ? 0 : 1 });
    if (same) return;
    if (!this.options.mainCustomToolsBuilder || !this.options.mainRuntime?.setCustomTools) return;
    const tools = this.options.mainCustomToolsBuilder(disabled);
    this.options.mainRuntime.setCustomTools(tools);
    const currentHandle = this.mainHandle;
    this.detachMainHandleForInterruption();
    if (currentHandle) await this.abortResetMainHandle(currentHandle, "builtin-tools-switch");
    await this.patchMainState({ sessionFilePath: undefined });
  }

  getDisabledBuiltinTools(): ReadonlySet<string> {
    return this.disabledBuiltinTools;
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
    logAgentd("tts enabled changed", { enabled });
    this.options.mainRuntime?.setMainAgentTTSEnabled?.(enabled);
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

  // ----- Pickle inspection -----
  //
  // `picky_pickle_sessions` is a list. When the user asks "how's that pickle
  // going?" the model needs a deeper but still bounded summary of one
  // specific session without spawning another Pickle (which would recursively
  // delegate). We surface the SessionSupervisor's in-memory PickyAgentSession
  // — already up to date because the supervisor is the source of truth — and
  // trim it to a short text-friendly shape.

  inspectPickleSession(sessionId: string): PickyAgentSession | undefined {
    return this.sessions.get(sessionId);
  }

  private detachMainHandleForInterruption(): void {
    this.mainHandleGeneration += 1;
    this.mainHandleUnsubscribe?.();
    this.mainHandleUnsubscribe = undefined;
    this.mainHandle = undefined;
    this.mainHandlePromise = undefined;
    this.mainDraft = "";
    this.mainContext = undefined;
    this.mainReplyContextId = "main";
    this.mainIsProcessing = false;
    this.mainTerminalProcessed = false;
    this.suppressNextMainReply = false;
    this.mainTurnId += 1;
    this.activeMainRuntimeInputId = undefined;
    this.interruptedMainInputIds.clear();
    if (this.pendingPickleCompletions.length > 0) logAgentd("Picky pending Pickle completions cleared", { count: this.pendingPickleCompletions.length });
    this.pendingPickleCompletions = [];
  }

  private async abortResetMainHandle(handle: RuntimeSessionHandle, label: string): Promise<void> {
    try {
      await handle.abort();
    } catch (error) {
      logAgentd("main reset abort failed", { label, error: error instanceof Error ? error.message : String(error) });
    }
  }

  announceMainHandoff(contextId: string, text: string): void {
    logAgentd("main handoff announced", { contextId, textChars: text.length });
    this.suppressNextMainReply = true;
    void this.appendMainMessage("assistant", text);
    this.emitQuickReply(contextId, text, { replyKind: "handoffAck" });
  }

  async route(context: PickyContextPacket): Promise<PickyAgentSession | undefined> {
    logAgentd("route requested", { contextId: context.id, source: context.source, transcriptChars: context.transcript?.length, screenshots: context.screenshots.length });
    if (this.options.mainRuntime) {
      await this.routeThroughMainAgent(context);
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


  async createPickleFromHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string; cwd?: string }): Promise<PickyAgentSession> {
    const cwd = normalizeOptionalString(handoff.cwd) ?? context.cwd;
    const handoffContext = cwd ? { ...context, cwd } : context;
    const sourceSessionFilePath = piSessionFilePathFromHandoffTranscript(handoffContext.transcript);
    logAgentd("pickle session create requested", { contextId: context.id, titleChars: handoff.title.length, instructionChars: handoff.instructions.length, cwd: handoffContext.cwd, sourceSessionFilePath });
    if (sourceSessionFilePath && this.runtime.resume) {
      return this.createPickleFromResumedHandoff(handoffContext, handoff, sourceSessionFilePath);
    }
    const session = await this.createVisibleSession(handoffContext, handoff.title.trim() || titleFromContext(context), buildPicklePrompt(handoffContext, handoff), { notifyMainOnCompletion: true });
    this.pickleSessionIds.add(session.id);
    await this.appendLog(session.id, `${HANDOFF_PREFIX}${handoff.instructions}`);
    if (handoffContext.cwd) await this.appendLog(session.id, `Picky handoff cwd: ${handoffContext.cwd}`);
    return this.mustGet(session.id);
  }

  private async createPickleFromResumedHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string; cwd?: string }, sourceSessionFilePath: string): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const cwd = normalizeOptionalString(context.cwd);
    const newFilePath = await snapshotPiSessionFile(sourceSessionFilePath, id);
    const title = handoff.title.trim() || titleFromContext(context);
    const session: PickyAgentSession = {
      id,
      title,
      status: "queued",
      cwd,
      createdAt: now,
      updatedAt: now,
      lastSummary: "Resuming source Pi session",
      logs: [
        `pi session: ${newFilePath}`,
        `source pi session snapshot: ${sourceSessionFilePath}`,
      ],
      notifyMainOnCompletion: true,
      tools: [],
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
      changedFiles: [],
      activitySummary: zeroActivitySummary(),
      piSessionFilePath: newFilePath,
    };
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
        await handle.abort();
        logAgentd("pickle handoff resume resolved after session was cancelled", { sessionId: id });
        return this.mustGet(id);
      }
      await this.attachRuntimeHandle(id, handle);
      await this.patch(id, { status: "running", lastSummary: "Started", thinkingPreview: undefined, piSessionFilePath: newFilePath });
      pendingHandle.resolve(handle);
      await handle.followUp({ text: handoff.instructions, imagePaths: [] });
      await this.appendLog(id, `${HANDOFF_PREFIX}${handoff.instructions}`);
      if (cwd) await this.appendLog(id, `Picky handoff cwd: ${cwd}`);
      void this.refreshPickleSessionTitleFromPi(id);
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


  async createEmptyPickleSession(context: PickyContextPacket): Promise<PickyAgentSession> {
    if (!this.runtime.prewarm) throw new Error("Runtime cannot prewarm empty Pickle sessions");
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const cwd = normalizeOptionalString(context.cwd);
    const pickleContext: PickyContextPacket = { ...context, cwd, transcript: undefined, screenshots: [] };
    const session: PickyAgentSession = {
      id,
      title: titleForEmptyPickleSession(pickleContext),
      status: "waiting_for_input",
      cwd: pickleContext.cwd,
      createdAt: now,
      updatedAt: now,
      lastSummary: "Ready for instructions",
      logs: [],
      notifyMainOnCompletion: false,
      tools: [],
      artifacts: [],
      changedFiles: [],
      activitySummary: zeroActivitySummary(),
    };
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
        await handle.abort();
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
   * source's status: a running source's JSONL is copied byte-for-byte and trimmed to the last
   * complete line so the runtime can resume on a non-corrupt transcript even mid-turn.
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
    const baseTitle = source.title.trim() || "Pickle";
    const sourceMessages = source.messages ?? [];
    const session: PickyAgentSession = {
      id,
      title: `(copy) ${baseTitle}`,
      status: "waiting_for_input",
      cwd,
      createdAt: now,
      updatedAt: now,
      lastSummary: "Duplicated from existing Pickle",
      logs: [
        `duplicated from session: ${source.id}`,
        ...(cwd ? [`source cwd: ${cwd}`] : []),
        `pi session: ${newFilePath}`,
      ],
      notifyMainOnCompletion: source.notifyMainOnCompletion ?? false,
      tools: [],
      artifacts: [],
      changedFiles: [],
      activitySummary: zeroActivitySummary(),
      messages: sourceMessages.map((message) => ({ ...message })),
      piSessionFilePath: newFilePath,
    };

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
      void this.refreshPickleSessionTitleFromPi(id);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("pickle session duplicate failed", { sourceSessionId, newSessionId: id, error: message });
      await this.patch(id, {
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
    const session: PickyAgentSession = {
      id,
      title: title?.trim() || titleFromContext(context),
      status: "completed",
      cwd: context.cwd,
      createdAt: now,
      updatedAt: now,
      lastSummary: "Pinned completed Pi session",
      finalAnswer: "Pinned from an idle Pi session. No Pickle run has been started yet.",
      logs: buildPinnedPickleSessionLogs(context),
      piSessionFilePath: piSessionFilePathFromHandoffTranscript(context.transcript),
      notifyMainOnCompletion: false,
      pinned: true,
      tools: [],
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
      changedFiles: [],
      activitySummary: zeroActivitySummary(),
    };
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

  private async createVisibleSession(context: PickyContextPacket, title: string, prompt = buildInitialTaskPrompt(context), options: { notifyMainOnCompletion?: boolean } = {}): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = this.sessionIdFactory();
    const session: PickyAgentSession = {
      id,
      title,
      status: "queued",
      cwd: context.cwd,
      createdAt: now,
      updatedAt: now,
      logs: [],
      ...(options.notifyMainOnCompletion === undefined ? {} : { notifyMainOnCompletion: options.notifyMainOnCompletion }),
      tools: [],
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
      changedFiles: [],
      activitySummary: zeroActivitySummary(),
    };
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
        await handle.abort();
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

  private async routeThroughMainAgent(context: PickyContextPacket): Promise<void> {
    logAgentd("main route requested", { contextId: context.id, source: context.source, transcriptChars: context.transcript?.length });
    await this.maybeRolloverMainAgent(context);
    const generation = this.mainHandleGeneration;
    this.beginMainTurn(context.id);
    this.mainContext = context;
    const prompt = buildMainAgentPrompt(context);
    // Append the user message to mainState.messages AFTER deliverMainPrompt
    // resolves. finally{} guarantees the message is still recorded if deliver
    // throws, so the next turn's context still has the user's earlier line.
    const transcript = context.transcript?.trim();
    try {
      if (this.mainHandlePromise && !this.mainHandle) {
        const handle = await this.mainHandlePromise;
        if (generation !== this.mainHandleGeneration) return;
        await this.deliverMainPrompt(handle, prompt);
        return;
      }
      if (!this.mainHandle) {
        const initial = this.createInitialMainHandle(prompt, context.cwd, generation);
        const trackedPromise = initial.then(({ handle }) => handle).finally(() => {
          if (this.mainHandlePromise === trackedPromise) this.mainHandlePromise = undefined;
        });
        this.mainHandlePromise = trackedPromise;
        const handle = await initial;
        if (generation !== this.mainHandleGeneration) return;
        if (!handle.initialPromptAlreadySent) await this.deliverMainPrompt(handle.handle, prompt);
        return;
      }
      await this.deliverMainPrompt(this.mainHandle, prompt);
    } finally {
      if (transcript) await this.appendMainMessage("user", transcript);
    }
  }

  private async maybeRolloverMainAgent(context: PickyContextPacket): Promise<void> {
    if (!this.options.mainRuntime || this.mainIsProcessing) return;
    const reason = await this.mainRolloverReason();
    if (!reason) return;

    const currentHandle = this.mainHandle;
    const pendingHandlePromise = this.mainHandlePromise;
    const summary = this.buildMainAgentRolloverSummary(reason);
    const now = new Date().toISOString();
    logAgentd("main rollover", { reason, messages: this.mainState.messages.length, turns: this.mainState.epochTurnCount ?? 0, summaryChars: summary.length });
    this.detachMainHandleForInterruption();
    await this.patchMainState({
      sessionFilePath: undefined,
      cwd: context.cwd ?? this.mainState.cwd,
      compactSummary: summary,
      epochStartedAt: now,
      epochTurnCount: 0,
      lastRolloverAt: now,
      lastRolloverReason: reason,
      contextUsage: undefined,
    });

    if (currentHandle) await this.abortResetMainHandle(currentHandle, "main-rollover");
    if (pendingHandlePromise) {
      void pendingHandlePromise
        .then(async (pendingHandle) => {
          if (pendingHandle !== currentHandle) await this.abortResetMainHandle(pendingHandle, "main-rollover-pending");
        })
        .catch((error) => {
          logAgentd("main rollover pending handle failed", { error: error instanceof Error ? error.message : String(error) });
        });
    }
  }

  private async mainRolloverReason(): Promise<string | undefined> {
    const turns = this.mainState.epochTurnCount ?? 0;
    if (turns >= MAIN_AGENT_ROLLOVER_TURN_LIMIT) return `turn-limit:${turns}`;
    const percent = this.mainState.contextUsage?.percent;
    if (typeof percent === "number" && Number.isFinite(percent) && percent >= MAIN_AGENT_ROLLOVER_CONTEXT_PERCENT) return `context:${Math.round(percent)}%`;
    return undefined;
  }

  private buildMainAgentRolloverSummary(reason: string): string {
    const lines = [
      `Rollover reason: ${reason}`,
      `Previous epoch turns: ${this.mainState.epochTurnCount ?? 0}`,
    ];
    const previousSummary = this.mainState.compactSummary?.trim();
    if (previousSummary) {
      lines.push("", "Prior rollover summary:", truncateMainSummaryText(previousSummary, 1_200));
    }
    const recentMessages = this.mainState.messages.slice(-MAIN_AGENT_SUMMARY_MESSAGE_LIMIT);
    if (recentMessages.length > 0) {
      lines.push("", "Recent visible Picky messages:");
      for (const message of recentMessages) {
        const role = message.role === "user" ? "User" : "Picky";
        lines.push(`- ${role}: ${truncateMainSummaryText(message.text, 360)}`);
      }
    }
    const pickleSessions = [...this.pickleSessionIds]
      .map((sessionId) => this.sessions.get(sessionId))
      .filter((session): session is PickyAgentSession => Boolean(session))
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      .slice(0, MAIN_AGENT_SUMMARY_PICKLE_SESSION_LIMIT);
    if (pickleSessions.length > 0) {
      lines.push("", "Recent Pickle sessions:");
      for (const session of pickleSessions) {
        lines.push(`- ${session.id} | ${session.title} | status=${session.status}`);
      }
    }
    return truncateMainSummaryText(lines.join("\n"), MAIN_AGENT_COMPACT_SUMMARY_LIMIT);
  }

  private async deliverMainPrompt(handle: RuntimeSessionHandle, prompt: ReturnType<typeof buildMainAgentPrompt>): Promise<void> {
    if (this.mainIsProcessing && handle.interrupt) {
      logAgentd("main interrupt", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, inputId: this.activeMainRuntimeInputId });
      if (this.activeMainRuntimeInputId) this.interruptedMainInputIds.add(this.activeMainRuntimeInputId);
      this.mainTerminalProcessed = false;
      this.mainDraft = "";
      await handle.interrupt(prompt);
      this.mainIsProcessing = true;
      return;
    }
    this.mainIsProcessing = true;
    logAgentd("main prompt delivered", { contextId: this.mainReplyContextId, turnId: this.mainTurnId });
    await handle.followUp(prompt);
  }

  private beginMainTurn(contextId: string): void {
    this.mainTurnId += 1;
    this.mainReplyContextId = contextId;
    this.activeMainRuntimeInputId = `main-turn-${this.mainTurnId}`;
    this.mainDraft = "";
    this.mainTerminalProcessed = false;
  }

  private async ensurePrewarmedMainHandle(cwd: string): Promise<RuntimeSessionHandle> {
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
    if (!this.options.mainRuntime?.prewarm) throw new Error("Main runtime cannot prewarm");
    const handle = await this.options.mainRuntime.prewarm({ cwd, sessionId: "picky" });
    logAgentd("main prewarmed", { cwd });
    if (generation !== this.mainHandleGeneration) {
      await this.abortResetMainHandle(handle, "stale-prewarm");
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
    const handle = await this.options.mainRuntime!.create(prompt, { cwd, sessionId: "picky" });
    if (generation !== this.mainHandleGeneration) {
      await this.abortResetMainHandle(handle, "stale-initial");
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
      await handle.injectInitialBootstrap(buildMainAgentBootstrapPair(this.mainState.compactSummary));
    } catch (error) {
      logAgentd("main bootstrap inject failed", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async tryResumeMainHandle(cwd: string, generation = this.mainHandleGeneration): Promise<RuntimeSessionHandle | undefined> {
    const sessionFilePath = this.mainState.sessionFilePath?.trim();
    if (!sessionFilePath || !this.options.mainRuntime?.resume) return undefined;
    try {
      logAgentd("main resume requested", { sessionFilePath, cwd });
      const handle = await this.options.mainRuntime.resume(sessionFilePath, { cwd, sessionId: "picky" });
      logAgentd("main resumed", { sessionFilePath, cwd });
      if (generation !== this.mainHandleGeneration) {
        await this.abortResetMainHandle(handle, "stale-resume");
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
      void this.abortResetMainHandle(handle, "stale-attach");
      return handle;
    }
    this.mainHandle = handle;
    this.applyMainThinkingLevel(handle);
    this.mainHandleUnsubscribe?.();
    this.mainHandleUnsubscribe = handle.subscribe((event) => {
      if (generation !== this.mainHandleGeneration) return;
      void this.applyMainRuntimeEvent(event);
    });
    return handle;
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
    const createdAt = new Date().toISOString();
    const message: PickyMainAgentMessage = { role, text: trimmed, createdAt };
    const patch: Partial<PickyMainAgentState> = { messages: [...this.mainState.messages, message].slice(-MAIN_AGENT_MESSAGE_LIMIT) };
    if (role === "user") {
      patch.epochTurnCount = (this.mainState.epochTurnCount ?? 0) + 1;
      patch.epochStartedAt = this.mainState.epochStartedAt ?? createdAt;
    }
    await this.patchMainState(patch);
    this.emit("mainMessage", message);
  }

  private async patchMainState(patch: Partial<PickyMainAgentState>): Promise<void> {
    const previousSessionFilePath = this.mainState.sessionFilePath;
    const previousCwd = this.mainState.cwd;
    this.mainState = normalizeMainAgentState({ ...this.mainState, ...patch });
    if (previousSessionFilePath !== this.mainState.sessionFilePath || previousCwd !== this.mainState.cwd) {
      this.emit("mainAgentSessionInfo", this.mainAgentSessionInfo());
    }
    const snapshot = this.mainState;
    const write = this.mainStateWriteChain.catch(() => undefined).then(() => this.store.saveMainAgentState(snapshot));
    this.mainStateWriteChain = write.catch(() => undefined);
    await write;
  }

  private async applyMainRuntimeEvent(event: RuntimeEvent): Promise<void> {
    if (event.type === "log") {
      const sessionFilePath = piSessionFilePathFromLogLine(event.line);
      if (sessionFilePath) await this.patchMainState({ sessionFilePath });
      return;
    }
    if (event.type === "context_usage") {
      await this.patchMainState({ contextUsage: event.usage });
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
      this.mainDraft += event.delta;
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
      const draftSnapshot = this.mainDraft;
      this.mainDraft = "";
      // Prefer the streamed draft so any deltas that the normalizer trimmed
      // out of the final assistant message are preserved, but fall back to
      // the event's text payload so runtimes that deliver a whole turn in
      // one shot (no prior `assistant_delta`) still flush the spoken turn
      // through TTS instead of silently dropping it.
      const reply = cleanFinalAnswer(draftSnapshot) ?? cleanFinalAnswer(event.text);
      if (!reply) {
        logAgentd("main turn text complete with empty draft", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, eventTextChars: event.text.length });
        return;
      }
      logAgentd("main turn text flush", { contextId: this.mainReplyContextId, turnId: this.mainTurnId, textChars: reply.length });
      await this.appendMainMessage("assistant", reply);
      const replyContextId = this.mainReplyContextId;
      if (replyContextId) {
        const isPickleReply = this.pickleSessionIds.has(replyContextId) || this.externalPickleReplyContexts.has(replyContextId);
        this.emitQuickReply(replyContextId, reply, {
          originSource: replyContextId === this.mainContext?.id ? quickReplyOriginFromContextSource(this.mainContext.source) : "system",
          replyKind: isPickleReply ? "pickleCompletion" : "main",
          sessionId: isPickleReply ? replyContextId : undefined,
        });
      }
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
        // Guard B: snapshot and clear `mainDraft` synchronously before any await,
        // so a racing terminal event that slipped past Guard A (e.g. via a custom
        // runtime that does not flip `mainTerminalProcessed`) cannot read the
        // still-populated draft and double-emit the reply.
        const draftSnapshot = this.mainDraft;
        this.mainDraft = "";
        logAgentd("main status", { status: event.status, contextId: this.mainReplyContextId, draftChars: draftSnapshot.length });
        const rawReply = cleanFinalAnswer(draftSnapshot) ?? (event.status === "failed" ? event.summary : undefined);
        if (this.suppressNextMainReply) {
          this.suppressNextMainReply = false;
        } else if (rawReply) {
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
              const isPickleReply = this.pickleSessionIds.has(this.mainReplyContextId) || this.externalPickleReplyContexts.has(this.mainReplyContextId);
              this.emitQuickReply(this.mainReplyContextId, reply, {
                originSource: this.mainReplyContextId === this.mainContext?.id ? quickReplyOriginFromContextSource(this.mainContext.source) : "system",
                replyKind: isPickleReply ? "pickleCompletion" : "main",
                sessionId: isPickleReply ? this.mainReplyContextId : undefined,
              });
              this.externalPickleReplyContexts.delete(this.mainReplyContextId);
            }
          }
        }
        this.schedulePickleCompletionDrain();
      }
    }
  }

  private async notifyPickyOfPickleCompletion(sessionId: string): Promise<void> {
    const session = this.mustGet(sessionId);
    if (this.pickleCompletionNotified.has(sessionId) || this.pickleCompletionInFlight.has(sessionId)) return;
    if (session.notifyMainOnCompletion === false) {
      this.pickleCompletionNotified.add(sessionId);
      logAgentd("Pickle completion notify skipped", { sessionId, status: session.status });
      return;
    }
    // Defer when the Picky is mid-turn (e.g. the handoff turn that spawned this
    // Pickle session has not emitted status:completed yet). Sending the followUp now
    // would clobber mainReplyContextId / mainDraft, and the in-flight turn's
    // suppressNextMainReply would later swallow this Pickle completion's reply when its
    // delayed status:completed finally arrives. Park the sessionId and let
    // applyMainRuntimeEvent drain it once the active turn ends.
    if (this.mainIsProcessing) {
      if (!this.pendingPickleCompletions.includes(sessionId) && !this.pickleCompletionNotified.has(sessionId) && !this.pickleCompletionInFlight.has(sessionId)) {
        this.pendingPickleCompletions.push(sessionId);
        logAgentd("Pickle completion deferred", { sessionId, status: session.status, queueLength: this.pendingPickleCompletions.length });
      }
      return;
    }
    await this.deliverPickleCompletionToMain(sessionId);
  }

  private async deliverPickleCompletionToMain(sessionId: string): Promise<void> {
    this.pendingPickleCompletions = this.pendingPickleCompletions.filter((pendingSessionId) => pendingSessionId !== sessionId);
    if (this.pickleCompletionNotified.has(sessionId) || this.pickleCompletionInFlight.has(sessionId)) return;
    const session = this.sessions.get(sessionId);
    if (!session) return;
    if (session.notifyMainOnCompletion === false) {
      this.pickleCompletionNotified.add(sessionId);
      logAgentd("Pickle completion notify skipped", { sessionId, status: session.status });
      return;
    }
    this.pickleCompletionInFlight.add(sessionId);
    try {
      const prompt = buildMainAgentPickleCompletionPrompt(session);
      this.mainReplyContextId = sessionId;
      this.mainDraft = "";
      const delivery = await this.preparePickyCompletionDelivery(prompt, session.cwd);
      if (!delivery) {
        // Child daemons have no local main runtime; forward the prebuilt prompt to the primary
        // daemon through the Picky app bridge so the user's main Picky session still gets a
        // "Pickle finished" message. Without this, the bell toggle would silently no-op for
        // every per-Pickle child since the per-Pickle migration removed the in-process
        // mainRuntime from child supervisors.
        if (this.options.forwardPickleCompletionToPrimary) {
          try {
            await this.options.forwardPickleCompletionToPrimary({ sessionId, prompt: prompt.text, cwd: session.cwd });
            this.pickleCompletionNotified.add(sessionId);
            logAgentd("Pickle completion forwarded to primary", { sessionId, status: session.status });
          } catch (error) {
            logAgentd("Pickle completion forward failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
          }
        } else {
          logAgentd("Pickle completion delivery unavailable", { sessionId, status: session.status });
        }
        return;
      }

      this.pickleCompletionNotified.add(sessionId);
      this.mainIsProcessing = true;
      logAgentd("Pickle completion notifying Picky", { sessionId, status: session.status });
      if (delivery.sendAsFollowUp) await delivery.handle.followUp(prompt);
    } finally {
      this.pickleCompletionInFlight.delete(sessionId);
    }
  }

  /**
   * Primary-daemon entrypoint for Pickle completions forwarded from a child daemon via the
   * Picky app bridge (`notifyMainOfPickleCompletion`). The child has already built the user-
   * facing prompt; we just need to deliver it to the main agent and tag the resulting reply
   * as a `pickleCompletion` quickReply so the menu-bar surface routes it to the originating
   * Pickle card. Returns nothing — failures are logged so the bridge response can ack delivery
   * without blocking on the LLM turn.
   */
  async deliverMainAgentPickleCompletion(sessionId: string, promptText: string, cwd?: string): Promise<void> {
    if (!this.options.mainRuntime) {
      logAgentd("Pickle completion forwarded notify rejected", { sessionId, reason: "no main runtime" });
      throw new Error("Main runtime is not configured for Pickle completion delivery");
    }
    const prompt: BuiltPrompt = { text: promptText, imagePaths: [] };
    this.mainReplyContextId = sessionId;
    this.mainDraft = "";
    this.externalPickleReplyContexts.add(sessionId);
    const delivery = await this.preparePickyCompletionDelivery(prompt, cwd);
    if (!delivery) {
      this.externalPickleReplyContexts.delete(sessionId);
      logAgentd("Pickle completion forwarded notify dropped", { sessionId, reason: "no main handle" });
      throw new Error("Main agent handle is unavailable");
    }
    this.mainIsProcessing = true;
    logAgentd("Pickle completion forwarded notify delivering", { sessionId, promptChars: prompt.text.length, sendAsFollowUp: delivery.sendAsFollowUp ? 1 : 0 });
    if (delivery.sendAsFollowUp) {
      // Fire-and-forget: the LLM turn may take seconds, and the bridge caller (child daemon)
      // should not wait on it. Errors are logged for forensics.
      void delivery.handle.followUp(prompt).catch((error) => {
        logAgentd("Pickle completion forwarded followUp failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
      });
    }
  }

  private schedulePickleCompletionDrain(): void {
    void this.drainPendingPickleCompletions().catch((error) => {
      logAgentd("Pickle completion drain failed", { error: error instanceof Error ? error.message : String(error) });
    });
  }

  private async drainPendingPickleCompletions(): Promise<void> {
    while (!this.mainIsProcessing) {
      const sessionId = this.pendingPickleCompletions.shift();
      if (!sessionId) return;
      logAgentd("Pickle completion draining", { sessionId, queueLength: this.pendingPickleCompletions.length });
      await this.deliverPickleCompletionToMain(sessionId);
    }
  }

  private async preparePickyCompletionDelivery(prompt: ReturnType<typeof buildMainAgentPickleCompletionPrompt>, cwd?: string): Promise<{ handle: RuntimeSessionHandle; sendAsFollowUp: boolean } | undefined> {
    if (this.mainHandle) return { handle: this.mainHandle, sendAsFollowUp: true };
    if (!this.options.mainRuntime) return undefined;
    if (this.mainHandlePromise) return { handle: await this.mainHandlePromise, sendAsFollowUp: true };
    if (this.options.mainRuntime.prewarm) return { handle: await this.ensurePrewarmedMainHandle(cwd ?? process.cwd()), sendAsFollowUp: true };

    const handle = await this.options.mainRuntime.create(prompt, { cwd, sessionId: "picky" });
    this.attachMainHandle(handle);
    return { handle, sendAsFollowUp: false };
  }

  async setNotifyMainOnCompletion(sessionId: string, enabled: boolean): Promise<PickyAgentSession> {
    if (!this.isPickleSession(sessionId)) throw new Error(`Session is not a Pickle: ${sessionId}`);
    await this.patch(sessionId, { notifyMainOnCompletion: enabled });
    // Disabling means "never surface this completion to Picky". Drop it from the deferred queue
    // now so the drain loop cannot stop on it after an active sibling flips mainIsProcessing
    // back to true. Without this, a [skip, active] queue order is fine but [active, skip] would
    // strand the skip entry forever because drain exits as soon as the active entry sets
    // mainIsProcessing=true. Notify queue push order across sibling Pickle completions is
    // non-deterministic (it depends on which RuntimeEventHandler microtask chain progresses
    // first), so we cannot rely on a particular ordering here.
    if (!enabled) {
      const queueIndex = this.pendingPickleCompletions.indexOf(sessionId);
      if (queueIndex >= 0) {
        this.pendingPickleCompletions.splice(queueIndex, 1);
        this.pickleCompletionNotified.add(sessionId);
        logAgentd("Pickle completion dequeued via setNotifyMainOnCompletion", { sessionId, queueLength: this.pendingPickleCompletions.length });
      }
    }
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
    this.pendingQueueDeliveries.delete(sessionId);
    this.materializedQueueDeliveries.delete(sessionId);
    this.turnActivity.delete(sessionId);
    this.noTurnRanSessionStateRestores.delete(sessionId);
    this.pendingResourceReloadSessionIDs.delete(sessionId);
    this.pendingPostCompactionReloadIds.delete(sessionId);
    this.lastEmittedSteeringMode.delete(sessionId);
    this.lastEmittedFollowUpMode.delete(sessionId);
    this.pickleCompletionNotified.delete(sessionId);
    this.pickleCompletionInFlight.delete(sessionId);
    const pendingIndex = this.pendingPickleCompletions.indexOf(sessionId);
    if (pendingIndex >= 0) this.pendingPickleCompletions.splice(pendingIndex, 1);
    this.externalPickleReplyContexts.delete(sessionId);
    logAgentd("session deleted", { sessionId });
  }

  async setSessionArchived(sessionId: string, archived: boolean): Promise<PickyAgentSession> {
    const patch: Partial<PickyAgentSession> = archived
      ? { archived: true, archivedAt: new Date().toISOString() }
      : { archived: false, archivedAt: undefined };
    await this.patch(sessionId, patch);
    // Emit a dedicated event in addition to the patch-driven sessionUpdated so
    // the client knows this archive-state change is authoritative (rather than
    // a stale `archived` field on an unrelated update). Picky's view model
    // mirrors this into its local manuallyArchivedSessionIDs UserDefaults so
    // tool-initiated unarchive (picky_unarchive_pickle) actually pops the
    // dock card back — the local intent set is the source of truth for dock
    // placement and is otherwise never touched by remote sessionUpdated.
    this.emit("sessionArchivedAuthoritative", sessionId, archived);
    return this.mustGet(sessionId);
  }

  async cycleSessionThinkingLevel(sessionId: string): Promise<PickyAgentSession> {
    const handle = await this.runtimeHandleForSessionCommand(sessionId, "cycle thinking level");
    if (!handle.cycleThinkingLevel) throw new Error("Runtime session does not support cycling thinking level");
    const currentAssistantRun = handle.cycleThinkingLevel();
    if (currentAssistantRun) await this.patch(sessionId, { currentAssistantRun });
    return this.mustGet(sessionId);
  }

  async cycleSessionModel(sessionId: string, direction: ModelCycleDirection): Promise<PickyAgentSession> {
    const handle = await this.runtimeHandleForSessionCommand(sessionId, "cycle model");
    if (!handle.cycleModel) throw new Error("Runtime session does not support cycling models");
    const currentAssistantRun = await handle.cycleModel(direction);
    if (currentAssistantRun) await this.patch(sessionId, { currentAssistantRun });
    return this.mustGet(sessionId);
  }

  async listRewindTargets(sessionId: string): Promise<RewindTarget[]> {
    return rewindListTargets(this.rewindDeps(), sessionId);
  }

  async rewindToEntry(sessionId: string, entryId: string): Promise<PickyAgentSession> {
    return runRewindToEntry(this.rewindDeps(), sessionId, entryId);
  }

  private rewindDeps(): RewindDeps {
    return {
      handle: (id, action) => this.runtimeHandleForSessionCommand(id, action),
      session: (id) => this.mustGet(id),
      removeMessages: (id, ids) => this.messageBuilder.removeMessages(id, ids),
      drainQueue: async (id, handle) => { this.pendingQueueDeliveries.delete(id); this.materializedQueueDeliveries.delete(id); handle.clearQueue(); await this.applyQueueUpdate(id, [], []); },
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
    this.clearPickleCompletionTracking(sessionId);
    if (this.mustGet(sessionId).pinned) await this.patch(sessionId, { pinned: false });
  }

  private clearPickleCompletionTracking(sessionId: string): void {
    this.pickleCompletionNotified.delete(sessionId);
    this.pickleCompletionInFlight.delete(sessionId);
    const queueIndex = this.pendingPickleCompletions.indexOf(sessionId);
    if (queueIndex >= 0) {
      this.pendingPickleCompletions.splice(queueIndex, 1);
      logAgentd("Pickle completion dequeued", { sessionId, queueLength: this.pendingPickleCompletions.length });
    }
  }

  /**
   * Starts/stops a JSONL tail watcher for a Pickle whose Pi terminal overlay or inline TUI is
   * driving the conversation. While enabled, new JSONL entries from the user-driven `pi --session`
   * process are inspected to infer status transitions (running <-> completed) so the HUD dock icon
   * keeps breathing/winking even though the agentd runtime is not the one producing turn events.
   * Idempotent: enabling an already-watched session, or disabling an unwatched one, is a no-op.
   */
  async setTerminalSessionTailEnabled(sessionId: string, enabled: boolean): Promise<void> {
    if (enabled) {
      if (this.terminalTailWatchers.has(sessionId)) return;
      const session = this.sessions.get(sessionId);
      if (!session) {
        logAgentd("terminal tail skipped", { sessionId, reason: "unknown session" });
        return;
      }
      const sessionFilePath = piSessionFilePathForSession(session);
      if (!sessionFilePath) {
        logAgentd("terminal tail skipped", { sessionId, reason: "no pi session file" });
        return;
      }
      const watcher = new PiSessionTailWatcher(
        sessionFilePath,
        (entries) => this.handleTerminalTailEntries(sessionId, entries),
        (error) => logAgentd("terminal tail error", { sessionId, error: error instanceof Error ? error.message : String(error) }),
        { onTruncate: () => this.handleTerminalTailTruncation(sessionId, sessionFilePath) },
      );
      try {
        await watcher.start();
        this.terminalTailWatchers.set(sessionId, watcher);
        logAgentd("terminal tail started", { sessionId, sessionFilePath });
      } catch (error) {
        logAgentd("terminal tail start failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
      }
      return;
    }
    const watcher = this.terminalTailWatchers.get(sessionId);
    if (!watcher) return;
    this.terminalTailWatchers.delete(sessionId);
    await watcher.stop().catch(() => undefined);
    logAgentd("terminal tail stopped", { sessionId });
  }

  /**
   * Invoked by `PiSessionTailWatcher` when the watched JSONL shrinks below its cursor, which
   * Pi triggers when `pi --session` / `/compact` rewrites the transcript from a TUI overlay
   * the user opened on top of an active Picky session. The in-memory `runtime.session` bound
   * inside our `PiSdkRuntimeSession` is now stale (it still references pre-compaction message
   * ids and parent chains), so we drop it from `runtimeHandles`. The next user input falls
   * through `runtimeHandleForUserInput` -> `tryResumeRuntimeHandle`, which calls
   * `runtime.resume(sessionFilePath, ...)` against the rewritten file and rebinds a fresh
   * in-memory session. Without this, the next follow-up would be sent to the LLM with the
   * pre-TUI context AND Pi SDK would append the response with a stale `parentId`, orphaning
   * the compaction summary fork when the user reopens the TUI.
   *
   * We deliberately do NOT call `handle.abort()`: the tail watcher is only active while the
   * TUI overlay is open, the HUD runtime is idle in that window, and `abort()` would emit a
   * user-visible "Cancelled" status that the user did not request. The orphaned handle is
   * left to be garbage-collected.
   */
  private handleTerminalTailTruncation(sessionId: string, sessionFilePath: string): void {
    if (!this.runtimeHandles.has(sessionId)) return;
    void this.detachRuntimeHandle(sessionId);
    logAgentd("terminal tail invalidated runtime handle after pi session rewrite", { sessionId, sessionFilePath });
  }

  private invalidateRuntimeHandleAfterTerminalSync(
    sessionId: string,
    outcome: { activeLastMessageId?: string; baselinePiMessageId?: string; importedMessageCount: number },
  ): void {
    const activeLastMessageId = outcome.activeLastMessageId?.trim();
    if (!activeLastMessageId) return;
    const baselinePiMessageId = outcome.baselinePiMessageId?.trim();
    const activePathAdvanced = baselinePiMessageId
      ? activeLastMessageId !== baselinePiMessageId
      : outcome.importedMessageCount > 0;
    if (!activePathAdvanced) return;
    if (!this.runtimeHandles.has(sessionId)) return;
    void this.detachRuntimeHandle(sessionId);
    logAgentd("terminal session sync invalidated runtime handle after pi session advanced", {
      sessionId,
      activeLastMessageId,
      ...(baselinePiMessageId ? { baselinePiMessageId } : {}),
      importedMessageCount: outcome.importedMessageCount,
    });
  }

  private async handleTerminalTailEntries(sessionId: string, entries: PiSessionTailEntry[]): Promise<void> {
    if (!this.sessions.has(sessionId)) return;
    const inferred = inferTerminalStatusFromEntries(entries);
    if (!inferred) return;
    const session = this.mustGet(sessionId);
    if (session.status === inferred) return;
    // Don't overwrite an explicit user-side cancellation. If the user clicked Stop while the
    // TUI was open, the cancelled state should stick until the overlay close reconcile
    // (`syncTerminalSession`) decides what to do with whatever Pi wrote after the cancel.
    if (session.status === "cancelled" && inferred !== "completed") return;
    logAgentd("terminal tail status patch", { sessionId, from: session.status, to: inferred });
    await this.patch(sessionId, { status: inferred });
  }

  async syncTerminalSession(sessionId: string, baselinePiMessageId?: string): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) throw new Error(`Session has no Pi session file to sync: ${sessionId}`);
    logAgentd("terminal session sync requested", { sessionId, sessionFilePath, baselinePiMessageId });
    const result = await readPiTerminalSessionMessages(sessionFilePath, baselinePiMessageId);
    if (result.todoStateResolved) {
      await this.updateTodoState(sessionId, result.todoState);
    }
    if (!result.baselineFound) {
      logAgentd("terminal session sync skipped", { sessionId, reason: "baseline pi message not found", baselinePiMessageId, activeLastMessageId: result.activeLastMessageId });
      this.emitTerminalSessionSyncOutcome(sessionId, { baselineFound: false, importedMessageCount: 0, activeLastMessageId: result.activeLastMessageId, baselinePiMessageId });
      return this.mustGet(sessionId);
    }

    const existingMessages = this.mustGet(sessionId).messages ?? [];
    const existingIds = new Set(existingMessages.map((message) => message.id));
    // Skip pi_extension user_text imports that mirror a HUD-originated user_text already
    // recorded after baseline. Happens when the user sends a HUD follow-up while the terminal
    // overlay is still open: agentd records the prompt locally AND Pi writes the same prompt
    // into its JSONL, so the post-close sync would otherwise produce a duplicate bubble labelled
    // "from Pi extension". Match is scoped to the terminal window (createdAt >= baseline) and
    // consumes one local entry per import to keep legitimate repeats elsewhere intact.
    const baselineCreatedAt = result.baselineCreatedAt;
    const hudUserTextsInWindow = existingMessages
      .filter((message) => message.kind === "user_text" && message.originatedBy === "user" && typeof message.text === "string" && message.text.trim().length > 0)
      .filter((message) => !baselineCreatedAt || message.createdAt >= baselineCreatedAt)
      .map((message) => (message.text ?? "").trim());
    const hudAgentTextsInWindow = existingMessages
      .filter((message) => message.kind === "agent_text" && typeof message.text === "string" && message.text.trim().length > 0)
      .filter((message) => !baselineCreatedAt || message.createdAt >= baselineCreatedAt)
      .map((message) => (message.text ?? "").trim());
    const messagesToImport = result.messages.filter((message) => {
      if (existingIds.has(message.id)) return false;
      const text = (message.text ?? "").trim();
      if (!text) return true;
      if (message.kind === "user_text") {
        const index = hudUserTextsInWindow.indexOf(text);
        if (index < 0) return true;
        hudUserTextsInWindow.splice(index, 1);
        return false;
      }
      if (message.kind === "agent_text") {
        const index = hudAgentTextsInWindow.indexOf(text);
        if (index < 0) return true;
        hudAgentTextsInWindow.splice(index, 1);
        return false;
      }
      return true;
    });
    this.invalidateRuntimeHandleAfterTerminalSync(sessionId, {
      activeLastMessageId: result.activeLastMessageId,
      baselinePiMessageId,
      importedMessageCount: messagesToImport.length,
    });
    if (messagesToImport.length === 0) {
      logAgentd("terminal session sync noop", { sessionId, activeLastMessageId: result.activeLastMessageId });
      this.emitTerminalSessionSyncOutcome(sessionId, { baselineFound: true, importedMessageCount: 0, activeLastMessageId: result.activeLastMessageId, baselinePiMessageId });
      return this.mustGet(sessionId);
    }

    await this.messageBuilder.recordTerminalSessionMessages(sessionId, messagesToImport);
    const latestAssistantText = [...messagesToImport].reverse().find((message) => message.kind === "agent_text")?.text?.trim();
    const latestUserText = [...messagesToImport].reverse().find((message) => message.kind === "user_text")?.text?.trim();
    const patch: Partial<PickyAgentSession> = {
      thinkingPreview: undefined,
      ...(latestAssistantText ? { lastSummary: latestAssistantText, finalAnswer: latestAssistantText } : {}),
      ...(latestUserText ? { logs: appendUniqueLog(this.mustGet(sessionId).logs, `${FOLLOWUP_PREFIX}${latestUserText}`) } : {}),
    };
    // A terminal overlay resume can be used as a recovery path for terminal Picky states
    // (notably `cancelled`). If Pi wrote a new assistant answer after the baseline, the
    // on-disk Pi transcript is now the source of truth and the HUD card should leave the
    // stale terminal status instead of continuing to look cancelled/failed.
    if (latestAssistantText) patch.status = "completed";
    await this.patch(sessionId, patch);
    logAgentd("terminal session synced", { sessionId, importedMessages: messagesToImport.length, activeLastMessageId: result.activeLastMessageId });
    this.emitTerminalSessionSyncOutcome(sessionId, { baselineFound: true, importedMessageCount: messagesToImport.length, activeLastMessageId: result.activeLastMessageId, baselinePiMessageId });
    return this.mustGet(sessionId);
  }

  private emitTerminalSessionSyncOutcome(
    sessionId: string,
    outcome: { baselineFound: boolean; importedMessageCount: number; activeLastMessageId?: string; baselinePiMessageId?: string },
  ): void {
    this.emit("terminalSessionSyncOutcome", sessionId, outcome);
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (session.archived === true) throw new Error("Cannot follow up an archived session");
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);

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
    const prompt: BuiltPrompt = buildFollowUpPrompt(text, context);
    logAgentd("follow-up requested", { sessionId, textChars: text.length, contextId: context?.id, images: prompt.imagePaths.length });
    await this.appendLog(sessionId, `${FOLLOWUP_PREFIX}${text}`);
    const commandReceiptId = await this.recordNonSkillSlashCommandReceipt(sessionId, text);
    await this.patch(sessionId, { status: "running", lastSummary: "Follow-up queued", finalAnswer: undefined, thinkingPreview: undefined });
    this.pushPendingQueueDelivery(sessionId, text, "user", {
      kind: "followUp",
      attachedImagesCount: prompt.imagePaths.length,
    });
    this.queueFollowUpDelivery(sessionId, handle, prompt, text, commandReceiptId);
    return this.mustGet(sessionId);
  }

  private queueFollowUpDelivery(
    sessionId: string,
    handle: RuntimeSessionHandle,
    prompt: BuiltPrompt,
    rawText: string,
    commandReceiptId?: string,
  ): void {
    // Pi SDK followUp may resolve only after an idle session finishes its whole next turn.
    // Picky follow-ups are enqueue semantics, so do not hold the caller/Picky tool open.
    //
    // `rawText` is the unwrapped user text we pushed into the pending queue and the value the
    // runtime adapter translates Pi's queue entries back to (see `isPromptInRuntimeQueue`).
    // `prompt.text` may be wrapped (e.g. visual follow-up adds a "# Picky follow-up" header), so
    // the pending lookup must use the raw text or the entry will never drain.
    void handle.followUp(prompt)
      .then(async () => {
        logAgentd("follow-up delivery finished", { sessionId });
        // Pi only fires queue_update when the prompt traverses the queue. For idle (non-streaming)
        // sessions Pi runs the prompt inline and never enqueues, so our deferred pending entry would
        // never get drained. Detect that by checking Pi's queue snapshot once the prompt is
        // accepted and drain explicitly when the prompt is not waiting in either queue.
        await this.waitForRuntimeEvents(sessionId);
        await this.waitForQueuedStateToSettle(sessionId);
        if (!this.isPromptInRuntimeQueue(handle, rawText)) {
          await this.drainPendingTextOnce(sessionId, rawText);
        }
      })
      .catch((error) => void this.handleFollowUpDeliveryError(sessionId, rawText, error, commandReceiptId));
  }

  private async handleFollowUpDeliveryError(sessionId: string, text: string, error: unknown, commandReceiptId?: string): Promise<void> {
    this.discardPendingTextOnce(sessionId, text);
    const message = error instanceof Error ? error.message : String(error);
    logAgentd("follow-up delivery failed", { sessionId, error: message });
    await this.messageBuilder.markCommandReceiptFailed(sessionId, commandReceiptId, message);
    await this.appendLog(sessionId, `follow-up failed: ${message}`);
    if (isTransientAgentBusyError(message)) {
      logAgentd("follow-up transient busy failure ignored", { sessionId, error: message });
      return;
    }
    const current = this.sessions.get(sessionId);
    if (!current || ["completed", "cancelled"].includes(current.status)) return;
    await this.patch(sessionId, { status: "failed", lastSummary: `Follow-up failed: ${message}` });
  }

  private async executeUserBash(sessionId: string, input: UserBashInput, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    await this.preparePickleSessionForUserInput(sessionId);
    const awaitedPendingHandle = this.pendingRuntimeHandles.has(sessionId);
    const handle = await this.runtimeHandleForUserInput(session, "user bash");
    const terminalAfterHandle = awaitedPendingHandle ? await this.assertNotTerminalForUserInput(sessionId, "bash") : undefined;
    if (terminalAfterHandle) return terminalAfterHandle;
    const terminalAfterMissingHandle = !handle ? await this.assertNotTerminalForUserInput(sessionId, "bash") : undefined;
    if (terminalAfterMissingHandle) return terminalAfterMissingHandle;
    if (!handle?.executeUserBash) {
      const reason = handle ? "Runtime does not support direct bash execution" : "Runtime session is not attached";
      await this.appendLog(sessionId, `bash rejected: ${reason}`);
      throw new Error(reason);
    }

    const previous = this.mustGet(sessionId);
    const wasRunning = previous.status === "running";
    const prefix = input.excludeFromContext ? "!!" : "!";
    logAgentd("user bash requested", { sessionId, commandChars: input.command.length, excludeFromContext: input.excludeFromContext, contextId: context?.id });
    await this.appendLog(sessionId, `${prefix}${input.command}`);
    await this.messageBuilder.flushAssistantText(sessionId);
    await this.messageBuilder.flushThinking(sessionId);
    await this.patch(sessionId, { status: "running", lastSummary: `Running bash: ${input.command}`, finalAnswer: undefined, thinkingPreview: undefined });

    const liveMessageId = `msg-user-bash-${randomUUID()}`;
    const liveStartedAt = Date.now();
    const liveUpdateIntervalMs = Math.max(1, this.options.userBashLiveUpdateIntervalMs ?? 1000);
    let liveOutput = "";
    let lastLiveMessageText = "";
    let livePublishChain = Promise.resolve();
    const publishLiveMessage = (text: string): Promise<void> => {
      if (text === lastLiveMessageText) return livePublishChain;
      lastLiveMessageText = text;
      livePublishChain = livePublishChain.then(() => this.messageBuilder.upsertSystemMessage(sessionId, liveMessageId, text));
      return livePublishChain;
    };
    const publishRunningMessage = (): Promise<void> => publishLiveMessage(formatUserBashRunningSystemMessage(input, liveOutput, Date.now() - liveStartedAt));
    const liveTimer = setInterval(() => { void publishRunningMessage(); }, liveUpdateIntervalMs);

    try {
      await publishRunningMessage();
      const result = await handle.executeUserBash(input.command, {
        excludeFromContext: input.excludeFromContext,
        onOutputChunk: (chunk) => { liveOutput = appendLiveBashOutput(liveOutput, chunk); },
      });
      clearInterval(liveTimer);
      const afterExecution = this.mustGet(sessionId);
      if (["cancelled", "failed"].includes(afterExecution.status)) {
        await livePublishChain;
        return afterExecution;
      }
      await publishLiveMessage(formatUserBashSystemMessage(input, result));
      await livePublishChain;
      const summary = userBashSummary(input.command, result);
      await this.patch(sessionId, wasRunning ? { lastSummary: summary, thinkingPreview: undefined } : { status: "completed", lastSummary: summary, thinkingPreview: undefined });
      return this.mustGet(sessionId);
    } catch (error) {
      clearInterval(liveTimer);
      const afterFailure = this.mustGet(sessionId);
      if (["cancelled", "failed"].includes(afterFailure.status)) {
        await livePublishChain;
        return afterFailure;
      }
      const message = error instanceof Error ? error.message : String(error);
      await publishLiveMessage(formatUserBashFailureSystemMessage(input, message, liveOutput));
      await livePublishChain;
      await this.appendLog(sessionId, `bash failed: ${message}`);
      await this.messageBuilder.recordError(sessionId, `Bash failed: ${message}`);
      await this.patch(sessionId, wasRunning ? { lastSummary: `Bash failed: ${message}`, thinkingPreview: undefined } : { status: "failed", lastSummary: `Bash failed: ${message}`, thinkingPreview: undefined });
      throw error;
    }
  }

  private async executeCompactCommandIfSupported(sessionId: string, text: string, handle: RuntimeSessionHandle): Promise<boolean> {
    if (!isCompactSlashCommand(text) || !handle.compact) return false;
    await this.cancelPendingExtensionUiForUserInput(sessionId, handle);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    const customInstructions = text.trim().replace(/^\/compact\s*/, "").trim() || undefined;
    logAgentd("compact requested", {
      sessionId,
      wasStreaming: handle.isStreaming,
      instructionChars: customInstructions?.length ?? 0,
    });
    await handle.compact(customInstructions);
    return true;
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

  async clearQueue(sessionId: string, _kind: "steering" | "followUp" | "all"): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle) throw new Error(`Session has no attached runtime: ${sessionId}`);
    // Drop pending deliveries BEFORE applyQueueUpdate so the [] -> [] transition is not
    // mis-interpreted as Pi delivering the prompts; user explicitly discarded them.
    this.pendingQueueDeliveries.delete(sessionId);
    this.materializedQueueDeliveries.delete(sessionId);
    handle.clearQueue();
    await this.applyQueueUpdate(sessionId, [], []);
  }

  private isPromptInRuntimeQueue(handle: RuntimeSessionHandle, text: string): boolean {
    // `handle.getFollowUpMessages` / `handle.getSteeringMessages` are translated by the runtime
    // adapter so slash-command expansions (e.g. Pi inlining the SKILL.md body for `/skill:<name>`)
    // resolve back to the raw text we submitted. That lets this raw-text lookup match correctly
    // even when Pi enqueues an expanded form, which is the regression that previously caused
    // `drainPendingTextOnce` to fire prematurely and duplicate the user bubble.
    const matches = (entry: string) => queueTextMatchesUserText(entry, text);
    return handle.getFollowUpMessages().some(matches) || handle.getSteeringMessages().some(matches);
  }

  private async recordNonSkillSlashCommandReceipt(sessionId: string, text: string): Promise<string | undefined> {
    if (!isNonSkillSlashCommand(text)) return undefined;
    return this.messageBuilder.recordCommandReceipt(sessionId, text);
  }

  private async drainPendingTextOnce(sessionId: string, text: string): Promise<void> {
    await this.drainPendingQueueDeliveryOnce(sessionId, (entry) => entry.text === text);
  }

  private async drainPendingQueueDeliveryOnce(sessionId: string, matches: (entry: PendingQueueDelivery) => boolean): Promise<PendingQueueDelivery | undefined> {
    const pending = this.pendingQueueDeliveries.get(sessionId);
    if (!pending || pending.length === 0) return undefined;
    const index = pending.findIndex(matches);
    if (index < 0) return undefined;
    const [entry] = pending.splice(index, 1);
    if (!entry) return undefined;
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
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
    pending.splice(index, 1);
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
  }

  private async removeMaterializedQueueItem(sessionId: string, delivery: PendingQueueDelivery): Promise<boolean> {
    const current = this.sessions.get(sessionId);
    if (!current) return false;

    const removeOne = (items: readonly PickyQueueItem[]): { items: PickyQueueItem[]; changed: boolean } => {
      const indexById = items.findIndex((item) => item.id === delivery.id);
      const index = indexById >= 0 ? indexById : items.findIndex((item) => queueItemMatchesDelivery(item, delivery));
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

  private pushPendingQueueDelivery(
    sessionId: string,
    text: string,
    originatedBy: "user" | "main_agent",
    options: { kind: "steering" | "followUp"; attachedImagesCount?: number },
  ): void {
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
    if (isNonSkillSlashCommand(text)) return;
    const list = this.pendingQueueDeliveries.get(sessionId) ?? [];
    list.push({
      id: randomUUID(),
      kind: options.kind,
      text,
      originatedBy,
      ...(options.attachedImagesCount && options.attachedImagesCount > 0
        ? { attachedImagesCount: options.attachedImagesCount }
        : {}),
    });
    this.pendingQueueDeliveries.set(sessionId, list);
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

  private dropAlreadyMaterializedQueueEntries(
    sessionId: string,
    queues: { steering: readonly string[]; followUp: readonly string[] },
    pendingDeliveries: readonly PendingQueueDelivery[],
  ): { steering: string[]; followUp: string[] } {
    const materialized = this.materializedQueueDeliveries.get(sessionId);
    if (!materialized || materialized.length === 0) {
      return { steering: [...queues.steering], followUp: [...queues.followUp] };
    }

    const pendingCounts = new Map<string, number>();
    for (const delivery of pendingDeliveries) {
      const key = `${delivery.kind}\u0000${delivery.text}`;
      pendingCounts.set(key, (pendingCounts.get(key) ?? 0) + 1);
    }

    const remainingMaterialized = [...materialized];
    const dropForKind = (kind: "steering" | "followUp", texts: readonly string[]): string[] => {
      const result: string[] = [];
      for (const text of texts) {
        const key = `${kind}\u0000${text}`;
        const pendingCount = pendingCounts.get(key) ?? 0;
        if (pendingCount > 0) {
          pendingCounts.set(key, pendingCount - 1);
          result.push(text);
          continue;
        }

        const materializedIndex = remainingMaterialized.findIndex((entry) => entry.kind === kind && entry.text === text);
        if (materializedIndex >= 0) {
          remainingMaterialized.splice(materializedIndex, 1);
          continue;
        }
        result.push(text);
      }
      return result;
    };

    const steering = dropForKind("steering", queues.steering);
    const followUp = dropForKind("followUp", queues.followUp);
    if (remainingMaterialized.length > 0) {
      this.materializedQueueDeliveries.set(sessionId, remainingMaterialized);
    } else {
      this.materializedQueueDeliveries.delete(sessionId);
    }
    return { steering, followUp };
  }

  private async applyQueueUpdateNow(sessionId: string, steering: readonly string[], followUp: readonly string[], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode): Promise<void> {
    if (!this.sessions.has(sessionId)) return;
    const enqueuedAt = new Date().toISOString();
    const current = this.mustGet(sessionId);
    const pendingDeliveries = this.pendingQueueDeliveries.get(sessionId) ?? [];
    const nextRuntimeQueues = this.dropAlreadyMaterializedQueueEntries(sessionId, { steering, followUp }, pendingDeliveries);
    const queuedSteers = queueItems(nextRuntimeQueues.steering, enqueuedAt, current.queuedSteers, pendingDeliveries.filter((entry) => entry.kind === "steering"), randomUUID);
    const queuedFollowUps = queueItems(nextRuntimeQueues.followUp, enqueuedAt, current.queuedFollowUps, pendingDeliveries.filter((entry) => entry.kind === "followUp"), randomUUID);
    const previousSteeringMode = this.lastEmittedSteeringMode.get(sessionId) ?? current.steeringMode ?? "one-at-a-time";
    const previousFollowUpMode = this.lastEmittedFollowUpMode.get(sessionId) ?? current.followUpMode ?? "one-at-a-time";
    const queueChanged = !sameQueueItems(current.queuedSteers ?? [], queuedSteers) || !sameQueueItems(current.queuedFollowUps ?? [], queuedFollowUps);
    const modeChanged = steeringMode !== (current.steeringMode ?? "one-at-a-time") || followUpMode !== (current.followUpMode ?? "one-at-a-time");
    const removedItems = diffQueueRemovedItems(current.queuedSteers ?? [], current.queuedFollowUps ?? [], nextRuntimeQueues.steering, nextRuntimeQueues.followUp);
    await this.patch(sessionId, { queuedSteers, queuedFollowUps, steeringMode, followUpMode });
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
    const exactMatch = await this.drainPendingQueueDeliveryOnce(sessionId, (entry) => {
      if (event.queueKind && entry.kind !== event.queueKind) return false;
      return entry.text === deliveredText || entry.text === event.text;
    });
    if (exactMatch || !event.queueKind) return;

    // Some Pi SDK paths can surface the built prompt as the message_start text while Picky tracks
    // the raw user instruction in pendingQueueDeliveries. If there is exactly one pending item of
    // the delivered queue kind, the message_start is still authoritative evidence that Pi consumed
    // that pending input even when no trailing queue_update [] is emitted.
    const sameKindPending = (this.pendingQueueDeliveries.get(sessionId) ?? []).filter((entry) => entry.kind === event.queueKind);
    if (sameKindPending.length === 1) {
      await this.drainPendingQueueDeliveryOnce(sessionId, (entry) => entry.id === sameKindPending[0]!.id);
    }
  }

  private async handleRuntimeInputMessage(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void> {
    if (event.originatedBy !== "pi_extension") return;
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
    const nextTurn = { ...currentTurn, [category]: currentTurn[category] + 1 };
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
      patch: {
        pendingExtensionUiRequest: undefined,
        thinkingPreview: undefined,
        tools: settleActiveTools(current.tools, "Tool was interrupted by a Picky daemon restart."),
        queuedSteers: [],
        queuedFollowUps: [],
        activitySummary: zeroActivitySummary(),
      },
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
        try {
          await handle.abort();
        } catch (abortError) {
          logAgentd("runtime resume aborted after terminal state failed", { sessionId: session.id, error: abortError instanceof Error ? abortError.message : String(abortError) });
        }
        pendingHandle.reject(new Error(`Runtime resume discarded because session is ${currentBeforeAttach.status}`));
        return undefined;
      }
      await this.attachRuntimeHandle(session.id, handle);
      pendingHandle.resolve(handle);
      await this.appendLog(session.id, `runtime reattached from pi session: ${sessionFilePath}`);
      const interrupted = await this.interruptedRuntimeLiveStatePatch(session.id);
      const current = this.mustGet(session.id);
      const reattachPatch: Partial<PickyAgentSession> = { ...interrupted.patch };
      if (!isTerminalStatus(current.status)) {
        // The previous extension UI dialog promise lived only inside the old daemon process,
        // so its requestId is no longer answerable. Drop the stale pending request so the HUD
        // does not re-show a form that the new ExtensionUiBridge cannot resolve, and ask the
        // user to continue via follow-up/steer instead.
        reattachPatch.status = "blocked";
        reattachPatch.lastSummary = interrupted.hadPendingExtensionUiRequest
          ? "Picky daemon restarted; the previous question can no longer be answered. Send a follow-up or steer message to continue."
          : "Previous run was interrupted by daemon restart; send a follow-up or steer message to continue.";
      }
      await this.patch(session.id, reattachPatch);
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

  async steer(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
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
    const prompt = buildSteerPrompt(text, context);
    const previousSession = this.mustGet(sessionId);
    if (isNoTurnStateRestoringSlashCommand(text)) this.rememberNoTurnRanSessionState(sessionId, previousSession);
    const revivedTerminalSession = isTerminalStatus(previousSession.status);
    if (revivedTerminalSession) {
      await this.patch(sessionId, { status: "running", lastSummary: "Steering message sent", thinkingPreview: undefined });
    }
    logAgentd("steer requested", { sessionId, textChars: text.length, contextId: context?.id, images: prompt.imagePaths.length, isStreaming: handle.isStreaming });
    const commandReceiptId = await this.recordNonSkillSlashCommandReceipt(sessionId, text);
    this.pushPendingQueueDelivery(sessionId, text, "user", {
      kind: "steering",
      attachedImagesCount: prompt.imagePaths.length,
    });
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
    if (outcome?.handledSynchronously || !this.isPromptInRuntimeQueue(handle, text)) {
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
      await this.patch(sessionId, { status: "running", lastSummary: "Steering message sent", finalAnswer: undefined, thinkingPreview: undefined });
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
    const handle = this.runtimeHandles.get(sessionId);
    const cancellationMessagesBefore = countSystemMessages(beforeAbort, "Cancelled by user");
    logAgentd("abort requested", { sessionId, hasHandle: Boolean(handle) });
    if (handle) {
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
    this.pendingQueueDeliveries.delete(sessionId);
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
    const session = this.mustGet(sessionId);
    if (session.pendingExtensionUiRequest?.id === requestId) {
      const pending = pendingBeforeAnswer?.id === requestId ? pendingBeforeAnswer : session.pendingExtensionUiRequest;
      const summary = pending ? summarizeExtensionUiAnswer(pending, value) : undefined;
      if (summary) await this.appendLog(sessionId, `${EXTENSION_ANSWER_PREFIX}${summary}`);
      await this.patch(sessionId, { pendingExtensionUiRequest: undefined, status: "running", lastSummary: "Extension UI answered", thinkingPreview: undefined });
    }
    return this.mustGet(sessionId);
  }

  private async detachRuntimeHandle(sessionId: string, abort = false): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    if (abort && handle) {
      await handle.abort();
      await this.waitForRuntimeEvents(sessionId);
    }
    this.runtimeHandleUnsubscribes.get(sessionId)?.();
    this.runtimeHandleUnsubscribes.delete(sessionId);
    this.runtimeHandles.delete(sessionId);
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
      if (event.type === "status" && event.noTurnRan && ["completed", "failed", "cancelled"].includes(event.status)) {
        const wasPendingReload = this.pendingResourceReloadSessionIDs.delete(sessionId);
        if (wasPendingReload && event.status === "completed" && !event.preserveSessionState) {
          this.emit("resourcesReloaded", sessionId);
        }
      }
      this.maybeDrainPostCompactionReload(sessionId);
    });
    const tracked = next.catch(() => undefined);
    this.runtimeEventChains.set(sessionId, tracked);
    await next;
    if (this.runtimeEventChains.get(sessionId) === tracked) this.runtimeEventChains.delete(sessionId);
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
    this.pendingQueueDeliveries.delete(sessionId);
    this.materializedQueueDeliveries.delete(sessionId);
    this.queueUpdateChains.delete(sessionId);
    this.turnActivity.delete(sessionId);
    this.noTurnRanSessionStateRestores.delete(sessionId);
    this.pendingResourceReloadSessionIDs.delete(sessionId);
    this.pendingPostCompactionReloadIds.delete(sessionId);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    this.messageBuilder.onSessionRemoved(sessionId);
    if (this.isPickleSession(sessionId)) this.clearPickleCompletionTracking(sessionId);
    await this.patch(sessionId, {
      title: this.isPickleSession(sessionId) ? titleForEmptyPickleSession({ ...(nextContext ?? {}), cwd } as PickyContextPacket) : current.title,
      status: "waiting_for_input",
      cwd,
      lastSummary: "Ready for instructions",
      finalAnswer: undefined,
      thinkingPreview: undefined,
      pendingExtensionUiRequest: undefined,
      logs: [],
      tools: [],
      artifacts: [],
      changedFiles: [],
      todoState: undefined,
      messages: [],
      queuedSteers: [],
      queuedFollowUps: [],
      activitySummary: zeroActivitySummary(),
      contextUsage: undefined,
      piSessionFilePath: event.sessionFilePath,
      pinned: false,
    });
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
    await this.runSessionWrite(sessionId, async () => {
      const session = this.mustGet(sessionId);
      const changedFiles = mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(line));
      const linkArtifacts = extractSessionLinkArtifacts(line).filter((artifact) => !session.artifacts.some((existing) => existing.url === artifact.url));
      const artifacts = mergeArtifacts(session.artifacts, linkArtifacts);
      const nextSession = {
        ...session,
        logs: [...session.logs, line],
        changedFiles,
        artifacts,
        ...(piSessionFilePath ? { piSessionFilePath } : {}),
        updatedAt: new Date().toISOString(),
      };
      await this.upsert(nextSession, { emitSession: false });
    });
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
      void this.refreshPickleSessionTitleFromPi(sessionId);
    }
  }

  // Pi names the underlying session asynchronously after the first turn, but session_info_changed
  // events do not fire when Picky resumes an existing pi session file. Read the JSONL directly and
  // patch the Pickle title so the HUD card shows Pi's name instead of "New Pickle · cwd".
  private async refreshPickleSessionTitleFromPi(sessionId: string): Promise<void> {
    if (!this.isPickleSession(sessionId)) return;
    const session = this.sessions.get(sessionId);
    if (!session) return;
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) return;
    try {
      const name = await readPiSessionInfoName(sessionFilePath);
      if (!name) return;
      const current = this.sessions.get(sessionId);
      if (!current || current.title === name) return;
      logAgentd("pickle session title refreshed from pi", { sessionId, previousTitle: current.title, name });
      await this.patch(sessionId, { title: name });
    } catch (error) {
      logAgentd("pickle session title refresh failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async materializeTerminalArtifacts(sessionId: string): Promise<void> {
    const materialized = await this.artifactMaterializer.materializeTerminalArtifacts(this.mustGet(sessionId));
    if (!materialized) return;
    await this.patch(sessionId, { artifacts: materialized.artifacts });
    for (const artifact of materialized.emittedArtifacts) this.emit("artifact", sessionId, artifact);
  }

  private async patch(sessionId: string, patch: Partial<PickyAgentSession>, options: { emitSession?: boolean } = {}): Promise<void> {
    await this.runSessionWrite(sessionId, async () => {
      const session = { ...this.mustGet(sessionId), ...patch, updatedAt: new Date().toISOString() };
      await this.upsert(session, options);
    });
  }

  private async updateTodoState(sessionId: string, todoState: PickyAgentSession["todoState"]): Promise<void> {
    const current = this.mustGet(sessionId).todoState;
    if (sameTodoState(current, todoState)) return;
    await this.patch(sessionId, { todoState }, { emitSession: false });
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => {
      this.emit("todoStateUpdated", sessionId, todoState, seq);
    });
  }

  private async syncSessionMessages(sessionId: string, messages: readonly PickySessionMessage[]): Promise<void> {
    await this.runSessionWrite(sessionId, async () => {
      const session = { ...this.mustGet(sessionId), messages: [...messages], updatedAt: new Date().toISOString() };
      this.sessions.set(session.id, session);
      await this.store.save(session);
    });
  }

  private async runSessionWrite(sessionId: string, work: () => Promise<void>): Promise<void> {
    const previous = this.patchChains.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(work);
    const tracked = next.catch(() => undefined);
    this.patchChains.set(sessionId, tracked);
    try {
      await next;
    } finally {
      if (this.patchChains.get(sessionId) === tracked) this.patchChains.delete(sessionId);
    }
  }

  private nextSeq(sessionId: string): number {
    const next = (this.sessionSeq.get(sessionId) ?? 0) + 1;
    this.sessionSeq.set(sessionId, next);
    return next;
  }

  private async upsert(session: PickyAgentSession, options: { emitSession?: boolean } = {}): Promise<void> {
    this.sessions.set(session.id, session);
    await this.store.save(session);
    if (options.emitSession ?? true) this.emit("session", session);
  }

  private mustGet(sessionId: string): PickyAgentSession {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error(`Unknown session: ${sessionId}`);
    return session;
  }
}

function makePointerOverlayRequestForContext(context: PickyContextPacket, request: PickyShowPointerRequest): PickyShowPointerResult["request"] {
  const screenshot = selectPointerScreenshot(context.screenshots, request);
  if (!screenshot.bounds) throw new Error(`No display bounds are available for ${screenshot.screenId ?? screenshot.id}.`);
  const screenshotSize = screenshotSizeFromMetadata(screenshot) ?? readImageSize(screenshot.path);
  if (!screenshotSize) {
    throw new Error(`Screenshot pixel coordinates require screenshot dimensions for ${screenshot.screenId ?? screenshot.id}.`);
  }

  const bounded = clampPointerCoordinates(request, screenshotSize);
  return {
    ...makePointerOverlayRequest({ ...request, ...bounded }, {
      contextId: context.id,
      screenId: screenshot.screenId,
      screenBounds: screenshot.bounds,
      screenshotSize,
    }),
    ...(bounded.clamped ? { clamped: true } : {}),
  };
}

function readImageSize(path: string): { width: number; height: number } | undefined {
  try {
    return readImageSizeFromBuffer(readFileSync(path));
  } catch {
    return undefined;
  }
}

function sameTodoState(left: PickyAgentSession["todoState"], right: PickyAgentSession["todoState"]): boolean {
  if (left === right) return true;
  if (!left || !right) return false;
  return left.updatedAt === right.updatedAt && JSON.stringify(left.tasks) === JSON.stringify(right.tasks);
}

function awaitPendingRuntimeHandle(pending: Promise<RuntimeSessionHandle>, signal?: AbortSignal): Promise<RuntimeSessionHandle> {
  if (!signal) return pending;
  if (signal.aborted) return Promise.reject(abortSignalReason(signal));
  return new Promise<RuntimeSessionHandle>((resolve, reject) => {
    const onAbort = () => reject(abortSignalReason(signal));
    signal.addEventListener("abort", onAbort, { once: true });
    pending.then(resolve, reject).finally(() => signal.removeEventListener("abort", onAbort));
  });
}

function abortSignalReason(signal: AbortSignal): unknown {
  return signal.reason ?? new Error("Pending runtime handle wait aborted");
}

function createPendingRuntimeHandle(): { promise: Promise<RuntimeSessionHandle>; resolve: (handle: RuntimeSessionHandle) => void; reject: (error: unknown) => void } {
  let resolve!: (handle: RuntimeSessionHandle) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<RuntimeSessionHandle>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  // The pending handle exists so slash-command requests can await startup; startup failures are
  // handled by the session creation path, so avoid an unhandled rejection when no request races it.
  promise.catch(() => undefined);
  return { promise, resolve, reject };
}

async function readRecentPinnedSourceState(sessionFilePath: string | undefined): Promise<{ messages: PickySessionMessage[]; todoState?: PickyAgentSession["todoState"] } | undefined> {
  if (!sessionFilePath) return undefined;
  try {
    const result = await readPiTerminalSessionMessages(sessionFilePath);
    const conversationMessages = result.messages.filter((message) => !isPickyHandoffCommandMessage(message));
    return {
      messages: lastTurns(conversationMessages, PINNED_SOURCE_TURN_COUNT),
      ...(result.todoState ? { todoState: result.todoState } : {}),
    };
  } catch {
    return undefined;
  }
}

function shouldReattachBlockedSessionOnStartup(session: PickyAgentSession): boolean {
  return session.status === "blocked" && session.archived !== true && Boolean(piSessionFilePathForSession(session));
}

function isOrphanedChildSessionRecovery(session: PickyAgentSession): boolean {
  return session.logs.includes(ORPHANED_CHILD_SESSION_RECOVERY_LOG);
}

function queueItemMatchesDelivery(item: PickyQueueItem, delivery: PendingQueueDelivery): boolean {
  return queueTextMatchesUserText(item.text, delivery.text);
}

function countSystemMessages(session: PickyAgentSession, text: string): number {
  return (session.messages ?? []).filter((message) => message.kind === "system" && message.text === text).length;
}

/**
 * Copy `sourcePath` to a sibling file whose basename is `<newSessionId><ext>`. The copy is a
 * snapshot — bytes are read into memory and the trailing partial line (if any) is dropped before
 * writing, so a forked transcript never starts with a half-written JSON record even when the
 * source is being appended to mid-turn. Returns the absolute destination path.
 */
async function snapshotPiSessionFile(sourcePath: string, newSessionId: string): Promise<string> {
  const data = await readFile(sourcePath);
  const lastNewline = data.lastIndexOf(0x0a /* \n */);
  const trimmed = lastNewline >= 0 ? data.subarray(0, lastNewline + 1) : data;
  const directory = dirname(sourcePath);
  await mkdir(directory, { recursive: true });
  const extension = extname(sourcePath) || ".jsonl";
  const destinationPath = join(directory, `${newSessionId}${extension}`);
  await writeFile(destinationPath, trimmed);
  return destinationPath;
}
