import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { ArtifactStore, extractChangedFilesFromExplicitText, extractGithubPullRequestUrls } from "./artifact-store.js";
import { buildFollowUpPrompt, buildInitialTaskPrompt, buildMainAgentPrompt, buildMainAgentSideCompletionPrompt, buildSideAgentPrompt } from "./prompt-builder.js";
import type { PickyAgentSession, PickyContextPacket, PickyExtensionUiRequest } from "./protocol.js";
import { SessionStore } from "./session-store.js";
import type { TaskRouter } from "./task-router.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./runtime/types.js";

export interface SessionSupervisorOptions {
  taskRouter?: TaskRouter;
  mainRuntime?: AgentRuntime;
}

export class SessionSupervisor extends EventEmitter {
  private sessions = new Map<string, PickyAgentSession>();
  private runtimeHandles = new Map<string, RuntimeSessionHandle>();
  private assistantDrafts = new Map<string, string>();
  private mainHandle?: RuntimeSessionHandle;
  private mainHandlePromise?: Promise<RuntimeSessionHandle>;
  private mainDraft = "";
  private mainContext?: PickyContextPacket;
  private mainReplyContextId = "main";
  private suppressNextMainReply = false;
  private sideSessionIds = new Set<string>();
  private sideCompletionNotified = new Set<string>();

  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore, private readonly artifactStore?: ArtifactStore, private readonly options: SessionSupervisorOptions = {}) {
    super();
  }

  async load(): Promise<void> {
    for (const session of await this.store.loadAll()) {
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
      }
    }
  }

  list(): PickyAgentSession[] {
    return [...this.sessions.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  get(id: string): PickyAgentSession | undefined {
    return this.sessions.get(id);
  }

  currentMainContext(): PickyContextPacket | undefined {
    return this.mainContext;
  }

  async prewarmMainAgent(cwd = process.cwd()): Promise<void> {
    if (!this.options.mainRuntime?.prewarm || this.mainHandle) return;
    await this.ensurePrewarmedMainHandle(cwd);
  }

  announceMainHandoff(contextId: string, text: string): void {
    this.suppressNextMainReply = true;
    this.emit("quickReply", contextId, text);
  }

  async route(context: PickyContextPacket): Promise<PickyAgentSession | undefined> {
    if (this.options.mainRuntime) {
      await this.routeThroughMainAgent(context);
      return undefined;
    }
    if (!this.options.taskRouter) return this.create(context);
    const decision = await this.options.taskRouter.route(context);
    if (decision.route === "quick_reply") {
      this.emit("quickReply", context.id, decision.reply);
      return undefined;
    }
    return this.create(context);
  }

  async create(context: PickyContextPacket): Promise<PickyAgentSession> {
    return this.createVisibleSession(context, titleFromContext(context), buildInitialTaskPrompt(context));
  }

  async createSideFromHandoff(context: PickyContextPacket, handoff: { title: string; instructions: string }): Promise<PickyAgentSession> {
    const session = await this.createVisibleSession(context, handoff.title.trim() || titleFromContext(context), buildSideAgentPrompt(context, handoff));
    this.sideSessionIds.add(session.id);
    await this.appendLog(session.id, `main-agent handoff: ${handoff.instructions}`);
    return this.mustGet(session.id);
  }

  private async createVisibleSession(context: PickyContextPacket, title: string, prompt = buildInitialTaskPrompt(context)): Promise<PickyAgentSession> {
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
      tools: [],
      artifacts: [],
      changedFiles: [],
    };
    await this.upsert(session);
    try {
      this.assistantDrafts.set(id, "");
      const handle = await this.runtime.create(prompt, { cwd: context.cwd, sessionId: id });
      this.runtimeHandles.set(id, handle);
      handle.subscribe((event) => void this.applyRuntimeEvent(id, event));
      await this.patch(id, { status: "running", lastSummary: "Started" });
      return this.mustGet(id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.patch(id, {
        status: "failed",
        lastSummary: `Failed to start runtime: ${message}`,
        logs: [...this.mustGet(id).logs, `Failed to start runtime: ${message}`],
      });
      throw error;
    }
  }

  private async routeThroughMainAgent(context: PickyContextPacket): Promise<void> {
    this.mainContext = context;
    this.mainReplyContextId = context.id;
    this.mainDraft = "";
    const prompt = buildMainAgentPrompt(context);
    if (this.options.mainRuntime!.prewarm) {
      const handle = await this.ensurePrewarmedMainHandle(context.cwd ?? process.cwd());
      await handle.followUp(prompt);
      return;
    }
    if (!this.mainHandle) {
      const handle = await this.options.mainRuntime!.create(prompt, { cwd: context.cwd, sessionId: "picky-main-agent" });
      this.attachMainHandle(handle);
      return;
    }
    await this.mainHandle.followUp(prompt);
  }

  private async ensurePrewarmedMainHandle(cwd: string): Promise<RuntimeSessionHandle> {
    if (this.mainHandle) return this.mainHandle;
    if (!this.mainHandlePromise) {
      this.mainHandlePromise = this.options.mainRuntime!.prewarm!({ cwd, sessionId: "picky-main-agent" })
        .then((handle) => this.attachMainHandle(handle))
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
      if (["completed", "failed", "cancelled"].includes(event.status)) {
        const reply = cleanFinalAnswer(this.mainDraft) ?? (event.status === "failed" ? event.summary : undefined);
        if (this.suppressNextMainReply) {
          this.suppressNextMainReply = false;
        } else if (reply) {
          this.emit("quickReply", this.mainReplyContextId, reply);
        }
        this.mainDraft = "";
      }
    }
  }

  private async notifyMainOfSideCompletion(sessionId: string): Promise<void> {
    if (!this.mainHandle || this.sideCompletionNotified.has(sessionId)) return;
    const session = this.mustGet(sessionId);
    this.sideCompletionNotified.add(sessionId);
    this.mainReplyContextId = sessionId;
    this.mainDraft = "";
    await this.mainHandle.followUp(buildMainAgentSideCompletionPrompt(session));
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);
    const handle = this.runtimeHandles.get(sessionId);
    if (!handle) {
      await this.patch(sessionId, {
        status: "blocked",
        lastSummary: "Runtime not attached after daemon restart; start a new task or resume support is required",
      });
      await this.appendLog(sessionId, "follow-up rejected: runtime session is not attached after daemon restart");
      throw new Error("Runtime session is not attached after daemon restart; start a new task or resume support is required");
    }
    this.assistantDrafts.set(sessionId, "");
    await this.appendLog(sessionId, `follow-up: ${text}`);
    await handle.followUp(buildFollowUpPrompt(sessionId, text, context));
    await this.patch(sessionId, { status: "running", lastSummary: "Follow-up queued", finalAnswer: undefined });
    return this.mustGet(sessionId);
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
    if (event.type === "log") return this.appendLog(sessionId, event.line);
    if (event.type === "assistant_delta") {
      this.assistantDrafts.set(sessionId, `${this.assistantDrafts.get(sessionId) ?? ""}${event.delta}`);
      return;
    }
    if (event.type === "status") {
      const terminal = ["completed", "failed", "cancelled"].includes(event.status);
      const finalAnswer = terminal ? cleanFinalAnswer(this.assistantDrafts.get(sessionId)) : undefined;
      const patch: Partial<PickyAgentSession> = { status: event.status, lastSummary: finalAnswer ? summaryFromFinalAnswer(finalAnswer) : event.summary };
      if (finalAnswer) {
        const session = this.mustGet(sessionId);
        patch.finalAnswer = finalAnswer;
        patch.changedFiles = mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(finalAnswer));
      }
      await this.patch(sessionId, patch);
      if (terminal) {
        await this.materializeTerminalArtifacts(sessionId);
        if (this.sideSessionIds.has(sessionId)) await this.notifyMainOfSideCompletion(sessionId);
      }
      return;
    }
    if (event.type === "extension_ui") return this.applyExtensionUiEvent(sessionId, event.request, event.waitsForInput);
    const session = this.mustGet(sessionId);
    const previous = session.tools.find((tool) => tool.toolCallId === event.toolCallId);
    const tools = session.tools.filter((tool) => tool.toolCallId !== event.toolCallId);
    tools.push({ ...previous, toolCallId: event.toolCallId, name: event.name, status: event.status, preview: event.preview, startedAt: previous?.startedAt ?? new Date().toISOString(), endedAt: event.status === "running" ? previous?.endedAt : new Date().toISOString() });
    await this.patch(sessionId, { tools });
  }

  private async applyExtensionUiEvent(sessionId: string, rawRequest: Record<string, unknown>, waitsForInput: boolean): Promise<void> {
    const request = rawRequest as PickyExtensionUiRequest;
    if (!waitsForInput) {
      await this.appendLog(sessionId, `extension ui: ${request.method}${request.title ? ` ${request.title}` : ""}`);
      return;
    }
    await this.patch(sessionId, { status: "waiting_for_input", pendingExtensionUiRequest: request, lastSummary: request.prompt ?? request.title ?? "Waiting for input" });
    this.emit("extensionUiRequest", request);
  }

  private async appendLog(sessionId: string, line: string): Promise<void> {
    const session = this.mustGet(sessionId);
    const changedFiles = mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(line));
    await this.patch(sessionId, { logs: [...session.logs, line], changedFiles });
    this.emit("log", sessionId, line);
  }

  private async materializeTerminalArtifacts(sessionId: string): Promise<void> {
    if (!this.artifactStore) return;
    const session = this.mustGet(sessionId);
    const now = new Date().toISOString();
    const prArtifacts = extractGithubPullRequestUrls([session.finalAnswer, session.lastSummary, ...session.logs, ...session.tools.map((tool) => tool.preview)].filter(Boolean).join("\n"))
      .filter((url) => !session.artifacts.some((artifact) => artifact.url === url))
      .map((url, index) => ({ id: `pr-${index + 1}`, kind: "pr", title: "GitHub PR", url, updatedAt: now }));
    const report = await this.artifactStore.writeSessionReport({ ...session, artifacts: [...session.artifacts, ...prArtifacts] });
    await this.patch(sessionId, { artifacts: mergeArtifacts([...session.artifacts, ...prArtifacts], [report]) });
    this.emit("artifact", sessionId, report);
    for (const artifact of prArtifacts) this.emit("artifact", sessionId, artifact);
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

function isTerminalStatus(status: PickyAgentSession["status"]): boolean {
  return ["completed", "failed", "cancelled"].includes(status);
}

function cleanFinalAnswer(text: string | undefined): string | undefined {
  const normalized = text?.replace(/\r\n/g, "\n").trim();
  return normalized ? normalized : undefined;
}

function summaryFromFinalAnswer(text: string): string {
  const firstParagraph = text.split(/\n\s*\n/).find((part) => part.trim().length > 0)?.trim() ?? text.trim();
  const singleLine = firstParagraph.replace(/\s+/g, " ");
  return singleLine.length > 220 ? `${singleLine.slice(0, 217)}...` : singleLine;
}

function titleFromContext(context: PickyContextPacket): string {
  const text = context.transcript?.trim();
  if (!text) return "Untitled Picky task";
  return text.length > 60 ? `${text.slice(0, 57)}...` : text;
}

function mergeChangedFiles(existing: PickyAgentSession["changedFiles"], incoming: PickyAgentSession["changedFiles"]): PickyAgentSession["changedFiles"] {
  const byPath = new Map(existing.map((file) => [file.path, file]));
  for (const file of incoming) byPath.set(file.path, file);
  return [...byPath.values()];
}

function mergeArtifacts(existing: PickyAgentSession["artifacts"], incoming: PickyAgentSession["artifacts"]): PickyAgentSession["artifacts"] {
  const byId = new Map(existing.map((artifact) => [artifact.id, artifact]));
  for (const artifact of incoming) byId.set(artifact.id, artifact);
  return [...byId.values()];
}
