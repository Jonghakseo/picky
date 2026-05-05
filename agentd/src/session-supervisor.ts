import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { ArtifactStore, extractChangedFilesFromExplicitText, extractSessionLinkArtifacts } from "./artifact-store.js";
import { ArtifactMaterializer } from "./application/artifact-materializer.js";
import { RuntimeEventHandler } from "./application/runtime-event-handler.js";
import { summarizeExtensionUiAnswer } from "./application/extension-ui-request-mapper.js";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentBootstrapPair, buildMainAgentPrompt, buildMainAgentSideCompletionPrompt, buildSideAgentPrompt } from "./prompt-builder.js";
import type { PickyActivitySummary, PickyAgentSession, PickyContextPacket, PickyFinalReport, PickyMainAgentMessage, PickyMainAgentState, PickyQueueItem, PickyQueueMode, PickySessionMessage } from "./protocol.js";
import { makePointerOverlayRequest, type PickyShowPointerRequest, type PickyShowPointerResult } from "./application/pointer-tool.js";
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
  private pendingSideCompletions: string[] = [];
  private sessionContexts = new Map<string, PickyContextPacket>();
  private sessionSeq = new Map<string, number>();
  private queueUpdateChains = new Map<string, Promise<void>>();
  private activityUpdateChains = new Map<string, Promise<void>>();
  private emitChains = new Map<string, Promise<void>>();
  private readonly messageBuilder: SessionMessageBuilder;
  private lastEmittedSteeringMode = new Map<string, PickyQueueMode>();
  private lastEmittedFollowUpMode = new Map<string, PickyQueueMode>();
  private pendingFinalReports = new Map<string, PickyFinalReport>();

  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore, artifactStore?: ArtifactStore, private readonly options: SessionSupervisorOptions = {}) {
    super();
    this.artifactMaterializer = new ArtifactMaterializer(artifactStore);
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
      appendLog: (sessionId, line) => this.appendLog(sessionId, line),
      materializeTerminalArtifacts: (sessionId) => this.materializeTerminalArtifacts(sessionId),
      applyQueueUpdate: (sessionId, steering, followUp) => this.applyQueueUpdate(sessionId, steering, followUp),
      incrementActivity: (sessionId, category) => this.incrementActivity(sessionId, category),
      notifySideCompletion: (sessionId) => this.notifyMainOfSideCompletion(sessionId),
      isSideSession: (sessionId) => this.sideSessionIds.has(sessionId),
      consumePendingFinalReport: (sessionId) => this.consumePendingFinalReport(sessionId),
      emitExtensionUiRequest: (request) => this.emit("extensionUiRequest", request),
      messageBuilder: this.messageBuilder,
    });
  }

  async load(): Promise<void> {
    this.mainState = normalizeMainAgentState(await this.store.loadMainAgentState());
    const persisted = await this.store.loadAll();
    logAgentd("sessions loading", { count: persisted.length });
    for (const persistedSession of persisted) {
      const isSideSession = hasSideSessionMarkerLog(persistedSession);
      if (isSideSession) this.sideSessionIds.add(persistedSession.id);
      const session = isSideSession && persistedSession.notifyMainOnCompletion === undefined
        ? { ...persistedSession, notifyMainOnCompletion: true }
        : persistedSession;
      this.sessions.set(session.id, session);
      this.messageBuilder.hydrateSession(session.id, session.messages);
      if (session !== persistedSession) await this.store.save(session);

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

    const fallbackHandle = await this.slashCommandFallbackHandle(session);
    const fallbackCommands = await this.listSlashCommandsFromHandle(sessionId, fallbackHandle, "main");
    return fallbackCommands ?? [];
  }

  private async listSlashCommandsFromHandle(sessionId: string, handle: RuntimeSessionHandle | undefined, source: "attached" | "main"): Promise<RuntimeSlashCommand[] | undefined> {
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
    const context = this.contextForPointerRequest(request);
    if (!context) throw new Error("No captured Picky context is available for pointer overlay validation.");
    const { screenshot, index } = selectScreenshot(context, request);
    if (!screenshot.bounds) throw new Error(`No display bounds are available for ${screenshot.screenId ?? screenshot.id}.`);
    const coordinateSpace = request.coordinateSpace ?? "screenshotPixel";
    const screenshotSize = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels
      ? { width: screenshot.screenshotWidthInPixels, height: screenshot.screenshotHeightInPixels }
      : readImageSize(screenshot.path);
    if (coordinateSpace === "screenshotPixel" && !screenshotSize) {
      throw new Error(`Screenshot pixel coordinates require screenshot dimensions for ${screenshot.screenId ?? screenshot.id}.`);
    }

    const bounded = clampPointerCoordinates(request, coordinateSpace, screenshot.bounds, screenshotSize);
    const overlayRequest = {
      ...makePointerOverlayRequest({ ...request, ...bounded, coordinateSpace }, {
        contextId: context.id,
        screenId: screenshot.screenId,
        screenIndex: index + 1,
        screenBounds: screenshot.bounds,
        screenshotSize,
      }),
      ...(bounded.clamped ? { clamped: true } : {}),
    };
    const emitted = overlayRequest.dryRun !== true;
    if (emitted) this.emit("pointerOverlayRequested", overlayRequest);
    return { request: overlayRequest, emitted };
  }

  private contextForPointerRequest(request: PickyShowPointerRequest): PickyContextPacket | undefined {
    const sourceSessionId = request.sourceSessionId?.trim();
    if (sourceSessionId) return this.sessionContexts.get(sourceSessionId) ?? this.mainContext;
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
    this.emit("quickReply", contextId, text);
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
      this.emit("quickReply", context.id, decision.reply);
      return undefined;
    }
    return this.create(context);
  }

  async create(context: PickyContextPacket): Promise<PickyAgentSession> {
    return this.createVisibleSession(context, titleFromContext(context), buildInitialTaskPrompt(context));
  }

  async createSideFromHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string; cwd?: string }): Promise<PickyAgentSession> {
    const cwd = normalizeOptionalString(handoff.cwd) ?? context.cwd;
    const handoffContext = cwd ? { ...context, cwd } : context;
    logAgentd("side session create requested", { contextId: context.id, titleChars: handoff.title.length, instructionChars: handoff.instructions.length, cwd: handoffContext.cwd });
    const session = await this.createVisibleSession(handoffContext, handoff.title.trim() || titleFromContext(context), buildSideAgentPrompt(handoffContext, handoff), { notifyMainOnCompletion: true, includePointerToolSessionHint: false });
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
    await this.upsert(session);
    logAgentd("empty side session queued", { sessionId: id, cwd: sideContext.cwd, contextId: context.id });
    try {
      const handle = await this.runtime.prewarm({ cwd: sideContext.cwd, sessionId: id });
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
      throw error;
    }
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

  private async createVisibleSession(context: PickyContextPacket, title: string, prompt = buildInitialTaskPrompt(context), options: { notifyMainOnCompletion?: boolean; includePointerToolSessionHint?: boolean } = {}): Promise<PickyAgentSession> {
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
    await this.upsert(session);
    logAgentd("session queued", { sessionId: id, titleChars: title.length, cwd: context.cwd });
    try {
      this.runtimeEventHandler.resetAssistantDraft(id);
      const runtimePrompt = options.includePointerToolSessionHint === false ? prompt : withPointerToolSessionHint(prompt, id);
      const handle = await this.runtime.create(runtimePrompt, { cwd: context.cwd, sessionId: id });
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
      throw error;
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
      await handle.injectInitialBootstrap(buildMainAgentBootstrapPair());
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
        const reply = cleanFinalAnswer(draftSnapshot) ?? (event.status === "failed" ? event.summary : undefined);
        if (this.suppressNextMainReply) {
          this.suppressNextMainReply = false;
        } else if (reply) {
          logAgentd("main quick reply", { contextId: this.mainReplyContextId, textChars: reply.length });
          await this.appendMainMessage("assistant", reply);
          this.emit("quickReply", this.mainReplyContextId, reply);
        }
        this.scheduleSideCompletionDrain();
      }
    }
  }

  private async notifyMainOfSideCompletion(sessionId: string): Promise<void> {
    const session = this.mustGet(sessionId);
    if (this.sideCompletionNotified.has(sessionId)) return;
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
      if (!this.pendingSideCompletions.includes(sessionId) && !this.sideCompletionNotified.has(sessionId)) {
        this.pendingSideCompletions.push(sessionId);
        logAgentd("side completion deferred", { sessionId, status: session.status, queueLength: this.pendingSideCompletions.length });
      }
      return;
    }
    await this.deliverSideCompletionToMain(sessionId);
  }

  private async deliverSideCompletionToMain(sessionId: string): Promise<void> {
    if (this.sideCompletionNotified.has(sessionId)) return;
    const session = this.sessions.get(sessionId);
    if (!session) return;
    if (session.notifyMainOnCompletion === false) {
      this.sideCompletionNotified.add(sessionId);
      logAgentd("side completion notify skipped", { sessionId, status: session.status });
      return;
    }
    const prompt = buildMainAgentSideCompletionPrompt(session);
    this.mainReplyContextId = sessionId;
    this.mainDraft = "";
    const delivery = await this.prepareMainCompletionDelivery(prompt, session.cwd);
    if (!delivery) return;

    this.sideCompletionNotified.add(sessionId);
    this.mainIsProcessing = true;
    logAgentd("side completion notifying main", { sessionId, status: session.status });
    if (delivery.sendAsFollowUp) await delivery.handle.followUp(prompt);
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

  async steerSideSession(sessionId: string, text: string): Promise<PickyAgentSession> {
    if (!this.isSideSession(sessionId)) throw new Error(`Session is not a Picky side agent: ${sessionId}`);
    return this.steer(sessionId, text);
  }

  private async prepareSideSessionForUserInput(sessionId: string): Promise<void> {
    if (!this.isSideSession(sessionId)) return;
    this.clearSideCompletionTracking(sessionId);
    this.pendingFinalReports.delete(sessionId);
    if (this.mustGet(sessionId).pinned) await this.patch(sessionId, { pinned: false });
  }

  private clearSideCompletionTracking(sessionId: string): void {
    this.sideCompletionNotified.delete(sessionId);
    const queueIndex = this.pendingSideCompletions.indexOf(sessionId);
    if (queueIndex >= 0) {
      this.pendingSideCompletions.splice(queueIndex, 1);
      logAgentd("side completion dequeued", { sessionId, queueLength: this.pendingSideCompletions.length });
    }
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);
    // TODO(PR6): replace this temporary guard with pinned side-session reattach.
    if (session.pinned) throw new Error("Pinned sessions cannot accept follow-ups yet (PR6 reattach)");
    // TODO(Step 2): §7.14 waiting_for_input auto-cancel is deferred; when
    // pendingExtensionUiRequest is active, steer/follow-up should cancel the question via
    // SessionMessageBuilder.cancelExtensionQuestion before continuing this flow.
    await this.prepareSideSessionForUserInput(sessionId);
    const handle = this.runtimeHandles.get(sessionId) ?? await this.tryResumeRuntimeHandle(session);
    if (!handle) {
      const hasPiSessionFile = Boolean(piSessionFilePathFromLogs(session.logs));
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
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    const prompt = buildFollowUpPrompt(sessionId, text, context);
    logAgentd("follow-up requested", { sessionId, textChars: text.length, contextId: context?.id });
    await this.appendLog(sessionId, `${FOLLOWUP_PREFIX}${text}`);
    await this.patch(sessionId, { status: "running", lastSummary: "Follow-up queued", finalAnswer: undefined, thinkingPreview: undefined });
    this.queueFollowUpDelivery(sessionId, handle, prompt);
    return this.mustGet(sessionId);
  }

  private queueFollowUpDelivery(sessionId: string, handle: RuntimeSessionHandle, prompt: ReturnType<typeof buildFollowUpPrompt>): void {
    // Pi SDK followUp may resolve only after an idle session finishes its whole next turn.
    // Picky follow-ups are enqueue semantics, so do not hold the caller/main-agent tool open.
    void handle.followUp(prompt)
      .then(() => logAgentd("follow-up delivery finished", { sessionId }))
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

  async submitFinalReport(sessionId: string, report: PickyFinalReport): Promise<void> {
    if (!this.sessions.has(sessionId)) {
      logAgentd("submit final report dropped (unknown session)", { sessionId });
      return;
    }
    logAgentd("submit final report received", { sessionId, status: report.status, summaryChars: report.summary.length });
    this.pendingFinalReports.set(sessionId, report);
    await this.patch(sessionId, { finalReport: report, finalAnswer: report.summary });
    await this.messageBuilder.recordFinalReport(sessionId, report);
  }

  private consumePendingFinalReport(sessionId: string): PickyFinalReport | undefined {
    const report = this.pendingFinalReports.get(sessionId);
    if (report) this.pendingFinalReports.delete(sessionId);
    return report;
  }

  async clearQueue(sessionId: string, kind: "steering" | "followUp" | "all"): Promise<void> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle) throw new Error(`Session has no attached runtime: ${sessionId}`);
    const drained = handle.clearQueue();
    if (kind === "steering") {
      for (const text of drained.followUp) {
        try {
          await handle.followUp({ text, imagePaths: [] });
        } catch (error) {
          logAgentd("clearQueue re-enqueue failed", { sessionId, text, error: error instanceof Error ? error.message : String(error) });
        }
      }
    } else if (kind === "followUp") {
      for (const text of drained.steering) {
        try {
          await handle.steer(text);
        } catch (error) {
          logAgentd("clearQueue re-enqueue failed", { sessionId, text, error: error instanceof Error ? error.message : String(error) });
        }
      }
    }
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
    await this.patch(sessionId, { queuedSteers, queuedFollowUps, steeringMode, followUpMode });

    const emittedSteeringMode = steeringMode === previousSteeringMode ? undefined : steeringMode;
    const emittedFollowUpMode = followUpMode === previousFollowUpMode ? undefined : followUpMode;
    this.lastEmittedSteeringMode.set(sessionId, steeringMode);
    this.lastEmittedFollowUpMode.set(sessionId, followUpMode);
    if (!queueChanged && !modeChanged) return;
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("queueUpdated", sessionId, queuedSteers, queuedFollowUps, emittedSteeringMode, emittedFollowUpMode, seq); });
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
    await this.patch(sessionId, { activitySummary: next });
    const seq = this.nextSeq(sessionId);
    await this.chainEmit(sessionId, async () => { this.emit("activityUpdated", sessionId, next, seq); });
  }

  private async tryResumeRuntimeHandle(session: PickyAgentSession): Promise<RuntimeSessionHandle | undefined> {
    if (!this.runtime.resume) return undefined;
    const sessionFilePath = piSessionFilePathFromLogs(session.logs);
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

  async steer(sessionId: string, text: string): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (session.status === "failed") throw new Error(`Cannot steer ${session.status} session`);
    // TODO(PR6): replace this temporary guard with pinned side-session reattach.
    if (session.pinned) throw new Error("Pinned sessions cannot accept steers yet (PR6 reattach)");
    // TODO(Step 2): §7.14 waiting_for_input auto-cancel is deferred; when
    // pendingExtensionUiRequest is active, steer/follow-up should cancel the question via
    // SessionMessageBuilder.cancelExtensionQuestion before continuing this flow.
    await this.prepareSideSessionForUserInput(sessionId);
    const handle = this.runtimeHandles.get(sessionId) ?? await this.tryResumeRuntimeHandle(session);
    if (!handle) {
      const reason = "Runtime session is not attached";
      await this.appendLog(sessionId, `steer rejected: ${reason}`);
      throw new Error(reason);
    }
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    logAgentd("steer requested", { sessionId, textChars: text.length });
    const outcome = await handle.steer(text);
    await this.appendLog(sessionId, `${STEER_PREFIX}${text}`);
    // Pi handles `/slash` extension commands and `input` handlers that return `handled` synchronously
    // inside `session.prompt()` without starting an agent turn. PiSdkRuntimeSession synthesizes a
    // `completed` runtime status for those and surfaces `handledSynchronously: true` here. Skipping
    // the `running` patch in that case keeps the HUD card from getting stuck on a loading spinner
    // (e.g. `/diff-review` reported by the user). Normal text steers still flip to `running`
    // immediately so the existing UX contract is preserved.
    if (!outcome?.handledSynchronously) {
      await this.patch(sessionId, { status: "running", lastSummary: "Steering message sent", finalAnswer: undefined, thinkingPreview: undefined });
    }
    return this.mustGet(sessionId);
  }

  async abort(sessionId: string): Promise<PickyAgentSession> {
    const handle = this.runtimeHandles.get(sessionId);
    logAgentd("abort requested", { sessionId, hasHandle: Boolean(handle) });
    if (handle) await handle.abort();
    this.pendingFinalReports.delete(sessionId);
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

  async openArtifact(sessionId: string, artifactId: string): Promise<string> {
    const session = this.mustGet(sessionId);
    const artifact = session.artifacts.find((candidate) => candidate.id === artifactId);
    if (!artifact?.path && !artifact?.url) throw new Error(`Unknown artifact: ${artifactId}`);
    return artifact.path ?? artifact.url!;
  }

  private async attachRuntimeHandle(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    this.runtimeHandles.set(sessionId, handle);
    handle.subscribe((event) => void this.applyRuntimeEvent(sessionId, event));
    await this.applyQueueUpdate(sessionId, handle.getSteeringMessages(), handle.getFollowUpMessages());
  }

  private async applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void> {
    await this.runtimeEventHandler.handle(sessionId, event);
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
    await this.patch(sessionId, { logs: [...session.logs, line], changedFiles, artifacts });
    this.emit("log", sessionId, line);
    if (line.startsWith(STEER_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(STEER_PREFIX.length), "user");
    } else if (line.startsWith(FOLLOWUP_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(FOLLOWUP_PREFIX.length), "user");
    } else if (line.startsWith(EXTENSION_ANSWER_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(EXTENSION_ANSWER_PREFIX.length), "user");
    } else if (line.startsWith(HANDOFF_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(HANDOFF_PREFIX.length), "main_agent");
    }
  }

  private async materializeTerminalArtifacts(sessionId: string): Promise<void> {
    const materialized = await this.artifactMaterializer.materializeTerminalArtifacts(this.mustGet(sessionId));
    if (!materialized) return;
    await this.patch(sessionId, { artifacts: materialized.artifacts });
    for (const artifact of materialized.emittedArtifacts) this.emit("artifact", sessionId, artifact);
  }

  private async patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void> {
    const session = { ...this.mustGet(sessionId), ...patch, updatedAt: new Date().toISOString() };
    await this.upsert(session);
  }

  private async syncSessionMessages(sessionId: string, messages: readonly PickySessionMessage[]): Promise<void> {
    const session = { ...this.mustGet(sessionId), messages: [...messages], updatedAt: new Date().toISOString() };
    this.sessions.set(session.id, session);
    await this.store.save(session);
  }

  private nextSeq(sessionId: string): number {
    const next = (this.sessionSeq.get(sessionId) ?? 0) + 1;
    this.sessionSeq.set(sessionId, next);
    return next;
  }

  private async upsert(session: PickyAgentSession): Promise<void> {
    this.sessions.set(session.id, session);
    await this.store.save(session);
    this.emit("session", session);
  }

  private mustGet(sessionId: string): PickyAgentSession {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error(`Unknown session: ${sessionId}`);
    return session;
  }
}

type ScreenshotContext = PickyContextPacket["screenshots"][number];

function selectScreenshot(context: PickyContextPacket, request: PickyShowPointerRequest): { screenshot: ScreenshotContext; index: number } {
  if (context.screenshots.length === 0) throw new Error("No screenshots are available for pointer overlay validation.");
  const requestedScreenId = request.screenId?.trim();
  if (requestedScreenId) {
    const index = context.screenshots.findIndex((screenshot) => screenshot.screenId === requestedScreenId || screenshot.id === requestedScreenId);
    if (index < 0) throw new Error(`Unknown pointer overlay screenId: ${requestedScreenId}`);
    return { screenshot: context.screenshots[index]!, index };
  }
  if (Number.isFinite(request.screenIndex)) {
    const index = Math.max(1, Math.floor(request.screenIndex!)) - 1;
    const screenshot = context.screenshots[index];
    if (!screenshot) throw new Error(`Unknown pointer overlay screenIndex: ${request.screenIndex}`);
    return { screenshot, index };
  }
  const cursorIndex = context.screenshots.findIndex((screenshot) => screenshot.isCursorScreen === true || /cursor|primary|focus/i.test(screenshot.label));
  const index = cursorIndex >= 0 ? cursorIndex : 0;
  return { screenshot: context.screenshots[index]!, index };
}

function clampPointerCoordinates(
  request: PickyShowPointerRequest,
  coordinateSpace: "screenshotPixel" | "displayPoint",
  bounds: { width: number; height: number },
  screenshotSize: { width: number; height: number } | undefined,
): { x: number; y: number; clamped?: boolean } {
  const width = coordinateSpace === "screenshotPixel" ? screenshotSize!.width : bounds.width;
  const height = coordinateSpace === "screenshotPixel" ? screenshotSize!.height : bounds.height;
  const x = clamp(request.x, 0, width);
  const y = clamp(request.y, 0, height);
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

function withPointerToolSessionHint(prompt: ReturnType<typeof buildInitialTaskPrompt>, sessionId: string): ReturnType<typeof buildInitialTaskPrompt> {
  return {
    ...prompt,
    text: [
      prompt.text,
      "",
      "## Picky visual pointer overlay",
      "- Tool available: `picky_show_pointer` shows a click-through visual overlay only; it never moves/clicks/drags/types with the real OS cursor.",
      `- If you call it from this visible session, pass sourceSessionId: ${sessionId} so Picky validates coordinates against this session's captured screenshots.`,
    ].join("\n"),
  };
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

function zeroActivitySummary(): PickyActivitySummary {
  return { edit: 0, bash: 0, thinking: 0, other: 0 };
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

function piSessionFilePathFromLogs(logs: string[]): string | undefined {
  for (const line of [...logs].reverse()) {
    const path = piSessionFilePathFromLogLine(line);
    if (path) return path;
  }
  return undefined;
}

function piSessionFilePathFromLogLine(line: string): string | undefined {
  const match = line.match(/^pi session:\s*(.+)$/);
  return match?.[1]?.trim() || undefined;
}

function normalizeSlashCommands(commands: RuntimeSlashCommand[]): RuntimeSlashCommand[] {
  const normalized: RuntimeSlashCommand[] = [];
  const seen = new Set<string>();
  for (const command of commands) {
    const name = command.name.trim();
    if (!name) continue;
    const source = command.source;
    if (source !== "extension" && source !== "prompt" && source !== "skill") continue;
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

function hasSideSessionMarkerLog(session: PickyAgentSession): boolean {
  return session.logs.some((line) => line.startsWith(HANDOFF_PREFIX.trimEnd()) || line.startsWith("pi-extension handoff pin:") || line.startsWith("manual side agent:"));
}

function titleForEmptySideSession(context: PickyContextPacket): string {
  const cwd = normalizeOptionalString(context.cwd);
  if (!cwd) return "New side agent";
  const basename = cwd.split(/[\\/]/).filter(Boolean).at(-1);
  return basename ? `New side agent · ${basename}` : "New side agent";
}
