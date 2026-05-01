import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { buildFollowUpPrompt, buildInitialTaskPrompt } from "./prompt-builder.js";
import type { PickyAgentSession, PickyContextPacket } from "./protocol.js";
import { SessionStore } from "./session-store.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./runtime/types.js";

export class SessionSupervisor extends EventEmitter {
  private sessions = new Map<string, PickyAgentSession>();
  private runtimeHandles = new Map<string, RuntimeSessionHandle>();

  constructor(private readonly runtime: AgentRuntime, private readonly store: SessionStore) {
    super();
  }

  async load(): Promise<void> {
    for (const session of await this.store.loadAll()) this.sessions.set(session.id, session);
  }

  list(): PickyAgentSession[] {
    return [...this.sessions.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  get(id: string): PickyAgentSession | undefined {
    return this.sessions.get(id);
  }

  async create(context: PickyContextPacket): Promise<PickyAgentSession> {
    const now = new Date().toISOString();
    const id = `session-${randomUUID()}`;
    const session: PickyAgentSession = {
      id,
      title: titleFromContext(context),
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
    const handle = await this.runtime.create(buildInitialTaskPrompt(context), { cwd: context.cwd });
    this.runtimeHandles.set(id, handle);
    handle.subscribe((event) => void this.applyRuntimeEvent(id, event));
    await this.patch(id, { status: "running", lastSummary: "Started" });
    return this.mustGet(id);
  }

  async followUp(sessionId: string, text: string, context?: PickyContextPacket): Promise<PickyAgentSession> {
    const session = this.mustGet(sessionId);
    if (["failed", "cancelled"].includes(session.status)) throw new Error(`Cannot follow up ${session.status} session`);
    const handle = this.runtimeHandles.get(sessionId);
    await this.appendLog(sessionId, `follow-up: ${text}`);
    if (handle) await handle.followUp(buildFollowUpPrompt(sessionId, text, context));
    await this.patch(sessionId, { status: "running", lastSummary: "Follow-up queued" });
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
    return this.mustGet(sessionId);
  }

  private async applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void> {
    if (event.type === "log") return this.appendLog(sessionId, event.line);
    if (event.type === "status") return this.patch(sessionId, { status: event.status, lastSummary: event.summary });
    const session = this.mustGet(sessionId);
    const tools = session.tools.filter((tool) => tool.toolCallId !== event.toolCallId);
    tools.push({ toolCallId: event.toolCallId, name: event.name, status: event.status, preview: event.preview, startedAt: new Date().toISOString() });
    await this.patch(sessionId, { tools });
  }

  private async appendLog(sessionId: string, line: string): Promise<void> {
    const session = this.mustGet(sessionId);
    await this.patch(sessionId, { logs: [...session.logs, line] });
    this.emit("log", sessionId, line);
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

function titleFromContext(context: PickyContextPacket): string {
  const text = context.transcript?.trim();
  if (!text) return "Untitled Picky task";
  return text.length > 60 ? `${text.slice(0, 57)}...` : text;
}
