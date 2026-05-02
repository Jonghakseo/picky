import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
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

  it("lists and resumes side sessions created from main-agent handoff", async () => {
    const supervisor = await makeSupervisor();
    const regular = await supervisor.create(context("regular"));
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    expect(supervisor.isSideSession(side.id)).toBe(true);
    expect(supervisor.listSideSessions().map((session) => session.id)).toEqual([side.id]);

    const updated = await supervisor.steerSideSession(side.id, "추가로 원인도 정리해줘");
    expect(updated.lastSummary).toBe("Steering message sent");
    expect(updated.logs.some((line) => line.includes("추가로 원인도 정리해줘"))).toBe(true);
    await expect(supervisor.steerSideSession(regular.id, "wrong target")).rejects.toThrow(/not a Picky side agent/);
  });

  it("validates and emits visual-only pointer overlays against captured screenshots", async () => {
    const supervisor = await makeSupervisor();
    const pointerContext: PickyContextPacket = {
      ...context("point here"),
      screenshots: [
        {
          id: "shot-1",
          label: "screen 1 — cursor is on this screen",
          path: "/tmp/shot-1.jpg",
          screenId: "screen1",
          bounds: { x: 100, y: 200, width: 300, height: 400 },
          screenshotWidthInPixels: 600,
          screenshotHeightInPixels: 800,
          isCursorScreen: true,
        },
      ],
    };
    const session = await supervisor.create(pointerContext);
    const emitted: unknown[] = [];
    supervisor.on("pointerOverlayRequested", (request) => emitted.push(request));

    const result = await supervisor.requestPointerOverlay({ sourceSessionId: session.id, screenIndex: 1, x: -20, y: 900, label: "target", durationMs: 99_999, confidence: 0.8 });

    expect(result.emitted).toBe(true);
    expect(emitted).toHaveLength(1);
    expect(result.request).toMatchObject({
      contextId: pointerContext.id,
      sourceSessionId: session.id,
      screenId: "screen1",
      screenIndex: 1,
      x: 0,
      y: 800,
      coordinateSpace: "screenshotPixel",
      clamped: true,
      durationMs: 10_000,
      confidence: 0.8,
      screenBounds: { x: 100, y: 200, width: 300, height: 400 },
      screenshotSize: { width: 600, height: 800 },
    });
  });

  it("supports pointer overlay dry runs without broadcasting", async () => {
    const supervisor = await makeSupervisor();
    await supervisor.create({
      ...context("point here"),
      screenshots: [{ id: "shot-1", label: "screen 1", path: "/tmp/shot-1.jpg", screenId: "screen1", bounds: { x: 0, y: 0, width: 100, height: 100 } }],
    });
    const emitted: unknown[] = [];
    supervisor.on("pointerOverlayRequested", (request) => emitted.push(request));

    const result = await supervisor.requestPointerOverlay({ coordinateSpace: "displayPoint", x: 50, y: 60, dryRun: true });

    expect(result.emitted).toBe(false);
    expect(emitted).toHaveLength(0);
    expect(result.request).toMatchObject({ coordinateSpace: "displayPoint", dryRun: true, x: 50, y: 60 });
  });

  it("uses the handoff cwd override for side session metadata, prompt context, and runtime cwd", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new RecordingRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate", cwd: "  /tmp/override-project  " });

    expect(side.cwd).toBe("/tmp/override-project");
    expect(side.logs).toContain("main-agent handoff cwd: /tmp/override-project");
    expect(runtime.creates[0].options.cwd).toBe("/tmp/override-project");
    expect(runtime.creates[0].prompt.text).toContain("- CWD: /tmp/override-project");
  });

  it("routes side-session follow-up compatibility calls through steer", async () => {
    const supervisor = await makeSupervisor();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    const result = await supervisor.followUpSideSession(side.id, "추가로 원인도 정리해줘", context("follow-up"));

    expect(result.lastSummary).toBe("Steering message sent");
    expect(result.logs.some((line) => line === "steer: 추가로 원인도 정리해줘")).toBe(true);
  });

  it("restores persisted side-session markers from handoff logs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const side = await firstSupervisor.createSideFromHandoff(context("persist side"), { title: "사이드 유지", instructions: "Keep marker" });

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    expect(secondSupervisor.isSideSession(side.id)).toBe(true);
    expect(secondSupervisor.listSideSessions().map((session) => session.id)).toEqual([side.id]);
  });

  it("pins an idle Pi handoff as a completed side session without starting runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir));
    await supervisor.load();

    const pinnedContext = {
      ...context("pin completed source"),
      transcript: "## Source Pi session\n- CWD: /tmp/project\n- Session file: /tmp/source-pi-session.jsonl\n",
    };
    const pinned = await supervisor.pinSideSession(pinnedContext, "Pinned source");

    expect(pinned.status).toBe("completed");
    expect(pinned.title).toBe("Pinned source");
    expect(pinned.lastSummary).toBe("Pinned completed Pi session");
    expect(pinned.finalAnswer).toMatch(/No Picky side-agent run/);
    expect(pinned.notifyMainOnCompletion).toBe(false);
    expect(pinned.logs).toContain("pi session: /tmp/source-pi-session.jsonl");
    expect(pinned.logs.some((line) => line.startsWith("pi-extension handoff pin:"))).toBe(true);
    expect(supervisor.isSideSession(pinned.id)).toBe(true);
  });

  it("does not notify the main agent when a local Pi session is pinned", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir), undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));
    await supervisor.load();

    await supervisor.pinSideSession(context("pin completed source"), "Pinned source");

    expect(mainRuntime.prewarmCalls).toBe(0);
    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
    expect(replies).toEqual([]);
  });

  it("lets side sessions opt out without replaying completed notifications", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate" });

    const disabled = await supervisor.setNotifyMainOnCompletion(side.id, false);
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "조사 완료" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(disabled.notifyMainOnCompletion).toBe(false);
    expect(mainRuntime.prewarmCalls).toBe(0);

    const enabled = await supervisor.setNotifyMainOnCompletion(side.id, true);
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Duplicate completed" });
    await settle();

    expect(enabled.notifyMainOnCompletion).toBe(true);
    expect(mainRuntime.prewarmCalls).toBe(0);

    await supervisor.followUp(side.id, "다시 확인해줘");
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "재조사 완료" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.prewarmCalls).toBe(1);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toContain("재조사 완료");
  });

  it("restores persisted pinned side sessions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const pinned = await firstSupervisor.pinSideSession(context("persist pinned"), "Pinned persisted");

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    expect(secondSupervisor.get(pinned.id)?.status).toBe("completed");
    expect(secondSupervisor.isSideSession(pinned.id)).toBe(true);
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

  it("rejects follow-up for restored sessions without resumable Pi session state", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const session = await firstSupervisor.create(context("restore follow up"));
    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    await expect(secondSupervisor.followUp(session.id, "continue")).rejects.toThrow(/Runtime session is not attached/);
    expect(secondSupervisor.get(session.id)?.status).toBe("blocked");
    expect(secondSupervisor.get(session.id)?.lastSummary).toMatch(/cannot resume saved Pi sessions/);
  });

  it("reattaches restored sessions from recorded Pi session files before follow-up", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "restored-with-pi-file",
      title: "Restored side agent",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Completed before restart",
      logs: ["pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();

    const updated = await supervisor.followUp("restored-with-pi-file", "continue after restart");

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/pi-session.jsonl", cwd: "/tmp/project", sessionId: "restored-with-pi-file" }]);
    expect(runtime.handle?.followUps[0].text).toContain("continue after restart");
    expect(updated.status).toBe("running");
    expect(updated.logs).toContain("runtime reattached from pi session: /tmp/pi-session.jsonl");
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
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir), undefined, { taskRouter: new StaticTaskRouter({ route: "quick_reply", reply: "바로 답변" }) });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const result = await supervisor.route(context("마이크 테스트"));

    expect(result).toBeUndefined();
    expect(supervisor.list()).toEqual([]);
    expect(replies).toEqual([{ contextId: "context-마이크 테스트", text: "바로 답변" }]);
  });

  it("routes voice requests through the main agent when configured", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const result = await supervisor.route(context("안녕"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "안녕하세요. 무엇을 도와드릴까요?" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(result).toBeUndefined();
    expect(sideRuntime.handle).toBeUndefined();
    expect(replies).toEqual([{ contextId: "context-안녕", text: "안녕하세요. 무엇을 도와드릴까요?" }]);
  });

  it("reuses the same main agent handle for later voice turns", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    await supervisor.route(context("첫 번째"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "첫 응답" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    await supervisor.route(context("두 번째"));

    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toContain("두 번째");
  });

  it("interrupts the active main-agent turn when newer voice input arrives", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.prewarmMainAgent("/tmp/project");
    await supervisor.route(context("첫 질문"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Started" });
    await supervisor.route(context("두 번째 질문"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "두 번째 응답" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.interrupts).toHaveLength(1);
    expect(mainRuntime.handle?.interrupts[0].text).toContain("두 번째 질문");
    expect(replies).toEqual([{ contextId: "context-두 번째 질문", text: "두 번째 응답" }]);
  });

  it("prewarms the main agent without creating a visible session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    await supervisor.prewarmMainAgent("/tmp/project");
    const prewarmedHandle = mainRuntime.handle;
    await supervisor.route(context("첫 실제 입력"));

    expect(mainRuntime.prewarmCalls).toBe(1);
    expect(mainRuntime.createCalls).toBe(0);
    expect(mainRuntime.handle).toBe(prewarmedHandle);
    expect(prewarmedHandle?.followUps).toHaveLength(1);
    expect(prewarmedHandle?.followUps[0].text).toContain("첫 실제 입력");
    expect(supervisor.list()).toEqual([]);
  });

  it("routes complex requests to the long-running runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir), undefined, { taskRouter: new StaticTaskRouter({ route: "handoff", reason: "needs tools" }) });

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

  it("stores the final assistant answer instead of replacing it with a generic completion label", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), new ArtifactStore(dir));
    const session = await supervisor.create(context("summarize video"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "영상 요약입니다.\n\n핵심 내용은 agentic engineering입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const updated = supervisor.get(session.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.finalAnswer).toBe("영상 요약입니다.\n\n핵심 내용은 agentic engineering입니다.");
    expect(updated.lastSummary).toBe("영상 요약입니다.");
    const reportPath = updated.artifacts.find((artifact) => artifact.id === "report")?.path;
    expect(reportPath).toBeTruthy();
    const markdown = await readFile(reportPath!, "utf8");
    expect(markdown).toContain("핵심 내용은 agentic engineering입니다.");
    expect(markdown).not.toContain("## Final answer\nCompleted");
  });

  it("emits terminal session update before terminal artifacts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), new ArtifactStore(dir));
    const events: string[] = [];
    supervisor.on("session", (updated) => {
      if (updated.status === "completed") events.push("session:completed");
    });
    supervisor.on("artifact", (_sessionId, artifact) => events.push(`artifact:${artifact.kind}`));
    const session = await supervisor.create(context("ordering terminal"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "Done" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(events.indexOf("session:completed")).toBeGreaterThanOrEqual(0);
    expect(events.indexOf("artifact:report")).toBeGreaterThan(events.indexOf("session:completed"));
    expect(supervisor.get(session.id)?.status).toBe("completed");
  });

  it("emits waiting_for_input session update before extension UI request", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const events: string[] = [];
    supervisor.on("session", (updated) => {
      if (updated.status === "waiting_for_input") events.push("session:waiting_for_input");
    });
    supervisor.on("extensionUiRequest", (request) => events.push(`extension:${request.id}`));
    const session = await supervisor.create(context("extension ordering"));

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: true,
      request: { id: "question-1", sessionId: session.id, method: "input", createdAt: "2026-05-01T00:00:00.000Z", prompt: "Need input" },
    });
    await settle();

    expect(events).toEqual(["session:waiting_for_input", "extension:question-1"]);
    expect(supervisor.get(session.id)?.pendingExtensionUiRequest?.id).toBe("question-1");
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

class ResumableRuntime implements AgentRuntime {
  handle?: ManualHandle;
  resumeCalls: Array<{ sessionFilePath: string; cwd?: string; sessionId?: string }> = [];

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return this.handle;
  }

  async resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.resumeCalls.push({ sessionFilePath, cwd: options.cwd, sessionId: options.sessionId });
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return this.handle;
  }
}

class RecordingRuntime implements AgentRuntime {
  creates: Array<{ prompt: BuiltPrompt; options: { cwd?: string; sessionId?: string } }> = [];

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.creates.push({ prompt, options });
    return new ManualHandle(options.sessionId ?? "manual");
  }
}

class ManualRuntime implements AgentRuntime {
  handle?: ManualHandle;
  createCalls = 0;
  prewarmCalls = 0;
  prewarm?: (options: { cwd?: string; sessionId?: string }) => Promise<RuntimeSessionHandle>;

  constructor(options: { supportsPrewarm?: boolean } = {}) {
    if (options.supportsPrewarm) {
      this.prewarm = async (prewarmOptions) => {
        this.prewarmCalls += 1;
        this.handle = new ManualHandle(prewarmOptions.sessionId ?? "manual");
        return this.handle;
      };
    }
  }

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.createCalls += 1;
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return this.handle;
  }
}

class ManualHandle implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  followUps: BuiltPrompt[] = [];
  interrupts: BuiltPrompt[] = [];
  constructor(readonly id: string) {}
  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.followUps.push(prompt);
  }
  async interrupt(prompt: BuiltPrompt): Promise<void> {
    this.interrupts.push(prompt);
  }
  steers: string[] = [];
  async steer(text: string): Promise<void> {
    this.steers.push(text);
  }
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
  await delay(10);
}

async function delay(milliseconds: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function makeSupervisor(): Promise<SessionSupervisor> {
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
  const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
  await supervisor.load();
  return supervisor;
}
