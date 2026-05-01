import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ArtifactStore } from "./artifact-store.js";
import type { PickyContextPacket } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import type { BuiltPrompt } from "./prompt-builder.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "./runtime/types.js";
import type { TaskRouteDecision, TaskRouter } from "./task-router.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

const context = (text: string): PickyContextPacket => ({
  id: `context-${text}`,
  source: "text",
  capturedAt: "2026-05-01T00:00:00.000Z",
  transcript: text,
  cwd: "/tmp/project",
  screenshots: [],
  warnings: [],
});

describe("SessionSupervisor", () => {
  it("creates multiple mock sessions concurrently", async () => {
    const supervisor = await makeSupervisor();
    const [first, second] = await Promise.all([supervisor.create(context("first")), supervisor.create(context("second"))]);
    expect(first.id).not.toBe(second.id);
    expect(supervisor.list()).toHaveLength(2);
  });

  it("queues follow-up for a selected session", async () => {
    const supervisor = await makeSupervisor();
    const session = await supervisor.create(context("initial"));
    const updated = await supervisor.followUp(session.id, "next step");
    expect(updated.status).toBe("running");
    expect(updated.logs.some((line) => line.includes("next step"))).toBe(true);
  });

  it("aborts a session", async () => {
    const supervisor = await makeSupervisor();
    const session = await supervisor.create(context("abort me"));
    const updated = await supervisor.abort(session.id);
    expect(updated.status).toBe("cancelled");
  });

  it("writes report and PR artifacts when a terminal status is observed", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new MockRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), new ArtifactStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("terminal report"));
    await supervisor.followUp(session.id, "Changed file: M Picky/App.swift - HUD follow-up\nhttps://github.com/acme/repo/pull/42");
    await supervisor.abort(session.id);

    const updated = supervisor.get(session.id)!;
    expect(updated.artifacts.some((artifact) => artifact.kind === "report" && artifact.path?.endsWith("report.md"))).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "pr" && artifact.url === "https://github.com/acme/repo/pull/42")).toBe(true);
    expect(updated.changedFiles).toEqual([{ status: "M", path: "Picky/App.swift", summary: "HUD follow-up" }]);
  });

  it("reloads persisted session metadata as blocked when runtime is not attached", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const session = await firstSupervisor.create(context("persist me"));

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();
    const restored = secondSupervisor.get(session.id);
    expect(restored?.title).toBe("persist me");
    expect(restored?.status).toBe("blocked");
    expect(restored?.lastSummary).toMatch(/Runtime not attached/);
  });

  it("rejects follow-up for restored sessions without marking them running", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const session = await firstSupervisor.create(context("restore follow up"));
    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    await expect(secondSupervisor.followUp(session.id, "continue")).rejects.toThrow(/Runtime session is not attached/);
    expect(secondSupervisor.get(session.id)?.status).toBe("blocked");
    expect(secondSupervisor.get(session.id)?.lastSummary).toMatch(/Runtime not attached/);
  });

  it("marks task creation failures as failed instead of leaving queued ghosts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir));
    await supervisor.load();

    await expect(supervisor.create(context("runtime fail"))).rejects.toThrow(/runtime unavailable/);
    const failed = supervisor.list()[0];
    expect(failed.status).toBe("failed");
    expect(failed.lastSummary).toMatch(/Failed to start runtime: runtime unavailable/);
    expect(failed.logs).toContain("Failed to start runtime: runtime unavailable");
  });

  it("skips corrupt persisted session metadata instead of crashing daemon startup", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sessionsDir = join(dir, "sessions");
    await mkdir(sessionsDir, { recursive: true });
    await writeFile(join(sessionsDir, "corrupt.json"), "{\"id\":\"broken\"}\n}");

    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await expect(supervisor.load()).resolves.toBeUndefined();
    expect(supervisor.list()).toEqual([]);
  });

  it("routes simple requests as quick replies without creating agent sessions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir), undefined, new StaticTaskRouter({ route: "quick_reply", reply: "바로 답변" }));
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const result = await supervisor.route(context("마이크 테스트"));

    expect(result).toBeUndefined();
    expect(supervisor.list()).toEqual([]);
    expect(replies).toEqual([{ contextId: "context-마이크 테스트", text: "바로 답변" }]);
  });

  it("routes complex requests to the long-running runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir), undefined, new StaticTaskRouter({ route: "handoff", reason: "needs tools" }));

    const session = await supervisor.route(context("코드 수정해줘"));

    expect(session?.title).toBe("코드 수정해줘");
    expect(supervisor.list()).toHaveLength(1);
  });

  it("does not turn fire-and-forget extension UI updates into pending input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("widget update"));

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: false,
      request: { id: "widget-1", sessionId: session.id, method: "setWidget", createdAt: "2026-05-01T00:00:00.000Z", title: "setWidget" },
    });
    await settle();

    const updated = supervisor.get(session.id);
    expect(updated?.status).toBe("running");
    expect(updated?.pendingExtensionUiRequest).toBeUndefined();
    expect(updated?.logs.at(-1)).toMatch(/extension ui: setWidget/);
  });

  it("rejects invalid follow-up transitions", async () => {
    const supervisor = await makeSupervisor();
    const session = await supervisor.create(context("cancel then follow"));
    await supervisor.abort(session.id);
    await expect(supervisor.followUp(session.id, "nope")).rejects.toThrow(/Cannot follow up/);
  });
});

class ThrowingRuntime implements AgentRuntime {
  async create(): Promise<never> {
    throw new Error("runtime unavailable");
  }
}

class StaticTaskRouter implements TaskRouter {
  constructor(private readonly decision: TaskRouteDecision) {}
  async route(): Promise<TaskRouteDecision> {
    return this.decision;
  }
}

class ManualRuntime implements AgentRuntime {
  handle?: ManualHandle;
  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return this.handle;
  }
}

class ManualHandle implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  constructor(readonly id: string) {}
  async followUp(): Promise<void> {}
  async steer(): Promise<void> {}
  async abort(): Promise<void> {}
  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

async function makeSupervisor(): Promise<SessionSupervisor> {
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
  const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
  await supervisor.load();
  return supervisor;
}
