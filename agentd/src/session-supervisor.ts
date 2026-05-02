import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { ArtifactStore, extractChangedFilesFromExplicitText } from "./artifact-store.js";
import { ArtifactMaterializer } from "./application/artifact-materializer.js";
import { RuntimeEventHandler } from "./application/runtime-event-handler.js";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentPrompt, buildMainAgentSideCompletionPrompt, buildSideAgentPrompt } from "./prompt-builder.js";
import type { PickyAgentSession, PickyContextPacket } from "./protocol.js";
import { SessionStore } from "./session-store.js";
import type { TaskRouter } from "./task-router.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./runtime/types.js";
import { mergeChangedFiles } from "./domain/changed-files.js";
import { isTerminalStatus } from "./domain/session-status.js";
import { cleanFinalAnswer } from "./domain/session-summary.js";
import { titleFromContext } from "./domain/session-title.js";
import { logAgentd } from "./local-log.js";

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
  private mainDraft = "";
  private mainContext?: PickyContextPacket;
  private mainReplyContextId = "main";
  private mainIsProcessing = false;
  private suppressNextMainReply = false;
  private suppressInterruptedMainCompletion = false;
  private sideSessionIds = new Set<string>();
  private sideCompletionNotified = new Set<string>();

  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore, artifactStore?: ArtifactStore, private readonly options: SessionSupervisorOptions = {}) {
    super();
    this.artifactMaterializer = new ArtifactMaterializer(artifactStore);
    this.runtimeEventHandler = new RuntimeEventHandler({
      getSession: (sessionId) => this.mustGet(sessionId),
      patchSession: (sessionId, patch) => this.patch(sessionId, patch),
      appendLog: (sessionId, line) => this.appendLog(sessionId, line),
      materializeTerminalArtifacts: (sessionId) => this.materializeTerminalArtifacts(sessionId),
      notifySideCompletion: (sessionId) => this.notifyMainOfSideCompletion(sessionId),
      isSideSession: (sessionId) => this.sideSessionIds.has(sessionId),
      emitExtensionUiRequest: (request) => this.emit("extensionUiRequest", request),
    });
  }

  async load(): Promise<void> {
    const persisted = await this.store.loadAll();
    logAgentd("sessions loading", { count: persisted.length });
    for (const persistedSession of persisted) {
      const isSideSession = hasSideSessionMarkerLog(persistedSession);
      if (isSideSession) this.sideSessionIds.add(persistedSession.id);
      const session = isSideSession && persistedSession.notifyMainOnCompletion === undefined
        ? { ...persistedSession, notifyMainOnCompletion: true }
        : persistedSession;
      if (!isTerminalStatus(session.status)) {
        const restored = {
          ...session,
          status: "blocked" as const,
          lastSummary: "Runtime not attached after daemon restart; start a new task or resume support is required",
          logs: [...session.logs, "Runtime not attached after daemon restart; start a new task or resume support is required"],
          pendingExtensionUiRequest: undefined,
          updatedAt: new Date().toISOString(),
        };
        this.sessions.set(restored.id, restored);
        await this.store.save(restored);
      } else {
        this.sessions.set(session.id, session);
        if (session !== persistedSession) await this.store.save(session);
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

  async prewarmMainAgent(cwd = process.cwd()): Promise<void> {
    if (!this.options.mainRuntime?.prewarm || this.mainHandle) return;
    logAgentd("main prewarm requested", { cwd });
    await this.ensurePrewarmedMainHandle(cwd);
  }

  announceMainHandoff(contextId: string, text: string): void {
    logAgentd("main handoff announced", { contextId, textChars: text.length });
    this.suppressNextMainReply = true;
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

  async createSideFromHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string }): Promise<PickyAgentSession> {
    logAgentd("side session create requested", { contextId: context.id, titleChars: handoff.title.length, instructionChars: handoff.instructions.length });
    const session = await this.createVisibleSession(context, handoff.title.trim() || titleFromContext(context), buildSideAgentPrompt(context, handoff), { notifyMainOnCompletion: true });
    this.sideSessionIds.add(session.id);
    await this.appendLog(session.id, `main-agent handoff: ${handoff.instructions}`);
    return this.mustGet(session.id);
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
      notifyMainOnCompletion: true,
      tools: [],
      artifacts: [],
      changedFiles: [],
    };
    this.sideSessionIds.add(id);
    logAgentd("side session pinned", { sessionId: id, titleChars: session.title.length, cwd: context.cwd, contextId: context.id });
    await this.upsert(session);
    await this.materializeTerminalArtifacts(id);
    await this.notifyMainOfSideCompletion(id);
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
      artifacts: [],
      changedFiles: [],
    };
    await this.upsert(session);
    logAgentd("session queued", { sessionId: id, titleChars: title.length, cwd: context.cwd });
    try {
      this.runtimeEventHandler.resetAssistantDraft(id);
      const handle = await this.runtime.create(prompt, { cwd: context.cwd, sessionId: id });
      this.runtimeHandles.set(id, handle);
      logAgentd("runtime attached", { sessionId: id });
      handle.subscribe((event) => void this.applyRuntimeEvent(id, event));
      await this.patch(id, { status: "running", lastSummary: "Started" });
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
    this.mainContext = context;
    this.mainReplyContextId = context.id;
    this.mainDraft = "";
    const prompt = buildMainAgentPrompt(context);
    if (this.options.mainRuntime!.prewarm) {
      const handle = await this.ensurePrewarmedMainHandle(context.cwd ?? process.cwd());
      await this.deliverMainPrompt(handle, prompt);
      return;
    }
    if (!this.mainHandle) {
      const handle = await this.options.mainRuntime!.create(prompt, { cwd: context.cwd, sessionId: "picky-main-agent" });
      this.attachMainHandle(handle);
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
      this.mainHandlePromise = this.options.mainRuntime!.prewarm!({ cwd, sessionId: "picky-main-agent" })
        .then((handle) => {
          logAgentd("main prewarmed", { cwd });
          return this.attachMainHandle(handle);
        })
        .finally(() => {
          this.mainHandlePromise = undefined;
        });
    }
    return this.mainHandlePromise;
  }

  private attachMainHandle(handle: RuntimeSessionHandle): RuntimeSessionHandle {
    this.mainHandle = handle;
    handle.subscribe((event) => void this.applyMainRuntimeEvent(event));
    return handle;
  }

  private async applyMainRuntimeEvent(event: RuntimeEvent): Promise<void> {
    if (event.type === "assistant_delta") {
      this.mainDraft += event.delta;
      return;
    }
    if (event.type === "status") {
      if (event.status === "running") {
        this.mainIsProcessing = true;
      }
      if (["completed", "failed", "cancelled"].includes(event.status)) {
        this.mainIsProcessing = false;
        if (this.suppressInterruptedMainCompletion) {
          this.suppressInterruptedMainCompletion = false;
          this.mainDraft = "";
          return;
        }
        logAgentd("main status", { status: event.status, contextId: this.mainReplyContextId, draftChars: this.mainDraft.length });
        const reply = cleanFinalAnswer(this.mainDraft) ?? (event.status === "failed" ? event.summary : undefined);
        if (this.suppressNextMainReply) {
          this.suppressNextMainReply = false;
        } else if (reply) {
          logAgentd("main quick reply", { contextId: this.mainReplyContextId, textChars: reply.length });
          this.emit("quickReply", this.mainReplyContextId, reply);
        }
        this.mainDraft = "";
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

  async followUpSideSession(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    if (!this.isSideSession(sessionId)) throw new Error(`Session is not a Picky side agent: ${sessionId}`);
    this.sideCompletionNotified.delete(sessionId);
    return this.followUp(sessionId, text, context);
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);
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
    if (this.isSideSession(sessionId)) this.sideCompletionNotified.delete(sessionId);
    this.runtimeEventHandler.resetAssistantDraft(sessionId);
    logAgentd("follow-up requested", { sessionId, textChars: text.length, contextId: context?.id });
    await this.appendLog(sessionId, `follow-up: ${text}`);
    await handle.followUp(buildFollowUpPrompt(sessionId, text, context));
    await this.patch(sessionId, { status: "running", lastSummary: "Follow-up queued", finalAnswer: undefined });
    return this.mustGet(sessionId);
  }

  private async tryResumeRuntimeHandle(session: PickyAgentSession): Promise<RuntimeSessionHandle | undefined> {
    if (!this.runtime.resume) return undefined;
    const sessionFilePath = piSessionFilePathFromLogs(session.logs);
    if (!sessionFilePath) return undefined;

    try {
      logAgentd("runtime resume requested", { sessionId: session.id, sessionFilePath });
      const handle = await this.runtime.resume(sessionFilePath, { cwd: session.cwd, sessionId: session.id });
      this.runtimeHandles.set(session.id, handle);
      handle.subscribe((event) => void this.applyRuntimeEvent(session.id, event));
      await this.appendLog(session.id, `runtime reattached from pi session: ${sessionFilePath}`);
      await this.patch(session.id, { status: "running", lastSummary: "Runtime reattached from previous Pi session", pendingExtensionUiRequest: undefined });
      return handle;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("runtime resume failed", { sessionId: session.id, sessionFilePath, error: message });
      await this.appendLog(session.id, `runtime reattach failed: ${message}`);
      return undefined;
    }
  }

  async steer(sessionId: string, text: string): Promise<PickyAgentSession> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle) throw new Error("Runtime session is not attached");
    await handle.steer(text);
    await this.appendLog(sessionId, `steer: ${text}`);
    return this.mustGet(sessionId);
  }

  async abort(sessionId: string): Promise<PickyAgentSession> {
    const handle = this.runtimeHandles.get(sessionId);
    logAgentd("abort requested", { sessionId, hasHandle: Boolean(handle) });
    if (handle) await handle.abort();
    await this.patch(sessionId, { status: "cancelled", lastSummary: "Cancelled" });
    await this.materializeTerminalArtifacts(sessionId);
    return this.mustGet(sessionId);
  }

  async answerExtensionUi(sessionId: string, requestId: string, value: unknown): Promise<PickyAgentSession> {
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle?.answerExtensionUi) throw new Error("Runtime session cannot answer extension UI requests");
    await handle.answerExtensionUi(requestId, value);
    const session = this.mustGet(sessionId);
    if (session.pendingExtensionUiRequest?.id === requestId) {
      await this.patch(sessionId, { pendingExtensionUiRequest: undefined, status: "running", lastSummary: "Extension UI answered" });
    }
    return this.mustGet(sessionId);
  }

  async openArtifact(sessionId: string, artifactId: string): Promise<string> {
    const session = this.mustGet(sessionId);
    const artifact = session.artifacts.find((candidate) => candidate.id === artifactId);
    if (!artifact?.path && !artifact?.url) throw new Error(`Unknown artifact: ${artifactId}`);
    return artifact.path ?? artifact.url!;
  }

  private async applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void> {
    await this.runtimeEventHandler.handle(sessionId, event);
  }

  private async appendLog(sessionId: string, line: string): Promise<void> {
    const session = this.mustGet(sessionId);
    const changedFiles = mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(line));
    await this.patch(sessionId, { logs: [...session.logs, line], changedFiles });
    this.emit("log", sessionId, line);
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
    const match = line.match(/^pi session:\s*(.+)$/);
    if (match?.[1]?.trim()) return match[1].trim();
  }
  return undefined;
}

function hasSideSessionMarkerLog(session: PickyAgentSession): boolean {
  return session.logs.some((line) => line.startsWith("main-agent handoff:") || line.startsWith("pi-extension handoff pin:"));
}
