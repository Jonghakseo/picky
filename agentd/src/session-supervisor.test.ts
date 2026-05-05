import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ArtifactStore } from "./artifact-store.js";
import type { PickyContextPacket } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import type { BuiltPrompt } from "./prompt-builder.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, ThinkingLevel } from "./runtime/types.js";
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

  it("prewarms an empty manual side session and waits for the first instruction", async () => {
    const runtime = new ManualRuntime({ supportsPrewarm: true });
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-side-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const session = await supervisor.createEmptySideSession({ ...context("manual"), source: "system", transcript: undefined, cwd: "  /tmp/manual-project  " });

    expect(runtime.createCalls).toBe(0);
    expect(runtime.prewarmCalls).toBe(1);
    expect(runtime.prewarmOptions).toEqual([{ cwd: "/tmp/manual-project", sessionId: session.id }]);
    expect(session.status).toBe("waiting_for_input");
    expect(session.cwd).toBe("/tmp/manual-project");
    expect(session.title).toBe("New side agent · manual-project");
    expect(session.notifyMainOnCompletion).toBe(false);
    expect(supervisor.isSideSession(session.id)).toBe(true);
    expect(supervisor.listSideSessions().map((side) => side.id)).toEqual([session.id]);
    expect(session.logs).toContain("manual side agent: waiting for first instruction");

    const steered = await supervisor.steerSideSession(session.id, "첫 작업 시작해줘");
    expect(steered.status).toBe("running");
    expect(runtime.handle?.steers).toEqual(["첫 작업 시작해줘"]);
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

  it("derives screenshot pixel dimensions from image files when context metadata is missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const imagePath = join(dir, "shot.jpg");
    const jpegHeader = Buffer.from([
      0xff, 0xd8,
      0xff, 0xe0, 0x00, 0x10,
      0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      0xff, 0xc0, 0x00, 0x11, 0x08, 0x03, 0x3b, 0x05, 0x00, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    ]);
    await writeFile(imagePath, jpegHeader);

    const supervisor = await makeSupervisor();
    const session = await supervisor.create({
      ...context("point here"),
      screenshots: [{ id: "shot-3", label: "screen 3", path: imagePath, screenId: "screen3", bounds: { x: 0, y: 0, width: 1728, height: 1117 } }],
    });

    const result = await supervisor.requestPointerOverlay({ sourceSessionId: session.id, screenId: "screen3", x: 405, y: 180, dryRun: true });

    expect(result.request).toMatchObject({
      coordinateSpace: "screenshotPixel",
      x: 405,
      y: 180,
      screenshotSize: { width: 1280, height: 827 },
      screenBounds: { x: 0, y: 0, width: 1728, height: 1117 },
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

  it("does not append pointer sourceSessionId hints to side-agent handoff prompts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new RecordingRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const direct = await supervisor.create(context("direct visual task"));
    await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate" });

    expect(runtime.creates[0].prompt.text).toContain("## Picky visual pointer overlay");
    expect(runtime.creates[0].prompt.text).toContain(`sourceSessionId: ${direct.id}`);
    expect(runtime.creates[1].prompt.text).toContain("# Picky side-agent task");
    expect(runtime.creates[1].prompt.text).not.toContain("## Picky visual pointer overlay");
    expect(runtime.creates[1].prompt.text).not.toContain("picky_show_pointer");
    expect(runtime.creates[1].prompt.text).not.toContain("sourceSessionId");
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

  it("prefers the runtime status finalAnswer over the streamed accumulator so reports do not include intermediate ReAct turns", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("multi-turn"), { title: "멀티턴 조사", instructions: "Investigate" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 중입니다." });
    runtime.handle?.emit({ type: "assistant_delta", delta: "계속 조사 중입니다." });
    runtime.handle?.emit({ type: "assistant_delta", delta: "최종 답변입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "최종 답변입니다." });
    await settle();

    const completed = supervisor.get(side.id)!;
    expect(completed.status).toBe("completed");
    expect(completed.finalAnswer).toBe("최종 답변입니다.");
    expect(completed.finalAnswer).not.toContain("조사 중입니다.");
  });

  it("marks completed side sessions as running when they are steered", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(supervisor.get(side.id)?.status).toBe("completed");
    expect(supervisor.get(side.id)?.finalAnswer).toBe("조사 완료입니다.");

    const updated = await supervisor.steerSideSession(side.id, "추가로 원인도 정리해줘");

    expect(runtime.handle?.steers).toEqual(["추가로 원인도 정리해줘"]);
    expect(updated.status).toBe("running");
    expect(updated.finalAnswer).toBeUndefined();
    expect(updated.lastSummary).toBe("Steering message sent");
  });

  // Regression for the `/diff-review` (and any other Pi `pi.registerCommand` slash command) HUD
  // spinner: PiSdkRuntimeSession.maybeEmitImmediateCompletion synthesizes a `completed` runtime
  // status when Pi handles a slash command synchronously inside `session.prompt()`, and reports
  // back via `RuntimeSteerResult.handledSynchronously`. Previously `steer()` then unconditionally
  // re-patched to `running`, leaving the HUD card stuck on the loading state forever.
  it("keeps a side session terminal when steer reports handledSynchronously (slash command)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(side.id)?.status).toBe("completed");

    // Replay PiSdkRuntimeSession's behaviour for slash commands: signal `handledSynchronously` and
    // (optionally) the synthetic `completed` status emit. The supervisor must NOT then resurrect
    // the session into `running`.
    runtime.handle!.steerOutcome = { handledSynchronously: true };

    const updated = await supervisor.steerSideSession(side.id, "/diff-review");

    expect(runtime.handle?.steers).toEqual(["/diff-review"]);
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).not.toBe("Steering message sent");
    expect(updated.logs).toContain("steer: /diff-review");
  });

  it("settles active tools when a session is aborted", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("abort active tool"));

    runtime.handle?.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running", preview: "sleep 60" });
    await settle();

    await supervisor.abort(session.id);

    const aborted = supervisor.get(session.id)!;
    expect(aborted.status).toBe("cancelled");
    expect(aborted.thinkingPreview).toBeUndefined();
    expect(aborted.tools[0]).toMatchObject({ status: "failed", preview: "Tool stopped because the session was cancelled." });
  });

  it("marks cancelled side sessions as running when they are steered", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    await supervisor.abort(side.id);

    expect(supervisor.get(side.id)?.status).toBe("cancelled");

    const updated = await supervisor.steerSideSession(side.id, "다시 진행해줘");

    expect(runtime.handle?.steers).toEqual(["다시 진행해줘"]);
    expect(updated.status).toBe("running");
    expect(updated.lastSummary).toBe("Steering message sent");
    expect(updated.logs).toContain("steer: 다시 진행해줘");
  });

  it("routes cancelled side-session follow-up calls through steer instead of regular follow-up", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    await supervisor.abort(side.id);

    const updated = await supervisor.followUp(side.id, "follow-up 경로로 다시 진행");

    expect(runtime.handle?.followUps).toEqual([]);
    expect(runtime.handle?.steers).toEqual(["follow-up 경로로 다시 진행"]);
    expect(updated.status).toBe("running");
    expect(updated.logs).toContain("steer: follow-up 경로로 다시 진행");
  });

  it("clears stale cancelled side-session output when a new steering turn starts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "취소 전 부분 답변" });
    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    await settle();

    expect(supervisor.get(side.id)?.status).toBe("cancelled");
    expect(supervisor.get(side.id)?.finalAnswer).toBe("취소 전 부분 답변");

    const resumed = await supervisor.steerSideSession(side.id, "새로 다시 진행");

    expect(resumed.status).toBe("running");
    expect(resumed.finalAnswer).toBeUndefined();
    expect(resumed.thinkingPreview).toBeUndefined();

    runtime.handle?.emit({ type: "assistant_delta", delta: "재개 후 답변" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const completed = supervisor.get(side.id)!;
    expect(completed.status).toBe("completed");
    expect(completed.finalAnswer).toBe("재개 후 답변");
    expect(completed.finalAnswer).not.toContain("취소 전 부분 답변");
  });

  it("keeps failed side sessions rejected from steering", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "failed", summary: "Failed" });
    await settle();

    await expect(supervisor.steerSideSession(side.id, "실패 세션 재개 시도")).rejects.toThrow(/Cannot steer failed session/);
    expect(runtime.handle?.steers).toEqual([]);
    expect(supervisor.get(side.id)?.status).toBe("failed");
  });

  it("keeps the runtime failure summary instead of replacing it with partial streamed text", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("failure after partial output"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "부분 출력만 스트리밍됨" });
    runtime.handle?.emit({ type: "status", status: "failed", summary: "Tool crashed before completion" });
    await settle();

    const failed = supervisor.get(session.id)!;
    expect(failed.status).toBe("failed");
    expect(failed.lastSummary).toBe("Tool crashed before completion");
  });

  it("reattaches cancelled persisted side sessions from Pi session files before steering", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "cancelled-with-pi-file",
      title: "Cancelled side agent",
      status: "cancelled",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Cancelled before restart",
      logs: ["main-agent handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
      finalAnswer: "이전 취소 답변",
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();

    expect(supervisor.isSideSession("cancelled-with-pi-file")).toBe(true);
    expect(supervisor.get("cancelled-with-pi-file")?.status).toBe("cancelled");

    const updated = await supervisor.steerSideSession("cancelled-with-pi-file", "재시작 후 다시 진행");

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/pi-session.jsonl", cwd: "/tmp/project", sessionId: "cancelled-with-pi-file" }]);
    expect(runtime.handle?.steers).toEqual(["재시작 후 다시 진행"]);
    expect(updated.status).toBe("running");
    expect(updated.finalAnswer).toBeUndefined();
    expect(updated.lastSummary).toBe("Steering message sent");
    expect(updated.logs).toContain("runtime reattached from pi session: /tmp/pi-session.jsonl");
    expect(updated.logs).toContain("steer: 재시작 후 다시 진행");
  });

  it("stores only the front of thinking blocks for current work", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("think through the HUD"));

    runtime.handle?.emit({ type: "thinking_delta", delta: "I need to inspect\n" });
    runtime.handle?.emit({ type: "thinking_delta", delta: "the HUD current work state." });
    await settle();

    expect(supervisor.get(session.id)?.thinkingPreview).toBe("I need to inspect the HUD current work state.");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(supervisor.get(session.id)?.thinkingPreview).toBeUndefined();
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
    expect(pinned.pinned).toBe(true);
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

  it("does not let a late empty terminal event overwrite a cancelled session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("cancel race"));

    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    await settle();
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(supervisor.get(session.id)?.status).toBe("cancelled");
    expect(supervisor.get(session.id)?.lastSummary).toBe("Cancelled");
  });

  it("does not let a late terminal answer overwrite a cancelled session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("cancel after answer"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "취소 전에 보이던 답변" });
    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    await settle();
    runtime.handle?.emit({ type: "assistant_delta", delta: "늦게 온 완료 답변" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const updated = supervisor.get(session.id);
    expect(updated?.status).toBe("cancelled");
    expect(updated?.finalAnswer).toBe("취소 전에 보이던 답변");
    expect(updated?.lastSummary).toBe("취소 전에 보이던 답변");
  });

  it("captures only the latest side-session steering answer when a steered run completes", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });
    await supervisor.load();
    const side = await supervisor.createSideFromHandoff(context("side request"), { title: "사이드 조사", instructions: "Investigate" });

    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "초기 답변" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    await supervisor.steerSideSession(side.id, "후속 질문");
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "후속 답변" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const updated = supervisor.get(side.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.finalAnswer).toBe("후속 답변");
    expect(updated.finalAnswer).not.toContain("초기 답변");
  });

  it("restores persisted pinned side sessions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const pinned = await firstSupervisor.pinSideSession(context("persist pinned"), "Pinned persisted");

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    expect(secondSupervisor.get(pinned.id)?.status).toBe("completed");
    expect(secondSupervisor.get(pinned.id)?.pinned).toBe(true);
    expect(secondSupervisor.isSideSession(pinned.id)).toBe(true);
  });

  it("clears pinned flag when a pinned side session is steered", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await supervisor.load();
    const pinned = await supervisor.pinSideSession(context("pin then steer"), "Pinned source");
    expect(pinned.pinned).toBe(true);

    // Steering currently fails because pinned sessions have no runtime handle yet,
    // but the pinned flag must be cleared before the runtime call so that any
    // subsequent successful run delivers the normal completion notification.
    await expect(supervisor.steerSideSession(pinned.id, "continue this work")).rejects.toThrow();

    expect(supervisor.get(pinned.id)?.pinned).toBe(false);
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
    expect(updated.artifacts.some((artifact) => artifact.kind === "report" && /report-.*\.md$/.test(artifact.path ?? ""))).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "github" && artifact.title === "#42" && artifact.url === "https://github.com/acme/repo/pull/42")).toBe(true);
    expect(updated.changedFiles).toEqual([{ status: "M", path: "Picky/App.swift", summary: "HUD follow-up" }]);
  });

  it("creates link artifacts from initial user input and appended logs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new MockRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const session = await supervisor.create(context("See https://github.com/acme/repo/issues/2777 and https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249"));
    await supervisor.followUp(session.id, "Notion https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226?source=copy_link");

    const updated = supervisor.get(session.id)!;
    expect(updated.artifacts.some((artifact) => artifact.kind === "github" && artifact.title === "#2777" && artifact.url === "https://github.com/acme/repo/issues/2777")).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "slack" && artifact.url === "https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249")).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "notion" && artifact.url === "https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226")).toBe(true);
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

  it("reattaches non-terminal persisted sessions from Pi session files without leaving stale work active", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "running-with-pi-file",
      title: "Running side agent",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Still working before restart",
      logs: ["main-agent handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [{ toolCallId: "tool-1", name: "bash", status: "running", startedAt: "2026-05-01T00:00:05.000Z" }],
      artifacts: [],
      changedFiles: [],
      thinkingPreview: "checking setup progress",
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);

    await supervisor.load();

    const restored = supervisor.get("running-with-pi-file");
    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/pi-session.jsonl", cwd: "/tmp/project", sessionId: "running-with-pi-file" }]);
    expect(restored?.status).toBe("blocked");
    expect(restored?.lastSummary).toBe("Previous run was interrupted by daemon restart; send a follow-up or steer message to continue.");
    expect(restored?.pendingExtensionUiRequest).toBeUndefined();
    expect(restored?.thinkingPreview).toBeUndefined();
    expect(restored?.tools[0]).toMatchObject({ status: "failed", preview: "Tool was interrupted by a Picky daemon restart." });
    expect(restored?.logs).toContain("runtime reattached from pi session: /tmp/pi-session.jsonl");
    expect(restored?.logs.some((line) => line.includes("Runtime not attached after daemon restart"))).toBe(false);
  });

  it("clears stale extension UI requests on reattach because the previous bridge promise is gone", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "waiting-with-pending-ui",
      title: "Waiting side agent",
      status: "waiting_for_input",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Waiting before restart",
      logs: ["main-agent handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
      pendingExtensionUiRequest: {
        id: "ui-1",
        sessionId: "waiting-with-pending-ui",
        method: "input",
        createdAt: "2026-05-01T00:00:05.000Z",
        prompt: "Need input",
      },
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);

    await supervisor.load();

    const restored = supervisor.get("waiting-with-pending-ui");
    expect(restored?.status).toBe("blocked");
    expect(restored?.pendingExtensionUiRequest).toBeUndefined();
    expect(restored?.lastSummary).toMatch(/previous question can no longer be answered/);
  });

  it("does not reattach archived non-terminal sessions during startup", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "archived-running-with-pi-file",
      title: "Archived side agent",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Archived before restart",
      logs: ["main-agent handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
      archived: true,
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);

    await supervisor.load();

    const restored = supervisor.get("archived-running-with-pi-file");
    expect(runtime.resumeCalls).toEqual([]);
    expect(restored?.status).toBe("cancelled");
    expect(restored?.lastSummary).toBe("Archived session was not resumed after daemon restart");
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
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "안녕" },
      { role: "assistant", text: "안녕하세요. 무엇을 도와드릴까요?" },
    ]);
  });

  it("resets main-agent messages and starts the next prompt on a new handle", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, undefined, { mainRuntime });

    await supervisor.route(context("이전 질문"));
    const previousHandle = mainRuntime.handle;
    previousHandle?.emit({ type: "log", line: "pi session: /tmp/previous-main.jsonl" });
    previousHandle?.emit({ type: "assistant_delta", delta: "이전 답변" });
    previousHandle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    await supervisor.resetMainAgent();
    previousHandle?.emit({ type: "assistant_delta", delta: "늦은 답변" });
    previousHandle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(previousHandle?.aborts).toBe(1);
    expect(supervisor.listMainMessages()).toEqual([]);
    expect(await store.loadMainAgentState()).toEqual({ messages: [] });

    await supervisor.route(context("새 질문"));

    expect(mainRuntime.createCalls).toBe(2);
    expect(mainRuntime.handle).not.toBe(previousHandle);
    expect(supervisor.listMainMessages().map((message) => message.text)).toEqual(["새 질문"]);
  });

  it("aborts the active main-agent turn without clearing visible message history", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.route(context("이전 질문"));
    const previousHandle = mainRuntime.handle;
    previousHandle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();

    await supervisor.abortMainAgent();
    previousHandle?.emit({ type: "assistant_delta", delta: "늦은 이전 답변" });
    previousHandle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(previousHandle?.aborts).toBe(1);
    expect(replies).toEqual([]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "이전 질문" },
    ]);
    expect((await store.loadMainAgentState()).messages.map((message) => message.text)).toEqual(["이전 질문"]);

    await supervisor.route(context("새 질문"));
    const nextHandle = mainRuntime.handle;
    nextHandle?.emit({ type: "assistant_delta", delta: "새 답변" });
    nextHandle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.createCalls).toBe(2);
    expect(nextHandle).not.toBe(previousHandle);
    expect(replies).toEqual([{ contextId: "context-새 질문", text: "새 답변" }]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "이전 질문" },
      { role: "user", text: "새 질문" },
      { role: "assistant", text: "새 답변" },
    ]);
  });

  it("aborts a pending prewarmed main-agent handle after voice input cancels it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new DeferredPrewarmRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    const prewarm = supervisor.prewarmMainAgent("/tmp/project");
    await settle();
    const pendingHandle = mainRuntime.handle;

    expect(mainRuntime.prewarmCalls).toBe(1);
    expect(pendingHandle).toBeDefined();

    await supervisor.abortMainAgent();
    mainRuntime.resolvePendingPrewarm();
    await prewarm;
    await settle();

    expect(pendingHandle?.aborts).toBe(1);

    await supervisor.route(context("새 음성 입력"));

    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle).not.toBe(pendingHandle);
    expect(supervisor.listMainMessages().map((message) => message.text)).toEqual(["새 음성 입력"]);
  });

  it("keeps only the latest 100 main-agent user and assistant messages", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    for (let index = 0; index < 101; index += 1) {
      await supervisor.route(context(`메시지 ${index}`));
      mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
      await settle();
    }

    const messages = supervisor.listMainMessages();
    expect(messages).toHaveLength(100);
    expect(messages[0]).toMatchObject({ role: "user", text: "메시지 1" });
    expect(messages.at(-1)).toMatchObject({ role: "user", text: "메시지 100" });
  });

  it("resumes the persisted main-agent Pi session after daemon restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.saveMainAgentState({ sessionFilePath: "/tmp/main-pi-session.jsonl", cwd: "/tmp/project", messages: [] });
    const mainRuntime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, undefined, { mainRuntime });
    await supervisor.load();

    await supervisor.route(context("재시작 후 질문"));

    expect(mainRuntime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/main-pi-session.jsonl", cwd: "/tmp/project", sessionId: "picky-main-agent" }]);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toContain("재시작 후 질문");
    expect(supervisor.listMainMessages().map((message) => message.text)).toEqual(["재시작 후 질문"]);
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

  it("applies configured thinking level to a future prewarmed main runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    await supervisor.setMainAgentThinkingLevel("high");
    await supervisor.prewarmMainAgent("/tmp/project");

    expect(mainRuntime.thinkingLevels).toEqual(["high"]);
    expect(mainRuntime.handle?.thinkingLevels).toEqual(["high"]);
  });

  it("applies configured thinking level to the active main runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    await supervisor.prewarmMainAgent("/tmp/project");
    const handle = mainRuntime.handle!;
    await supervisor.setMainAgentThinkingLevel("xhigh");

    expect(mainRuntime.thinkingLevels).toEqual(["xhigh"]);
    expect(handle.thinkingLevels).toEqual(["xhigh"]);
  });

  it("injects the main-agent bootstrap pair on a fresh prewarm so the rules ride the first turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    await supervisor.prewarmMainAgent("/tmp/project");
    expect(mainRuntime.handle?.bootstrapInjections).toHaveLength(1);
    const injection = mainRuntime.handle!.bootstrapInjections[0]!;
    expect(injection.user).toContain("마크다운");
    expect(injection.assistant).toBe("OK");
  });

  it("skips bootstrap injection when the main agent resumes from a persisted Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.saveMainAgentState({ sessionFilePath: "/tmp/main-pi-session.jsonl", cwd: "/tmp/project", messages: [] });
    const mainRuntime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, undefined, { mainRuntime });
    await supervisor.load();

    await supervisor.route(context("재시작 후 질문"));

    expect(mainRuntime.handle?.bootstrapInjections).toEqual([]);
  });

  it("injects the bootstrap pair when the main runtime cannot prewarm and goes straight to create", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), undefined, { mainRuntime });

    await supervisor.route(context("첫 창을연 텍스트"));

    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle?.bootstrapInjections).toHaveLength(1);
  });

  it("defers a side completion notification while the handoff turn is still in flight, then drains it without losing the reply", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    // 1) Voice command routed to the main agent — main turn starts running.
    const userCtx = context("사이드 띄워서 작업 해줘");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();

    // 2) Main decides to hand off: it announces the handoff text (which sets
    //    suppressNextMainReply=true) and spawns the side session. The handoff
    //    turn has NOT yet emitted status:completed.
    supervisor.announceMainHandoff(userCtx.id, "사이드에 위임할게요");
    const sideSession = await supervisor.createSideFromHandoff(userCtx, { title: "task", instructions: "do it" });
    await settle();

    expect(replies).toContainEqual({ contextId: userCtx.id, text: "사이드에 위임할게요" });

    // 3) Side session finishes BEFORE the main handoff turn ends. The
    //    notification must be deferred — sending it now would clobber
    //    mainReplyContextId/mainDraft and let the handoff turn's
    //    suppressNextMainReply swallow this side completion's reply.
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "사이드 결과 X" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);

    // 4) Handoff turn finally ends. suppressNextMainReply is consumed here, the
    //    handoff turn's draft is discarded, and the deferred side completion is
    //    drained from the queue and delivered as a fresh main turn.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "핸드오프 잔여 텍스트" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0]?.text).toContain(`Side session: ${sideSession.id}`);
    // Handoff-turn draft must NOT have been emitted as a quickReply (suppress
    // consumed it correctly), and no spurious side-completion reply was emitted.
    expect(replies.filter((entry) => entry.contextId === sideSession.id)).toHaveLength(0);
    expect(replies.filter((entry) => entry.contextId === userCtx.id)).toEqual([
      { contextId: userCtx.id, text: "사이드에 위임할게요" },
    ]);

    // 5) Main processes the side-completion follow-up. Its reply must arrive
    //    against the side session's id, not the original user context.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "사이드 작업 마쳤어요" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toContainEqual({ contextId: sideSession.id, text: "사이드 작업 마쳤어요" });
  });

  // Regression for the `/diff-review` follow-up: the previous fix synthesized a `completed`
  // runtime status with `noTurnRan: true` so the HUD spinner clears, but the side session must
  // NOT also notify the main agent (no real turn produced any progress). RuntimeEventHandler
  // skips notifySideCompletion + materializeTerminalArtifacts when `noTurnRan` is set.
  it("does not notify the main agent when a side session synthesizes a completion without running a turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });

    const userCtx = context("사이드 시작");
    await supervisor.route(userCtx);
    supervisor.announceMainHandoff(userCtx.id, "사이드 위임");
    const sideSession = await supervisor.createSideFromHandoff(userCtx, { title: "task", instructions: "do it" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // PiSdkRuntimeSession marks synthetic slash-command completions with `noTurnRan: true`.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
    await settle();

    expect(supervisor.get(sideSession.id)?.status).toBe("completed");
    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
  });

  it("delivers a side completion notification immediately when the main agent is idle", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const userCtx = context("사이드 시작");
    await supervisor.route(userCtx);
    supervisor.announceMainHandoff(userCtx.id, "사이드 위임");
    const sideSession = await supervisor.createSideFromHandoff(userCtx, { title: "task", instructions: "do it" });

    // Handoff turn ends BEFORE the side session emits its terminal status.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // Now main is idle; side completion must be delivered immediately.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0]?.text).toContain(`Side session: ${sideSession.id}`);

    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "바로 끝났어요" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toContainEqual({ contextId: sideSession.id, text: "바로 끝났어요" });
  });

  it("never queues a deferred notification when notifyMainOnCompletion is disabled", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });

    const userCtx = context("조용히 진행");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();
    supervisor.announceMainHandoff(userCtx.id, "위임");
    const sideSession = await supervisor.createSideFromHandoff(userCtx, { title: "task", instructions: "do it" });
    await supervisor.setNotifyMainOnCompletion(sideSession.id, false);

    // Side terminal status arrives while main is still busy on the handoff turn.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // Main turn ends. Drain runs but the disabled flag must keep the queue empty.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
  });

  it("clears deferred side completion notifications when the main agent is aborted", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });

    const userCtx = context("긴 작업");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();
    supervisor.announceMainHandoff(userCtx.id, "위임");
    await supervisor.createSideFromHandoff(userCtx, { title: "task", instructions: "do it" });

    // Side completes while main is still running the handoff turn → deferred.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const handleBeforeAbort = mainRuntime.handle;
    expect(handleBeforeAbort?.followUps ?? []).toHaveLength(0);

    // User aborts the main agent before the handoff turn finishes. The pending
    // queue must be cleared so a stale terminal event from the orphaned handle
    // can never re-trigger delivery against a fresh main session.
    await supervisor.abortMainAgent();
    handleBeforeAbort?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(handleBeforeAbort?.followUps ?? []).toHaveLength(0);

    // A new main turn must not see the dropped notification either.
    await supervisor.route(context("다음 질문"));
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
  });

  it("drops a queued side completion when the user steers the side session before the main agent drains it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), undefined, { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const userCtx = context("이어서 진행");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();
    supervisor.announceMainHandoff(userCtx.id, "위임");
    const sideSession = await supervisor.createSideFromHandoff(userCtx, { title: "task", instructions: "do it" });

    // Side completes while main is mid-turn → deferred.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // User immediately steers the side session, which also drops the deferred
    // notification because the side run is no longer terminal.
    await supervisor.steerSideSession(sideSession.id, "한 번 더 다듬어줘");

    // Main handoff turn ends; the drain must find an empty queue.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
    expect(replies.filter((entry) => entry.contextId === sideSession.id)).toEqual([]);
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

  it("appends an `extension ui answer:` log entry summarizing the user's askUserQuestion answer", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("answer log"));

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: true,
      request: {
        id: "ui-form",
        sessionId: session.id,
        method: "askUserQuestion",
        title: "Confirm",
        questions: [
          {
            id: "commit-confirm",
            type: "radio",
            prompt: "Continue?",
            options: [
              { value: "commit", label: "Commit" },
              { value: "stop", label: "Stop and review" },
            ],
          },
        ],
        createdAt: "2026-05-01T00:00:00.000Z",
      },
    });
    await settle();

    await supervisor.answerExtensionUi(session.id, "ui-form", { value: { "commit-confirm": "stop" } });

    const updated = supervisor.get(session.id)!;
    expect(runtime.handle?.extensionUiAnswers).toEqual([{ requestId: "ui-form", value: { value: { "commit-confirm": "stop" } } }]);
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.logs.includes("extension ui answer: Stop and review")).toBe(true);
  });

  it("does not append an answer log when the user cancels an extension UI request", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("cancel answer"));

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: true,
      request: { id: "ui-cancel", sessionId: session.id, method: "input", prompt: "Need input", createdAt: "2026-05-01T00:00:00.000Z" },
    });
    await settle();

    await supervisor.answerExtensionUi(session.id, "ui-cancel", { cancelled: true });

    const updated = supervisor.get(session.id)!;
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.logs.some((line) => line.startsWith("extension ui answer:"))).toBe(false);
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

  it("lists slash commands from the attached runtime handle", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("slash commands"));
    runtime.handle!.slashCommands = [
      { name: "deploy", description: "Deploy", source: "extension" },
      { name: "deploy", description: "Duplicate", source: "extension" },
      { name: "  skill:context7-cli  ", description: "  Docs  ", source: "skill" },
    ];

    await expect(supervisor.listSlashCommands(session.id)).resolves.toEqual([
      { name: "deploy", description: "Deploy", source: "extension" },
      { name: "skill:context7-cli", description: "Docs", source: "skill" },
    ]);
  });

  it("falls back to the main runtime command catalog when the session handle is missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), undefined, { mainRuntime });
    await supervisor.load();
    const session = await supervisor.create(context("slash commands"));
    await supervisor.prewarmMainAgent("/tmp/project");
    mainRuntime.handle!.slashCommands = [{ name: "deploy", description: "Deploy", source: "extension" }];
    (supervisor as unknown as { runtimeHandles: Map<string, RuntimeSessionHandle> }).runtimeHandles.delete(session.id);

    await expect(supervisor.listSlashCommands(session.id)).resolves.toEqual([
      { name: "deploy", description: "Deploy", source: "extension" },
    ]);
  });

  it("returns an empty slash command list when the runtime handle is missing and no fallback is available", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("slash commands"));
    runtime.handle = undefined;

    await expect(supervisor.listSlashCommands(session.id)).resolves.toEqual([]);
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

class DeferredPrewarmRuntime implements AgentRuntime {
  handle?: ManualHandle;
  createCalls = 0;
  prewarmCalls = 0;
  private resolvePrewarm?: () => void;

  prewarm = async (options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> => {
    this.prewarmCalls += 1;
    const handle = new ManualHandle(options.sessionId ?? "manual");
    this.handle = handle;
    return new Promise<RuntimeSessionHandle>((resolve) => {
      this.resolvePrewarm = () => resolve(handle);
    });
  };

  resolvePendingPrewarm(): void {
    this.resolvePrewarm?.();
    this.resolvePrewarm = undefined;
  }

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.createCalls += 1;
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return this.handle;
  }
}

class ManualRuntime implements AgentRuntime {
  handle?: ManualHandle;
  createCalls = 0;
  thinkingLevels: string[] = [];
  prewarmCalls = 0;
  prewarmOptions: Array<{ cwd?: string; sessionId?: string }> = [];
  prewarm?: (options: { cwd?: string; sessionId?: string }) => Promise<RuntimeSessionHandle>;

  constructor(options: { supportsPrewarm?: boolean } = {}) {
    if (options.supportsPrewarm) {
      this.prewarm = async (prewarmOptions) => {
        this.prewarmCalls += 1;
        this.prewarmOptions.push(prewarmOptions);
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

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevels.push(level);
  }
}

class ManualHandle implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  followUps: BuiltPrompt[] = [];
  interrupts: BuiltPrompt[] = [];
  bootstrapInjections: Array<{ user: string; assistant: string }> = [];
  extensionUiAnswers: Array<{ requestId: string; value: unknown }> = [];
  thinkingLevels: string[] = [];
  slashCommands: RuntimeSlashCommand[] = [];
  constructor(readonly id: string) {}
  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.followUps.push(prompt);
  }
  async interrupt(prompt: BuiltPrompt): Promise<void> {
    this.interrupts.push(prompt);
  }
  steers: string[] = [];
  steerOutcome: { handledSynchronously: boolean } = { handledSynchronously: false };
  aborts = 0;
  async steer(text: string): Promise<{ handledSynchronously: boolean }> {
    this.steers.push(text);
    return this.steerOutcome;
  }
  async abort(): Promise<void> {
    this.aborts += 1;
  }
  async answerExtensionUi(requestId: string, value: unknown): Promise<void> {
    this.extensionUiAnswers.push({ requestId, value });
  }
  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    this.bootstrapInjections.push(messages);
  }
  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevels.push(level);
  }
  listSlashCommands(): RuntimeSlashCommand[] {
    return this.slashCommands;
  }
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
