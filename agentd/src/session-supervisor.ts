import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { extractChangedFilesFromExplicitText, extractSessionLinkArtifacts } from "./artifact-store.js";
import { ArtifactMaterializer } from "./application/artifact-materializer.js";
import { RuntimeEventHandler } from "./application/runtime-event-handler.js";
import { summarizeExtensionUiAnswer } from "./application/extension-ui-request-mapper.js";
import { buildInitialTaskPrompt, buildMainAgentBootstrapPair, buildMainAgentPrompt, buildMainAgentSideCompletionPrompt, buildSideAgentPrompt, buildSteerPrompt, type BuiltPrompt } from "./prompt-builder.js";
import type { EventEnvelope, ModelCycleDirection, PickyActivitySummary, PickyAgentSession, PickyContextPacket, PickyMainAgentMessage, PickyMainAgentState, PickyQueueItem, PickyQueueMode, PickySessionMessage } from "./protocol.js";
import { makePointerOverlayRequest, type PickyShowPointerRequest, type PickyShowPointerResult } from "./application/pointer-tool.js";
import { parsePointerTags, type ParsedPointerTags } from "./application/pointer-tag-parser.js";
import { readPiSessionInfoName, readPiTerminalSessionMessages } from "./application/pi-session-syncer.js";
import { SessionStore } from "./session-store.js";
import type { TaskRouter } from "./task-router.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, ThinkingLevel } from "./runtime/types.js";
import { mergeArtifacts } from "./domain/artifacts.js";
import { mergeChangedFiles } from "./domain/changed-files.js";
import { isTerminalStatus } from "./domain/session-status.js";
import { HANDOFF_PREFIX, FOLLOWUP_PREFIX, STEER_PREFIX, EXTENSION_ANSWER_PREFIX } from "./domain/log-prefixes.js";
import { cleanFinalAnswer } from "./domain/session-summary.js";
import { settleActiveTools } from "./domain/tool-activity.js";
import { titleFromContext } from "./domain/session-title.js";
import type { ToolCategory } from "./domain/tool-categorizer.js";
import { logAgentd } from "./local-log.js";
import { SessionMessageBuilder } from "./session-message-builder.js";

export interface SessionSupervisorOptions {
  taskRouter?: TaskRouter;
  mainRuntime?: AgentRuntime;
}

type QuickReplyEvent = Extract<EventEnvelope, { type: "quickReply" }>;
type QuickReplyMetadata = Pick<QuickReplyEvent, "originSource" | "replyKind" | "sessionId" | "inputId">;
const POINTER_OVERLAY_SEQUENCE_INTERVAL_MS = 1_000;

export class SessionSupervisor extends EventEmitter {
  private sessions = new Map<string, PickyAgentSession>();
  private runtimeHandles = new Map<string, RuntimeSessionHandle>();
  private readonly artifactMaterializer: ArtifactMaterializer;
  private readonly runtimeEventHandler: RuntimeEventHandler;
  private mainHandle?: RuntimeSessionHandle;
  private mainHandlePromise?: Promise<RuntimeSessionHandle>;
  private mainHandleUnsubscribe?: () => void;
  private mainHandleGeneration = 0;
  private mainThinkingLevel?: ThinkingLevel;
  /// Free-form user instructions appended to every main-agent per-turn prompt. Mirrors the
  /// `mainAgentExtraInstructions` field stored in PickySettings on the Picky.app side; pushed
  /// over the websocket via `setMainAgentExtraInstructions` whenever settings are saved.
  private mainExtraInstructions = "";
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
  private suppressNextMainReply = false;
  private suppressInterruptedMainCompletion = false;
  private sideSessionIds = new Set<string>();
  private sideCompletionNotified = new Set<string>();
  private sideCompletionInFlight = new Set<string>();
  private pendingSideCompletions: string[] = [];
  private sessionContexts = new Map<string, PickyContextPacket>();
  private pendingRuntimeHandles = new Map<string, Promise<RuntimeSessionHandle>>();
  private sessionSeq = new Map<string, number>();
  private queueUpdateChains = new Map<string, Promise<void>>();
  private activityUpdateChains = new Map<string, Promise<void>>();
  private turnActivity = new Map<string, PickyActivitySummary>();
  private runtimeEventChains = new Map<string, Promise<void>>();
  private emitChains = new Map<string, Promise<void>>();
  private readonly messageBuilder: SessionMessageBuilder;
  private noTurnRanSessionStateRestores = new Map<string, Partial<PickyAgentSession>>();
  private lastEmittedSteeringMode = new Map<string, PickyQueueMode>();
  private lastEmittedFollowUpMode = new Map<string, PickyQueueMode>();
  // Track follow-up/steer prompts that Pi has queued but not yet started processing. We defer the
  // user_text journal write until Pi actually dequeues the prompt, so the HUD can render queued
  // items as pending bubbles instead of (incorrectly) hiding them behind a duplicate user bubble.
  private pendingQueueDeliveries = new Map<string, Array<{ text: string; originatedBy: "user" | "main_agent" }>>();
  // Serialize all session-state writes per session id. Without this, concurrent patch/sync calls
  // capture stale snapshots in their `{ ...mustGet(), ...patch }` spread and overwrite each
  // other's in-memory cache + persisted state. The status:running patch and the synthetic
  // status:completed (from /name interception) racing against session_info/log patches was
  // observed to revert the session back to 'running' after a /name slash command.
  private patchChains = new Map<string, Promise<void>>();

  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore, private readonly options: SessionSupervisorOptions = {}) {
    super();
    this.artifactMaterializer = new ArtifactMaterializer();
    this.messageBuilder = new SessionMessageBuilder({
      emitAppended: async (sessionId, message, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageAppended", sessionId, message, seq); }); },
      emitReplaced: async (sessionId, messageId, message, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageReplaced", sessionId, messageId, message, seq); }); },
      emitRemoved: async (sessionId, messageId, seq) => { await this.chainEmit(sessionId, async () => { this.emit("messageRemoved", sessionId, messageId, seq); }); },
      nextSeq: (sessionId) => this.nextSeq(sessionId),
      now: () => new Date().toISOString(),
      syncSessionMessages: async (sessionId, messages) => { await this.syncSessionMessages(sessionId, messages); },
    });
    this.runtimeEventHandler = new RuntimeEventHandler({
      getSession: (sessionId) => this.mustGet(sessionId),
      patchSession: (sessionId, patch) => this.patch(sessionId, patch),
      consumeNoTurnRanSessionStateRestore: (sessionId) => this.consumeNoTurnRanSessionStateRestore(sessionId),
      appendLog: (sessionId, line) => this.appendLog(sessionId, line),
      materializeTerminalArtifacts: (sessionId) => this.materializeTerminalArtifacts(sessionId),
      applyQueueUpdate: (sessionId, steering, followUp) => this.applyQueueUpdate(sessionId, steering, followUp),
      incrementActivity: (sessionId, category) => this.incrementActivity(sessionId, category),
      commitTurnActivity: (sessionId) => this.commitTurnActivity(sessionId),
      notifySideCompletion: (sessionId) => this.notifyMainOfSideCompletion(sessionId),
      isSideSession: (sessionId) => this.sideSessionIds.has(sessionId),
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
      const isSideSession = hasSideSessionMarkerLog(migratedSession);
      if (isSideSession) this.sideSessionIds.add(migratedSession.id);
      const session = isSideSession && migratedSession.notifyMainOnCompletion === undefined
        ? { ...migratedSession, notifyMainOnCompletion: true }
        : migratedSession;
      this.sessions.set(session.id, session);
      this.messageBuilder.hydrateSession(session.id, session.messages);
      if (session.piSessionFilePath !== persistedSession.piSessionFilePath || session.notifyMainOnCompletion !== persistedSession.notifyMainOnCompletion) await this.store.save(session);
      if (this.sideSessionIds.has(session.id)) void this.refreshSideSessionTitleFromPi(session.id);

      if (!isTerminalStatus(session.status)) {
        if (session.archived === true) {
          const restored = {
            ...session,
            status: "cancelled" as const,
            lastSummary: "Archived session was not resumed after daemon restart",
            pendingExtensionUiRequest: undefined,
            updatedAt: new Date().toISOString(),
          };
          this.sessions.set(restored.id, restored);
          await this.store.save(restored);
          continue;
        }

        const resumedHandle = await this.tryResumeRuntimeHandle(session);
        if (!resumedHandle) {
          const restored = {
            ...this.mustGet(session.id),
            status: "blocked" as const,
            lastSummary: "Runtime not attached after daemon restart; start a new task or resume support is required",
            logs: appendUniqueLog(this.mustGet(session.id).logs, "Runtime not attached after daemon restart; start a new task or resume support is required"),
            pendingExtensionUiRequest: undefined,
            updatedAt: new Date().toISOString(),
          };
          this.sessions.set(restored.id, restored);
          await this.store.save(restored);
        }
      } else if (shouldReattachBlockedSessionOnStartup(session)) {
        await this.tryResumeRuntimeHandle(session);
      }
    }
  }

  list(): PickyAgentSession[] {
    return [...this.sessions.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  listSideSessions(): PickyAgentSession[] {
    return this.list().filter((session) => this.sideSessionIds.has(session.id));
  }

  isSideSession(sessionId: string): boolean {
    return this.sideSessionIds.has(sessionId);
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

  private async pendingRuntimeHandle(sessionId: string): Promise<RuntimeSessionHandle | undefined> {
    const pending = this.pendingRuntimeHandles.get(sessionId);
    if (!pending) return undefined;
    try {
      return await pending;
    } catch (error) {
      logAgentd("slash commands pending runtime failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
      return undefined;
    }
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

  private schedulePointerOverlaysFromTags(parsed: ParsedPointerTags, context: PickyContextPacket | undefined): void {
    if (!context || parsed.points.length === 0) return;
    const requests = parsed.points.flatMap((point, index) => {
      try {
        return [{ index, request: makePointerOverlayRequestForContext(context, point) }];
      } catch (error) {
        logAgentd("main pointer tag ignored", { contextId: context.id, error: error instanceof Error ? error.message : String(error) });
        return [];
      }
    });
    for (const item of requests) {
      setTimeout(() => {
        this.emit("pointerOverlayRequested", item.request);
      }, item.index * POINTER_OVERLAY_SEQUENCE_INTERVAL_MS);
    }
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

  async resetMainAgent(): Promise<void> {
    logAgentd("main reset requested", { messages: this.mainState.messages.length, hadHandle: this.mainHandle ? 1 : 0 });
    const currentHandle = this.mainHandle;
    const pendingHandlePromise = this.mainHandlePromise;
    this.detachMainHandleForInterruption();
    await this.patchMainState({ messages: [], sessionFilePath: undefined, cwd: undefined });

    if (currentHandle) await this.abortResetMainHandle(currentHandle, "current");
    if (pendingHandlePromise) {
      void pendingHandlePromise
        .then(async (pendingHandle) => {
          if (pendingHandle !== currentHandle) await this.abortResetMainHandle(pendingHandle, "pending");
          if (this.mainHandle === pendingHandle) {
            this.detachMainHandleForInterruption();
            await this.patchMainState({ sessionFilePath: undefined, cwd: undefined });
          }
        })
        .catch((error) => {
          logAgentd("main reset pending handle failed", { error: error instanceof Error ? error.message : String(error) });
        });
    }
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

  setMainAgentExtraInstructions(instructions: string): void {
    this.mainExtraInstructions = instructions.trim();
    logAgentd("main extra instructions configured", { instructionChars: this.mainExtraInstructions.length });
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
    this.suppressInterruptedMainCompletion = false;
    if (this.pendingSideCompletions.length > 0) logAgentd("main pending side completions cleared", { count: this.pendingSideCompletions.length });
    this.pendingSideCompletions = [];
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

  async createSideFromHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string; cwd?: string }): Promise<PickyAgentSession> {
    const cwd = normalizeOptionalString(handoff.cwd) ?? context.cwd;
    const handoffContext = cwd ? { ...context, cwd } : context;
    logAgentd("side session create requested", { contextId: context.id, titleChars: handoff.title.length, instructionChars: handoff.instructions.length, cwd: handoffContext.cwd });
    const session = await this.createVisibleSession(handoffContext, handoff.title.trim() || titleFromContext(context), buildSideAgentPrompt(handoffContext, handoff), { notifyMainOnCompletion: true });
    this.sideSessionIds.add(session.id);
    await this.appendLog(session.id, `${HANDOFF_PREFIX}${handoff.instructions}`);
    if (handoffContext.cwd) await this.appendLog(session.id, `main-agent handoff cwd: ${handoffContext.cwd}`);
    return this.mustGet(session.id);
  }

  async createEmptySideSession(context: PickyContextPacket): Promise<PickyAgentSession> {
    if (!this.runtime.prewarm) throw new Error("Runtime cannot prewarm empty side sessions");
    const now = new Date().toISOString();
    const id = `session-${randomUUID()}`;
    const cwd = normalizeOptionalString(context.cwd);
    const sideContext: PickyContextPacket = { ...context, cwd, transcript: undefined, screenshots: [] };
    const session: PickyAgentSession = {
      id,
      title: titleForEmptySideSession(sideContext),
      status: "waiting_for_input",
      cwd: sideContext.cwd,
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
    this.sideSessionIds.add(id);
    this.sessionContexts.set(id, sideContext);
    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(id, pendingHandle.promise);
    try {
      await this.upsert(session);
      logAgentd("empty side session queued", { sessionId: id, cwd: sideContext.cwd, contextId: context.id });
      const handle = await this.runtime.prewarm({ cwd: sideContext.cwd, sessionId: id });
      pendingHandle.resolve(handle);
      await this.attachRuntimeHandle(id, handle);
      await this.appendLog(id, "manual side agent: waiting for first instruction");
      if (sideContext.cwd) await this.appendLog(id, `manual side agent cwd: ${sideContext.cwd}`);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("empty side session prewarm failed", { sessionId: id, error: message });
      await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to start runtime: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to start runtime: ${message}`],
      });
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
    }
  }

  /**
   * Fork an existing side-session into a brand-new sibling session that resumes from a snapshot
   * of the source's Pi JSONL transcript. The new session inherits cwd, message history, and
   * notification preference, but starts with empty activity counters / artifacts / changed-files
   * (per-session usage telemetry should not double-count). Forking is allowed regardless of the
   * source's status: a running source's JSONL is copied byte-for-byte and trimmed to the last
   * complete line so the runtime can resume on a non-corrupt transcript even mid-turn.
   *
   * The new title is `(copy) <source title>`; Pi will rename the underlying session as soon as
   * the user runs `/name` (existing `refreshSideSessionTitleFromPi` flow handles the resync).
   */
  async duplicateSideSession(sourceSessionId: string): Promise<PickyAgentSession> {
    if (!this.runtime.resume) throw new Error("Runtime cannot duplicate sessions");
    const source = this.mustGet(sourceSessionId);
    const sourceFilePath = this.resolveSourcePiSessionFile(source);
    if (!sourceFilePath) throw new Error(`Session has no Pi session file to duplicate: ${sourceSessionId}`);

    const now = new Date().toISOString();
    const id = `session-${randomUUID()}`;
    const cwd = normalizeOptionalString(source.cwd);
    const newFilePath = await snapshotPiSessionFile(sourceFilePath, id);
    const baseTitle = source.title.trim() || "side agent";
    const sourceMessages = source.messages ?? [];
    const session: PickyAgentSession = {
      id,
      title: `(copy) ${baseTitle}`,
      status: "waiting_for_input",
      cwd,
      createdAt: now,
      updatedAt: now,
      lastSummary: "Duplicated from existing side agent",
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

    this.sideSessionIds.add(id);
    const pendingHandle = createPendingRuntimeHandle();
    this.pendingRuntimeHandles.set(id, pendingHandle.promise);
    try {
      await this.upsert(session);
      // hydrate AFTER upsert so the in-memory journal exists before the resumed runtime emits
      // any tool/assistant deltas. Without hydration, the first appendInternal would build a
      // fresh empty journal and overwrite the persisted message history via syncSessionMessages.
      this.messageBuilder.hydrateSession(id, session.messages);
      logAgentd("side session duplicate queued", {
        sourceSessionId,
        newSessionId: id,
        sourceFilePath,
        newFilePath,
        messages: session.messages?.length ?? 0,
        cwd,
      });
      const handle = await this.runtime.resume(newFilePath, { cwd, sessionId: id });
      pendingHandle.resolve(handle);
      await this.attachRuntimeHandle(id, handle);
      logAgentd("side session duplicate ready", { sourceSessionId, newSessionId: id });
      // Pull the freshly-resumed Pi session_info name (when present) so the (copy) prefix is
      // applied on top of Pi's own name rather than a stale Picky default.
      void this.refreshSideSessionTitleFromPi(id);
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("side session duplicate failed", { sourceSessionId, newSessionId: id, error: message });
      await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to duplicate session: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to duplicate session: ${message}`],
      });
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
    }
  }

  private resolveSourcePiSessionFile(session: PickyAgentSession): string | undefined {
    const fromSession = piSessionFilePathForSession(session);
    if (fromSession) return fromSession;
    const handle = this.runtimeHandles.get(session.id);
    return handle?.getSessionFilePath?.();
  }

  async pinSideSession(context: PickyContextPacket, title?: string): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = `session-${randomUUID()}`;
    const session: PickyAgentSession = {
      id,
      title: title?.trim() || titleFromContext(context),
      status: "completed",
      cwd: context.cwd,
      createdAt: now,
      updatedAt: now,
      lastSummary: "Pinned completed Pi session",
      finalAnswer: "Pinned from an idle Pi session. No Picky side-agent run has been started yet.",
      logs: buildPinnedSideSessionLogs(context),
      piSessionFilePath: piSessionFilePathFromHandoffTranscript(context.transcript),
      notifyMainOnCompletion: false,
      pinned: true,
      tools: [],
      artifacts: extractSessionLinkArtifacts(context.transcript ?? "", now),
      changedFiles: [],
      activitySummary: zeroActivitySummary(),
    };
    this.sideSessionIds.add(id);
    logAgentd("side session pinned", { sessionId: id, titleChars: session.title.length, cwd: context.cwd, contextId: context.id });
    await this.upsert(session);
    await this.messageBuilder.seedPinnedSession(id, context.transcript, session.finalAnswer, session.title);
    await this.materializeTerminalArtifacts(id);
    return this.mustGet(id);
  }

  private async createVisibleSession(context: PickyContextPacket, title: string, prompt = buildInitialTaskPrompt(context), options: { notifyMainOnCompletion?: boolean } = {}): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = `session-${randomUUID()}`;
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
    try {
      await this.upsert(session);
      logAgentd("session queued", { sessionId: id, titleChars: title.length, cwd: context.cwd });
      this.runtimeEventHandler.resetAssistantDraft(id);
      const handle = await this.runtime.create(prompt, { cwd: context.cwd, sessionId: id });
      pendingHandle.resolve(handle);
      await this.attachRuntimeHandle(id, handle);
      logAgentd("runtime attached", { sessionId: id });
      await this.patch(id, { status: "running", lastSummary: "Started", thinkingPreview: undefined });
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("runtime start failed", { sessionId: id, error: message });
      await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to start runtime: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to start runtime: ${message}`],
      });
      pendingHandle.reject(error);
      throw error;
    } finally {
      if (this.pendingRuntimeHandles.get(id) === pendingHandle.promise) this.pendingRuntimeHandles.delete(id);
    }
  }

  private async routeThroughMainAgent(context: PickyContextPacket): Promise<void> {
    logAgentd("main route requested", { contextId: context.id, source: context.source, transcriptChars: context.transcript?.length });
    const generation = this.mainHandleGeneration;
    this.mainContext = context;
    this.mainReplyContextId = context.id;
    this.mainDraft = "";
    if (context.transcript?.trim()) await this.appendMainMessage("user", context.transcript.trim());
    const prompt = buildMainAgentPrompt(context);
    if (this.mainHandlePromise && !this.mainHandle) {
      const handle = await this.mainHandlePromise;
      if (generation !== this.mainHandleGeneration) return;
      await this.deliverMainPrompt(handle, prompt);
      return;
    }
    if (!this.mainHandle) {
      const handle = await this.createInitialMainHandle(prompt, context.cwd, generation);
      if (generation !== this.mainHandleGeneration) return;
      if (!handle.initialPromptAlreadySent) await this.deliverMainPrompt(handle.handle, prompt);
      return;
    }
    await this.deliverMainPrompt(this.mainHandle, prompt);
  }

  private async deliverMainPrompt(handle: RuntimeSessionHandle, prompt: ReturnType<typeof buildMainAgentPrompt>): Promise<void> {
    if (this.mainIsProcessing && handle.interrupt) {
      logAgentd("main interrupt", { contextId: this.mainReplyContextId });
      this.suppressInterruptedMainCompletion = true;
      this.mainDraft = "";
      await handle.interrupt(prompt);
      this.suppressInterruptedMainCompletion = false;
      this.mainIsProcessing = true;
      return;
    }
    this.mainIsProcessing = true;
    logAgentd("main prompt delivered", { contextId: this.mainReplyContextId });
    await handle.followUp(prompt);
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
    const handle = await this.options.mainRuntime.prewarm({ cwd, sessionId: "picky-main-agent" });
    logAgentd("main prewarmed", { cwd });
    if (generation !== this.mainHandleGeneration) {
      await this.abortResetMainHandle(handle, "stale-prewarm");
      return handle;
    }
    await this.patchMainState({ cwd });
    const attached = this.attachMainHandle(handle, generation);
    await this.injectMainBootstrap(attached);
    return attached;
  }

  private async createInitialMainHandle(prompt: ReturnType<typeof buildMainAgentPrompt>, cwd?: string, generation = this.mainHandleGeneration): Promise<{ handle: RuntimeSessionHandle; initialPromptAlreadySent: boolean }> {
    const resumed = await this.tryResumeMainHandle(cwd ?? process.cwd(), generation);
    if (resumed) return { handle: resumed, initialPromptAlreadySent: false };
    const handle = await this.options.mainRuntime!.create(prompt, { cwd, sessionId: "picky-main-agent" });
    if (generation !== this.mainHandleGeneration) {
      await this.abortResetMainHandle(handle, "stale-initial");
      return { handle, initialPromptAlreadySent: true };
    }
    await this.patchMainState({ cwd });
    const attached = this.attachMainHandle(handle, generation);
    await this.injectMainBootstrap(attached);
    return { handle: attached, initialPromptAlreadySent: true };
  }

  private async injectMainBootstrap(handle: RuntimeSessionHandle): Promise<void> {
    if (!handle.injectInitialBootstrap) return;
    try {
      // Bake the user's extra instructions into the standing bootstrap turn instead of every
      // per-turn prompt: it costs zero tokens beyond the first turn, mirrors the "standing
      // instructions" mental model, and makes changes opt-in via main-agent reset.
      await handle.injectInitialBootstrap(buildMainAgentBootstrapPair(this.mainExtraInstructions));
    } catch (error) {
      logAgentd("main bootstrap inject failed", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  private async tryResumeMainHandle(cwd: string, generation = this.mainHandleGeneration): Promise<RuntimeSessionHandle | undefined> {
    const sessionFilePath = this.mainState.sessionFilePath?.trim();
    if (!sessionFilePath || !this.options.mainRuntime?.resume) return undefined;
    try {
      logAgentd("main resume requested", { sessionFilePath, cwd });
      const handle = await this.options.mainRuntime.resume(sessionFilePath, { cwd, sessionId: "picky-main-agent" });
      logAgentd("main resumed", { sessionFilePath, cwd });
      if (generation !== this.mainHandleGeneration) {
        await this.abortResetMainHandle(handle, "stale-resume");
        return handle;
      }
      await this.patchMainState({ cwd });
      return this.attachMainHandle(handle, generation);
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
    const message: PickyMainAgentMessage = { role, text: trimmed, createdAt: new Date().toISOString() };
    await this.patchMainState({ messages: [...this.mainState.messages, message].slice(-MAIN_AGENT_MESSAGE_LIMIT) });
    this.emit("mainMessage", message);
  }

  private async patchMainState(patch: Partial<PickyMainAgentState>): Promise<void> {
    this.mainState = normalizeMainAgentState({ ...this.mainState, ...patch });
    await this.store.saveMainAgentState(this.mainState);
  }

  private async applyMainRuntimeEvent(event: RuntimeEvent): Promise<void> {
    if (event.type === "log") {
      const sessionFilePath = piSessionFilePathFromLogLine(event.line);
      if (sessionFilePath) await this.patchMainState({ sessionFilePath });
      return;
    }
    if (event.type === "assistant_delta") {
      // A new delta means a new turn has started. Re-arm the terminal guard even
      // if the runtime did not emit an explicit `status:"running"` between turns
      // (Pi normally does, but follow-up flows that immediately stream content can
      // skip it). Without this, a side-completion follow-up turn whose `running`
      // is omitted would be silently swallowed by the prior turn's guard.
      this.mainTerminalProcessed = false;
      this.mainDraft += event.delta;
      return;
    }
    if (event.type === "status") {
      if (event.status === "running") {
        this.mainIsProcessing = true;
        this.mainTerminalProcessed = false;
      }
      if (["completed", "failed", "cancelled"].includes(event.status)) {
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
        if (this.suppressInterruptedMainCompletion) {
          this.suppressInterruptedMainCompletion = false;
          this.scheduleSideCompletionDrain();
          return;
        }
        logAgentd("main status", { status: event.status, contextId: this.mainReplyContextId, draftChars: draftSnapshot.length });
        const rawReply = cleanFinalAnswer(draftSnapshot) ?? (event.status === "failed" ? event.summary : undefined);
        if (this.suppressNextMainReply) {
          this.suppressNextMainReply = false;
        } else if (rawReply) {
          const pointerContext = this.mainContext;
          const parsedPointerTags = event.status === "completed" ? parsePointerTags(rawReply) : { text: rawReply, points: [], explicitNone: false };
          const reply = cleanFinalAnswer(parsedPointerTags.text);
          if (reply) {
            logAgentd("main quick reply", { contextId: this.mainReplyContextId, textChars: reply.length, pointerTags: parsedPointerTags.points.length });
            await this.appendMainMessage("assistant", reply);
            this.emitQuickReply(this.mainReplyContextId, reply, {
              originSource: this.mainReplyContextId === this.mainContext?.id ? quickReplyOriginFromContextSource(this.mainContext.source) : "system",
              replyKind: this.sideSessionIds.has(this.mainReplyContextId) ? "sideCompletion" : "main",
              sessionId: this.sideSessionIds.has(this.mainReplyContextId) ? this.mainReplyContextId : undefined,
            });
          }
          this.schedulePointerOverlaysFromTags(parsedPointerTags, pointerContext);
        }
        this.scheduleSideCompletionDrain();
      }
    }
  }

  private async notifyMainOfSideCompletion(sessionId: string): Promise<void> {
    const session = this.mustGet(sessionId);
    if (this.sideCompletionNotified.has(sessionId) || this.sideCompletionInFlight.has(sessionId)) return;
    if (session.notifyMainOnCompletion === false) {
      this.sideCompletionNotified.add(sessionId);
      logAgentd("side completion notify skipped", { sessionId, status: session.status });
      return;
    }
    // Defer when the main agent is mid-turn (e.g. the handoff turn that spawned this
    // side session has not emitted status:completed yet). Sending the followUp now
    // would clobber mainReplyContextId / mainDraft, and the in-flight turn's
    // suppressNextMainReply would later swallow this side completion's reply when its
    // delayed status:completed finally arrives. Park the sessionId and let
    // applyMainRuntimeEvent drain it once the active turn ends.
    if (this.mainIsProcessing) {
      if (!this.pendingSideCompletions.includes(sessionId) && !this.sideCompletionNotified.has(sessionId) && !this.sideCompletionInFlight.has(sessionId)) {
        this.pendingSideCompletions.push(sessionId);
        logAgentd("side completion deferred", { sessionId, status: session.status, queueLength: this.pendingSideCompletions.length });
      }
      return;
    }
    await this.deliverSideCompletionToMain(sessionId);
  }

  private async deliverSideCompletionToMain(sessionId: string): Promise<void> {
    if (this.sideCompletionNotified.has(sessionId) || this.sideCompletionInFlight.has(sessionId)) return;
    const session = this.sessions.get(sessionId);
    if (!session) return;
    if (session.notifyMainOnCompletion === false) {
      this.sideCompletionNotified.add(sessionId);
      logAgentd("side completion notify skipped", { sessionId, status: session.status });
      return;
    }
    this.sideCompletionInFlight.add(sessionId);
    try {
      const prompt = buildMainAgentSideCompletionPrompt(session);
      this.mainReplyContextId = sessionId;
      this.mainDraft = "";
      const delivery = await this.prepareMainCompletionDelivery(prompt, session.cwd);
      if (!delivery) return;

      this.sideCompletionNotified.add(sessionId);
      this.mainIsProcessing = true;
      logAgentd("side completion notifying main", { sessionId, status: session.status });
      if (delivery.sendAsFollowUp) await delivery.handle.followUp(prompt);
    } finally {
      this.sideCompletionInFlight.delete(sessionId);
    }
  }

  private scheduleSideCompletionDrain(): void {
    void this.drainPendingSideCompletions().catch((error) => {
      logAgentd("side completion drain failed", { error: error instanceof Error ? error.message : String(error) });
    });
  }

  private async drainPendingSideCompletions(): Promise<void> {
    if (this.mainIsProcessing) return;
    const sessionId = this.pendingSideCompletions.shift();
    if (!sessionId) return;
    logAgentd("side completion draining", { sessionId, queueLength: this.pendingSideCompletions.length });
    await this.deliverSideCompletionToMain(sessionId);
  }

  private async prepareMainCompletionDelivery(prompt: ReturnType<typeof buildMainAgentSideCompletionPrompt>, cwd?: string): Promise<{ handle: RuntimeSessionHandle; sendAsFollowUp: boolean } | undefined> {
    if (this.mainHandle) return { handle: this.mainHandle, sendAsFollowUp: true };
    if (!this.options.mainRuntime) return undefined;
    if (this.mainHandlePromise) return { handle: await this.mainHandlePromise, sendAsFollowUp: true };
    if (this.options.mainRuntime.prewarm) return { handle: await this.ensurePrewarmedMainHandle(cwd ?? process.cwd()), sendAsFollowUp: true };

    const handle = await this.options.mainRuntime.create(prompt, { cwd, sessionId: "picky-main-agent" });
    this.attachMainHandle(handle);
    return { handle, sendAsFollowUp: false };
  }

  async setNotifyMainOnCompletion(sessionId: string, enabled: boolean): Promise<PickyAgentSession> {
    if (!this.isSideSession(sessionId)) throw new Error(`Session is not a Picky side agent: ${sessionId}`);
    await this.patch(sessionId, { notifyMainOnCompletion: enabled });
    return this.mustGet(sessionId);
  }

  async setSessionArchived(sessionId: string, archived: boolean): Promise<PickyAgentSession> {
    await this.patch(sessionId, { archived });
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

  private async runtimeHandleForSessionCommand(sessionId: string, action: string): Promise<RuntimeSessionHandle> {
    const session = this.mustGet(sessionId);
    const handle = this.runtimeHandles.get(sessionId) ?? await this.tryResumeRuntimeHandle(session);
    if (!handle) {
      const reason = "Runtime session is not attached";
      await this.appendLog(sessionId, `${action} rejected: ${reason}`);
      throw new Error(reason);
    }
    return handle;
  }

  async steerSideSession(sessionId: string, text: string): Promise<PickyAgentSession> {
    if (!this.isSideSession(sessionId)) throw new Error(`Session is not a Picky side agent: ${sessionId}`);
    return this.steer(sessionId, text);
  }

  private async prepareSideSessionForUserInput(sessionId: string): Promise<void> {
    if (!this.isSideSession(sessionId)) return;
    this.clearSideCompletionTracking(sessionId);
    if (this.mustGet(sessionId).pinned) await this.patch(sessionId, { pinned: false });
  }

  private clearSideCompletionTracking(sessionId: string): void {
    this.sideCompletionNotified.delete(sessionId);
    this.sideCompletionInFlight.delete(sessionId);
    const queueIndex = this.pendingSideCompletions.indexOf(sessionId);
    if (queueIndex >= 0) {
      this.pendingSideCompletions.splice(queueIndex, 1);
      logAgentd("side completion dequeued", { sessionId, queueLength: this.pendingSideCompletions.length });
    }
  }

  async syncTerminalSession(sessionId: string, baselinePiMessageId?: string): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) throw new Error(`Session has no Pi session file to sync: ${sessionId}`);
    logAgentd("terminal session sync requested", { sessionId, sessionFilePath, baselinePiMessageId });
    const result = await readPiTerminalSessionMessages(sessionFilePath, baselinePiMessageId);
    if (!result.baselineFound) {
      logAgentd("terminal session sync skipped", { sessionId, reason: "baseline pi message not found", baselinePiMessageId, activeLastMessageId: result.activeLastMessageId });
      return this.mustGet(sessionId);
    }

    const existingIds = new Set(this.mustGet(sessionId).messages?.map((message) => message.id) ?? []);
    const messagesToImport = result.messages.filter((message) => !existingIds.has(message.id));
    if (messagesToImport.length === 0) {
      logAgentd("terminal session sync noop", { sessionId, activeLastMessageId: result.activeLastMessageId });
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
    return this.mustGet(sessionId);
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);
    await this.prepareSideSessionForUserInput(sessionId);
    const handle = this.runtimeHandles.get(sessionId) ?? await this.tryResumeRuntimeHandle(session);
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
    await this.cancelPendingExtensionUiForUserInput(sessionId, handle);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    if (isNoTurnStateRestoringSlashCommand(text)) this.rememberNoTurnRanSessionState(sessionId);
    const prompt: BuiltPrompt = { text, imagePaths: [] };
    logAgentd("follow-up requested", { sessionId, textChars: text.length, contextId: context?.id });
    await this.appendLog(sessionId, `${FOLLOWUP_PREFIX}${text}`);
    await this.patch(sessionId, { status: "running", lastSummary: "Follow-up queued", finalAnswer: undefined, thinkingPreview: undefined });
    this.pushPendingQueueDelivery(sessionId, text, "user");
    this.queueFollowUpDelivery(sessionId, handle, prompt);
    return this.mustGet(sessionId);
  }

  private queueFollowUpDelivery(sessionId: string, handle: RuntimeSessionHandle, prompt: BuiltPrompt): void {
    // Pi SDK followUp may resolve only after an idle session finishes its whole next turn.
    // Picky follow-ups are enqueue semantics, so do not hold the caller/main-agent tool open.
    void handle.followUp(prompt)
      .then(async () => {
        logAgentd("follow-up delivery finished", { sessionId });
        // Pi only fires queue_update when the prompt traverses the queue. For idle (non-streaming)
        // sessions Pi runs the prompt inline and never enqueues, so our deferred pending entry would
        // never get drained. Detect that by checking Pi's queue snapshot once the prompt is
        // accepted and drain explicitly when the prompt is not waiting in either queue.
        if (!this.isPromptInRuntimeQueue(handle, prompt.text)) {
          await this.drainPendingTextOnce(sessionId, prompt.text);
        }
      })
      .catch((error) => void this.handleFollowUpDeliveryError(sessionId, error));
  }

  private async handleFollowUpDeliveryError(sessionId: string, error: unknown): Promise<void> {
    const message = error instanceof Error ? error.message : String(error);
    logAgentd("follow-up delivery failed", { sessionId, error: message });
    await this.appendLog(sessionId, `follow-up failed: ${message}`);
    const current = this.sessions.get(sessionId);
    if (!current || ["completed", "cancelled"].includes(current.status)) return;
    await this.patch(sessionId, { status: "failed", lastSummary: `Follow-up failed: ${message}` });
  }

  private async cancelPendingExtensionUiForUserInput(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    const pending = this.mustGet(sessionId).pendingExtensionUiRequest;
    if (!pending) return;
    if (handle.answerExtensionUi) await handle.answerExtensionUi(pending.id, { cancelled: true });
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
    handle.clearQueue();
    await this.applyQueueUpdate(sessionId, [], []);
  }

  private isPromptInRuntimeQueue(handle: RuntimeSessionHandle, text: string): boolean {
    return handle.getFollowUpMessages().includes(text) || handle.getSteeringMessages().includes(text);
  }

  private async drainPendingTextOnce(sessionId: string, text: string): Promise<void> {
    const pending = this.pendingQueueDeliveries.get(sessionId);
    if (!pending || pending.length === 0) return;
    const index = pending.findIndex((entry) => entry.text === text);
    if (index < 0) return;
    const [entry] = pending.splice(index, 1);
    if (!entry) return;
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
    await this.messageBuilder.recordUserText(sessionId, entry.text, entry.originatedBy);
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

  private pushPendingQueueDelivery(sessionId: string, text: string, originatedBy: "user" | "main_agent"): void {
    // Slash commands like /diff, /fix-tests, /name, /compact are not really chat input — they
    // either run an extension overlay, fire a prompt template, or trigger a Picky-intercepted
    // built-in. Recording them as user_text adds a misleading bubble to the conversation card.
    // Skills (/skill:<name>) ARE recorded because they expand into a real prompt and the user
    // expects to see what they invoked. The strict identifier match also exempts path-like
    // inputs (/Users/foo) which contain a second '/' before whitespace.
    if (isNonSkillSlashCommand(text)) return;
    const list = this.pendingQueueDeliveries.get(sessionId) ?? [];
    list.push({ text, originatedBy });
    this.pendingQueueDeliveries.set(sessionId, list);
  }

  private async drainDeliveredQueueItems(sessionId: string, removedTexts: readonly string[]): Promise<void> {
    const pending = this.pendingQueueDeliveries.get(sessionId);
    if (!pending || pending.length === 0) return;
    for (const text of removedTexts) {
      const index = pending.findIndex((entry) => entry.text === text);
      if (index < 0) continue;
      const [entry] = pending.splice(index, 1);
      if (!entry) continue;
      await this.messageBuilder.recordUserText(sessionId, entry.text, entry.originatedBy);
    }
    if (pending.length === 0) this.pendingQueueDeliveries.delete(sessionId);
  }

  async applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle || !this.sessions.has(sessionId)) return;
    const steeringMode = handle.steeringMode;
    const followUpMode = handle.followUpMode;
    const previous = this.queueUpdateChains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(() => this.applyQueueUpdateNow(sessionId, steering, followUp, steeringMode, followUpMode));
    this.queueUpdateChains.set(sessionId, next.catch(() => undefined));
    await next;
  }

  private async applyQueueUpdateNow(sessionId: string, steering: readonly string[], followUp: readonly string[], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode): Promise<void> {
    if (!this.sessions.has(sessionId)) return;
    const enqueuedAt = new Date().toISOString();
    const current = this.mustGet(sessionId);
    const queuedSteers = queueItems(steering, enqueuedAt, current.queuedSteers);
    const queuedFollowUps = queueItems(followUp, enqueuedAt, current.queuedFollowUps);
    const previousSteeringMode = this.lastEmittedSteeringMode.get(sessionId) ?? current.steeringMode ?? "one-at-a-time";
    const previousFollowUpMode = this.lastEmittedFollowUpMode.get(sessionId) ?? current.followUpMode ?? "one-at-a-time";
    const queueChanged = !sameQueueItems(current.queuedSteers ?? [], queuedSteers) || !sameQueueItems(current.queuedFollowUps ?? [], queuedFollowUps);
    const modeChanged = steeringMode !== (current.steeringMode ?? "one-at-a-time") || followUpMode !== (current.followUpMode ?? "one-at-a-time");
    const removedTexts = diffQueueRemovedTexts(current.queuedSteers ?? [], current.queuedFollowUps ?? [], steering, followUp);
    await this.patch(sessionId, { queuedSteers, queuedFollowUps, steeringMode, followUpMode });
    if (removedTexts.length > 0 && !isTerminalStatus(current.status)) {
      await this.drainDeliveredQueueItems(sessionId, removedTexts);
    }

    const emittedSteeringMode = steeringMode === previousSteeringMode ? undefined : steeringMode;
    const emittedFollowUpMode = followUpMode === previousFollowUpMode ? undefined : followUpMode;
    this.lastEmittedSteeringMode.set(sessionId, steeringMode);
    this.lastEmittedFollowUpMode.set(sessionId, followUpMode);
    if (!queueChanged && !modeChanged) return;
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("queueUpdated", sessionId, queuedSteers, queuedFollowUps, emittedSteeringMode, emittedFollowUpMode, seq); });
  }

  private async handleRuntimeInputMessage(sessionId: string, event: Extract<RuntimeEvent, { type: "input_message" }>): Promise<void> {
    if (event.originatedBy !== "pi_extension") return;
    await this.prepareSideSessionForUserInput(sessionId);
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
    const current = session.activitySummary ?? zeroActivitySummary();
    const next = { ...current, [category]: current[category] + 1 };
    const currentTurn = this.turnActivity.get(sessionId) ?? zeroActivitySummary();
    this.turnActivity.set(sessionId, { ...currentTurn, [category]: currentTurn[category] + 1 });
    await this.patch(sessionId, { activitySummary: next });
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("activityUpdated", sessionId, next, seq); });
  }

  private async commitTurnActivity(sessionId: string): Promise<void> {
    const previous = this.activityUpdateChains.get(sessionId) ?? Promise.resolve();
    const next = previous.then(() => this.commitTurnActivityNow(sessionId));
    this.activityUpdateChains.set(sessionId, next.catch(() => undefined));
    await next;
  }

  private async commitTurnActivityNow(sessionId: string): Promise<void> {
    const snapshot = this.turnActivity.get(sessionId);
    if (!snapshot || activityTotal(snapshot) <= 0) return;
    await this.messageBuilder.recordActivitySnapshot(sessionId, snapshot);
    this.turnActivity.delete(sessionId);
  }

  private async tryResumeRuntimeHandle(session: PickyAgentSession): Promise<RuntimeSessionHandle | undefined> {
    if (!this.runtime.resume) return undefined;
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) return undefined;

    try {
      logAgentd("runtime resume requested", { sessionId: session.id, sessionFilePath });
      const handle = await this.runtime.resume(sessionFilePath, { cwd: session.cwd, sessionId: session.id });
      await this.attachRuntimeHandle(session.id, handle);
      await this.appendLog(session.id, `runtime reattached from pi session: ${sessionFilePath}`);
      const current = this.mustGet(session.id);
      const reattachPatch: Partial<PickyAgentSession> = {
        tools: settleActiveTools(current.tools, "Tool was interrupted by a Picky daemon restart."),
        thinkingPreview: undefined,
      };
      if (!isTerminalStatus(current.status)) {
        // The previous extension UI dialog promise lived only inside the old daemon process,
        // so its requestId is no longer answerable. Drop the stale pending request so the HUD
        // does not re-show a form that the new ExtensionUiBridge cannot resolve, and ask the
        // user to continue via follow-up/steer instead.
        reattachPatch.status = "blocked";
        reattachPatch.lastSummary = current.pendingExtensionUiRequest
          ? "Picky daemon restarted; the previous question can no longer be answered. Send a follow-up or steer message to continue."
          : "Previous run was interrupted by daemon restart; send a follow-up or steer message to continue.";
        if (current.pendingExtensionUiRequest) {
          reattachPatch.pendingExtensionUiRequest = undefined;
          await this.messageBuilder.cancelExtensionQuestion(session.id, current.pendingExtensionUiRequest.id);
        }
      }
      await this.patch(session.id, reattachPatch);
      return handle;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("runtime resume failed", { sessionId: session.id, sessionFilePath, error: message });
      await this.appendLog(session.id, `runtime reattach failed: ${message}`);
      return undefined;
    }
  }

  async steer(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    await this.prepareSideSessionForUserInput(sessionId);
    const handle = this.runtimeHandles.get(sessionId) ?? await this.tryResumeRuntimeHandle(session);
    if (!handle) {
      const reason = "Runtime session is not attached";
      await this.appendLog(sessionId, `steer rejected: ${reason}`);
      throw new Error(reason);
    }
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
    this.pushPendingQueueDelivery(sessionId, text, "user");
    const outcome = await handle.steer(prompt);
    await this.appendLog(sessionId, `${STEER_PREFIX}${text}`);
    // Pi accepted the prompt: either it queued the steer (queue_update will eventually drain the
    // pending entry) or it executed inline. For the inline case the prompt is no longer in either
    // Pi queue, so drain immediately so the user_text journal entry surfaces without waiting for a
    // queue_update that will never fire.
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
    const beforeAbort = this.mustGet(sessionId);
    const handle = this.runtimeHandles.get(sessionId);
    const cancellationMessagesBefore = countSystemMessages(beforeAbort, "Cancelled by user");
    logAgentd("abort requested", { sessionId, hasHandle: Boolean(handle) });
    if (handle) {
      await handle.abort();
      await this.waitForRuntimeEvents(sessionId);
    }
    if (beforeAbort.status !== "cancelled" && countSystemMessages(this.mustGet(sessionId), "Cancelled by user") === cancellationMessagesBefore) {
      await this.messageBuilder.recordSystemMessage(sessionId, "Cancelled by user");
    }
    // Pending follow-up/steer prompts that were waiting for Pi to dequeue them will never be
    // processed after an abort, so drop their journal placeholders too.
    this.pendingQueueDeliveries.delete(sessionId);
    const current = this.mustGet(sessionId);
    await this.patch(sessionId, { status: "cancelled", lastSummary: "Cancelled", tools: settleActiveTools(current.tools, "Tool stopped because the session was cancelled."), thinkingPreview: undefined });
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

  private async attachRuntimeHandle(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    this.runtimeHandles.set(sessionId, handle);
    handle.subscribe((event) => void this.applyRuntimeEvent(sessionId, event));
    await this.applyQueueUpdate(sessionId, handle.getSteeringMessages(), handle.getFollowUpMessages());
  }

  private async applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void> {
    if (event.type !== "status") {
      await this.runtimeEventHandler.handle(sessionId, event);
      return;
    }
    const previous = this.runtimeEventChains.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(() => this.runtimeEventHandler.handle(sessionId, event));
    const tracked = next.catch(() => undefined);
    this.runtimeEventChains.set(sessionId, tracked);
    await next;
    if (this.runtimeEventChains.get(sessionId) === tracked) this.runtimeEventChains.delete(sessionId);
  }

  private async waitForRuntimeEvents(sessionId: string): Promise<void> {
    await (this.runtimeEventChains.get(sessionId) ?? Promise.resolve());
  }

  private async chainEmit(sessionId: string, fn: () => Promise<void>): Promise<void> {
    const previous = this.emitChains.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(fn);
    this.emitChains.set(sessionId, next);
    await next;
    if (this.emitChains.get(sessionId) === next) this.emitChains.delete(sessionId);
  }

  private async appendLog(sessionId: string, line: string): Promise<void> {
    const session = this.mustGet(sessionId);
    const changedFiles = mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(line));
    const linkArtifacts = extractSessionLinkArtifacts(line).filter((artifact) => !session.artifacts.some((existing) => existing.url === artifact.url));
    const artifacts = mergeArtifacts(session.artifacts, linkArtifacts);
    const piSessionFilePath = piSessionFilePathFromLogLine(line);
    await this.patch(sessionId, { logs: [...session.logs, line], changedFiles, artifacts, ...(piSessionFilePath ? { piSessionFilePath } : {}) }, { emitSession: false });
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
      void this.refreshSideSessionTitleFromPi(sessionId);
    }
  }

  // Pi names the underlying session asynchronously after the first turn, but session_info_changed
  // events do not fire when Picky resumes an existing pi session file. Read the JSONL directly and
  // patch the side-agent title so the HUD card shows Pi's name instead of "New side agent · cwd".
  private async refreshSideSessionTitleFromPi(sessionId: string): Promise<void> {
    if (!this.isSideSession(sessionId)) return;
    const session = this.sessions.get(sessionId);
    if (!session) return;
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) return;
    try {
      const name = await readPiSessionInfoName(sessionFilePath);
      if (!name) return;
      const current = this.sessions.get(sessionId);
      if (!current || current.title === name) return;
      logAgentd("side session title refreshed from pi", { sessionId, previousTitle: current.title, name });
      await this.patch(sessionId, { title: name });
    } catch (error) {
      logAgentd("side session title refresh failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
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

type ScreenshotContext = PickyContextPacket["screenshots"][number];

function makePointerOverlayRequestForContext(context: PickyContextPacket, request: PickyShowPointerRequest): PickyShowPointerResult["request"] {
  const screenshot = selectScreenshot(context, request);
  if (!screenshot.bounds) throw new Error(`No display bounds are available for ${screenshot.screenId ?? screenshot.id}.`);
  const screenshotSize = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels
    ? { width: screenshot.screenshotWidthInPixels, height: screenshot.screenshotHeightInPixels }
    : readImageSize(screenshot.path);
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

function selectScreenshot(context: PickyContextPacket, request: PickyShowPointerRequest): ScreenshotContext {
  if (context.screenshots.length === 0) throw new Error("No screenshots are available for pointer overlay validation.");
  const requestedScreenId = request.screenId?.trim();
  if (requestedScreenId) {
    const screenshot = context.screenshots.find((candidate) => candidate.screenId === requestedScreenId || candidate.id === requestedScreenId);
    if (!screenshot) throw new Error(`Unknown pointer overlay screenId: ${requestedScreenId}`);
    return screenshot;
  }
  const cursorScreenshot = context.screenshots.find((screenshot) => screenshot.isCursorScreen === true || /cursor|primary|focus/i.test(screenshot.label));
  return cursorScreenshot ?? context.screenshots[0]!;
}

function clampPointerCoordinates(
  request: PickyShowPointerRequest,
  screenshotSize: { width: number; height: number },
): { x: number; y: number; clamped?: boolean } {
  const x = clamp(request.x, 0, screenshotSize.width);
  const y = clamp(request.y, 0, screenshotSize.height);
  return { x, y, clamped: x !== request.x || y !== request.y ? true : undefined };
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function readImageSize(path: string): { width: number; height: number } | undefined {
  try {
    const buffer = readFileSync(path);
    return readPngSize(buffer) ?? readJpegSize(buffer);
  } catch {
    return undefined;
  }
}

function readPngSize(buffer: Buffer): { width: number; height: number } | undefined {
  if (buffer.length < 24) return undefined;
  const isPng = buffer[0] === 0x89
    && buffer[1] === 0x50
    && buffer[2] === 0x4e
    && buffer[3] === 0x47
    && buffer[4] === 0x0d
    && buffer[5] === 0x0a
    && buffer[6] === 0x1a
    && buffer[7] === 0x0a;
  if (!isPng) return undefined;
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  return width > 0 && height > 0 ? { width, height } : undefined;
}

function readJpegSize(buffer: Buffer): { width: number; height: number } | undefined {
  if (buffer.length < 4 || buffer[0] !== 0xff || buffer[1] !== 0xd8) return undefined;
  let offset = 2;
  while (offset + 9 < buffer.length) {
    if (buffer[offset] !== 0xff) {
      offset += 1;
      continue;
    }

    while (buffer[offset] === 0xff) offset += 1;
    const marker = buffer[offset++];
    if (marker === undefined || marker === 0xd9 || marker === 0xda) return undefined;
    if (offset + 2 > buffer.length) return undefined;
    const segmentLength = buffer.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > buffer.length) return undefined;

    if (isJpegStartOfFrameMarker(marker)) {
      const height = buffer.readUInt16BE(offset + 3);
      const width = buffer.readUInt16BE(offset + 5);
      return width > 0 && height > 0 ? { width, height } : undefined;
    }

    offset += segmentLength;
  }
  return undefined;
}

function isJpegStartOfFrameMarker(marker: number): boolean {
  return (marker >= 0xc0 && marker <= 0xcf)
    && marker !== 0xc4
    && marker !== 0xc8
    && marker !== 0xcc;
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function queueItems(items: readonly string[], enqueuedAt: string, previous: readonly PickyQueueItem[] | undefined = []): PickyQueueItem[] {
  return items.map((text, index) => ({ text, enqueuedAt: previous[index]?.text === text ? previous[index]!.enqueuedAt : enqueuedAt }));
}

function sameQueueItems(left: readonly PickyQueueItem[], right: readonly PickyQueueItem[]): boolean {
  return left.length === right.length && left.every((item, index) => item.text === right[index]?.text && item.enqueuedAt === right[index]?.enqueuedAt);
}

/**
 * Compute texts that exist in the previous combined queue (steers + follow-ups) but not in the new
 * one, accounting for duplicates. Used to detect prompts that Pi has just dequeued (= started
 * processing) so the supervisor can record their user_text journal entry now instead of at enqueue
 * time.
 */
function diffQueueRemovedTexts(
  previousSteers: readonly PickyQueueItem[],
  previousFollowUps: readonly PickyQueueItem[],
  nextSteers: readonly string[],
  nextFollowUps: readonly string[],
): string[] {
  const counts = new Map<string, number>();
  for (const text of nextSteers) counts.set(text, (counts.get(text) ?? 0) + 1);
  for (const text of nextFollowUps) counts.set(text, (counts.get(text) ?? 0) + 1);
  const removed: string[] = [];
  const visit = (item: PickyQueueItem): void => {
    const remaining = counts.get(item.text) ?? 0;
    if (remaining > 0) {
      counts.set(item.text, remaining - 1);
    } else {
      removed.push(item.text);
    }
  };
  for (const item of previousSteers) visit(item);
  for (const item of previousFollowUps) visit(item);
  return removed;
}

function zeroActivitySummary(): PickyActivitySummary {
  return { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 };
}

function activityTotal(summary: PickyActivitySummary): number {
  return summary.read + summary.bash + summary.edit + summary.write + summary.thinking + summary.other;
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

function buildPinnedSideSessionLogs(context: PickyContextPacket): string[] {
  const logs = ["pi-extension handoff pin: completed idle Pi session", `source context id: ${context.id}`];
  if (context.cwd) logs.push(`source cwd: ${context.cwd}`);
  const sessionFile = piSessionFilePathFromHandoffTranscript(context.transcript);
  if (sessionFile) logs.push(`pi session: ${sessionFile}`);
  if (context.transcript?.trim()) logs.push(`source transcript:\n${context.transcript.trim()}`);
  return logs;
}

function piSessionFilePathFromHandoffTranscript(transcript: string | undefined): string | undefined {
  if (!transcript) return undefined;
  for (const line of transcript.split(/\r?\n/)) {
    const match = line.match(/^\s*-\s*Session file:\s*(.+)$/);
    const path = match?.[1]?.trim();
    if (path && !path.startsWith("(") && path !== "ephemeral" && path !== "unavailable") return path;
  }
  return undefined;
}

function isNameSlashCommand(text: string): boolean {
  return /^\s*\/name(\s|$)/.test(text);
}

function isCompactSlashCommand(text: string): boolean {
  return /^\s*\/compact(\s|$)/.test(text);
}

function isNoTurnStateRestoringSlashCommand(text: string): boolean {
  return isNameSlashCommand(text) || isCompactSlashCommand(text);
}

// Matches `/name`, `/name args` where name is an identifier-like token without `/` or `:`.
// Intentionally rejects `/skill:context7-cli` (skill commands stay visible as user text) and
// `/Users/foo` (path-like inputs).
function isNonSkillSlashCommand(text: string): boolean {
  return /^\s*\/[a-zA-Z][\w-]*(\s|$)/.test(text);
}

function piSessionFilePathForSession(session: PickyAgentSession): string | undefined {
  return normalizeOptionalString(session.piSessionFilePath) ?? piSessionFilePathFromLogs(session.logs);
}

function shouldReattachBlockedSessionOnStartup(session: PickyAgentSession): boolean {
  return session.status === "blocked" && session.archived !== true && Boolean(piSessionFilePathForSession(session));
}

function withPiSessionFileFromLogs(session: PickyAgentSession): PickyAgentSession {
  if (normalizeOptionalString(session.piSessionFilePath)) return session;
  const piSessionFilePath = piSessionFilePathFromLogs(session.logs);
  return piSessionFilePath ? { ...session, piSessionFilePath } : session;
}

function piSessionFilePathFromLogs(logs: string[]): string | undefined {
  for (const line of [...logs].reverse()) {
    const path = piSessionFilePathFromLogLine(line);
    if (path) return path;
  }
  return undefined;
}

function piSessionFilePathFromLogLine(line: string): string | undefined {
  for (const candidate of line.split(/\r?\n/)) {
    const match = candidate.match(/^pi session:\s*(.+)$/)
      ?? candidate.match(/^runtime reattached from pi session:\s*(.+)$/)
      ?? candidate.match(/^\s*-\s*Session file:\s*(.+)$/);
    const path = normalizeOptionalString(match?.[1]);
    if (path && !path.startsWith("(") && path !== "ephemeral" && path !== "unavailable") return path;
  }
  return undefined;
}

function quickReplyOriginFromContextSource(source: string | undefined): QuickReplyMetadata["originSource"] {
  switch (source) {
    case "voice":
      return "voice";
    case "voice-follow-up":
    case "voiceFollowUp":
    case "voice_follow_up":
      return "voiceFollowUp";
    case "text":
      return "text";
    case "text-follow-up":
    case "textFollowUp":
    case "text_follow_up":
      return "textFollowUp";
    default:
      return "unknown";
  }
}

function normalizeSlashCommands(commands: RuntimeSlashCommand[]): RuntimeSlashCommand[] {
  const normalized: RuntimeSlashCommand[] = [];
  const seen = new Set<string>();
  for (const command of commands) {
    const name = command.name.trim();
    if (!name) continue;
    const source = command.source;
    if (source !== "extension" && source !== "prompt" && source !== "skill" && source !== "builtin") continue;
    const key = `${source}:${name}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const description = command.description?.trim();
    normalized.push({ name, source, ...(description ? { description } : {}) });
  }
  return normalized;
}

const MAIN_AGENT_MESSAGE_LIMIT = 100;

function normalizeMainAgentState(state: PickyMainAgentState): PickyMainAgentState {
  return { ...state, messages: state.messages.slice(-MAIN_AGENT_MESSAGE_LIMIT) };
}

function appendUniqueLog(logs: string[], line: string): string[] {
  return logs.includes(line) ? logs : [...logs, line];
}

function countSystemMessages(session: PickyAgentSession, text: string): number {
  return (session.messages ?? []).filter((message) => message.kind === "system" && message.text === text).length;
}

function hasSideSessionMarkerLog(session: PickyAgentSession): boolean {
  return session.logs.some(
    (line) => line.startsWith(HANDOFF_PREFIX.trimEnd())
      || line.startsWith("main-agent handoff cwd:")
      || line.startsWith("pi-extension handoff pin:")
      || line.startsWith("manual side agent:"),
  );
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

function titleForEmptySideSession(context: PickyContextPacket): string {
  const cwd = normalizeOptionalString(context.cwd);
  if (!cwd) return "New side agent";
  const basename = cwd.split(/[\\/]/).filter(Boolean).at(-1);
  return basename ? `New side agent · ${basename}` : "New side agent";
}
