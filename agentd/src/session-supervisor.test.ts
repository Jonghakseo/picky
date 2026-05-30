import { appendFile, mkdir, mkdtemp, readFile, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickyContextPacket, PickyMainAgentState } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import type { BuiltPrompt } from "./prompt-builder.js";
import type { AgentRuntime, AnswerExtensionUiOptions, RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeSessionHandle, RuntimeSlashCommand, ThinkingLevel } from "./runtime/types.js";
import type { TaskRouteDecision, TaskRouter } from "./task-router.js";
import { ORPHANED_CHILD_SESSION_RECOVERY_LOG, ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY, SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

const context = (text: string): PickyContextPacket => ({
  id: `context-${text}`,
  source: "text",
  capturedAt: "2026-05-01T00:00:00.000Z",
  transcript: text,
  cwd: "/tmp/project",
  screenshots: [],
  inkMarks: [],
  warnings: [],
});

const contextWithPiSessionFile = (text: string, sessionFilePath: string): PickyContextPacket => ({
  ...context(text),
  transcript: `${text}\n\n## Source Pi session\n- CWD: /tmp/project\n- Session file: ${sessionFilePath}\n`,
});

describe("SessionSupervisor", () => {
  it("creates multiple mock sessions concurrently", async () => {
    const supervisor = await makeSupervisor();
    const [first, second] = await Promise.all([supervisor.create(context("first")), supervisor.create(context("second"))]);
    expect(first.id).not.toBe(second.id);
    expect(supervisor.list()).toHaveLength(2);
  });

  it("records archivedAt timestamp when a session is archived", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    const session = await supervisor.create(context("test archivedAt"));

    const before = Date.now();
    const archived = await supervisor.setSessionArchived(session.id, true);
    const after = Date.now();

    expect(archived.archived).toBe(true);
    expect(archived.archivedAt).toBeDefined();
    const ts = new Date(archived.archivedAt!).getTime();
    expect(ts).toBeGreaterThanOrEqual(before);
    expect(ts).toBeLessThanOrEqual(after);
  });

  it("clears archivedAt when a session is unarchived", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    const session = await supervisor.create(context("test unarchive"));

    await supervisor.setSessionArchived(session.id, true);
    const unarchived = await supervisor.setSessionArchived(session.id, false);

    expect(unarchived.archived).toBe(false);
    expect(unarchived.archivedAt).toBeUndefined();
  });

  it("rejects followUp/steer/abort on an archived session so external callers (e.g. picky CLI) cannot steer hidden Pickles", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-archived-guard-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("archived guard"));
    await supervisor.setSessionArchived(session.id, true);

    await expect(supervisor.followUp(session.id, "more please")).rejects.toThrow(/Cannot follow up an archived session/);
    await expect(supervisor.steer(session.id, "please change direction")).rejects.toThrow(/Cannot steer an archived session/);
    await expect(supervisor.abort(session.id)).rejects.toThrow(/Cannot abort an archived session/);
  });

  it("keeps a session cancelled when abort happens while runtime create is pending", async () => {
    const runtime = new DeferredCreateRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pending-create-abort-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-create" });
    await supervisor.load();

    const creating = supervisor.create(context("slow create"));
    await waitUntil(() => supervisor.get("pending-create")?.status === "queued");
    await supervisor.abort("pending-create");
    expect(supervisor.get("pending-create")?.status).toBe("cancelled");

    runtime.resolveAll();
    const created = await creating;
    await settle();

    expect(created.status).toBe("cancelled");
    expect(supervisor.get("pending-create")?.status).toBe("cancelled");
    expect(runtime.handles[0]?.aborts).toBe(1);
  });

  it("keeps a session cancelled when pending runtime create rejects after abort", async () => {
    const runtime = new DeferredCreateRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pending-create-reject-after-abort-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-create-reject" });
    await supervisor.load();

    const creating = supervisor.create(context("slow create rejects"));
    await waitUntil(() => supervisor.get("pending-create-reject")?.status === "queued");
    await supervisor.abort("pending-create-reject");
    expect(supervisor.get("pending-create-reject")?.status).toBe("cancelled");

    runtime.rejectAll(new Error("runtime boot failed"));
    const created = await creating;
    await settle();

    expect(created.status).toBe("cancelled");
    expect(supervisor.get("pending-create-reject")?.status).toBe("cancelled");
    expect(supervisor.get("pending-create-reject")?.lastSummary).toBe("Cancelled");
  });

  it("queues follow-up for a selected session", async () => {
    const supervisor = await makeSupervisor();
    const session = await supervisor.create(context("initial"));
    const updated = await supervisor.followUp(session.id, "next step");
    expect(updated.status).toBe("running");
    expect(updated.logs.some((line) => line.includes("next step"))).toBe(true);
  });

  it("executes ! follow-up input as Pi user bash without starting an agent turn", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-user-bash-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Initial done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");

    const updated = await supervisor.followUp(session.id, "!pwd");
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 1);

    expect(runtime.handle!.followUps).toEqual([]);
    expect(runtime.handle!.userBashExecutions).toEqual([{ command: "pwd", excludeFromContext: false }]);
    expect(updated.status).toBe("completed");
    expect(supervisor.get(session.id)?.messages?.some((message) => message.kind === "system" && message.text?.includes("### 🖥️ pwd") && message.text.includes("✅ Completed · exit 0 · added to Pi context"))).toBe(true);
  });

  it("keeps a session cancelled when in-flight direct bash finishes after abort", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-user-bash-abort-race-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Initial done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");

    let finishBash!: () => void;
    runtime.handle!.onUserBash = async () => {
      await new Promise<void>((resolve) => { finishBash = resolve; });
    };
    const running = supervisor.followUp(session.id, "!sleep 1");
    await waitUntil(() => supervisor.get(session.id)?.status === "running" && runtime.handle!.userBashExecutions.length === 1);

    await supervisor.abort(session.id);
    expect(supervisor.get(session.id)?.status).toBe("cancelled");
    finishBash();
    await running;
    await settle();

    expect(supervisor.get(session.id)?.status).toBe("cancelled");
    expect(supervisor.get(session.id)?.lastSummary).toBe("Cancelled");
  });

  it("rejects ! follow-up input for cancelled and failed sessions", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-user-bash-terminal-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const cancelled = await supervisor.create(context("cancelled bash"));
    await supervisor.abort(cancelled.id);

    await expect(supervisor.followUp(cancelled.id, "!pwd")).rejects.toThrow(/Cannot follow up cancelled session/);
    expect(runtime.handle!.userBashExecutions).toEqual([]);

    const failed = await supervisor.create(context("failed bash"));
    runtime.handle!.emit({ type: "status", status: "failed", summary: "failed turn" });
    await waitUntil(() => supervisor.get(failed.id)?.status === "failed");

    await expect(supervisor.followUp(failed.id, "!pwd")).rejects.toThrow(/Cannot follow up failed session/);
    expect(runtime.handle!.userBashExecutions).toEqual([]);
  });

  it("updates the user bash HUD message while the command is still running", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-user-bash-live-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { userBashLiveUpdateIntervalMs: 10 });
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Initial done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");
    runtime.handle!.onUserBash = async (_handle, _command, options) => {
      options?.onOutputChunk?.("first line\n");
      await delay(30);
      options?.onOutputChunk?.("second line\n");
      await delay(30);
    };

    const running = supervisor.followUp(session.id, "!printf live");

    await waitUntil(() => supervisor.get(session.id)?.messages?.some((message) => message.kind === "system" && message.text?.includes("⏳ Running") && message.text.includes("first line")) === true);
    await waitUntil(() => supervisor.get(session.id)?.messages?.some((message) => message.kind === "system" && message.text?.includes("⏳ Running") && message.text.includes("second line")) === true);
    await running;
    const bashMessages = supervisor.get(session.id)?.messages?.filter((message) => message.kind === "system" && message.text?.includes("### 🖥️ printf live")) ?? [];
    expect(bashMessages).toHaveLength(1);
    expect(bashMessages[0]?.text).toContain("✅ Completed · exit 0 · added to Pi context");
  });

  it("executes !! steer input as hidden Pi user bash", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-hidden-user-bash-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Initial done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");

    await supervisor.steer(session.id, "!!printenv SECRET");

    expect(runtime.handle!.steerPrompts).toEqual([]);
    expect(runtime.handle!.userBashExecutions).toEqual([{ command: "printenv SECRET", excludeFromContext: true }]);
    expect(supervisor.get(session.id)?.messages?.some((message) => message.kind === "system" && message.text?.includes("### 🖥️ printenv SECRET") && message.text.includes("✅ Completed · exit 0 · hidden from Pi context"))).toBe(true);
  });

  it("projects queue updates with monotonic sequence numbers", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-queue-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    const events: Array<{ sessionId: string; steering: unknown[]; followUp: unknown[]; seq: number }> = [];
    supervisor.on("queueUpdated", (sessionId, steering, followUp, _steeringMode, _followUpMode, seq) => events.push({ sessionId, steering, followUp, seq }));

    runtime.handle!.emit({ type: "queue_update", steering: ["first"], followUp: [] });
    runtime.handle!.emit({ type: "queue_update", steering: ["first"], followUp: ["second"] });
    runtime.handle!.emit({ type: "queue_update", steering: [], followUp: ["second"] });
    await waitUntil(() => events.length === 3);

    expect(events.map((event) => event.seq)).toEqual([1, 2, 3]);
    expect(events.at(0)).toMatchObject({ sessionId: session.id, steering: [{ text: "first" }], followUp: [] });
    expect(supervisor.get(session.id)?.queuedSteers ?? []).toEqual([]);
    expect((supervisor.get(session.id)?.queuedFollowUps ?? []).map((item) => item.text)).toEqual(["second"]);
  });

  it("emits queue modes only when they change", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-mode-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    const events: Array<{ steeringMode?: string; followUpMode?: string }> = [];
    supervisor.on("queueUpdated", (_sessionId, _steering, _followUp, steeringMode, followUpMode) => {
      events.push({ ...(steeringMode ? { steeringMode } : {}), ...(followUpMode ? { followUpMode } : {}) });
    });

    runtime.handle!.emit({ type: "queue_update", steering: ["first"], followUp: [] });
    runtime.handle!.steeringMode = "all";
    runtime.handle!.emit({ type: "queue_update", steering: ["first", "second"], followUp: [] });
    runtime.handle!.emit({ type: "queue_update", steering: ["first", "second", "third"], followUp: [] });
    await waitUntil(() => events.length === 3);

    expect(events).toEqual([{}, { steeringMode: "all" }, {}]);
    expect(supervisor.get(session.id)?.steeringMode).toBe("all");
  });

  it("increments activity once per new running tool call", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-tool-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity tools"));
    const events: Array<{ summary: NonNullable<ReturnType<SessionSupervisor["get"]>>["activitySummary"]; seq: number }> = [];
    supervisor.on("activityUpdated", (_sessionId, activitySummary, seq) => events.push({ summary: activitySummary, seq }));

    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running", preview: "npm test" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running", preview: "npm test --watch" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "done" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 1 && events.length === 1);

    expect(supervisor.get(session.id)?.activitySummary).toMatchObject({ read: 0, bash: 1, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(events.map((event) => event.seq)).toEqual([1]);
  });

  it("broadcasts activitySummary via sessionActivityUpdated without an accompanying full sessionUpdated", async () => {
    // Phase 1 of the live-update slim-down: streaming tool/thinking turns previously fired a full
    // sessionUpdated (full PickyAgentSession payload) on top of every sessionActivityUpdated, which
    // doubled HUD decode/render work on busy turns. The activitySummary patch must stay disk-
    // persistent but stop emitting a session event; only the dedicated activity event is allowed.
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-no-session-update-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity no session emit"));

    const sessionEvents: PickyAgentSession[] = [];
    const activityEvents: Array<{ seq: number; summary: NonNullable<ReturnType<SessionSupervisor["get"]>>["activitySummary"] }> = [];
    supervisor.on("session", (emitted: PickyAgentSession) => sessionEvents.push(emitted));
    supervisor.on("activityUpdated", (_sessionId, summary, seq) => activityEvents.push({ seq, summary }));

    // Drive a thinking-only turn so the only patches in flight are activity + thinking preview.
    // Tool/queue paths still legitimately emit a session for their own fields and would mask the
    // assertion we care about here.
    runtime.handle!.emit({ type: "thinking_delta", delta: "reasoning step" });
    await waitUntil(() => activityEvents.length === 1);

    expect(activityEvents.map((event) => event.summary)).toEqual([{ read: 0, bash: 0, edit: 0, write: 0, thinking: 1, other: 0 }]);
    // The thinking delta itself triggers a thinkingPreview patch (which still emits a session
    // until Phase 3); the activitySummary patch is the one we are guaranteeing is silent now.
    // A full sessionUpdated for activity would push this past the single thinkingPreview emit.
    expect(sessionEvents.length).toBeLessThanOrEqual(1);
    if (sessionEvents.length === 1) {
      expect(sessionEvents[0]?.thinkingPreview).toBe("reasoning step");
    }

    // Disk persistence still mirrors the new activitySummary so reconnect/snapshot is correct.
    const persisted = await new SessionStore(dir).loadAll();
    const restored = persisted.find((entry) => entry.id === session.id);
    expect(restored?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 1, other: 0 });
  });

  it("emits a turn-local activity message at terminal turn boundary and resets it for the next turn", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-message-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity message"));
    const messages: Array<{ kind: string; activitySnapshot?: unknown }> = [];
    supervisor.on("messageAppended", (_sessionId, message) => messages.push({ kind: message.kind, activitySnapshot: message.activitySnapshot }));

    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => messages.some((message) => message.kind === "agent_activity"));

    await supervisor.followUp(session.id, "next turn");
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-2", name: "edit", status: "running" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => messages.filter((message) => message.kind === "agent_activity").length === 2);

    const activityMessages = messages.filter((message) => message.kind === "agent_activity");
    expect(activityMessages.map((message) => message.activitySnapshot)).toEqual([
      { read: 0, bash: 1, edit: 0, write: 0, thinking: 0, other: 0 },
      { read: 0, bash: 0, edit: 1, write: 0, thinking: 0, other: 0 },
    ]);
    // activitySummary tracks the live turn only, so it resets to zero once each turn commits.
    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
  });

  it("classifies read, bash, edit, write, and unknown tools in the activity summary", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-category-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity categories"));

    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "read", status: "running" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-2", name: "bash", status: "running" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-3", name: "edit", status: "running" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-4", name: "write", status: "running" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-5", name: "mcp__notion__readPage", status: "running" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.other === 1);

    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 1, bash: 1, edit: 1, write: 1, thinking: 0, other: 1 });
  });

  it("counts one thinking step per contiguous thinking run", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-thinking-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity thinking"));

    for (let index = 0; index < 5; index += 1) runtime.handle!.emit({ type: "thinking_delta", delta: `step ${index} ` });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.thinking === 1);

    expect(supervisor.get(session.id)?.activitySummary).toMatchObject({ thinking: 1 });
  });

  it("starts a new thinking step after assistant text or tool activity", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-thinking-boundary-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity thinking boundaries"));

    runtime.handle!.emit({ type: "thinking_delta", delta: "first" });
    runtime.handle!.emit({ type: "assistant_delta", delta: "answer" });
    runtime.handle!.emit({ type: "thinking_delta", delta: "second" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "read", status: "running" });
    runtime.handle!.emit({ type: "thinking_delta", delta: "third" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.thinking === 3);

    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 1, bash: 0, edit: 0, write: 0, thinking: 3, other: 0 });
  });

  it("shares monotonic sequence numbers across queue and activity updates", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-seq-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    await supervisor.create(context("activity seq"));
    const events: Array<{ type: "queue" | "activity"; seq: number }> = [];
    supervisor.on("queueUpdated", (_sessionId, _steering, _followUp, _steeringMode, _followUpMode, seq) => events.push({ type: "queue", seq }));
    supervisor.on("activityUpdated", (_sessionId, _activitySummary, seq) => events.push({ type: "activity", seq }));

    runtime.handle!.emit({ type: "queue_update", steering: ["first"], followUp: [] });
    await waitUntil(() => events.length === 1);
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    await waitUntil(() => events.length === 2);
    runtime.handle!.emit({ type: "queue_update", steering: [], followUp: ["second"] });
    await waitUntil(() => events.length === 3);

    expect(events).toEqual([{ type: "queue", seq: 1 }, { type: "activity", seq: 2 }, { type: "queue", seq: 3 }]);
  });

  it("keeps pinned sessions at zero activity without activity events", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-pinned-test-"));
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir));
    const events: unknown[] = [];
    supervisor.on("activityUpdated", (...args) => events.push(args));
    await supervisor.load();

    const pinned = await supervisor.pinPickleSession(context("pin completed source"), "Pinned source");

    expect(pinned.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(events).toEqual([]);
  });

  it("dedupes tool calls per turn and resets the live activity summary at each turn boundary", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-followup-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity follow-up"));

    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 1);

    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 0);
    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });

    await supervisor.followUp(session.id, "next turn");
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 1);

    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 0, bash: 1, edit: 0, write: 0, thinking: 0, other: 0 });
  });

  it("preserves enqueuedAt for unchanged queue items", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-queue-timestamp-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("queue timestamp"));

    runtime.handle!.emit({ type: "queue_update", steering: ["first"], followUp: [] });
    await waitUntil(() => (supervisor.get(session.id)?.queuedSteers ?? []).length === 1);
    const firstEnqueuedAt = supervisor.get(session.id)?.queuedSteers?.[0]?.enqueuedAt;
    await delay(2);
    runtime.handle!.emit({ type: "queue_update", steering: ["first", "second"], followUp: [] });
    await waitUntil(() => (supervisor.get(session.id)?.queuedSteers ?? []).length === 2);

    expect(supervisor.get(session.id)?.queuedSteers?.[0]?.enqueuedAt).toBe(firstEnqueuedAt);
    expect(supervisor.get(session.id)?.queuedSteers?.[1]?.enqueuedAt).not.toBe(firstEnqueuedAt);
  });

  it("preserves enqueuedAt for queue items that shift after a dequeue", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-queue-shift-timestamp-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("queue shift timestamp"));

    runtime.handle!.emit({ type: "queue_update", steering: ["first", "second", "third"], followUp: [] });
    await waitUntil(() => (supervisor.get(session.id)?.queuedSteers ?? []).length === 3);
    const secondEnqueuedAt = supervisor.get(session.id)?.queuedSteers?.[1]?.enqueuedAt;
    const thirdEnqueuedAt = supervisor.get(session.id)?.queuedSteers?.[2]?.enqueuedAt;
    await delay(2);

    runtime.handle!.emit({ type: "queue_update", steering: ["second", "third"], followUp: [] });
    await waitUntil(() => (supervisor.get(session.id)?.queuedSteers ?? []).length === 2);

    expect(supervisor.get(session.id)?.queuedSteers?.map((item) => ({ text: item.text, enqueuedAt: item.enqueuedAt }))).toEqual([
      { text: "second", enqueuedAt: secondEnqueuedAt },
      { text: "third", enqueuedAt: thirdEnqueuedAt },
    ]);
  });

  it("captures initial queue and modes on runtime attach", async () => {
    const runtime = new InitialQueueRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-initial-queue-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const session = await supervisor.create(context("initial queue"));

    expect(supervisor.get(session.id)?.queuedSteers?.map((item) => item.text)).toEqual(["initial steer"]);
    expect(supervisor.get(session.id)?.queuedFollowUps?.map((item) => item.text)).toEqual(["initial follow-up"]);
    expect(supervisor.get(session.id)?.steeringMode).toBe("all");
    expect(supervisor.get(session.id)?.followUpMode).toBe("all");
  });

  it("clears all queues for any clear kind and immediately broadcasts empty queue state", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-clear-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    const events: Array<{ steering: unknown[]; followUp: unknown[] }> = [];
    supervisor.on("queueUpdated", (_sessionId, steering, followUp) => events.push({ steering, followUp }));
    await runtime.handle!.steer({ text: "steer a", imagePaths: [] });
    await runtime.handle!.steer({ text: "steer b", imagePaths: [] });
    await runtime.handle!.followUp({ text: "follow a", imagePaths: [] });
    await runtime.handle!.followUp({ text: "follow b", imagePaths: [] });
    runtime.handle!.emit({ type: "queue_update", steering: ["steer a", "steer b"], followUp: ["follow a", "follow b"] });
    await waitUntil(() => (supervisor.get(session.id)?.queuedSteers ?? []).length === 2);

    await supervisor.clearQueue(session.id, "steering");
    expect(runtime.handle!.getSteeringMessages()).toEqual([]);
    expect(runtime.handle!.getFollowUpMessages()).toEqual([]);
    expect(supervisor.get(session.id)?.queuedSteers).toEqual([]);
    expect(supervisor.get(session.id)?.queuedFollowUps).toEqual([]);
    expect(events.at(-1)).toMatchObject({ steering: [], followUp: [] });

    await runtime.handle!.steer({ text: "steer c", imagePaths: [] });
    await runtime.handle!.followUp({ text: "follow c", imagePaths: [] });
    await supervisor.clearQueue(session.id, "followUp");
    expect(runtime.handle!.getSteeringMessages()).toEqual([]);
    expect(runtime.handle!.getFollowUpMessages()).toEqual([]);

    await runtime.handle!.steer({ text: "steer d", imagePaths: [] });
    await runtime.handle!.followUp({ text: "follow d", imagePaths: [] });
    await supervisor.clearQueue(session.id, "all");
    expect(runtime.handle!.getSteeringMessages()).toEqual([]);
    expect(runtime.handle!.getFollowUpMessages()).toEqual([]);
  });

  it("lists and resumes Pickle sessions created from a legacy handoff log", async () => {
    const supervisor = await makeSupervisor();
    const regular = await supervisor.create(context("regular"));
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    expect(supervisor.isPickleSession(pickle.id)).toBe(true);
    expect(supervisor.listPickleSessions().map((session) => session.id)).toEqual([pickle.id]);

    const updated = await supervisor.steerPickleSession(pickle.id, "추가로 원인도 정리해줘");
    expect(updated.lastSummary).toBe("Steering message sent");
    expect(updated.logs.some((line) => line.includes("추가로 원인도 정리해줘"))).toBe(true);
    await expect(supervisor.steerPickleSession(regular.id, "wrong target")).rejects.toThrow(/not a Pickle/);
  });

  it("duplicates a Pickle session by snapshotting its Pi transcript and resuming the copy", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-duplicate-"));
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const sourceFilePath = join(dir, "source-pi.jsonl");
    await writeFile(sourceFilePath, '{"type":"user_text","text":"hello"}\n{"type":"agent_text","text":"world"}\n');
    const source = await supervisor.pinPickleSession(contextWithPiSessionFile("original work", sourceFilePath), "Original work");

    const fork = await supervisor.duplicatePickleSession(source.id);

    expect(fork.id).not.toBe(source.id);
    expect(fork.title).toBe("(copy) Original work");
    expect(fork.status).toBe("waiting_for_input");
    expect(fork.cwd).toBe("/tmp/project");
    expect(fork.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(fork.tools).toEqual([]);
    expect(fork.artifacts).toEqual([]);
    expect(fork.changedFiles).toEqual([]);
    expect(supervisor.isPickleSession(fork.id)).toBe(true);

    expect(runtime.resumeCalls).toHaveLength(1);
    const [resume] = runtime.resumeCalls;
    expect(resume?.sessionId).toBe(fork.id);
    expect(resume?.cwd).toBe("/tmp/project");
    expect(resume?.sessionFilePath).not.toBe(sourceFilePath);
    expect(resume?.sessionFilePath?.endsWith(`${fork.id}.jsonl`)).toBe(true);
    expect(fork.piSessionFilePath).toBe(resume?.sessionFilePath);

    const copied = await readFile(resume!.sessionFilePath, "utf8");
    const original = await readFile(sourceFilePath, "utf8");
    expect(copied).toBe(original);
  });

  it("copies the source Pickle session's message history and notify-on-completion preference", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-duplicate-history-"));
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const sourceFilePath = join(dir, "history-pi.jsonl");
    await writeFile(sourceFilePath, '{"hello":1}\n');
    const source = await supervisor.createPickleFromHandoff(
      context("history source"),
      { title: "History source", instructions: "Investigate" },
    );
    // Emit the diagnostic log Pi normally fires once the runtime binds, so the supervisor
    // captures piSessionFilePath the same way it would in production.
    runtime.handle!.emit({ type: "log", line: `pi session: ${sourceFilePath}` });
    await waitUntil(() => supervisor.get(source.id)?.piSessionFilePath === sourceFilePath);
    runtime.handle!.emit({ type: "assistant_delta", delta: "step one" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => (supervisor.get(source.id)?.messages ?? []).some((message) => message.kind === "agent_text"));
    await supervisor.setNotifyMainOnCompletion(source.id, false);

    const fork = await supervisor.duplicatePickleSession(source.id);

    const sourceMessages = supervisor.get(source.id)?.messages ?? [];
    expect(sourceMessages.length).toBeGreaterThan(0);
    expect((fork.messages ?? []).map((message) => ({ id: message.id, kind: message.kind, text: message.text }))).toEqual(
      sourceMessages.map((message) => ({ id: message.id, kind: message.kind, text: message.text })),
    );
    expect(fork.notifyMainOnCompletion).toBe(false);
  });

  it("snapshots a streaming source by trimming a partial trailing JSONL line before resuming", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-duplicate-streaming-"));
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const sourceFilePath = join(dir, "streaming-pi.jsonl");
    // Simulate a Pi JSONL that is being written mid-line: two complete records plus a partial
    // third line that has not yet flushed its trailing newline.
    await writeFile(sourceFilePath, '{"line":1}\n{"line":2}\n{"line":3,"partial":');
    const source = await supervisor.pinPickleSession(contextWithPiSessionFile("streaming source", sourceFilePath), "Streaming");

    const fork = await supervisor.duplicatePickleSession(source.id);

    const copyPath = runtime.resumeCalls[0]?.sessionFilePath;
    expect(copyPath).toBeTruthy();
    const copied = await readFile(copyPath!, "utf8");
    expect(copied).toBe('{"line":1}\n{"line":2}\n');
    expect(fork.title).toBe("(copy) Streaming");
  });

  it("throws when the source Pickle session has no Pi transcript on disk", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-duplicate-missing-"));
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const source = await supervisor.createPickleFromHandoff(context("no transcript"), { title: "No transcript", instructions: "Investigate" });

    await expect(supervisor.duplicatePickleSession(source.id)).rejects.toThrow(/no Pi session file to duplicate/);
  });

  it("throws when the runtime cannot resume sessions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-duplicate-no-resume-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const source = await supervisor.createPickleFromHandoff(
      contextWithPiSessionFile("resume unsupported", "/tmp/whatever.jsonl"),
      { title: "Resume unsupported", instructions: "Investigate" },
    );

    await expect(supervisor.duplicatePickleSession(source.id)).rejects.toThrow(/Runtime cannot duplicate sessions/);
  });

  it("prewarms an empty manual Pickle session and waits for the first instruction", async () => {
    const runtime = new ManualRuntime({ supportsPrewarm: true, assistantRunMetadata: { model: "anthropic/claude-opus-4-7", thinkingLevel: "high" } });
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const session = await supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined, cwd: "  /tmp/manual-project  " });

    expect(runtime.createCalls).toBe(0);
    expect(runtime.prewarmCalls).toBe(1);
    expect(runtime.prewarmOptions).toEqual([{ cwd: "/tmp/manual-project", sessionId: session.id }]);
    expect(session.status).toBe("waiting_for_input");
    expect(session.cwd).toBe("/tmp/manual-project");
    expect(session.title).toBe("New Pickle · manual-project");
    expect(session.notifyMainOnCompletion).toBe(false);
    expect(session.currentAssistantRun).toEqual({ model: "anthropic/claude-opus-4-7", thinkingLevel: "high" });
    expect(supervisor.isPickleSession(session.id)).toBe(true);
    expect(supervisor.listPickleSessions().map((pickle) => pickle.id)).toEqual([session.id]);
    expect(session.logs).toContain("manual pickle: waiting for first instruction");

    const steered = await supervisor.steerPickleSession(session.id, "첫 작업 시작해줘");
    expect(steered.status).toBe("running");
    expect(runtime.handle?.interrupts).toEqual([]);
    expect(runtime.handle?.steers).toEqual(["첫 작업 시작해줘"]);
  });

  it("accepts the first empty Pickle instruction while prewarm is still pending", async () => {
    const runtime = new DeferredPrewarmRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-early-input-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "empty-pickle-early-input" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined });
    await waitForPendingPrewarm(runtime);

    const steering = supervisor.steerPickleSession("empty-pickle-early-input", "첫 작업 시작해줘");
    await settle();
    expect(runtime.handle?.steers).toEqual([]);

    runtime.resolvePendingPrewarm();
    const [created, steered] = await Promise.all([creating, steering]);
    await settle();

    expect(created.id).toBe("empty-pickle-early-input");
    expect(steered.status).toBe("running");
    expect(runtime.handle?.steers).toEqual(["첫 작업 시작해줘"]);
    expect(supervisor.get("empty-pickle-early-input")?.logs.some((line) => line === "steer: 첫 작업 시작해줘")).toBe(true);
  });

  it("ignores pending steer when abort happens before prewarm resolves", async () => {
    const runtime = new DeferredPrewarmRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-pending-steer-abort-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-steer-abort" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined });
    await waitForPendingPrewarm(runtime);

    const steering = supervisor.steerPickleSession("pending-steer-abort", "do not run");
    await settle();
    await supervisor.abort("pending-steer-abort");

    const steered = await steering;
    runtime.resolvePendingPrewarm();
    const created = await creating;
    await settle();

    expect(steered.status).toBe("cancelled");
    expect(created.status).toBe("cancelled");
    expect(supervisor.get("pending-steer-abort")?.status).toBe("cancelled");
    expect(runtime.handle?.steers).toEqual([]);
    expect(runtime.handle?.aborts).toBe(1);
  });

  it("ignores pending follow-up when abort happens before prewarm resolves", async () => {
    const runtime = new DeferredPrewarmRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-pending-followup-abort-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-followup-abort" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined });
    await waitForPendingPrewarm(runtime);

    const following = supervisor.followUp("pending-followup-abort", "do not follow");
    await settle();
    await supervisor.abort("pending-followup-abort");

    const followed = await following;
    runtime.resolvePendingPrewarm();
    await creating;
    await settle();

    expect(followed.status).toBe("cancelled");
    expect(supervisor.get("pending-followup-abort")?.status).toBe("cancelled");
    expect(runtime.handle?.followUps).toEqual([]);
  });

  it("ignores pending user bash when abort happens before prewarm resolves", async () => {
    const runtime = new DeferredPrewarmRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-pending-bash-abort-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-bash-abort" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined });
    await waitForPendingPrewarm(runtime);

    const bash = supervisor.followUp("pending-bash-abort", "!pwd");
    await settle();
    await supervisor.abort("pending-bash-abort");

    const result = await bash;
    runtime.resolvePendingPrewarm();
    await creating;
    await settle();

    expect(result.status).toBe("cancelled");
    expect(supervisor.get("pending-bash-abort")?.status).toBe("cancelled");
    expect(runtime.handle?.userBashExecutions).toEqual([]);
  });

  it("settles pending input with failed state when prewarm rejects", async () => {
    const runtime = new DeferredPrewarmRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-pending-prewarm-reject-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-prewarm-reject" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined });
    await waitForPendingPrewarm(runtime);
    const steering = supervisor.steerPickleSession("pending-prewarm-reject", "will fail");
    await settle();

    runtime.rejectPendingPrewarm(new Error("prewarm exploded"));

    await expect(creating).rejects.toThrow(/prewarm exploded/);
    const steered = await steering;
    expect(steered.status).toBe("failed");
    expect(steered.lastSummary).toBe("Failed to start runtime: prewarm exploded");
    expect(supervisor.get("pending-prewarm-reject")?.logs).toContain("Failed to start runtime: prewarm exploded");
  });

  it("applies pending create completion patch before pending steering patch", async () => {
    const runtime = new DeferredCreateRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pending-create-steer-order-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-create-steer-order" });
    await supervisor.load();
    const summaries: string[] = [];
    supervisor.on("session", (session: PickyAgentSession) => {
      if (session.id === "pending-create-steer-order" && session.lastSummary) summaries.push(session.lastSummary);
    });

    const creating = supervisor.create(context("slow create for steer"));
    await waitUntil(() => supervisor.get("pending-create-steer-order")?.status === "queued");
    const steering = supervisor.steer("pending-create-steer-order", "adjust while starting");
    await settle();
    expect(runtime.handles[0]?.steers).toEqual([]);

    runtime.resolveAll();
    await Promise.all([creating, steering]);
    await settle();

    expect(runtime.handles[0]?.steers).toEqual(["adjust while starting"]);
    expect(summaries.indexOf("Started")).toBeGreaterThanOrEqual(0);
    expect(summaries.indexOf("Steering message sent")).toBeGreaterThan(summaries.indexOf("Started"));
    expect(supervisor.get("pending-create-steer-order")?.lastSummary).toBe("Steering message sent");
  });

  it("preserves consecutive pending inputs after prewarm resolves", async () => {
    const runtime = new DeferredPrewarmRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-pending-consecutive-inputs-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "pending-consecutive-inputs" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession({ ...context("manual"), source: "system", transcript: undefined });
    await waitForPendingPrewarm(runtime);

    const first = supervisor.steerPickleSession("pending-consecutive-inputs", "first");
    const second = supervisor.followUp("pending-consecutive-inputs", "second");
    await settle();
    runtime.resolvePendingPrewarm();
    await Promise.all([creating, first, second]);
    await settle();

    expect(runtime.handle?.steers).toEqual(["first"]);
    expect(runtime.handle?.followUps.map((prompt) => prompt.text)).toEqual(["second"]);
    expect(userTexts(supervisor.get("pending-consecutive-inputs"))).toEqual(["first", "second"]);
  });

  it("queues active Pickle-session steering without interrupting current work", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-steer-queue-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "Pickle work", instructions: "Investigate" });

    runtime.handle!.isStreaming = true;
    runtime.handle?.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running", preview: "sleep 50" });
    await waitUntil(() => supervisor.get(session.id)?.tools[0]?.status === "running");

    const steered = await supervisor.steerPickleSession(session.id, "아니다 10초");

    expect(runtime.handle?.interrupts).toEqual([]);
    expect(runtime.handle?.steers).toEqual(["아니다 10초"]);
    expect(steered.status).toBe("running");
    expect(steered.lastSummary).toBe("Steering message sent");
    expect(steered.tools[0]).toMatchObject({ toolCallId: "tool-1", status: "running", preview: "sleep 50" });
    expect(steered.queuedSteers?.map((item) => item.text)).toEqual(["아니다 10초"]);
  });

  it("falls back to queued steer for active Pickle sessions when interrupt is unavailable", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-steer-fallback-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "Pickle work", instructions: "Investigate" });
    (runtime.handle as unknown as { interrupt?: undefined }).interrupt = undefined;

    const steered = await supervisor.steerPickleSession(session.id, "기존 큐 방식");

    expect(runtime.handle?.interrupts).toEqual([]);
    expect(runtime.handle?.steers).toEqual(["기존 큐 방식"]);
    expect(steered.status).toBe("running");
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
    await supervisor.create(pointerContext);
    const emitted: unknown[] = [];
    supervisor.on("pointerOverlayRequested", (request) => emitted.push(request));

    const result = await supervisor.requestPointerOverlay({ x: -20, y: 900, label: "target" });

    expect(emitted).toHaveLength(1);
    expect(result.request).toMatchObject({
      contextId: pointerContext.id,
      screenId: "screen1",
      x: 0,
      y: 800,
      clamped: true,
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
    await supervisor.create({
      ...context("point here"),
      screenshots: [{ id: "shot-3", label: "screen 3", path: imagePath, screenId: "screen3", bounds: { x: 0, y: 0, width: 1728, height: 1117 } }],
    });

    const result = await supervisor.requestPointerOverlay({ screenId: "screen3", x: 405, y: 180 });

    expect(result.request).toMatchObject({
      x: 405,
      y: 180,
      screenshotSize: { width: 1280, height: 827 },
      screenBounds: { x: 0, y: 0, width: 1728, height: 1117 },
    });
  });

  it("does not append pointer hints to visible Pickle prompts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new RecordingRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    await supervisor.create(context("direct visual task"));
    await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate" });

    expect(runtime.creates[0].prompt.text).not.toContain("## Picky visual pointer overlay");
    expect(runtime.creates[0].prompt.text).not.toContain("sourceSessionId");
    expect(runtime.creates[1].prompt.text).toContain("# Picky Pickle task");
    expect(runtime.creates[1].prompt.text).not.toContain("## Picky visual pointer overlay");
    expect(runtime.creates[1].prompt.text).not.toContain("sourceSessionId");
  });

  it("uses the handoff cwd override for Pickle session metadata and runtime cwd", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new RecordingRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate", cwd: "  /tmp/override-project  " });

    expect(pickle.cwd).toBe("/tmp/override-project");
    expect(pickle.logs).toContain("Picky handoff cwd: /tmp/override-project");
    expect(runtime.creates[0].options.cwd).toBe("/tmp/override-project");
  });

  it("routes Pickle-session follow-ups through the follow-up queue", async () => {
    const supervisor = await makeSupervisor();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    const result = await supervisor.followUp(pickle.id, "추가로 원인도 정리해줘", context("follow-up"));
    await settle();

    const updated = supervisor.get(pickle.id)!;
    expect(result.lastSummary).toBe("Follow-up queued");
    expect(updated.logs.some((line: string) => line === "follow-up: 추가로 원인도 정리해줘")).toBe(true);
    expect((updated.queuedFollowUps ?? []).map((item) => item.text)).toEqual(["추가로 원인도 정리해줘"]);
    expect(updated.queuedSteers ?? []).toEqual([]);
  });

  it("cancels a pending extension UI question before sending a follow-up", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-followup-cancel-ui-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("pending follow-up"));

    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-follow", sessionId: session.id, method: "input", prompt: "Need input", createdAt: "2026-05-01T00:00:00.000Z" } });
    await waitUntil(() => supervisor.get(session.id)?.pendingExtensionUiRequest?.id === "ui-follow");

    await supervisor.followUp(session.id, "continue instead");
    await settle();

    const updated = supervisor.get(session.id)!;
    expect(runtime.handle?.extensionUiAnswers).toEqual([{ requestId: "ui-follow", value: { cancelled: true }, options: { ignoreUnknown: true } }]);
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.messages?.find((message) => message.id === "ui-follow")?.cancelledAt).toBeDefined();
    expect(runtime.handle?.followUps.map((prompt) => prompt.text)).toContain("continue instead");
  });

  it("keeps follow-up flowing when the pending extension UI dialog is already stale on the runtime side", async () => {
    // Regression for the case where supervisor.state.pendingExtensionUiRequest has
    // an id the bridge no longer knows about (turn completed, runtime resume,
    // timeout, etc.). Previously the cleanup call threw "Unknown extension UI
    // request" and supervisor.followUp surfaced it as command failed, so the
    // user's chat message disappeared without ever reaching the runtime.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-followup-stale-ui-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("pending stale follow-up"));

    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-stale", sessionId: session.id, method: "confirm", prompt: "Confirm?", createdAt: "2026-05-01T00:00:00.000Z" } });
    await waitUntil(() => supervisor.get(session.id)?.pendingExtensionUiRequest?.id === "ui-stale");
    runtime.handle!.stalePendingRequestIds.add("ui-stale");

    await expect(supervisor.followUp(session.id, "continue anyway")).resolves.toBeDefined();
    await settle();

    const updated = supervisor.get(session.id)!;
    expect(runtime.handle?.extensionUiAnswers).toEqual([{ requestId: "ui-stale", value: { cancelled: true }, options: { ignoreUnknown: true } }]);
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.messages?.find((message) => message.id === "ui-stale")?.cancelledAt).toBeDefined();
    expect(runtime.handle?.followUps.map((prompt) => prompt.text)).toContain("continue anyway");
  });

  it("clears a pending extension UI request when the runtime turn completes", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-pending-ui-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("terminal pending ui"));

    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-terminal", sessionId: session.id, method: "confirm", prompt: "Confirm?", createdAt: "2026-05-01T00:00:00.000Z" } });
    await waitUntil(() => supervisor.get(session.id)?.pendingExtensionUiRequest?.id === "ui-terminal" && supervisor.get(session.id)?.messages?.some((message) => message.id === "ui-terminal") === true);

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed" && supervisor.get(session.id)?.pendingExtensionUiRequest === undefined);

    const updated = supervisor.get(session.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.messages?.find((message) => message.id === "ui-terminal")?.cancelledAt).toBeDefined();
  });

  it("cancels a pending extension UI question before steering", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-steer-cancel-ui-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("pending steer"));

    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-steer", sessionId: session.id, method: "input", prompt: "Need input", createdAt: "2026-05-01T00:00:00.000Z" } });
    await waitUntil(() => supervisor.get(session.id)?.pendingExtensionUiRequest?.id === "ui-steer");

    await supervisor.steer(session.id, "do this instead");

    const updated = supervisor.get(session.id)!;
    expect(runtime.handle?.extensionUiAnswers).toEqual([{ requestId: "ui-steer", value: { cancelled: true }, options: { ignoreUnknown: true } }]);
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.messages?.find((message) => message.id === "ui-steer")?.cancelledAt).toBeDefined();
    expect(runtime.handle?.interrupts).toEqual([]);
    expect(runtime.handle?.steers).toEqual(["do this instead"]);
  });

  it("prefers the runtime status finalAnswer over the streamed accumulator so reports do not include intermediate ReAct turns", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("multi-turn"), { title: "멀티턴 조사", instructions: "Investigate" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 중입니다." });
    runtime.handle?.emit({ type: "assistant_delta", delta: "계속 조사 중입니다." });
    runtime.handle?.emit({ type: "assistant_delta", delta: "최종 답변입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "최종 답변입니다." });
    await settle();

    const completed = supervisor.get(pickle.id)!;
    expect(completed.status).toBe("completed");
    expect(completed.finalAnswer).toBe("최종 답변입니다.");
    expect(completed.finalAnswer).not.toContain("조사 중입니다.");
  });

  it("marks completed Pickle sessions as running when they are steered", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.finalAnswer).toBe("조사 완료입니다.");

    const updated = await supervisor.steerPickleSession(pickle.id, "추가로 원인도 정리해줘");

    expect(runtime.handle?.steers).toEqual(["추가로 원인도 정리해줘"]);
    expect(updated.status).toBe("running");
    expect(updated.finalAnswer).toBeUndefined();
    expect(updated.lastSummary).toBe("Steering message sent");
  });

  it("restores a terminal Pickle session if runtime steer throws during revival", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-steer-error-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => supervisor.get(pickle.id)?.status === "completed");
    const completed = supervisor.get(pickle.id)!;
    runtime.handle!.onSteer = () => { throw new Error("Pi SDK steer failed"); };

    await expect(supervisor.steerPickleSession(pickle.id, "다시 시도해줘")).rejects.toThrow("Pi SDK steer failed");

    expect(supervisor.get(pickle.id)).toMatchObject({
      status: completed.status,
      lastSummary: completed.lastSummary,
      finalAnswer: completed.finalAnswer,
    });
  });

  it("passes follow-up context and screenshot image paths to the runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-follow-up-context-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    const followUpContext: PickyContextPacket = {
      ...context("look here"),
      id: "context-follow-up-visual",
      selectedText: "selected follow-up snippet",
      screenshots: [
        { id: "screenshot-1", label: "Main display", path: "/tmp/picky-follow-up.png", screenId: "main", isCursorScreen: true },
      ],
    };

    await supervisor.followUp(session.id, "use this screenshot", followUpContext);

    expect(runtime.handle?.followUps).toHaveLength(1);
    expect(runtime.handle?.followUps[0]?.text).toContain("## User follow-up\n- Source: text\n\nuse this screenshot");
    expect(runtime.handle?.followUps[0]?.text).toContain("## Captured context");
    expect(runtime.handle?.followUps[0]?.text).toContain("selected follow-up snippet");
    expect(runtime.handle?.followUps[0]?.imagePaths).toEqual(["/tmp/picky-follow-up.png"]);
  });

  it("passes steer context and screenshot image paths to the runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("initial"));
    const steerContext: PickyContextPacket = {
      ...context("look here"),
      id: "context-steer-visual",
      selectedText: "selected snippet",
      screenshots: [
        { id: "screenshot-1", label: "Main display", path: "/tmp/picky-steer.png", screenId: "main", isCursorScreen: true },
      ],
    };

    await supervisor.steer(session.id, "use this screenshot", steerContext);

    expect(runtime.handle?.steerPrompts).toHaveLength(1);
    expect(runtime.handle?.steerPrompts[0]?.text).toContain("## User steering instruction\n- Source: text\n\nuse this screenshot");
    expect(runtime.handle?.steerPrompts[0]?.text).toContain("## Captured context");
    expect(runtime.handle?.steerPrompts[0]?.text).toContain("selected snippet");
    expect(runtime.handle?.steerPrompts[0]?.imagePaths).toEqual(["/tmp/picky-steer.png"]);
  });

  // Regression for the `/diff-review` (and any other Pi `pi.registerCommand` slash command) HUD
  // spinner: PiSdkRuntimeSession.maybeEmitImmediateCompletion synthesizes a `completed` runtime
  // status when Pi handles a slash command synchronously inside `session.prompt()`, and reports
  // back via `RuntimeSteerResult.handledSynchronously`. Previously `steer()` then unconditionally
  // re-patched to `running`, leaving the HUD card stuck on the loading state forever.
  it("keeps a Pickle session terminal when steer reports handledSynchronously (slash command)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");

    // Replay PiSdkRuntimeSession's behaviour for slash commands: signal `handledSynchronously` and
    // (optionally) the synthetic `completed` status emit. The supervisor must NOT then resurrect
    // the session into `running`.
    runtime.handle!.steerOutcome = { handledSynchronously: true };

    const updated = await supervisor.steerPickleSession(pickle.id, "/diff-review");

    expect(runtime.handle?.steers).toEqual(["/diff-review"]);
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).not.toBe("Steering message sent");
    expect(updated.logs).toContain("steer: /diff-review");
  });

  it("keeps a running Pickle session running when /name is handled without an agent turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "running", summary: "Still working" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Still working");

    runtime.handle!.steerOutcome = { handledSynchronously: true };
    runtime.handle!.onSteer = (handle) => {
      handle.emit({ type: "session_info", name: "새 세션 이름" });
      handle.emit({ type: "status", status: "completed", summary: "Session renamed to 새 세션 이름", noTurnRan: true, preserveSessionState: true });
    };

    const updated = await supervisor.steerPickleSession(pickle.id, "/name 새 세션 이름");
    await settle();

    expect(updated.status).toBe("running");
    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.title).toBe("새 세션 이름");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Still working");
  });

  it("ignores a stale no-turn restore status after the session was cancelled", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-noturn-abort-race-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("slash restore"));

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Initial done", finalAnswer: "done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");
    await supervisor.steer(session.id, "/name renamed");
    await supervisor.abort(session.id);
    expect(supervisor.get(session.id)?.status).toBe("cancelled");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Session renamed", noTurnRan: true, preserveSessionState: true });
    await settle();

    expect(supervisor.get(session.id)?.status).toBe("cancelled");
    expect(supervisor.get(session.id)?.lastSummary).toBe("Cancelled");
  });

  it("resets the same Pickle card when /new replaces the underlying Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "기존 작업", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "기존 답변" });
    runtime.handle?.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running", preview: "old tool" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => (supervisor.get(pickle.id)?.messages?.length ?? 0) > 0);
    await waitUntil(() => (supervisor.get(pickle.id)?.tools.length ?? 0) > 0);
    expect(supervisor.get(pickle.id)?.messages?.length).toBeGreaterThan(0);
    expect(supervisor.get(pickle.id)?.tools.length).toBeGreaterThan(0);

    runtime.handle!.onFollowUp = (handle, prompt) => {
      if (prompt.text === "/new") void handle.newSession();
    };

    await supervisor.followUp(pickle.id, "/new");
    await settle();

    const updated = supervisor.get(pickle.id)!;
    expect(updated.id).toBe(pickle.id);
    expect(updated.title).toBe("New Pickle · project");
    expect(updated.status).toBe("waiting_for_input");
    expect(updated.lastSummary).toBe("Ready for instructions");
    expect(updated.messages).toEqual([]);
    expect(updated.logs).toEqual([]);
    expect(updated.tools).toEqual([]);
    expect(updated.artifacts).toEqual([]);
    expect(updated.changedFiles).toEqual([]);
    expect(updated.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(updated.piSessionFilePath).toBe("/tmp/manual-new-session-1.jsonl");
  });

  it("resets live turn activity counters when /new replaces the underlying Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-replaced-activity-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "기존 작업", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "tool", toolCallId: "tool-read", name: "read", status: "running", preview: "old file" });
    await waitUntil(() => supervisor.get(pickle.id)?.activitySummary?.read === 1);
    await runtime.handle!.newSession();
    await waitUntil(() => supervisor.get(pickle.id)?.status === "waiting_for_input");

    runtime.handle?.emit({ type: "tool", toolCallId: "tool-bash", name: "bash", status: "running", preview: "ls" });
    await waitUntil(() => supervisor.get(pickle.id)?.activitySummary?.bash === 1);

    expect(supervisor.get(pickle.id)?.activitySummary).toEqual({ read: 0, bash: 1, edit: 0, write: 0, thinking: 0, other: 0 });
  });

  it("does not let in-flight old tool activity reappear after /new replaces the Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-replaced-activity-race-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "기존 작업", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "tool", toolCallId: "tool-read-race", name: "read", status: "running", preview: "old file" });
    await runtime.handle!.newSession();
    await settle();

    expect(supervisor.get(pickle.id)?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(supervisor.get(pickle.id)?.tools).toEqual([]);
  });

  it("drops stale no-turn state restores when /new replaces the underlying Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-replaced-restore-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "기존 작업", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "기존 답변" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => supervisor.get(pickle.id)?.status === "completed");
    await supervisor.steerPickleSession(pickle.id, "/name 새 이름");

    await runtime.handle!.newSession();
    await settle();

    expect(supervisor.get(pickle.id)).toMatchObject({
      status: "waiting_for_input",
      lastSummary: "Ready for instructions",
      finalAnswer: undefined,
      messages: [],
    });
  });

  it("keeps a running Pickle session running when /compact is rejected during an active turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "running", summary: "Still working" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Still working");

    runtime.handle!.isStreaming = true;
    runtime.handle!.onFollowUp = (handle) => {
      handle.emit({ type: "status", status: "completed", summary: "/compact is unavailable while the agent is running", noTurnRan: true, preserveSessionState: true });
    };

    await supervisor.followUp(pickle.id, "/compact");
    await settle();

    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Still working");
  });

  it("shows /reload loading state and settles without an agent turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");

    runtime.handle!.onFollowUp = (handle, prompt) => {
      if (prompt.text === "/reload") {
        handle.emit({ type: "status", status: "running", summary: "Reloading Pi resources…" });
        handle.emit({ type: "status", status: "completed", summary: "Pi resources reloaded", noTurnRan: true });
      }
    };
    const resourcesReloaded: string[] = [];
    supervisor.on("resourcesReloaded", (sessionId) => resourcesReloaded.push(sessionId));

    await supervisor.followUp(pickle.id, "/reload");
    await settle();

    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).toBe("Pi resources reloaded");
    expect(resourcesReloaded).toEqual([pickle.id]);
    expect(userTexts(updated)).not.toContain("/reload");
  });

  it("restores the previous state when /reload is rejected before running", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("조사 완료입니다.");

    runtime.handle!.onFollowUp = (handle, prompt) => {
      if (prompt.text === "/reload") {
        handle.emit({ type: "status", status: "completed", summary: "/reload is unavailable while the agent is running", noTurnRan: true, preserveSessionState: true });
      }
    };

    await supervisor.followUp(pickle.id, "/reload");
    await settle();

    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).toBe("조사 완료입니다.");
  });

  it("records a compact completion system message after automatic overflow compaction", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "running", summary: "Compacting after context overflow…" });
    runtime.handle?.emit({ type: "status", status: "running", summary: "Compaction completed; retrying…", compactionCompleted: true, compactionReason: "overflow" });
    await settle();

    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("running");
    expect(updated.lastSummary).toBe("Compaction completed; retrying…");
    expect((updated.messages ?? []).some((message) => message.kind === "system" && message.text === "Session compacted after context overflow")).toBe(true);
  });

  it("surfaces threshold compaction even when it starts after a completed turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "context_usage", usage: { tokens: 184_000, contextWindow: 200_000, percent: 92 } });
    runtime.handle?.emit({ type: "assistant_delta", delta: "완료 답변" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("완료 답변");
    expect(supervisor.get(pickle.id)?.contextUsage?.percent).toBe(92);

    runtime.handle?.emit({ type: "status", status: "running", summary: "Compacting session…", compactionStarted: true, compactionReason: "threshold" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Compacting session…");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, compactionReason: "threshold" });
    await waitUntil(() => supervisor.get(pickle.id)?.status === "completed" && supervisor.get(pickle.id)?.lastSummary === "Session compacted");
    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).toBe("Session compacted");
    expect((updated.messages ?? []).some((message) => message.kind === "system" && message.text === "Session compacted")).toBe(true);
    // contextUsage tokens/percent must reset to null on compactionCompleted so the
    // Pickle header drops to "?%" instead of staying pinned on the stale 92% (the
    // post-compaction count is unknown until the next model response). The contextWindow
    // is preserved so the bar can still show the model's window size.
    expect(updated.contextUsage).toEqual({ tokens: null, contextWindow: 200_000, percent: null });
  });

  it("records a compact failure system message after automatic threshold compaction fails", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "context_usage", usage: { tokens: 258_568, contextWindow: 272_000, percent: 95.06176470588235 } });
    await settle();
    runtime.handle?.emit({ type: "status", status: "completed", summary: "작업 완료" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Auto-compaction failed: Summarization failed: server overloaded", noTurnRan: true, compactionFailed: true, compactionReason: "threshold" });
    await waitUntil(() => {
      const updated = supervisor.get(pickle.id);
      return updated?.lastSummary === "Auto-compaction failed: Summarization failed: server overloaded"
        && (updated.messages ?? []).some((message) => message.kind === "system" && message.text?.startsWith("Auto-compaction failed") === true);
    });

    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).toBe("Auto-compaction failed: Summarization failed: server overloaded");
    expect(updated.contextUsage?.percent).toBe(95.06176470588235);
    expect((updated.messages ?? []).some((message) => message.kind === "system" && message.text?.startsWith("Auto-compaction failed") && message.text.includes("Summarization failed: server overloaded") && message.text.includes("258,568/272,000 tokens"))).toBe(true);
    expect((updated.messages ?? []).some((message) => message.kind === "agent_error")).toBe(false);
  });

  it("does not let late compaction completion resurrect a cancelled session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("cancelled");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, compactionReason: "threshold" });
    await settle();
    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("cancelled");
    expect((updated.messages ?? []).some((message) => message.kind === "system" && message.text === "Session compacted")).toBe(false);
  });

  it("does not let a successful /compact restore leak into a later /name", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("조사 완료입니다.");

    runtime.handle!.onFollowUp = (handle, prompt) => {
      if (prompt.text === "/compact") {
        handle.emit({ type: "status", status: "running", summary: "Compacting session…" });
        handle.emit({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true });
      }
      if (prompt.text.startsWith("/name ")) {
        handle.emit({ type: "session_info", name: "컴팩션 후 이름" });
        handle.emit({ type: "status", status: "completed", summary: "Session renamed to 컴팩션 후 이름", noTurnRan: true, preserveSessionState: true });
      }
    };

    await supervisor.followUp(pickle.id, "/compact");
    await waitUntil(() => supervisor.get(pickle.id)?.lastSummary === "Session compacted");
    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Session compacted");
    expect((supervisor.get(pickle.id)?.messages ?? []).some((message) => message.kind === "system" && message.text === "Session compacted")).toBe(true);

    await supervisor.followUp(pickle.id, "/name 컴팩션 후 이름");
    await waitUntil(() => supervisor.get(pickle.id)?.title === "컴팩션 후 이름" && supervisor.get(pickle.id)?.status === "completed");

    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.title).toBe("컴팩션 후 이름");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Session compacted");
  });

  it("restores the previous terminal state when /name is sent as a follow-up", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "조사 완료입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("조사 완료입니다.");

    runtime.handle!.onFollowUp = (handle) => {
      handle.emit({ type: "session_info", name: "완료 세션 이름" });
      handle.emit({ type: "status", status: "completed", summary: "Session renamed to 완료 세션 이름", noTurnRan: true, preserveSessionState: true });
    };

    await supervisor.followUp(pickle.id, "/name 완료 세션 이름");
    await settle();

    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.title).toBe("완료 세션 이름");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("조사 완료입니다.");
    expect(supervisor.get(pickle.id)?.finalAnswer).toBe("조사 완료입니다.");
  });

  it("preserves synchronous runtime tool events when steering a completed Pickle session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");

    runtime.handle!.onSteer = (handle) => {
      handle.emit({ type: "tool", toolCallId: "sync-tool", name: "bash", status: "running", preview: "sleep 10" });
    };

    const updated = await supervisor.steerPickleSession(pickle.id, "interrupt now");

    expect(updated.status).toBe("running");
    expect(updated.tools).toEqual([expect.objectContaining({ toolCallId: "sync-tool", name: "bash", status: "running", preview: "sleep 10" })]);
  });

  it("preserves synchronous runtime queue events when following up a completed Pickle session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");

    runtime.handle!.onFollowUp = (handle) => {
      handle.emit({ type: "queue_update", steering: ["queued steer"], followUp: ["queued follow-up"] });
    };

    const updated = await supervisor.followUp(pickle.id, "continue");
    await waitUntil(() => (supervisor.get(pickle.id)?.queuedSteers ?? []).length === 1);

    expect(updated.status).toBe("running");
    expect(supervisor.get(pickle.id)?.queuedSteers?.map((item) => item.text)).toEqual(["queued steer"]);
    expect(supervisor.get(pickle.id)?.queuedFollowUps?.map((item) => item.text)).toEqual(["queued follow-up"]);
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

  it("marks cancelled Pickle sessions as running when they are steered", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    await supervisor.abort(pickle.id);

    expect(supervisor.get(pickle.id)?.status).toBe("cancelled");

    const updated = await supervisor.steerPickleSession(pickle.id, "다시 진행해줘");

    expect(runtime.handle?.steers).toEqual(["다시 진행해줘"]);
    expect(updated.status).toBe("running");
    expect(updated.lastSummary).toBe("Steering message sent");
    expect(updated.logs).toContain("steer: 다시 진행해줘");
  });

  it("rejects cancelled Pickle-session follow-up calls", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    await supervisor.abort(pickle.id);

    await expect(supervisor.followUp(pickle.id, "follow-up 경로로 다시 진행")).rejects.toThrow(/Cannot follow up cancelled session/);
    expect(runtime.handle?.followUps).toEqual([]);
    expect(runtime.handle?.steers).toEqual([]);
  });

  it("clears stale cancelled Pickle-session output when a new steering turn starts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "취소 전 부분 답변" });
    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    await settle();

    expect(supervisor.get(pickle.id)?.status).toBe("cancelled");
    expect(supervisor.get(pickle.id)?.finalAnswer).toBe("취소 전 부분 답변");

    const resumed = await supervisor.steerPickleSession(pickle.id, "새로 다시 진행");

    expect(resumed.status).toBe("running");
    expect(resumed.finalAnswer).toBeUndefined();
    expect(resumed.thinkingPreview).toBeUndefined();

    runtime.handle?.emit({ type: "assistant_delta", delta: "재개 후 답변" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const completed = supervisor.get(pickle.id)!;
    expect(completed.status).toBe("completed");
    expect(completed.finalAnswer).toBe("재개 후 답변");
    expect(completed.finalAnswer).not.toContain("취소 전 부분 답변");
  });

  it("allows failed Pickle sessions to be steered back to running", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "status", status: "failed", summary: "Failed" });
    await settle();

    const steered = await supervisor.steerPickleSession(pickle.id, "실패 세션 재개 시도");

    expect(runtime.handle?.steers).toEqual(["실패 세션 재개 시도"]);
    expect(steered.status).toBe("running");
    expect(steered.lastSummary).toBe("Steering message sent");
    expect(steered.thinkingPreview).toBeUndefined();
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

  it("reattaches cancelled persisted Pickle sessions from Pi session files before steering", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "cancelled-with-pi-file",
      title: "Cancelled Pickle",
      status: "cancelled",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Cancelled before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
      finalAnswer: "이전 취소 답변",
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();

    expect(supervisor.isPickleSession("cancelled-with-pi-file")).toBe(true);
    expect(supervisor.get("cancelled-with-pi-file")?.status).toBe("cancelled");
    expect(supervisor.get("cancelled-with-pi-file")?.piSessionFilePath).toBe("/tmp/pi-session.jsonl");

    const updated = await supervisor.steerPickleSession("cancelled-with-pi-file", "재시작 후 다시 진행");

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/pi-session.jsonl", cwd: "/tmp/project", sessionId: "cancelled-with-pi-file" }]);
    expect(runtime.handle?.steers).toEqual(["재시작 후 다시 진행"]);
    expect(updated.status).toBe("running");
    expect(updated.finalAnswer).toBeUndefined();
    expect(updated.lastSummary).toBe("Steering message sent");
    expect(updated.logs).toContain("runtime reattached from pi session: /tmp/pi-session.jsonl");
    expect(updated.piSessionFilePath).toBe("/tmp/pi-session.jsonl");
    expect(updated.logs).toContain("steer: 재시작 후 다시 진행");
  });

  it("stores Pi session file paths as explicit session metadata", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("capture pi session metadata"));

    runtime.handle?.emit({ type: "log", line: "pi session: /tmp/explicit-pi-session.jsonl" });
    await settle();

    const updated = supervisor.get(session.id);
    expect(updated?.piSessionFilePath).toBe("/tmp/explicit-pi-session.jsonl");
    expect(updated?.logs).toContain("pi session: /tmp/explicit-pi-session.jsonl");
  });

  it("stores only the front of thinking blocks for current work", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("think through the HUD"));

    runtime.handle?.emit({ type: "thinking_delta", delta: "I need to inspect\n" });
    runtime.handle?.emit({ type: "thinking_delta", delta: "the HUD current work state." });
    await waitUntil(() => supervisor.get(session.id)?.thinkingPreview === "I need to inspect the HUD current work state.");

    expect(supervisor.get(session.id)?.thinkingPreview).toBe("I need to inspect the HUD current work state.");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(supervisor.get(session.id)?.thinkingPreview).toBeUndefined();
  });

  it("restores persisted Pickle-session markers from handoff logs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const pickle = await firstSupervisor.createPickleFromHandoff(context("persist pickle"), { title: "피클 유지", instructions: "Keep marker" });

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    expect(secondSupervisor.isPickleSession(pickle.id)).toBe(true);
    expect(secondSupervisor.listPickleSessions().map((session) => session.id)).toEqual([pickle.id]);
  });

  it("restores Pickle-session markers from manual Pickle logs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "manual-pickle-marker",
      title: "Manual Pickle",
      status: "waiting_for_input",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:00.000Z",
      logs: ["manual pickle: waiting for first instruction"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });

    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();

    expect(supervisor.isPickleSession("manual-pickle-marker")).toBe(true);
    expect(supervisor.listPickleSessions().map((session) => session.id)).toEqual(["manual-pickle-marker"]);
  });

  it("restores Pickle-session markers from handoff cwd logs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "pickle-cwd-marker",
      title: "Pickle",
      status: "blocked",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      logs: ["pi session: /tmp/pi-session.jsonl", "Picky handoff cwd: /tmp/project"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });

    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();

    expect(supervisor.isPickleSession("pickle-cwd-marker")).toBe(true);
    expect(supervisor.listPickleSessions().map((session) => session.id)).toEqual(["pickle-cwd-marker"]);
  });

  it("migrates legacy agent_report messages instead of skipping persisted sessions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sessionsDir = join(dir, "sessions");
    await mkdir(sessionsDir, { recursive: true });
    await writeFile(join(sessionsDir, "legacy-report.json"), JSON.stringify({
      id: "legacy-report",
      title: "Legacy report",
      status: "completed",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      logs: ["Picky handoff: investigate"],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "report-1", kind: "agent_report", createdAt: "2026-05-01T00:00:05.000Z", text: "legacy report body" },
      ],
    }));

    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await supervisor.load();

    expect(supervisor.get("legacy-report")?.messages?.[0]?.kind).toBe("agent_text");
    expect(supervisor.isPickleSession("legacy-report")).toBe(true);
  });

  it("pins an idle Pi handoff as a completed Pickle session without starting runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir));
    await supervisor.load();

    const pinnedContext = {
      ...context("pin completed source"),
      transcript: "## Source Pi session\n- CWD: /tmp/project\n- Session file: /tmp/source-pi-session.jsonl\n",
    };
    const pinned = await supervisor.pinPickleSession(pinnedContext, "Pinned source");

    expect(pinned.status).toBe("completed");
    expect(pinned.title).toBe("Pinned source");
    expect(pinned.lastSummary).toBe("Pinned completed Pi session");
    expect(pinned.finalAnswer).toMatch(/No Pickle run/);
    expect(pinned.notifyMainOnCompletion).toBe(false);
    expect(pinned.pinned).toBe(true);
    expect(pinned.logs).toContain("pi session: /tmp/source-pi-session.jsonl");
    expect(pinned.piSessionFilePath).toBe("/tmp/source-pi-session.jsonl");
    expect(pinned.logs.some((line) => line.startsWith("pi-extension handoff pin:"))).toBe(true);
    expect(supervisor.isPickleSession(pinned.id)).toBe(true);
  });

  it("imports the last two source Pi turns when pinning an idle Pi handoff", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pinned-source-turns-"));
    const piSessionFile = join(dir, "source-pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "first prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "first answer" }], timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:03.000Z", message: { role: "user", content: "second prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:04.000Z", message: { role: "assistant", content: [{ type: "text", text: "second answer" }], timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "u3", parentId: "a2", timestamp: "2026-05-01T00:00:05.000Z", message: { role: "user", content: "third prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a3", parentId: "u3", timestamp: "2026-05-01T00:00:06.000Z", message: { role: "assistant", content: [{ type: "text", text: "third answer" }], timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "u4", parentId: "a3", timestamp: "2026-05-01T00:00:07.000Z", message: { role: "user", content: "/handoff-to-picky pin this in Picky", timestamp: 0 } }),
    ].join("\n"));
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir));
    await supervisor.load();

    const pinned = await supervisor.pinPickleSession(contextWithPiSessionFile("pin completed source", piSessionFile), "Pinned source");

    expect(pinned.messages?.map((message) => ({ kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { kind: "user_text", text: "second prompt", originatedBy: "pi_extension" },
      { kind: "agent_text", text: "second answer", originatedBy: undefined },
      { kind: "user_text", text: "third prompt", originatedBy: "pi_extension" },
      { kind: "agent_text", text: "third answer", originatedBy: undefined },
    ]);
    expect(pinned.lastSummary).toBe("third answer");
    expect(pinned.finalAnswer).toBe("third answer");
  });

  it("captures pi session file emitted via setTimeout(0) inside prewarm before patchMainState resolves", async () => {
    // Regression: pi 0.74 populates `runtime.session.sessionFile` synchronously inside
    // createHandle, so the runtime's reportDiagnostics emit (scheduled via setTimeout(0))
    // races with the supervisor's `await patchMainState({ cwd })` and used to land before
    // attachMainHandle subscribed. The fix attaches first; this test fails if attach
    // happens after the patch I/O.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-prewarm-race-"));
    const racingMain = new RacingPrewarmRuntime("/tmp/from-prewarm.jsonl");
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir), { mainRuntime: racingMain });
    const observed: Array<{ sessionFilePath?: string; cwd?: string }> = [];
    supervisor.on("mainAgentSessionInfo", (info: { sessionFilePath?: string; cwd?: string }) => observed.push(info));
    await supervisor.load();

    await supervisor.prewarmMainAgent("/tmp/project");
    await settle();

    expect(supervisor.mainAgentSessionInfo().sessionFilePath).toBe("/tmp/from-prewarm.jsonl");
    expect(observed.some((info) => info.sessionFilePath === "/tmp/from-prewarm.jsonl")).toBe(true);
  });

  it("does not notify Picky when a local Pi session is pinned", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));
    await supervisor.load();

    await supervisor.pinPickleSession(context("pin completed source"), "Pinned source");

    expect(mainRuntime.prewarmCalls).toBe(0);
    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
    expect(replies).toEqual([]);
  });

  it("does not attach a prewarmed empty Pickle runtime after the session was cancelled", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-empty-pickle-abort-"));
    const runtime = new DeferredPrewarmRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { sessionIdFactory: () => "empty-pickle-abort" });
    await supervisor.load();

    const creating = supervisor.createEmptyPickleSession(context("manual pickle"));
    await waitForPendingPrewarm(runtime);
    await supervisor.abort("empty-pickle-abort");
    expect(supervisor.get("empty-pickle-abort")?.status).toBe("cancelled");

    runtime.resolvePendingPrewarm();
    const session = await creating;
    await settle();

    expect(session.status).toBe("cancelled");
    expect(supervisor.get("empty-pickle-abort")?.status).toBe("cancelled");
    expect(runtime.handle?.aborts).toBe(1);
    expect((supervisor as unknown as { runtimeHandles: Map<string, RuntimeSessionHandle> }).runtimeHandles.has("empty-pickle-abort")).toBe(false);
    expect(supervisor.get("empty-pickle-abort")?.logs).toEqual([]);
  });

  it("lets Pickle sessions opt out without replaying completed notifications", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate" });

    const disabled = await supervisor.setNotifyMainOnCompletion(pickle.id, false);
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "조사 완료" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(disabled.notifyMainOnCompletion).toBe(false);
    expect(mainRuntime.prewarmCalls).toBe(0);

    const enabled = await supervisor.setNotifyMainOnCompletion(pickle.id, true);
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Duplicate completed" });
    await settle();

    expect(enabled.notifyMainOnCompletion).toBe(true);
    expect(mainRuntime.prewarmCalls).toBe(0);

    await supervisor.followUp(pickle.id, "다시 확인해줘");
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "재조사 완료" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => mainRuntime.prewarmCalls === 1 && (mainRuntime.handle?.followUps.length ?? 0) === 1);

    expect(mainRuntime.prewarmCalls).toBe(1);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toContain("재조사 완료");
  });

  it("forwards Pickle completion through the bridge when the supervisor has no main runtime", async () => {
    // Regression: per-Pickle child daemons removed the in-process mainRuntime, which silently
    // broke the bell-icon "Notify on completion" because `deliverPickleCompletionToMain` would
    // return from `preparePickyCompletionDelivery` without logging or calling anything. With
    // `forwardPickleCompletionToPrimary` wired, the prebuilt prompt is handed to the Picky app
    // bridge instead.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-bridge-forward-"));
    const sideRuntime = new ManualRuntime();
    const forwarded: Array<{ sessionId: string; prompt: string; cwd?: string }> = [];
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), {
      forwardPickleCompletionToPrimary: async (request) => {
        forwarded.push(request);
      },
    });
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("bridged pickle"), { title: "Bridged Pickle", instructions: "Investigate" });

    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "Bridged answer" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => forwarded.length === 1);

    expect(forwarded).toHaveLength(1);
    expect(forwarded[0].sessionId).toBe(pickle.id);
    expect(forwarded[0].prompt).toContain("Bridged answer");
    expect(forwarded[0].prompt).toContain(`Title: ${pickle.title}`);
    // Once forwarded the supervisor must not double-notify on later terminal restatements.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(forwarded).toHaveLength(1);
  });

  it("skips forwarding when the per-Pickle bell toggle is off", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-bridge-off-"));
    const sideRuntime = new ManualRuntime();
    const forwarded: Array<{ sessionId: string }> = [];
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), {
      forwardPickleCompletionToPrimary: async (request) => {
        forwarded.push({ sessionId: request.sessionId });
      },
    });
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("silenced pickle"), { title: "Silenced", instructions: "Investigate" });
    await supervisor.setNotifyMainOnCompletion(pickle.id, false);

    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(forwarded).toEqual([]);
  });

  it("deliverMainAgentPickleCompletion forwards a child prompt to the main runtime as a Pickle completion reply", async () => {
    // Primary-daemon entrypoint for child-forwarded completions: builds no prompt itself,
    // tags the eventual quickReply as `pickleCompletion`, and lets the main handle complete
    // the turn asynchronously so the bridge ack does not block on the LLM.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-primary-relay-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    const quickReplies: Array<{ contextId: string; text: string; replyKind?: string; sessionId?: string }> = [];
    supervisor.on("quickReply", (contextId, text, metadata = {}) => quickReplies.push({ contextId, text, replyKind: metadata.replyKind, sessionId: metadata.sessionId }));

    await supervisor.deliverMainAgentPickleCompletion("child-session-id", "Pickle finished prompt body", "/tmp/project");
    await settle();

    expect(mainRuntime.prewarmCalls).toBe(1);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toBe("Pickle finished prompt body");

    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "피클이 끝났어요" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "done" });
    await settle();

    expect(quickReplies).toHaveLength(1);
    expect(quickReplies[0]).toMatchObject({ contextId: "child-session-id", replyKind: "pickleCompletion", sessionId: "child-session-id" });
    expect(quickReplies[0].text).toContain("피클이 끝났어요");
  });

  it("drops a queued Pickle completion immediately when its notification is disabled mid-queue", async () => {
    // Regression: the deferred queue's order across sibling Pickle completions is
    // non-deterministic — both RuntimeEventHandler.applyEvent microtask chains race after
    // `firstHandle.emit(completed)` and `secondHandle.emit(completed)`. When the order ended up
    // as [active, skip], drainPendingPickleCompletions delivered the active entry first, that
    // flipped mainIsProcessing back to true via followUp, and the drain loop exited before it
    // could pop the skip entry — leaving it stranded in the queue forever. setNotifyMainOnCompletion
    // now removes the disabled entry from the queue at the call site so the drain never sees it.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-disable-dequeue-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    await supervisor.route(context("main busy"));
    const mainHandle = mainRuntime.handle!;
    mainHandle.emit({ type: "status", status: "running", summary: "Main busy" });
    await settle();

    const active = await supervisor.createPickleFromHandoff(context("active pickle"), { title: "Active Pickle", instructions: "Investigate active" });
    const activeHandle = sideRuntime.handle!;
    const skip = await supervisor.createPickleFromHandoff(context("skip pickle"), { title: "Skip Pickle", instructions: "Investigate skip" });
    const skipHandle = sideRuntime.handle!;

    activeHandle.emit({ type: "assistant_delta", delta: "Active answer" });
    activeHandle.emit({ type: "status", status: "completed", summary: "Active complete" });
    skipHandle.emit({ type: "assistant_delta", delta: "Skip answer" });
    skipHandle.emit({ type: "status", status: "completed", summary: "Skip complete" });
    await waitUntil(() => (supervisor as unknown as { pendingPickleCompletions: string[] }).pendingPickleCompletions.length === 2);

    // Force the [active, skip] order regardless of how the two microtask chains finished by
    // rewriting the queue in place. The disabled entry must be discarded by the call below.
    const queue = (supervisor as unknown as { pendingPickleCompletions: string[] }).pendingPickleCompletions;
    queue.splice(0, queue.length, active.id, skip.id);

    await supervisor.setNotifyMainOnCompletion(skip.id, false);
    expect((supervisor as unknown as { pendingPickleCompletions: string[] }).pendingPickleCompletions).toEqual([active.id]);

    mainHandle.emit({ type: "status", status: "completed", summary: "Main complete", finalAnswer: "Main answer" });
    await settle();

    expect(mainHandle.followUps).toHaveLength(1);
    expect(mainHandle.followUps[0].text).toContain(active.title);
    expect(mainHandle.followUps[0].text).toContain("Active answer");
    expect((supervisor as unknown as { pendingPickleCompletions: string[] }).pendingPickleCompletions).toEqual([]);
  });

  it("continues draining Pickle completion notifications after a skipped queued item", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pickle-drain-skip-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    await supervisor.route(context("main busy"));
    const mainHandle = mainRuntime.handle!;
    mainHandle.emit({ type: "status", status: "running", summary: "Main busy" });
    await settle();

    const first = await supervisor.createPickleFromHandoff(context("first pickle"), { title: "First Pickle", instructions: "Investigate first" });
    const firstHandle = sideRuntime.handle!;
    const second = await supervisor.createPickleFromHandoff(context("second pickle"), { title: "Second Pickle", instructions: "Investigate second" });
    const secondHandle = sideRuntime.handle!;

    firstHandle.emit({ type: "assistant_delta", delta: "First answer" });
    firstHandle.emit({ type: "status", status: "completed", summary: "First complete" });
    secondHandle.emit({ type: "assistant_delta", delta: "Second answer" });
    secondHandle.emit({ type: "status", status: "completed", summary: "Second complete" });
    await waitUntil(() => (supervisor as unknown as { pendingPickleCompletions: string[] }).pendingPickleCompletions.length === 2);

    await supervisor.setNotifyMainOnCompletion(first.id, false);
    mainHandle.emit({ type: "status", status: "completed", summary: "Main complete", finalAnswer: "Main answer" });
    await settle();

    expect(mainHandle.followUps).toHaveLength(1);
    expect(mainHandle.followUps[0].text).toContain(second.title);
    expect(mainHandle.followUps[0].text).toContain("Second answer");
    expect((supervisor as unknown as { pendingPickleCompletions: string[] }).pendingPickleCompletions).toEqual([]);
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

  it("captures only the latest Pickle-session steering answer when a steered run completes", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate" });

    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "초기 답변" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    await supervisor.steerPickleSession(pickle.id, "후속 질문");
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "후속 답변" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.finalAnswer).toBe("후속 답변");
    expect(updated.finalAnswer).not.toContain("초기 답변");
  });

  it("restores persisted pinned Pickle sessions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const pinned = await firstSupervisor.pinPickleSession(context("persist pinned"), "Pinned persisted");

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await secondSupervisor.load();

    expect(secondSupervisor.get(pinned.id)?.status).toBe("completed");
    expect(secondSupervisor.get(pinned.id)?.pinned).toBe(true);
    expect(secondSupervisor.isPickleSession(pinned.id)).toBe(true);
  });

  it("reattaches a persisted pinned session before accepting follow-up input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), store);
    await firstSupervisor.load();
    const pinned = await firstSupervisor.pinPickleSession(contextWithPiSessionFile("persist pinned with source", "/tmp/source-pi-session.jsonl"), "Pinned persisted");

    const runtime = new ResumableRuntime();
    const secondSupervisor = new SessionSupervisor(runtime, store);
    await secondSupervisor.load();

    const followedUp = await secondSupervisor.followUp(pinned.id, "continue after app restart");
    await settle();

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/source-pi-session.jsonl", cwd: "/tmp/project", sessionId: pinned.id }]);
    expect(runtime.handle?.followUps.map((prompt) => prompt.text)).toEqual(["continue after app restart"]);
    expect(followedUp.pinned).toBe(false);
    expect(secondSupervisor.get(pinned.id)?.pinned).toBe(false);
    expect(userTexts(secondSupervisor.get(pinned.id))).toContain("continue after app restart");
  });

  it("keeps a session cancelled when abort happens while follow-up is reattaching the runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-followup-reattach-abort-"));
    const store = new SessionStore(dir);
    const firstSupervisor = new SessionSupervisor(new MockRuntime(), store);
    await firstSupervisor.load();
    const pinned = await firstSupervisor.pinPickleSession(contextWithPiSessionFile("persist pinned with source", "/tmp/source-pi-session.jsonl"), "Pinned persisted");

    const runtime = new DeferredResumeRuntime();
    const secondSupervisor = new SessionSupervisor(runtime, store);
    await secondSupervisor.load();

    const following = secondSupervisor.followUp(pinned.id, "continue after app restart");
    await waitUntil(() => runtime.resumeCalls.length === 1);
    await secondSupervisor.abort(pinned.id);
    expect(secondSupervisor.get(pinned.id)?.status).toBe("cancelled");

    runtime.resolvePendingResume();
    const followedUp = await following;
    await settle();

    expect(followedUp.status).toBe("cancelled");
    expect(secondSupervisor.get(pinned.id)?.status).toBe("cancelled");
    expect(secondSupervisor.get(pinned.id)?.lastSummary).toBe("Cancelled");
    expect(runtime.handle?.followUps).toEqual([]);
    expect(runtime.handle?.aborts).toBe(1);
    expect((secondSupervisor as unknown as { runtimeHandles: Map<string, RuntimeSessionHandle> }).runtimeHandles.has(pinned.id)).toBe(false);
    expect(userTexts(secondSupervisor.get(pinned.id))).not.toContain("continue after app restart");
  });

  it("reattaches a pinned session and sends steering input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pinned = await supervisor.pinPickleSession(contextWithPiSessionFile("pin then steer", "/tmp/source-pi-session.jsonl"), "Pinned source");
    expect(pinned.pinned).toBe(true);

    const steered = await supervisor.steerPickleSession(pinned.id, "continue this work");

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/source-pi-session.jsonl", cwd: "/tmp/project", sessionId: pinned.id }]);
    expect(runtime.handle?.steerPrompts.map((prompt) => prompt.text)).toEqual(["continue this work"]);
    expect(steered.pinned).toBe(false);
    expect(steered.status).toBe("running");
  });

  it("reattaches a pinned session and sends follow-up input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pinned = await supervisor.pinPickleSession(contextWithPiSessionFile("pin then follow up", "/tmp/source-pi-session.jsonl"), "Pinned source");

    const followedUp = await supervisor.followUp(pinned.id, "continue this work");
    await settle();

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/source-pi-session.jsonl", cwd: "/tmp/project", sessionId: pinned.id }]);
    expect(runtime.handle?.followUps.map((prompt) => prompt.text)).toEqual(["continue this work"]);
    expect(followedUp.pinned).toBe(false);
    expect(supervisor.get(pinned.id)?.status).toBe("running");
    expect(userTexts(supervisor.get(pinned.id))).toContain("continue this work");
  });

  it("ignores late tool/thinking/assistant events after abort", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-late-events-after-abort-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("late events after abort"));

    await supervisor.abort(session.id);
    const aborted = supervisor.get(session.id)!;
    runtime.handle?.emit({ type: "assistant_delta", delta: "late answer" });
    runtime.handle?.emit({ type: "thinking_delta", delta: "late thinking" });
    runtime.handle?.emit({ type: "tool", toolCallId: "late-tool", name: "bash", status: "running", preview: "late" });
    runtime.handle?.emit({ type: "queue_update", steering: ["late steer"], followUp: [] });
    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "late-ui", sessionId: session.id, method: "input", prompt: "Late", createdAt: "2026-05-01T00:00:00.000Z" } });
    runtime.handle?.emit({ type: "input_message", role: "user", text: "late extension input", originatedBy: "pi_extension" });
    await settle();

    expect(supervisor.get(session.id)).toMatchObject({
      status: aborted.status,
      tools: aborted.tools,
      thinkingPreview: aborted.thinkingPreview,
      queuedSteers: aborted.queuedSteers,
    });
    expect(supervisor.get(session.id)?.pendingExtensionUiRequest).toBeUndefined();
    expect(userTexts(supervisor.get(session.id))).not.toContain("late extension input");
  });

  it("clears a pending extension UI request when aborting", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-abort-pending-ui-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("abort pending ui"));

    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-abort", sessionId: session.id, method: "input", prompt: "Need input", createdAt: "2026-05-01T00:00:00.000Z" } });
    await waitUntil(() => supervisor.get(session.id)?.pendingExtensionUiRequest?.id === "ui-abort");

    await supervisor.abort(session.id);

    expect(supervisor.get(session.id)?.status).toBe("cancelled");
    expect(supervisor.get(session.id)?.pendingExtensionUiRequest).toBeUndefined();
    expect(supervisor.get(session.id)?.messages?.find((message) => message.id === "ui-abort")?.cancelledAt).toBeDefined();
  });

  it("aborts a session without duplicating the cancellation system message", async () => {
    const supervisor = await makeSupervisor();
    const session = await supervisor.create(context("abort me"));
    const updated = await supervisor.abort(session.id);
    await settle();
    expect(updated.status).toBe("cancelled");
    expect(supervisor.get(session.id)?.messages?.filter((message) => message.kind === "system" && message.text === "Cancelled by user")).toHaveLength(1);
  });

  it("records cancellation system messages for separate cancelled turns", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-repeat-cancel-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("cancel twice"));

    await supervisor.abort(session.id);
    await supervisor.steer(session.id, "run again");
    await supervisor.abort(session.id);

    expect(supervisor.get(session.id)?.messages?.filter((message) => message.kind === "system" && message.text === "Cancelled by user")).toHaveLength(2);
  });

  it("coalesces duplicate runtime cancelled status events in the same turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-duplicate-cancel-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("duplicate cancel"));

    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled again" });
    await settle();

    expect(supervisor.get(session.id)?.messages?.filter((message) => message.kind === "system" && message.text === "Cancelled by user")).toHaveLength(1);
  });

  it("writes link and changed-file artifacts when a terminal status is observed", async () => {
    // Session report file generation was removed; only link extraction and
    // changed-file detection remain in the terminal materialize step. Verify
    // those still run end-to-end on terminal status.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new MockRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("terminal report"));
    await supervisor.followUp(session.id, "Changed file: M Picky/App.swift - HUD follow-up\nhttps://github.com/acme/repo/pull/42");
    await supervisor.abort(session.id);

    const updated = supervisor.get(session.id)!;
    expect(updated.artifacts.some((artifact) => artifact.kind === "github" && artifact.title === "#42" && artifact.url === "https://github.com/acme/repo/pull/42")).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "report")).toBe(false);
    expect(updated.changedFiles).toEqual([{ status: "M", path: "Picky/App.swift", summary: "HUD follow-up" }]);
  });

  it("creates link artifacts from initial user input and appended logs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new MockRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const session = await supervisor.create(context("See https://github.com/acme/repo/issues/2777 and https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249"));
    await supervisor.followUp(session.id, "Notion https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226?source=copy_link");

    const updated = supervisor.get(session.id)!;
    expect(updated.artifacts.some((artifact) => artifact.kind === "github" && artifact.title === "#2777" && artifact.url === "https://github.com/acme/repo/issues/2777")).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "slack" && artifact.url === "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249")).toBe(true);
    expect(updated.artifacts.some((artifact) => artifact.kind === "notion" && artifact.url === "https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226")).toBe(true);
  });

  it("does not trust user-controlled multiline follow-up text as a Pi session file marker", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pi-session-injection-"));
    const injectedSessionFile = join(dir, "injected.jsonl");
    await writeFile(injectedSessionFile, "");
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("inject session path"));

    await supervisor.followUp(session.id, `normal follow-up\npi session: ${injectedSessionFile}`);
    await settle();

    expect(supervisor.get(session.id)?.piSessionFilePath).toBeUndefined();
  });

  it("reloads persisted session metadata as blocked when runtime is not attached", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "interrupted-session",
      title: "persist me",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Still working before restart",
      logs: [],
      tools: [{ toolCallId: "tool-1", name: "bash", status: "running", startedAt: "2026-05-01T00:00:05.000Z" }],
      artifacts: [],
      changedFiles: [],
      queuedSteers: [{ text: "stale steer", enqueuedAt: "2026-05-01T00:00:06.000Z" }],
      queuedFollowUps: [{ text: "stale follow-up", enqueuedAt: "2026-05-01T00:00:07.000Z" }],
      activitySummary: { read: 0, bash: 1, edit: 0, write: 0, thinking: 1, other: 0 },
      thinkingPreview: "checking setup progress",
    });

    const secondSupervisor = new SessionSupervisor(new MockRuntime(), store);
    await secondSupervisor.load();
    const restored = secondSupervisor.get("interrupted-session");
    expect(restored?.title).toBe("persist me");
    expect(restored?.status).toBe("blocked");
    expect(restored?.lastSummary).toMatch(/Runtime not attached/);
    expect(restored?.thinkingPreview).toBeUndefined();
    expect(restored?.tools[0]).toMatchObject({ status: "failed", preview: "Tool was interrupted by a Picky daemon restart." });
    expect(restored?.queuedSteers).toEqual([]);
    expect(restored?.queuedFollowUps).toEqual([]);
    expect(restored?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
  });

  it("reattaches non-terminal persisted sessions from Pi session files without leaving stale work active", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "running-with-pi-file",
      title: "Running Pickle",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Still working before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [{ toolCallId: "tool-1", name: "bash", status: "running", startedAt: "2026-05-01T00:00:05.000Z" }],
      artifacts: [],
      changedFiles: [],
      queuedSteers: [{ text: "stale steer", enqueuedAt: "2026-05-01T00:00:06.000Z" }],
      queuedFollowUps: [{ text: "stale follow-up", enqueuedAt: "2026-05-01T00:00:07.000Z" }],
      activitySummary: { read: 0, bash: 1, edit: 0, write: 0, thinking: 1, other: 0 },
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
    expect(restored?.queuedSteers).toEqual([]);
    expect(restored?.queuedFollowUps).toEqual([]);
    expect(restored?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(restored?.logs).toContain("runtime reattached from pi session: /tmp/pi-session.jsonl");
    expect(restored?.logs.some((line) => line.includes("Runtime not attached after daemon restart"))).toBe(false);
  });

  it("recovers orphaned scoped child non-terminal sessions as blocked without startup resume", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const scopedStore = new SessionStore(dir, { scopeSessionId: "orphan-child" });
    await scopedStore.save({
      id: "orphan-child",
      title: "Orphan Child Pickle",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Still working in child before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/orphan-child.jsonl"],
      tools: [{ toolCallId: "tool-1", name: "bash", status: "running", startedAt: "2026-05-01T00:00:05.000Z" }],
      artifacts: [],
      changedFiles: [],
      queuedSteers: [{ text: "stale steer", enqueuedAt: "2026-05-01T00:00:06.000Z" }],
      queuedFollowUps: [{ text: "stale follow-up", enqueuedAt: "2026-05-01T00:00:07.000Z" }],
      activitySummary: { read: 0, bash: 1, edit: 0, write: 0, thinking: 1, other: 0 },
      thinkingPreview: "checking setup progress",
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));

    await supervisor.load();

    const restored = supervisor.get("orphan-child");
    expect(runtime.resumeCalls).toEqual([]);
    expect(restored?.status).toBe("blocked");
    expect(restored?.lastSummary).toBe("Child Pickle daemon is not attached after Picky restart; send a follow-up or steer message to continue.");
    expect(restored?.thinkingPreview).toBeUndefined();
    expect(restored?.tools[0]).toMatchObject({ status: "failed", preview: "Tool was interrupted by a Picky daemon restart." });
    expect(restored?.queuedSteers).toEqual([]);
    expect(restored?.queuedFollowUps).toEqual([]);
    expect(restored?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });

    const flat = JSON.parse(await readFile(join(dir, "sessions", "orphan-child.json"), "utf8"));
    expect(flat.status).toBe("blocked");

    const followedUp = await supervisor.followUp("orphan-child", "continue after recovery");

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/orphan-child.jsonl", cwd: "/tmp/project", sessionId: "orphan-child" }]);
    expect(runtime.handle?.followUps[0].text).toContain("continue after recovery");
    expect(followedUp.status).toBe("running");
  });

  it("strips the orphaned recovery marker on the first restart so it never re-triggers", async () => {
    // Regression: previously the ORPHANED marker stayed in `logs` forever, so every restart
    // re-entered the orphaned branch and the session was permanently stuck on `blocked` even
    // when the Pi session file was still resumable.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const scopedStore = new SessionStore(dir, { scopeSessionId: "orphan-once" });
    await scopedStore.save({
      id: "orphan-once",
      title: "Orphan Once Pickle",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Still working in child before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/orphan-once.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));

    await supervisor.load();

    const restored = supervisor.get("orphan-once");
    expect(restored?.status).toBe("blocked");
    expect(restored?.lastSummary).toBe(ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY);
    expect(restored?.logs).not.toContain(ORPHANED_CHILD_SESSION_RECOVERY_LOG);

    const flat = JSON.parse(await readFile(join(dir, "sessions", "orphan-once.json"), "utf8"));
    expect(flat.status).toBe("blocked");
    expect(flat.logs).not.toContain(ORPHANED_CHILD_SESSION_RECOVERY_LOG);
  });

  it("auto-reattaches a previously orphaned session on the next restart when the Pi session file is still around", async () => {
    // Regression: the orphaned marker used to be sticky, so even after a fresh restart with the
    // Pi session file intact, the supervisor would refuse to reattach the runtime and the user
    // saw the dock icon stuck in the blocked state forever.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const scopedStore = new SessionStore(dir, { scopeSessionId: "orphan-then-reattach" });
    await scopedStore.save({
      id: "orphan-then-reattach",
      title: "Orphan Then Reattach Pickle",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Still working in child before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/orphan-then-reattach.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });
    const runtime = new ResumableRuntime();
    const flatStore = new SessionStore(dir);

    const firstSupervisor = new SessionSupervisor(runtime, flatStore);
    await firstSupervisor.load();
    expect(runtime.resumeCalls).toEqual([]);

    const secondSupervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await secondSupervisor.load();

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/orphan-then-reattach.jsonl", cwd: "/tmp/project", sessionId: "orphan-then-reattach" }]);
    const reattached = secondSupervisor.get("orphan-then-reattach");
    expect(reattached?.logs).toContain("runtime reattached from pi session: /tmp/orphan-then-reattach.jsonl");
  });

  it("reattaches blocked sessions from Pi session files during startup", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "blocked-with-pi-file",
      title: "Blocked Pickle",
      status: "blocked",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Previous run was interrupted by daemon restart; send a follow-up or steer message to continue.",
      logs: ["Picky handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);

    await supervisor.load();
    const followedUp = await supervisor.followUp("blocked-with-pi-file", "continue after another restart");

    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/pi-session.jsonl", cwd: "/tmp/project", sessionId: "blocked-with-pi-file" }]);
    expect(runtime.handle?.followUps[0].text).toContain("continue after another restart");
    expect(followedUp.status).toBe("running");
    expect(followedUp.logs).toContain("runtime reattached from pi session: /tmp/pi-session.jsonl");
  });

  it("clears stale extension UI requests on reattach because the previous bridge promise is gone", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "waiting-with-pending-ui",
      title: "Waiting Pickle",
      status: "waiting_for_input",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Waiting before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [{ toolCallId: "tool-ui", name: "read", status: "running", startedAt: "2026-05-01T00:00:05.000Z" }],
      artifacts: [],
      changedFiles: [],
      queuedSteers: [{ text: "stale steer", enqueuedAt: "2026-05-01T00:00:06.000Z" }],
      queuedFollowUps: [{ text: "stale follow-up", enqueuedAt: "2026-05-01T00:00:07.000Z" }],
      activitySummary: { read: 1, bash: 0, edit: 0, write: 0, thinking: 1, other: 0 },
      thinkingPreview: "thinking while waiting",
      pendingExtensionUiRequest: {
        id: "ui-1",
        sessionId: "waiting-with-pending-ui",
        method: "input",
        createdAt: "2026-05-01T00:00:05.000Z",
        prompt: "Need input",
      },
      messages: [
        {
          id: "ui-1",
          kind: "agent_question",
          createdAt: "2026-05-01T00:00:05.000Z",
          question: {
            id: "ui-1",
            sessionId: "waiting-with-pending-ui",
            method: "input",
            createdAt: "2026-05-01T00:00:05.000Z",
            prompt: "Need input",
          },
        },
      ],
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);

    await supervisor.load();

    const restored = supervisor.get("waiting-with-pending-ui");
    expect(restored?.status).toBe("blocked");
    expect(restored?.pendingExtensionUiRequest).toBeUndefined();
    expect(restored?.messages?.[0]?.cancelledAt).toBeDefined();
    expect(restored?.thinkingPreview).toBeUndefined();
    expect(restored?.tools[0]).toMatchObject({ status: "failed", preview: "Tool was interrupted by a Picky daemon restart." });
    expect(restored?.queuedSteers).toEqual([]);
    expect(restored?.queuedFollowUps).toEqual([]);
    expect(restored?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(restored?.lastSummary).toMatch(/previous question can no longer be answered/);
  });

  it("does not reattach archived non-terminal sessions during startup", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "archived-running-with-pi-file",
      title: "Archived Pickle",
      status: "running",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Archived before restart",
      logs: ["Picky handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [{ toolCallId: "tool-1", name: "bash", status: "running", startedAt: "2026-05-01T00:00:05.000Z" }],
      artifacts: [],
      changedFiles: [],
      queuedSteers: [{ text: "stale steer", enqueuedAt: "2026-05-01T00:00:06.000Z" }],
      queuedFollowUps: [{ text: "stale follow-up", enqueuedAt: "2026-05-01T00:00:07.000Z" }],
      activitySummary: { read: 0, bash: 1, edit: 0, write: 0, thinking: 1, other: 0 },
      thinkingPreview: "still thinking before archive restart",
      archived: true,
    });
    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);

    await supervisor.load();

    const restored = supervisor.get("archived-running-with-pi-file");
    expect(runtime.resumeCalls).toEqual([]);
    expect(restored?.status).toBe("cancelled");
    expect(restored?.lastSummary).toBe("Archived session was not resumed after daemon restart");
    expect(restored?.thinkingPreview).toBeUndefined();
    expect(restored?.tools[0]).toMatchObject({ status: "failed", preview: "Tool was interrupted by a Picky daemon restart." });
    expect(restored?.queuedSteers).toEqual([]);
    expect(restored?.queuedFollowUps).toEqual([]);
    expect(restored?.activitySummary).toEqual({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });
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
      title: "Restored Pickle",
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
    const supervisor = new SessionSupervisor(new ThrowingRuntime(), new SessionStore(dir), { taskRouter: new StaticTaskRouter({ route: "quick_reply", reply: "바로 답변" }) });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const result = await supervisor.route(context("마이크 테스트"));

    expect(result).toBeUndefined();
    expect(supervisor.list()).toEqual([]);
    expect(replies).toEqual([{ contextId: "context-마이크 테스트", text: "바로 답변" }]);
  });

  it("forwards TTS toggle changes to the main runtime so Realtime can switch response modality", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-tts-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();

    supervisor.setTTSEnabled(false);
    supervisor.setTTSEnabled(false); // idempotent: should not re-forward
    supervisor.setTTSEnabled(true);

    expect(mainRuntime.ttsEnabledCalls).toEqual([false, true]);
  });

  it("routes voice requests through Picky when configured", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
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

  it("serializes concurrent first main-agent routes through one initial runtime", async () => {
    const mainRuntime = new DeferredCreateRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-initial-race-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir), { mainRuntime });
    await supervisor.load();

    const first = supervisor.route({ ...context("first main request"), id: "main-race-first" });
    const second = supervisor.route({ ...context("second main request"), id: "main-race-second" });
    await settle();
    const createCallsBeforeResolve = mainRuntime.createCalls;

    mainRuntime.resolveAll();
    await Promise.all([first, second]);

    expect(createCallsBeforeResolve).toBe(1);
    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handles).toHaveLength(1);
    expect(mainRuntime.handles[0]?.followUps).toHaveLength(1);
  });

  it("persists concurrent main-agent state writes in logical order", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-state-write-race-"));
    const store = new DelayedFirstMainStateStore(dir);
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    const mainMessages = supervisor as unknown as { appendMainMessage(role: "user" | "assistant", text: string): Promise<void> };

    const first = mainMessages.appendMainMessage("user", "first message");
    await waitUntil(() => store.firstMainSaveStarted);
    const second = mainMessages.appendMainMessage("assistant", "second message");
    await settle();

    store.releaseFirstMainSave();
    await Promise.all([first, second]);

    const persisted = await store.loadMainAgentState();
    expect(persisted.messages.map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "first message" },
      { role: "assistant", text: "second message" },
    ]);
  });

  // Pi emits both `turn_end` and `agent_end` for a single agent run, both of which
  // pi-event-normalizer.ts maps to `status:"completed"`. They arrive back-to-back
  // through the same fire-and-forget subscriber, and the previous applyMainRuntimeEvent
  // implementation cleared `mainDraft` only AFTER `await appendMainMessage`, so the
  // second terminal event read the still-populated draft and re-emitted both the
  // `mainMessage` (Picky menu-bar Messages tab) and the `quickReply` (TTS) events.
  // Two consecutive runtime status events with the same draft must produce exactly
  // one assistant message and one quickReply.
  it("deduplicates a duplicated terminal status event so the main reply and TTS only fire once per turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    const broadcastedMainMessages: Array<{ role: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));
    supervisor.on("mainMessage", (message) => broadcastedMainMessages.push({ role: message.role, text: message.text }));

    await supervisor.route(context("안녕"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "안녕하세요. 무엇을 도와드릴까요?" });
    // Replay Pi's `turn_end` -> `agent_end` pair: both normalize to `status:"completed"`
    // and arrive synchronously back-to-back.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "안녕하세요. 무엇을 도와드릴까요?" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "안녕하세요. 무엇을 도와드릴까요?" });
    await settle();

    // Both the user-visible Messages tab (broadcasted via `mainMessage`) and the TTS
    // pipeline (driven by `quickReply`) must see exactly one assistant entry per turn.
    expect(replies.filter((reply) => reply.text === "안녕하세요. 무엇을 도와드릴까요?")).toHaveLength(1);
    expect(broadcastedMainMessages.filter((message) => message.role === "assistant")).toEqual([
      { role: "assistant", text: "안녕하세요. 무엇을 도와드릴까요?" },
    ]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "안녕" },
      { role: "assistant", text: "안녕하세요. 무엇을 도와드릴까요?" },
    ]);

    // The next turn must re-arm: a fresh assistant_delta + status:completed pair
    // (without an explicit status:running between them, mirroring follow-up flows
    // used elsewhere in this suite) should produce a new reply, not be swallowed
    // by the guard.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "두 번째 답변" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies.filter((reply) => reply.text === "두 번째 답변")).toHaveLength(1);
    expect(broadcastedMainMessages.filter((message) => message.text === "두 번째 답변")).toEqual([
      { role: "assistant", text: "두 번째 답변" },
    ]);
  });

  // Per-turn TTS flush. When the main agent answers with [text -> tool -> text],
  // the user expects each text block to be a separate TTS playback rather than the
  // concatenated 'text1 text2' the supervisor used to emit at agent_end. The runtime
  // surfaces an explicit `turn_text_complete` event for the intermediate-turn case
  // (carrying the text the LLM streamed in that turn), and the supervisor flushes
  // mainDraft right then so the next turn's deltas accumulate cleanly.
  it("flushes per-turn assistant text as separate quickReplies when a turn ends with text followed by tool calls", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.route(context("현재 시각 알려줘"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    // Turn 1: LLM streamed an intro before calling a tool. The intro deltas land
    // in mainDraft just like a normal reply.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "잠시만요, 도구 호출하고 이어서 말씀드릴게요." });
    // Pi's turn_end for a turn that mixed text + tool calls now surfaces as an
    // explicit per-turn flush. The supervisor must emit a quickReply with the
    // accumulated text and clear its draft so turn 2's deltas do not stack on
    // top of turn 1's text.
    mainRuntime.handle?.emit({ type: "turn_text_complete", text: "잠시만요, 도구 호출하고 이어서 말씀드릴게요." });
    await settle();

    expect(replies).toEqual([
      { contextId: "context-현재 시각 알려줘", text: "잠시만요, 도구 호출하고 이어서 말씀드릴게요." },
    ]);

    // Turn 2: tool result came back, LLM streams the actual answer and the agent
    // run terminates. The terminal status must produce a fresh quickReply containing
    // ONLY turn 2's text, never the concatenation of turn 1 + turn 2.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "지금 시각은 소 9시 47분입니다." });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toEqual([
      { contextId: "context-현재 시각 알려줘", text: "잠시만요, 도구 호출하고 이어서 말씀드릴게요." },
      { contextId: "context-현재 시각 알려줘", text: "지금 시각은 소 9시 47분입니다." },
    ]);
    // The persisted main-message transcript also keeps the two assistant lines
    // separate, matching what the user sees in the menu-bar Messages tab.
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "현재 시각 알려줘" },
      { role: "assistant", text: "잠시만요, 도구 호출하고 이어서 말씀드릴게요." },
      { role: "assistant", text: "지금 시각은 소 9시 47분입니다." },
    ]);
  });

  // A turn_text_complete without any buffered text (e.g. a noisy normalizer fallback
  // or a runtime that emits it on a tool-only turn) must be a no-op rather than emit
  // a blank quickReply that would silence Picky's TTS layer or surface an empty bubble.
  it("ignores turn_text_complete with no buffered draft text", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.route(context("도구만"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    mainRuntime.handle?.emit({ type: "turn_text_complete", text: "" });
    await settle();

    expect(replies).toEqual([]);
  });

  // Non-streaming main runtimes (or any future adapter that emits an entire
  // assistant message in one shot rather than via `assistant_delta`) deliver
  // their turn text only through `turn_text_complete.text`. mainDraft is empty
  // in that path, so the supervisor must fall back to the event payload when
  // flushing, otherwise the per-turn TTS announcement is silently dropped.
  it("falls back to turn_text_complete.text when mainDraft is empty", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.route(context("시각 알려줘"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    mainRuntime.handle?.emit({ type: "turn_text_complete", text: "파일 확인해볼게요." });
    await waitUntil(() => replies.some((reply) => reply.contextId === "context-시각 알려줘" && reply.text === "파일 확인해볼게요."));

    expect(replies).toEqual([
      { contextId: "context-시각 알려줘", text: "파일 확인해볼게요." },
    ]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "시각 알려줘" },
      { role: "assistant", text: "파일 확인해볼게요." },
    ]);
  });

  // Picky's TTS setting (Voice tab) propagates to agentd so Realtime can switch
  // response.create modality. The supervisor stores the current value
  // (defaults to true) and fires change listeners on real transitions.
  it("tracks ttsEnabled state and notifies listeners on every change", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    const changes: boolean[] = [];
    const unsubscribe = supervisor.onTTSEnabledChange((enabled) => changes.push(enabled));

    // Default state is enabled so fresh installs keep audio responses until
    // the user explicitly opts out.
    expect(supervisor.getTTSEnabled()).toBe(true);

    supervisor.setTTSEnabled(false);
    expect(supervisor.getTTSEnabled()).toBe(false);
    supervisor.setTTSEnabled(true);
    expect(supervisor.getTTSEnabled()).toBe(true);

    // Idempotent: setting the same value again must NOT fire a listener again,
    // otherwise downstream subscribers would thrash on every settings broadcast
    // even when nothing changed.
    supervisor.setTTSEnabled(true);

    expect(changes).toEqual([false, true]);

    unsubscribe();
    supervisor.setTTSEnabled(false);
    expect(changes).toEqual([false, true]);
  });

  // Defense-in-depth for the user-reported full-text-twice TTS bug. The persisted Pi session
  // JSONL recorded exactly one assistant message (stopReason:"stop") yet TTS played the full
  // reply twice, proving the duplication happens at `applyMainRuntimeEvent` emit time on a
  // path that bypasses Guard A (`mainTerminalProcessed`). Simulate that bypass by re-arming
  // the guard between two terminal events for the same turn and verify the second identical
  // emit on the same context is suppressed within the 2s window.
  it("suppresses a duplicate main quick reply with identical (contextId, text) within a 2s window even if Guard A is bypassed", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.route(context("안녕"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "응, 잘 들려. 무슨 일 도와줄까?" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    // Simulate a Guard-A bypass: a stray assistant_delta replays the same full text and
    // re-arms `mainTerminalProcessed`, then a second status:completed arrives. Without the
    // (contextId, text, time) dedup, this would emit a second identical quickReply and
    // drive a second TTS playback of the same reply.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "응, 잘 들려. 무슨 일 도와줄까?" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies.filter((reply) => reply.text === "응, 잘 들려. 무슨 일 도와줄까?")).toHaveLength(1);
  });

  // Counterpart of the dedup guard: a legitimate same-text reply on a different contextId
  // (e.g. two voice turns that both end with "OK") must still surface as two quickReply
  // emits. The dedup key must include contextId to avoid swallowing this case.
  it("does not suppress an identical reply text when the context id differs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.route(context("첫 질문"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "OK" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    await supervisor.route(context("두번째 질문"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "OK" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies.filter((reply) => reply.text === "OK")).toHaveLength(2);
  });

  it("resets Picky messages and starts the next prompt on a new handle", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, { mainRuntime });

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

  it("aborts the active Picky turn without clearing visible message history", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, { mainRuntime });
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

  it("aborts a pending prewarmed Picky handle after voice input cancels it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new DeferredPrewarmRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

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

  it("keeps only the latest 100 Picky user and assistant messages", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

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

  it("rolls over the main Pi session after the bounded epoch turn limit and carries a compact summary", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-rollover-turns-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    for (let index = 0; index < 40; index += 1) {
      await supervisor.route(context(`질문 ${index}`));
      mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
      await settle();
    }
    const previousHandle = mainRuntime.handle;

    await supervisor.route(context("롤오버 후 질문"));

    expect(previousHandle?.aborts).toBe(1);
    expect(mainRuntime.createCalls).toBe(2);
    expect(mainRuntime.handle).not.toBe(previousHandle);
    expect(mainRuntime.handle?.bootstrapInjections.at(-1)?.user).toContain("Previous Picky epoch summary");
    expect(mainRuntime.handle?.bootstrapInjections.at(-1)?.user).toContain("질문 39");
    expect(supervisor.listMainMessages().at(-1)).toMatchObject({ role: "user", text: "롤오버 후 질문" });
  });

  it("rolls over the main Pi session when context usage crosses the proactive threshold", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-rollover-context-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.route(context("첫 질문"));
    const previousHandle = mainRuntime.handle;
    previousHandle?.emit({ type: "status", status: "completed", summary: "Completed" });
    previousHandle?.emit({ type: "context_usage", usage: { tokens: 150_000, contextWindow: 200_000, percent: 75 } });
    await settle();

    await supervisor.route(context("다음 질문"));

    expect(previousHandle?.aborts).toBe(1);
    expect(mainRuntime.createCalls).toBe(2);
    expect(mainRuntime.handle).not.toBe(previousHandle);
    expect(mainRuntime.handle?.bootstrapInjections.at(-1)?.user).toContain("context:75%");
  });

  it("does not roll over the main Pi session solely because the persisted session file is large", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-large-session-file-"));
    const largeSessionFile = join(dir, "large-main-session.jsonl");
    await writeFile(largeSessionFile, "x".repeat(2_100_000), "utf8");
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.route(context("첫 질문"));
    const handle = mainRuntime.handle;
    handle?.emit({ type: "log", line: `pi session: ${largeSessionFile}` });
    handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    await supervisor.route(context("두 번째 질문"));

    expect(handle?.aborts).toBe(0);
    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle).toBe(handle);
    expect(handle?.followUps).toHaveLength(1);
    expect(handle?.followUps[0].text).toContain("두 번째 질문");
  });

  it("resumes the persisted Picky Pi session after daemon restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.saveMainAgentState({ sessionFilePath: "/tmp/main-pi-session.jsonl", cwd: "/tmp/project", messages: [] });
    const mainRuntime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, { mainRuntime });
    await supervisor.load();

    await supervisor.route(context("재시작 후 질문"));

    expect(mainRuntime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/main-pi-session.jsonl", cwd: "/tmp/project", sessionId: "picky" }]);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toContain("재시작 후 질문");
    expect(supervisor.listMainMessages().map((message) => message.text)).toEqual(["재시작 후 질문"]);
  });

  it("reuses the same Picky handle for later voice turns", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.route(context("첫 번째"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "첫 응답" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    await supervisor.route(context("두 번째"));

    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0].text).toContain("두 번째");
  });

  it("soft-switches the active Picky main model without resetting the Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-model-soft-switch-"));
    const store = new SessionStore(dir);
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, { mainRuntime });

    await supervisor.route(context("첫 질문"));
    const handle = mainRuntime.handle!;
    handle.emit({ type: "log", line: "pi session: /tmp/picky-main.jsonl" });
    handle.emit({ type: "assistant_delta", delta: "첫 답변" });
    handle.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    await supervisor.setMainAgentModel("anthropic/claude-sonnet-4-5");

    expect(mainRuntime.modelPatterns).toEqual(["anthropic/claude-sonnet-4-5"]);
    expect(handle.modelPatterns).toEqual(["anthropic/claude-sonnet-4-5"]);
    expect(handle.aborts).toBe(0);
    expect(mainRuntime.handle).toBe(handle);
    expect((await store.loadMainAgentState()).sessionFilePath).toBe("/tmp/picky-main.jsonl");

    await supervisor.route(context("두 번째 질문"));

    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle).toBe(handle);
    expect(handle.followUps.at(-1)?.text).toContain("두 번째 질문");
  });

  it("restores automatic Picky main model selection on the active Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-model-auto-soft-switch-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.route(context("첫 질문"));
    const handle = mainRuntime.handle!;

    await supervisor.setMainAgentModel("anthropic/claude-sonnet-4-5");
    await supervisor.setMainAgentModel("");

    expect(mainRuntime.modelPatterns).toEqual(["anthropic/claude-sonnet-4-5", undefined]);
    expect(handle.modelPatterns).toEqual(["anthropic/claude-sonnet-4-5", undefined]);
    expect(handle.aborts).toBe(0);
    expect(mainRuntime.handle).toBe(handle);
  });

  it("interrupts the active Picky turn when newer voice input arrives", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });
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

  it("does not attach an aborted previous main reply to the newer input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-interrupt-aborted-reply-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.prewarmMainAgent("/tmp/project");
    await supervisor.route(context("이전 입력"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Started" });
    await supervisor.route(context("새 입력"));

    // Pi may flush partial assistant text from the aborted previous turn before its
    // cancelled terminal event arrives. That stale text must not become the answer to
    // `새 입력` just because the supervisor already switched `mainReplyContextId`.
    mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-2", delta: "이전 입력에 대한 늦은 답변" });
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-2", status: "cancelled", summary: "Interrupted turn aborted" });
    mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-3", delta: "새 입력에 대한 답변" });
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.interrupts).toHaveLength(1);
    expect(replies).toEqual([{ contextId: "context-새 입력", text: "새 입력에 대한 답변" }]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "이전 입력" },
      { role: "user", text: "새 입력" },
      { role: "assistant", text: "새 입력에 대한 답변" },
    ]);
  });

  it("lets replacement main deltas flow when the new running event beats the old cancelled status", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-interrupt-running-before-cancel-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.prewarmMainAgent("/tmp/project");
    await supervisor.route(context("이전 입력"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Started" });
    await supervisor.route(context("새 입력"));

    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "running", summary: "Replacement started" });
    mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-3", delta: "새 입력에 대한 답변" });
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-2", status: "cancelled", summary: "Old turn aborted" });
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toEqual([{ contextId: "context-새 입력", text: "새 입력에 대한 답변" }]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "이전 입력" },
      { role: "user", text: "새 입력" },
      { role: "assistant", text: "새 입력에 대한 답변" },
    ]);
  });

  for (const replacementTerminalStatus of ["completed", "failed"] as const) {
    it(`finalizes a fast ${replacementTerminalStatus} replacement turn before suppressing the old cancelled turn`, async () => {
      const dir = await mkdtemp(join(tmpdir(), `picky-agentd-main-interrupt-fast-${replacementTerminalStatus}-before-cancel-`));
      const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
      const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });
      const replies: Array<{ contextId: string; text: string }> = [];
      supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

      await supervisor.prewarmMainAgent("/tmp/project");
      await supervisor.route(context("이전 입력"));
      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-2", status: "running", summary: "Started" });
      await supervisor.route(context("새 입력"));

      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "running", summary: "Replacement started" });
      mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-3", delta: "빠른 대체 응답" });
      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: replacementTerminalStatus, summary: "Replacement ended" });
      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-2", status: "cancelled", summary: "Old turn aborted late" });
      await waitUntil(() => replies.some((reply) => reply.contextId === "context-새 입력" && reply.text === "빠른 대체 응답"));

      expect(replies).toEqual([{ contextId: "context-새 입력", text: "빠른 대체 응답" }]);
      expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
        { role: "user", text: "이전 입력" },
        { role: "user", text: "새 입력" },
        { role: "assistant", text: "빠른 대체 응답" },
      ]);
    });
  }

  for (const oldTerminalStatus of ["completed", "failed"] as const) {
    it(`lets replacement main deltas flow when the new running event beats the old ${oldTerminalStatus} status`, async () => {
      const dir = await mkdtemp(join(tmpdir(), `picky-agentd-main-interrupt-running-before-${oldTerminalStatus}-`));
      const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
      const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });
      const replies: Array<{ contextId: string; text: string }> = [];
      supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

      await supervisor.prewarmMainAgent("/tmp/project");
      await supervisor.route(context("이전 입력"));
      mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Started" });
      await supervisor.route(context("새 입력"));

      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "running", summary: "Replacement started" });
      mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-3", delta: "새 입력에 대한 답변" });
      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-2", status: oldTerminalStatus, summary: "Old turn ended late" });
      mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "completed", summary: "Completed" });
      await settle();

      expect(replies).toEqual([{ contextId: "context-새 입력", text: "새 입력에 대한 답변" }]);
      expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
        { role: "user", text: "이전 입력" },
        { role: "user", text: "새 입력" },
        { role: "assistant", text: "새 입력에 대한 답변" },
      ]);
    });
  }

  it("keeps only the final main reply across consecutive A-B-C interrupts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-main-interrupt-abc-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    await supervisor.prewarmMainAgent("/tmp/project");
    await supervisor.route(context("A"));
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "A started" });
    await supervisor.route(context("B"));
    mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-2", delta: "A stale" });
    await supervisor.route(context("C"));
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-2", status: "cancelled", summary: "A cancelled" });
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-3", status: "cancelled", summary: "B cancelled" });
    mainRuntime.handle?.emit({ type: "assistant_delta", inputId: "main-turn-4", delta: "C final" });
    mainRuntime.handle?.emit({ type: "status", inputId: "main-turn-4", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.interrupts).toHaveLength(2);
    expect(replies).toEqual([{ contextId: "context-C", text: "C final" }]);
    expect(supervisor.listMainMessages().map((message) => ({ role: message.role, text: message.text }))).toEqual([
      { role: "user", text: "A" },
      { role: "user", text: "B" },
      { role: "user", text: "C" },
      { role: "assistant", text: "C final" },
    ]);
  });

  it("prewarms Picky without creating a visible session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

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
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.setMainAgentThinkingLevel("high");
    await supervisor.prewarmMainAgent("/tmp/project");

    expect(mainRuntime.thinkingLevels).toEqual(["high"]);
    expect(mainRuntime.handle?.thinkingLevels).toEqual(["high"]);
  });

  it("applies configured thinking level to the active main runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.prewarmMainAgent("/tmp/project");
    const handle = mainRuntime.handle!;
    await supervisor.setMainAgentThinkingLevel("xhigh");

    expect(mainRuntime.thinkingLevels).toEqual(["xhigh"]);
    expect(handle.thinkingLevels).toEqual(["xhigh"]);
  });

  it("injects the Picky bootstrap pair on a fresh prewarm so the rules ride the first turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.prewarmMainAgent("/tmp/project");
    expect(mainRuntime.handle?.bootstrapInjections).toHaveLength(1);
    const injection = mainRuntime.handle!.bootstrapInjections[0]!;
    expect(injection.user).toContain("natural sentences in the user's language");
    expect(injection.assistant).toBe("OK");
  });

  it("skips bootstrap injection when Picky resumes from a persisted Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.saveMainAgentState({ sessionFilePath: "/tmp/main-pi-session.jsonl", cwd: "/tmp/project", messages: [] });
    const mainRuntime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), store, { mainRuntime });
    await supervisor.load();

    await supervisor.route(context("재시작 후 질문"));

    expect(mainRuntime.handle?.bootstrapInjections).toEqual([]);
  });

  it("injects the bootstrap pair when the main runtime cannot prewarm and goes straight to create", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    await supervisor.route(context("첫 창을연 텍스트"));

    expect(mainRuntime.createCalls).toBe(1);
    expect(mainRuntime.handle?.bootstrapInjections).toHaveLength(1);
  });

  it("defers a Pickle completion notification while the handoff turn is still in flight, then drains it without losing the reply", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    // 1) Voice command routed to Picky — Picky turn starts running.
    const userCtx = context("피클 띄워서 작업 해줘");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();

    // 2) Main decides to hand off: it announces the handoff text (which sets
    //    suppressNextMainReply=true) and spawns the Pickle session. The handoff
    //    turn has NOT yet emitted status:completed.
    supervisor.announceMainHandoff(userCtx.id, "피클에 위임할게요");
    const pickleSession = await supervisor.createPickleFromHandoff(userCtx, { title: "task", instructions: "do it" });
    await settle();

    expect(replies).toContainEqual({ contextId: userCtx.id, text: "피클에 위임할게요" });

    // 3) Pickle session finishes BEFORE the main handoff turn ends. The
    //    notification must be deferred — sending it now would clobber
    //    mainReplyContextId/mainDraft and let the handoff turn's
    //    suppressNextMainReply swallow this Pickle completion's reply.
    sideRuntime.handle?.emit({ type: "assistant_delta", delta: "피클 결과 X" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);

    // 4) Handoff turn finally ends. suppressNextMainReply is consumed here, the
    //    handoff turn's draft is discarded, and the deferred Pickle completion is
    //    drained from the queue and delivered as a fresh Picky turn.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "핸드오프 잔여 텍스트" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0]?.text).toContain(`Title: ${pickleSession.title}`);
    // Handoff-turn draft must NOT have been emitted as a quickReply (suppress
    // consumed it correctly), and no spurious Pickle-completion reply was emitted.
    expect(replies.filter((entry) => entry.contextId === pickleSession.id)).toHaveLength(0);
    expect(replies.filter((entry) => entry.contextId === userCtx.id)).toEqual([
      { contextId: userCtx.id, text: "피클에 위임할게요" },
    ]);

    // 5) Main processes the Pickle-completion follow-up. Its reply must arrive
    //    against the Pickle session's id, not the original user context.
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "피클 작업 마쳤어요" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toContainEqual({ contextId: pickleSession.id, text: "피클 작업 마쳤어요" });
  });

  // Regression for the `/diff-review` follow-up: the previous fix synthesized a `completed`
  // runtime status with `noTurnRan: true` so the HUD spinner clears, but the Pickle session must
  // NOT also notify Picky (no real turn produced any progress). RuntimeEventHandler
  // skips notifyPickleCompletion + materializeTerminalArtifacts when `noTurnRan` is set.
  it("does not notify Picky when a Pickle session synthesizes a completion without running a turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });

    const userCtx = context("피클 시작");
    await supervisor.route(userCtx);
    supervisor.announceMainHandoff(userCtx.id, "피클 위임");
    const pickleSession = await supervisor.createPickleFromHandoff(userCtx, { title: "task", instructions: "do it" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // PiSdkRuntimeSession marks synthetic slash-command completions with `noTurnRan: true`.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
    await settle();

    expect(supervisor.get(pickleSession.id)?.status).toBe("completed");
    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
  });

  it("delivers a Pickle completion notification immediately when Picky is idle", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const userCtx = context("피클 시작");
    await supervisor.route(userCtx);
    supervisor.announceMainHandoff(userCtx.id, "피클 위임");
    const pickleSession = await supervisor.createPickleFromHandoff(userCtx, { title: "task", instructions: "do it" });

    // Handoff turn ends BEFORE the Pickle session emits its terminal status.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // Now main is idle; Pickle completion must be delivered immediately.
    // Pi can emit both turn_end and agent_end as completed back-to-back; those
    // duplicate terminal events must still produce only one main follow-up.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => (mainRuntime.handle?.followUps ?? []).length === 1);

    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0]?.text).toContain(`Title: ${pickleSession.title}`);

    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "바로 끝났어요" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => replies.some((reply) => reply.contextId === pickleSession.id && reply.text === "바로 끝났어요"));

    expect(replies).toContainEqual({ contextId: pickleSession.id, text: "바로 끝났어요" });
  });

  it("never queues a deferred notification when notifyMainOnCompletion is disabled", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });

    const userCtx = context("조용히 진행");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();
    supervisor.announceMainHandoff(userCtx.id, "위임");
    const pickleSession = await supervisor.createPickleFromHandoff(userCtx, { title: "task", instructions: "do it" });
    await supervisor.setNotifyMainOnCompletion(pickleSession.id, false);

    // Pickle terminal status arrives while main is still busy on the handoff turn.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // Main turn ends. Drain runs but the disabled flag must keep the queue empty.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
  });

  it("clears deferred Pickle completion notifications when Picky is aborted", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });

    const userCtx = context("긴 작업");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();
    supervisor.announceMainHandoff(userCtx.id, "위임");
    await supervisor.createPickleFromHandoff(userCtx, { title: "task", instructions: "do it" });

    // Pickle completes while main is still running the handoff turn → deferred.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const handleBeforeAbort = mainRuntime.handle;
    expect(handleBeforeAbort?.followUps ?? []).toHaveLength(0);

    // User aborts Picky before the handoff turn finishes. The pending
    // queue must be cleared so a stale terminal event from the orphaned handle
    // can never re-trigger delivery against a fresh main session.
    await supervisor.abortMainAgent();
    handleBeforeAbort?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(handleBeforeAbort?.followUps ?? []).toHaveLength(0);

    // A new Picky turn must not see the dropped notification either.
    await supervisor.route(context("다음 질문"));
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
  });

  it("drops a queued Pickle completion when the user steers the Pickle session before Picky drains it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));

    const userCtx = context("이어서 진행");
    await supervisor.route(userCtx);
    mainRuntime.handle?.emit({ type: "status", status: "running", summary: "Running" });
    await settle();
    supervisor.announceMainHandoff(userCtx.id, "위임");
    const pickleSession = await supervisor.createPickleFromHandoff(userCtx, { title: "task", instructions: "do it" });

    // Pickle completes while main is mid-turn → deferred.
    sideRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    // User immediately steers the Pickle session, which also drops the deferred
    // notification because the pickle run is no longer terminal.
    await supervisor.steerPickleSession(pickleSession.id, "한 번 더 다듬어줘");

    // Main handoff turn ends; the drain must find an empty queue.
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(mainRuntime.handle?.followUps ?? []).toHaveLength(0);
    expect(replies.filter((entry) => entry.contextId === pickleSession.id)).toEqual([]);
  });

  // Regression for the double-ack bug seen in Realtime mode: the Realtime model
  // itself produces a natural follow-up text after `picky_start_pickle` returns
  // (via `main_realtime_turn_done` -> `appendMainMessage`). If `announceMainHandoff`
  // also injects the curated handoffAck as both a `mainMessage` and a `quickReply`,
  // the Messages tab ends up with two assistant bubbles for one user turn and the
  // system TTS races (and reorders) against the Realtime audio stream. The
  // interaction reducer also gets a `quickReply replyKind=handoffAck` for the same
  // inputId the Realtime turn still owns, locking the cursor in `.processing`.
  // The fix gates the curated-ack side effects on `isMainRealtimeRuntime`.
  it("skips the curated handoffAck mainMessage and quickReply when the main runtime is Realtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    // Minimal stub that passes isMainRealtimeRuntime. We are not exercising the
    // realtime turn surface here — only verifying that announceMainHandoff stays
    // silent on this runtime.
    const realtimeRuntime = {
      async create(_prompt: BuiltPrompt, _options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
        throw new Error("create not used in this test");
      },
      async configureMainRealtimeAuth() {},
      async beginMainRealtimeVoiceTurn() {},
      async appendMainRealtimeInputAudio() {},
      async commitMainRealtimeVoiceTurn() {},
      async cancelMainRealtimeVoiceTurn() {},
    } as unknown as AgentRuntime;
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime: realtimeRuntime });
    const replies: Array<{ contextId: string; text: string; replyKind?: string }> = [];
    const mainMessages: Array<{ role: string; text: string }> = [];
    supervisor.on("quickReply", (contextId, text, metadata = {}) => replies.push({ contextId, text, replyKind: metadata.replyKind }));
    supervisor.on("mainMessage", (message) => mainMessages.push({ role: message.role, text: message.text }));

    const userCtx = context("피클 띄워줘");
    supervisor.announceMainHandoff(userCtx.id, "피클에 위임할게요");
    await settle();

    // Neither the curated ack bubble nor its TTS quickReply may fire on the
    // Realtime path — the Realtime model's own follow-up will handle the ack.
    expect(mainMessages.filter((message) => message.text === "피클에 위임할게요")).toHaveLength(0);
    expect(replies.filter((reply) => reply.replyKind === "handoffAck")).toHaveLength(0);
    expect(supervisor.listMainMessages()).toHaveLength(0);
  });

  it("routes complex requests to the long-running runtime", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir), { taskRouter: new StaticTaskRouter({ route: "handoff", reason: "needs tools" }) });

    const session = await supervisor.route(context("코드 수정해줘"));

    expect(session?.title).toBe("코드 수정해줘");
    expect(supervisor.list()).toHaveLength(1);
  });

  it("ignores fire-and-forget setWidget updates", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("widget update"));
    const logEvents: string[] = [];
    let sessionEvents = 0;
    supervisor.on("log", (_sessionId, line) => logEvents.push(line));
    supervisor.on("session", () => { sessionEvents += 1; });
    const logCountBefore = supervisor.get(session.id)?.logs.length ?? 0;

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: false,
      request: { id: "widget-1", sessionId: session.id, method: "setWidget", createdAt: "2026-05-01T00:00:00.000Z", title: "setWidget" },
    });
    await settle();

    const updated = supervisor.get(session.id);
    expect(updated?.status).toBe("running");
    expect(updated?.pendingExtensionUiRequest).toBeUndefined();
    expect(updated?.logs.length).toBe(logCountBefore);
    expect(logEvents).toEqual([]);
    expect(sessionEvents).toBe(0);
  });

  it("records non-blocking notify requests as visible session messages with severity", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("notify update"));
    const appended: Array<{ text?: string; notifyType?: string }> = [];
    supervisor.on("messageAppended", (_sessionId, message) => appended.push({ text: message.text, notifyType: message.notifyType }));

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: false,
      request: { id: "notify-1", sessionId: session.id, method: "notify", createdAt: "2026-05-01T00:00:00.000Z", prompt: "Long extension update", notifyType: "warning" },
    });
    await waitUntil(() => appended.some((message) => message.text === "Long extension update" && message.notifyType === "warning"));

    const updated = supervisor.get(session.id);
    expect(updated?.status).toBe("running");
    expect(updated?.pendingExtensionUiRequest).toBeUndefined();
    expect(updated?.messages?.some((message) => message.id === "notify-1" && message.text === "Long extension update" && message.notifyType === "warning")).toBe(true);
    expect(appended).toContainEqual({ text: "Long extension update", notifyType: "warning" });
  });

  it("keeps streamed assistant text in one bubble when notify fires mid-stream", async () => {
    // Regression: an extension `notify` arriving while assistant deltas were still
    // streaming used to flush the in-flight draft and force the remaining deltas
    // into a fresh agent_text message, visibly cutting the response in half with
    // the notify wedged in between (e.g. observational memory hooks bisecting an
    // answer). The notify should record as its own message without splitting the
    // surrounding assistant reply.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("notify mid-stream"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "PR 생성 완료. " });
    runtime.handle?.emit({ type: "assistant_delta", delta: "본문 wrapper 는 flex-1..." });
    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: false,
      request: { id: "notify-mid", sessionId: session.id, method: "notify", createdAt: "2026-05-01T00:00:00.000Z", prompt: "Observational memory: 3 observations recorded", notifyType: "info" },
    });
    runtime.handle?.emit({ type: "assistant_delta", delta: " 은 현상이 안 났는데, " });
    runtime.handle?.emit({ type: "assistant_delta", delta: "Lexical 기본값 이후 회귀로 드러남." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "done" });
    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).some((message) => message.kind === "agent_text"));

    const textBubbles = (supervisor.get(session.id)?.messages ?? []).filter((message) => message.kind === "agent_text");
    expect(textBubbles).toHaveLength(1);
    expect(textBubbles[0].text).toBe("PR 생성 완료. 본문 wrapper 는 flex-1... 은 현상이 안 났는데, Lexical 기본값 이후 회귀로 드러남.");
    const visible = (supervisor.get(session.id)?.messages ?? []).filter((message) => message.kind === "agent_text" || message.id === "notify-mid");
    expect(visible.map((message) => ({ id: message.id, kind: message.kind }))).toEqual([
      { id: "notify-mid", kind: "system" },
      { id: textBubbles[0].id, kind: "agent_text" },
    ]);
  });

  it("appends runtime logs without emitting full session updates", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const store = new SessionStore(dir);
    const supervisor = new SessionSupervisor(runtime, store);
    const session = await supervisor.create(context("runtime log"));
    const logEvents: string[] = [];
    let sessionEvents = 0;
    supervisor.on("log", (_sessionId, line) => logEvents.push(line));
    supervisor.on("session", () => { sessionEvents += 1; });

    runtime.handle?.emit({ type: "log", line: "tool output line" });
    await waitUntil(() => logEvents.length === 1);

    expect(supervisor.get(session.id)?.logs.at(-1)).toBe("tool output line");
    expect(logEvents).toEqual(["tool output line"]);
    expect(sessionEvents).toBe(0);
    const persisted = (await store.loadAll()).find((candidate) => candidate.id === session.id);
    expect(persisted?.logs.at(-1)).toBe("tool output line");
  });

  it("preserves concurrent appended logs and derived artifacts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-concurrent-log-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("concurrent logs"));
    const appendLog = (supervisor as unknown as { appendLog(sessionId: string, line: string): Promise<void> }).appendLog.bind(supervisor);

    await Promise.all([
      appendLog(session.id, "Changed file: M Picky/App.swift - HUD fix\nhttps://github.com/acme/repo/pull/42"),
      appendLog(session.id, "pi session: /tmp/picky-concurrent-pi-session.jsonl"),
    ]);

    const updated = supervisor.get(session.id);
    expect(updated?.logs).toEqual(expect.arrayContaining([
      "Changed file: M Picky/App.swift - HUD fix\nhttps://github.com/acme/repo/pull/42",
      "pi session: /tmp/picky-concurrent-pi-session.jsonl",
    ]));
    expect(updated?.changedFiles).toEqual([{ status: "M", path: "Picky/App.swift", summary: "HUD fix" }]);
    expect(updated?.artifacts.some((artifact) => artifact.kind === "github" && artifact.url === "https://github.com/acme/repo/pull/42")).toBe(true);
    expect(updated?.piSessionFilePath).toBe("/tmp/picky-concurrent-pi-session.jsonl");
  });

  it("stores the final assistant answer instead of replacing it with a generic completion label", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("summarize video"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "영상 요약입니다.\n\n핵심 내용은 agentic engineering입니다." });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    const updated = supervisor.get(session.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.finalAnswer).toBe("영상 요약입니다.\n\n핵심 내용은 agentic engineering입니다.");
    expect(updated.lastSummary).toBe("영상 요약입니다.");
    expect(updated.artifacts.some((artifact) => artifact.id === "report")).toBe(false);
  });

  it("surfaces a GitHub PR link badge as soon as the assistant message commits, even before terminal status", async () => {
    // Regression: a `/skill:create-pr` follow-up typically leaves the Pickle session at
    // waiting_for_input (not terminal) once the assistant emits "PR 생성 완료:
    // https://github.com/...". `materializeTerminalArtifacts` only runs at terminal status, so
    // the Links row in the HUD used to stay empty until either a new patch refreshed the
    // `gh pr view` cache or the session eventually terminated. The status handler must extract
    // link artifacts from the flushed assistant text on waiting_for_input so the PR badge
    // appears immediately.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-link-waiting-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const session = await supervisor.create(context("create pr"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "PR 생성 완료: https://github.com/example/product/pull/2993\n- 브랜치: refactor/cli-shared-arg-helpers" });
    runtime.handle?.emit({ type: "status", status: "waiting_for_input", summary: "Awaiting next instruction", finalAnswer: "PR 생성 완료: https://github.com/example/product/pull/2993\n- 브랜치: refactor/cli-shared-arg-helpers" });
    await settle();

    const updated = supervisor.get(session.id)!;
    expect(updated.status).toBe("waiting_for_input");
    expect(updated.artifacts.some((artifact) => artifact.kind === "github" && artifact.url === "https://github.com/example/product/pull/2993")).toBe(true);
  });

  it("emits terminal session update before terminal artifacts", async () => {
    // Use a link in the final answer so the materializer emits a github
    // artifact at terminal status — this is the only artifact type produced
    // automatically now that session report file generation is gone.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const events: string[] = [];
    supervisor.on("session", (updated) => {
      if (updated.status === "completed") events.push("session:completed");
    });
    supervisor.on("artifact", (_sessionId, artifact) => events.push(`artifact:${artifact.kind}`));
    // Emit the GitHub URL inside the assistant's final answer so it shows up in
    // session.finalAnswer when the materializer runs at terminal status — not in
    // the initial context (which would emit the artifact at create time, before
    // session:completed).
    const session = await supervisor.create(context("ordering terminal"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "Done. PR: https://github.com/acme/repo/pull/99" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(events.indexOf("session:completed")).toBeGreaterThanOrEqual(0);
    expect(events.indexOf("artifact:github")).toBeGreaterThan(events.indexOf("session:completed"));
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

  it("forwards non-blocking editor text requests without entering waiting_for_input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    const requests: Array<{ id: string; method: string; text?: string }> = [];
    supervisor.on("extensionUiRequest", (request) => requests.push({ id: request.id, method: request.method, text: request.text }));
    const session = await supervisor.create(context("editor text"));

    runtime.handle?.emit({
      type: "extension_ui",
      waitsForInput: false,
      request: { id: "editor-1", sessionId: session.id, method: "set_editor_text", createdAt: "2026-05-01T00:00:00.000Z", text: "review comments" },
    });
    await settle();

    expect(requests).toEqual([{ id: "editor-1", method: "set_editor_text", text: "review comments" }]);
    expect(supervisor.get(session.id)?.status).not.toBe("waiting_for_input");
    expect(supervisor.get(session.id)?.pendingExtensionUiRequest).toBeUndefined();
    expect(supervisor.get(session.id)?.logs).toContain("extension ui: set_editor_text");
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

  it("waits for a pending session runtime before falling back to the main command catalog", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    const session = await supervisor.create({ ...context("slash command race"), cwd: "/tmp/product" });
    await supervisor.prewarmMainAgent("/tmp/picky");
    mainRuntime.handle!.slashCommands = [{ name: "skill:context7-cli", description: "Docs", source: "skill" }];

    const sideHandle = new ManualHandle(session.id);
    sideHandle.slashCommands = [{ name: "skill:general-click-event-insight", description: "Product insight", source: "skill" }];
    (supervisor as unknown as { runtimeHandles: Map<string, RuntimeSessionHandle> }).runtimeHandles.delete(session.id);
    (supervisor as unknown as { pendingRuntimeHandles: Map<string, Promise<RuntimeSessionHandle>> }).pendingRuntimeHandles.set(
      session.id,
      delay(20).then(() => sideHandle),
    );

    await expect(supervisor.listSlashCommands(session.id)).resolves.toEqual([
      { name: "skill:general-click-event-insight", description: "Product insight", source: "skill" },
    ]);
  });

  it("resumes a persisted Pickle session command catalog before falling back to the main catalog", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "restored-product-session",
      title: "Restored product session",
      status: "completed",
      cwd: "/tmp/product",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      logs: ["Picky handoff: investigate", "pi session: /tmp/product-pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });
    const runtime = new ResumableRuntime([
      { name: "skill:general-click-event-insight", description: "Product insight", source: "skill" },
    ]);
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(runtime, store, { mainRuntime });
    await supervisor.load();
    await supervisor.prewarmMainAgent("/tmp/picky");
    mainRuntime.handle!.slashCommands = [{ name: "skill:context7-cli", description: "Docs", source: "skill" }];

    await expect(supervisor.listSlashCommands("restored-product-session")).resolves.toEqual([
      { name: "skill:general-click-event-insight", description: "Product insight", source: "skill" },
    ]);
    expect(runtime.resumeCalls).toEqual([{ sessionFilePath: "/tmp/product-pi-session.jsonl", cwd: "/tmp/product", sessionId: "restored-product-session" }]);
  });

  it("falls back to the main runtime command catalog when the session handle is missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir), { mainRuntime });
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

  it("appends user_text messages from steer, follow-up, extension answer, and Picky handoff sources", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-message-sources-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("message sources"));

    await supervisor.steer(session.id, "user steer");
    await supervisor.followUp(session.id, "user follow-up");
    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-message", sessionId: session.id, method: "input", prompt: "Need input", createdAt: "2026-05-01T00:00:00.000Z" } });
    await settle();
    await supervisor.answerExtensionUi(session.id, "ui-message", "answer text");
    const pickle = await supervisor.createPickleFromHandoff(context("handoff"), { title: "Pickle", instructions: "main instructions" });

    expect(supervisor.get(session.id)?.messages?.filter((message) => message.kind === "user_text").map((message) => ({ text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { text: "user steer", originatedBy: "user" },
      { text: "user follow-up", originatedBy: "user" },
      { text: "answer text", originatedBy: "user" },
    ]);
    expect(supervisor.get(pickle.id)?.messages).toMatchObject([{ kind: "user_text", text: "main instructions", originatedBy: "main_agent" }]);
  });

  it("records Pi extension injected user and custom messages as extension-origin user bubbles", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pi-extension-input-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("extension input"));

    runtime.handle?.emit({ type: "input_message", role: "user", text: "subagent finished", originatedBy: "pi_extension" });
    runtime.handle?.emit({ type: "input_message", role: "custom", text: "custom extension note", originatedBy: "pi_extension" });
    runtime.handle?.emit({ type: "input_message", role: "custom", text: "hidden custom note", originatedBy: "pi_extension", display: false });
    await settle();

    expect(supervisor.get(session.id)?.messages?.filter((message) => message.kind === "user_text").map((message) => ({ text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { text: "subagent finished", originatedBy: "pi_extension" },
      { text: "custom extension note", originatedBy: "pi_extension" },
    ]);
  });

  it("revives a terminal session when a Pi extension triggers a new input turn", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-pi-extension-revive-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("extension revive"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "old answer" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "old answer" });
    await settle();
    expect(supervisor.get(session.id)?.status).toBe("completed");

    runtime.handle?.emit({ type: "input_message", role: "user", text: "extension follow-up", originatedBy: "pi_extension" });
    await waitUntil(() => supervisor.get(session.id)?.status === "running");

    expect(supervisor.get(session.id)?.status).toBe("running");
    expect(supervisor.get(session.id)?.finalAnswer).toBeUndefined();
    expect(supervisor.get(session.id)?.messages?.at(-1)).toMatchObject({ kind: "user_text", text: "extension follow-up", originatedBy: "pi_extension" });
  });

  it("defers user_text for queued follow-ups until Pi dequeues them", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-deferred-followup-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("deferred follow-up"));
    runtime.handle!.isStreaming = true;

    await supervisor.followUp(session.id, "queued one");
    await supervisor.followUp(session.id, "queued two");
    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: ["queued one", "queued two"] });
    await settle();

    // While items sit in Pi's queue we must NOT have written user_text yet (otherwise the HUD
    // would hide the pending bubbles). queuedFollowUps is the source of truth for the UI.
    expect(userTexts(supervisor.get(session.id))).toEqual([]);
    expect(supervisor.get(session.id)?.queuedFollowUps?.map((item) => item.text)).toEqual(["queued one", "queued two"]);

    // Pi dequeues "queued one" → user_text is recorded for that text only.
    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: ["queued two"] });
    await settle();
    expect(userTexts(supervisor.get(session.id))).toEqual(["queued one"]);
    expect(supervisor.get(session.id)?.queuedFollowUps?.map((item) => item.text)).toEqual(["queued two"]);

    // Pi dequeues "queued two" → second user_text recorded.
    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: [] });
    await waitUntil(() => userTexts(supervisor.get(session.id)).length === 2);
    expect(userTexts(supervisor.get(session.id))).toEqual(["queued one", "queued two"]);
    expect(supervisor.get(session.id)?.queuedFollowUps).toEqual([]);
  });

  it("tags duplicate queued follow-ups with stable delivery ids and drains one occurrence at a time", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-queued-followup-ids-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("duplicate follow-up ids"));
    runtime.handle!.isStreaming = true;

    await supervisor.followUp(session.id, "repeat");
    await supervisor.followUp(session.id, "repeat");
    await settle();

    const queued = supervisor.get(session.id)?.queuedFollowUps ?? [];
    expect(queued.map((item) => item.text)).toEqual(["repeat", "repeat"]);
    expect(queued.every((item) => typeof item.id === "string" && item.id.length > 0)).toBe(true);
    expect(new Set(queued.map((item) => item.id)).size).toBe(2);

    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: ["repeat"] });
    await settle();

    expect(userTexts(supervisor.get(session.id))).toEqual(["repeat"]);
    expect(supervisor.get(session.id)?.queuedFollowUps?.map((item) => ({ id: item.id, text: item.text }))).toEqual([
      { id: queued[1]!.id, text: "repeat" },
    ]);

    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: [] });
    await settle();

    expect(userTexts(supervisor.get(session.id))).toEqual(["repeat", "repeat"]);
    expect(supervisor.get(session.id)?.queuedFollowUps).toEqual([]);
  });

  it("clears the matching pending bubble when a queued follow-up materializes without a final queue_update", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-stale-followup-bubble-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("stale pending follow-up"));
    runtime.handle!.isStreaming = true;
    runtime.handle!.onFollowUp = (handle) => {
      // Pi accepted and then consumed the prompt before emitting the trailing empty queue_update.
      // The supervisor must not leave the already-materialized user_text visible as a pending item.
      handle.queuedFollowUpTexts = [];
    };

    await supervisor.followUp(session.id, "materialize me");
    await waitUntil(() => userTexts(supervisor.get(session.id)).length === 1);

    expect(userTexts(supervisor.get(session.id))).toEqual(["materialize me"]);
    expect(supervisor.get(session.id)?.queuedFollowUps).toEqual([]);
  });

  it("records user_text without waiting for queue_update when Pi runs the prompt inline", async () => {
    // Simulate Pi's direct path: handle.followUp accepts the prompt but never queues it. The
    // supervisor should detect the prompt is not in Pi's queue snapshot and drain the pending
    // user_text immediately so the journal does not stay empty forever.
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-idle-followup-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("idle follow-up"));
    runtime.handle!.onFollowUp = (handle) => {
      // Mimic Pi's direct (non-streaming) path: the prompt is consumed inline rather than enqueued.
      handle.followUps = [];
    };

    await supervisor.followUp(session.id, "idle text");
    await settle();

    expect(userTexts(supervisor.get(session.id))).toEqual(["idle text"]);
  });

  it("carries attachedImagesCount from the context screenshots to the journaled user_text on steer", async () => {
    // PTT / QuickInput on an armed Pickle ships screenshots via the structured
    // context channel, not in the message body. The HUD needs the count back
    // on the user_text bubble so the user can tell the model received them.
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-attached-images-count-steer-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("armed pickle"));

    await supervisor.steer(session.id, "refocus on this", {
      ...context("new direction"),
      id: "ctx-attached-steer",
      screenshots: [
        { id: "s1", label: "Main", path: "/tmp/a.png", screenId: "main", isCursorScreen: true },
        { id: "s2", label: "Sec", path: "/tmp/b.png", screenId: "sec" },
      ],
    });
    await settle();

    const userMessages = (supervisor.get(session.id)?.messages ?? []).filter(
      (message) => message.kind === "user_text",
    );
    expect(userMessages.map((m) => ({ text: m.text, count: m.attachedImagesCount }))).toEqual([
      { text: "refocus on this", count: 2 },
    ]);
  });

  it("carries attachedImagesCount from the context screenshots to the journaled user_text on follow-up", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-attached-images-count-followup-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("armed pickle"));
    // Mimic Pi's direct (non-streaming) path: the prompt is consumed inline rather than enqueued,
    // so the supervisor drains the pending user_text immediately.
    runtime.handle!.onFollowUp = (handle) => {
      handle.followUps = [];
    };

    await supervisor.followUp(session.id, "check the screen", {
      ...context("look here"),
      id: "ctx-attached-followup",
      screenshots: [
        { id: "s1", label: "Main", path: "/tmp/a.png", screenId: "main", isCursorScreen: true },
      ],
    });
    await settle();

    const userMessages = (supervisor.get(session.id)?.messages ?? []).filter(
      (message) => message.kind === "user_text",
    );
    expect(userMessages.map((m) => ({ text: m.text, count: m.attachedImagesCount }))).toEqual([
      { text: "check the screen", count: 1 },
    ]);
  });

  it("omits attachedImagesCount when no screenshots are attached", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-no-attached-images-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("plain pickle"));

    await supervisor.steer(session.id, "plain text steer");
    await settle();

    const userMessages = (supervisor.get(session.id)?.messages ?? []).filter(
      (message) => message.kind === "user_text",
    );
    expect(userMessages).toHaveLength(1);
    expect(userMessages[0]?.text).toBe("plain text steer");
    expect(userMessages[0]?.attachedImagesCount).toBeUndefined();
  });

  it("discards pending follow-up text when runtime delivery fails", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-failed-followup-pending-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("failed follow-up"));
    runtime.handle!.onFollowUp = () => {
      throw new Error("delivery down");
    };

    await supervisor.followUp(session.id, "retry me");
    await waitUntil(() => supervisor.get(session.id)?.status === "failed");

    const pending = (supervisor as unknown as { pendingQueueDeliveries: Map<string, unknown[]> }).pendingQueueDeliveries;
    expect(pending.get(session.id)).toBeUndefined();
    expect(userTexts(supervisor.get(session.id))).toEqual([]);
  });

  it("records a command receipt instead of user_text for non-skill slash follow-ups", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-slash-receipt-followup-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("slash follow-up receipt"));

    await supervisor.followUp(session.id, "/c");
    await settle();

    expect(userTexts(supervisor.get(session.id))).toEqual([]);
    expect(commandReceipts(supervisor.get(session.id))).toEqual([{ command: "/c", status: "submitted", detail: undefined }]);
  });

  it("marks a non-skill slash command receipt as failed when delivery fails", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-slash-receipt-failed-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("slash receipt failure"));
    runtime.handle!.onSteer = () => {
      throw new Error("unmerged paths");
    };

    await expect(supervisor.steer(session.id, "/c")).rejects.toThrow("unmerged paths");
    await settle();

    expect(userTexts(supervisor.get(session.id))).toEqual([]);
    expect(commandReceipts(supervisor.get(session.id))).toEqual([{ command: "/c", status: "failed", detail: "unmerged paths" }]);
  });

  it("records exactly one raw user_text for a queued /skill: follow-up after the runtime adapter translates Pi's expansion", async () => {
    // Regression: before the runtime adapter translated Pi-side slash command expansions back to
    // the raw user text, this scenario produced THREE artifacts for one follow-up: a premature
    // raw user bubble from drainPendingTextOnce (because isPromptInRuntimeQueue looked up raw
    // text in a queue that contained the expansion), a pending-bubble showing the expansion in
    // the HUD follow-up area, and a duplicate "from Pi extension" bubble when Pi emitted the
    // expansion as a role="custom" message. With the adapter translating both queue snapshots
    // and suppressing the custom echo, the supervisor sees the raw text in `queue_update` and
    // records it exactly once.
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-skill-followup-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("skill follow-up"));
    runtime.handle!.isStreaming = true;

    const rawText = "/skill:self-healing 으로 검증";
    await supervisor.followUp(session.id, rawText);
    await settle();

    // While the slash command sits in Pi's queue (post-translation: raw text), nothing should
    // have been written to the journal yet. The HUD shows the raw text in the pending bubble.
    expect(userTexts(supervisor.get(session.id))).toEqual([]);
    expect(supervisor.get(session.id)?.queuedFollowUps?.map((item) => item.text)).toEqual([rawText]);

    // Pi dequeues the slash command and starts the turn. The adapter has suppressed the
    // role="custom" echo that Pi would have emitted with the SKILL.md body.
    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: [] });
    await settle();

    const messages = supervisor.get(session.id)?.messages ?? [];
    expect(messages.filter((message) => message.kind === "user_text").map((message) => ({ text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { text: rawText, originatedBy: "user" },
    ]);
    expect(supervisor.get(session.id)?.queuedFollowUps).toEqual([]);
  });

  it("drops pending queue deliveries on clearQueue without recording user_text", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-clearqueue-pending-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("clearqueue"));
    runtime.handle!.isStreaming = true;

    await supervisor.followUp(session.id, "discard me");
    runtime.handle?.emit({ type: "queue_update", steering: [], followUp: ["discard me"] });
    await settle();
    expect(supervisor.get(session.id)?.queuedFollowUps?.map((item) => item.text)).toEqual(["discard me"]);

    await supervisor.clearQueue(session.id, "all");
    await settle();
    expect(supervisor.get(session.id)?.queuedFollowUps).toEqual([]);
    expect(userTexts(supervisor.get(session.id))).toEqual([]);
  });

  it("commits assistant text before queued follow-up turn", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-message-queued-turn-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("queued final answer"));

    runtime.handle?.emit({ type: "assistant_delta", delta: "Turn one answer" });
    runtime.handle?.emit({ type: "status", status: "running", summary: "Next turn started", finalAnswer: "Turn one answer" });
    await waitUntil(() => supervisor.get(session.id)?.messages?.some((message) => message.kind === "agent_text") === true);

    expect(supervisor.get(session.id)?.messages).toMatchObject([{ kind: "agent_text", text: "Turn one answer" }]);
    expect(supervisor.get(session.id)?.finalAnswer).toBe("Turn one answer");
  });

  it("emits incremental events with monotonic seq across message and queue paths", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-message-queue-seq-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    await supervisor.create(context("message queue seq"));
    const events: Array<{ type: "message" | "queue"; seq: number }> = [];
    supervisor.on("messageAppended", (_sessionId, _message, seq) => events.push({ type: "message", seq }));
    supervisor.on("queueUpdated", (_sessionId, _steering, _followUp, _steeringMode, _followUpMode, seq) => events.push({ type: "queue", seq }));

    runtime.handle?.emit({ type: "assistant_delta", delta: "Answer" });
    runtime.handle?.emit({ type: "status", status: "running", summary: "Next", finalAnswer: "Answer" });
    runtime.handle?.emit({ type: "queue_update", steering: ["next steer"], followUp: [] });
    await waitUntil(() => events.length === 2);

    expect(events.map((event) => event.seq)).toEqual([...events].map((event) => event.seq).sort((a, b) => a - b));
    expect(new Set(events.map((event) => event.seq)).size).toBe(events.length);
  });

  it("syncs Pi terminal transcript additions into canonical session messages without duplicating prior HUD history", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-sync-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "old prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "old answer" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:03.000Z", message: { role: "user", content: "terminal thanks", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:04.000Z", message: { role: "assistant", content: [{ type: "text", text: "terminal reply" }], timestamp: 0, stopReason: "stop" } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-sync-session",
      title: "Terminal sync",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "old answer",
      finalAnswer: "old answer",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "msg-existing-user", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "old prompt" },
        { id: "msg-existing-agent", kind: "agent_text", createdAt: "2026-05-01T00:00:02.000Z", text: "old answer" },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<unknown> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("terminal-sync-session", "a1");

    expect(supervisor.get("terminal-sync-session")?.messages?.map((message) => ({ id: message.id, kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { id: "msg-existing-user", kind: "user_text", text: "old prompt", originatedBy: "user" },
      { id: "msg-existing-agent", kind: "agent_text", text: "old answer", originatedBy: undefined },
      { id: "msg-pi-user-u2", kind: "user_text", text: "terminal thanks", originatedBy: "pi_extension" },
      { id: "msg-pi-agent-a2", kind: "agent_text", text: "terminal reply", originatedBy: undefined },
    ]);
    expect(supervisor.get("terminal-sync-session")?.lastSummary).toBe("terminal reply");
    expect(supervisor.get("terminal-sync-session")?.finalAnswer).toBe("terminal reply");
    expect(outcomes).toEqual([{ baselineFound: true, importedMessageCount: 2, activeLastMessageId: "a2", baselinePiMessageId: "a1" }]);

    await supervisor.syncTerminalSession("terminal-sync-session", "a1");
    expect(supervisor.get("terminal-sync-session")?.messages).toHaveLength(4);
    expect(outcomes.at(-1)).toEqual({ baselineFound: true, importedMessageCount: 0, activeLastMessageId: "a2", baselinePiMessageId: "a1" });
  });

  it("imports Pi terminal thinking and tool-call activity into canonical session messages", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-sync-activity-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "old prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "old answer" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "a1", timestamp: "2026-05-01T00:00:03.000Z", message: { role: "assistant", content: [{ type: "thinking", thinking: "checking terminal state" }, { type: "toolCall", name: "bash", arguments: { command: "echo hi" } }, { type: "toolCall", name: "read", arguments: { path: "README.md" } }], timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "t1", parentId: "a2", timestamp: "2026-05-01T00:00:04.000Z", message: { role: "toolResult", content: [{ type: "text", text: "tool output" }], timestamp: 0 } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-sync-activity-session",
      title: "Terminal sync activity",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "old answer",
      finalAnswer: "old answer",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "msg-existing-user", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "old prompt" },
        { id: "msg-existing-agent", kind: "agent_text", createdAt: "2026-05-01T00:00:02.000Z", text: "old answer" },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<unknown> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("terminal-sync-activity-session", "a1");

    expect(supervisor.get("terminal-sync-activity-session")?.messages?.map((message) => ({ id: message.id, kind: message.kind, text: message.text, activitySnapshot: message.activitySnapshot }))).toEqual([
      { id: "msg-existing-user", kind: "user_text", text: "old prompt", activitySnapshot: undefined },
      { id: "msg-existing-agent", kind: "agent_text", text: "old answer", activitySnapshot: undefined },
      { id: "msg-pi-thinking-a2", kind: "agent_thinking", text: "checking terminal state", activitySnapshot: undefined },
      { id: "msg-pi-activity-a2", kind: "agent_activity", text: undefined, activitySnapshot: { read: 1, bash: 1, edit: 0, write: 0, thinking: 0, other: 0 } },
    ]);
    expect(supervisor.get("terminal-sync-activity-session")?.lastSummary).toBe("old answer");
    expect(supervisor.get("terminal-sync-activity-session")?.finalAnswer).toBe("old answer");
    expect(outcomes).toEqual([{ baselineFound: true, importedMessageCount: 2, activeLastMessageId: "a2", baselinePiMessageId: "a1" }]);
  });

  it("skips re-importing a HUD follow-up that Pi mirrored to the JSONL while the terminal overlay was open", async () => {
    // Regression: opening the terminal overlay captures a baseline Pi message id. If the user
    // sends a HUD follow-up while the overlay is still open, agentd records the prompt locally
    // as a user_text (originatedBy="user") AND Pi writes the same prompt into the JSONL. When
    // the overlay closes, syncTerminalSession used to import that JSONL user message as a
    // pi_extension duplicate, producing two identical bubbles in the HUD (the second one
    // labelled "from Pi extension"). The sync must dedup the mirrored entry against the
    // HUD-originated user_text recorded after baseline.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-sync-hud-dedup-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "old prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "old answer" }], timestamp: 0, stopReason: "stop" } }),
      // HUD follow-up sent while the terminal overlay was open: agentd already journaled this
      // text locally, and Pi mirrored it into the JSONL.
      JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:05.000Z", message: { role: "user", content: "내가 방금 뭐라고 말했지?", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:06.000Z", message: { role: "assistant", content: [{ type: "text", text: "방금 요청은 이거였습니다: ..." }], timestamp: 0, stopReason: "stop" } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-sync-hud-dedup",
      title: "HUD dedup",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "old answer",
      finalAnswer: "old answer",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "msg-existing-user", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "old prompt" },
        { id: "msg-existing-agent", kind: "agent_text", createdAt: "2026-05-01T00:00:02.000Z", text: "old answer" },
        // HUD follow-up recorded while terminal overlay was still open. createdAt is later than
        // the baseline (a1) timestamp, so the sync should treat this as a candidate to dedup.
        { id: "msg-hud-followup", kind: "user_text", createdAt: "2026-05-01T00:00:04.000Z", originatedBy: "user", text: "내가 방금 뭐라고 말했지?" },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<{ baselineFound: boolean; importedMessageCount: number; activeLastMessageId?: string; baselinePiMessageId?: string }> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("terminal-sync-hud-dedup", "a1");

    expect(supervisor.get("terminal-sync-hud-dedup")?.messages?.map((message) => ({ id: message.id, kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { id: "msg-existing-user", kind: "user_text", text: "old prompt", originatedBy: "user" },
      { id: "msg-existing-agent", kind: "agent_text", text: "old answer", originatedBy: undefined },
      { id: "msg-hud-followup", kind: "user_text", text: "내가 방금 뭐라고 말했지?", originatedBy: "user" },
      { id: "msg-pi-agent-a2", kind: "agent_text", text: "방금 요청은 이거였습니다: ...", originatedBy: undefined },
    ]);
    // Only the assistant message gets imported; the mirrored HUD user_text is suppressed.
    expect(outcomes).toEqual([{ baselineFound: true, importedMessageCount: 1, activeLastMessageId: "a2", baselinePiMessageId: "a1" }]);
  });

  it("skips re-importing a HUD assistant answer that Pi mirrored to the JSONL while the terminal overlay was open", async () => {
    // Regression: while a terminal overlay is open, the HUD can receive the assistant answer
    // through the live runtime stream first. Closing the overlay then syncs the same Pi JSONL
    // assistant message back into the HUD as msg-pi-agent-*, producing two identical answer
    // bubbles. Dedup post-baseline assistant text against already-journaled HUD agent_text.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-sync-agent-dedup-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "old prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "old answer" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:05.000Z", message: { role: "user", content: "흠", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:06.000Z", message: { role: "assistant", content: [{ type: "text", text: "괜찮습니다. 이어서 볼게요." }], timestamp: 0, stopReason: "stop" } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-sync-agent-dedup",
      title: "Agent dedup",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "괜찮습니다. 이어서 볼게요.",
      finalAnswer: "괜찮습니다. 이어서 볼게요.",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "msg-existing-user", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "old prompt" },
        { id: "msg-existing-agent", kind: "agent_text", createdAt: "2026-05-01T00:00:02.000Z", text: "old answer" },
        { id: "msg-hud-followup", kind: "user_text", createdAt: "2026-05-01T00:00:04.000Z", originatedBy: "user", text: "흠" },
        { id: "msg-hud-agent", kind: "agent_text", createdAt: "2026-05-01T00:00:06.000Z", text: "괜찮습니다. 이어서 볼게요." },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<{ baselineFound: boolean; importedMessageCount: number; activeLastMessageId?: string; baselinePiMessageId?: string }> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("terminal-sync-agent-dedup", "a1");

    expect(supervisor.get("terminal-sync-agent-dedup")?.messages?.map((message) => ({ id: message.id, kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { id: "msg-existing-user", kind: "user_text", text: "old prompt", originatedBy: "user" },
      { id: "msg-existing-agent", kind: "agent_text", text: "old answer", originatedBy: undefined },
      { id: "msg-hud-followup", kind: "user_text", text: "흠", originatedBy: "user" },
      { id: "msg-hud-agent", kind: "agent_text", text: "괜찮습니다. 이어서 볼게요.", originatedBy: undefined },
    ]);
    expect(outcomes).toEqual([{ baselineFound: true, importedMessageCount: 0, activeLastMessageId: "a2", baselinePiMessageId: "a1" }]);
  });

  it("still imports a terminal-typed user_text that happens to repeat older HUD text but precedes the baseline", async () => {
    // Guard rail: dedup is scoped to the terminal-open window (createdAt >= baseline). A HUD
    // user_text recorded BEFORE baseline must not suppress an unrelated import even if the
    // text happens to match — that import is legitimately new terminal activity.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-sync-dedup-window-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "ping", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "pong" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:05.000Z", message: { role: "user", content: "ping", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:06.000Z", message: { role: "assistant", content: [{ type: "text", text: "pong again" }], timestamp: 0, stopReason: "stop" } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-sync-window",
      title: "Dedup window",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "pong",
      finalAnswer: "pong",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        // Earlier HUD message with the same text as the post-baseline terminal entry. Because
        // its createdAt is before the baseline (a1 at 00:00:02), it must NOT be used to dedup.
        { id: "msg-hud-old", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "ping" },
        { id: "msg-existing-agent", kind: "agent_text", createdAt: "2026-05-01T00:00:02.000Z", text: "pong" },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();

    await supervisor.syncTerminalSession("terminal-sync-window", "a1");

    expect(supervisor.get("terminal-sync-window")?.messages?.map((message) => ({ id: message.id, originatedBy: message.originatedBy, text: message.text }))).toEqual([
      { id: "msg-hud-old", originatedBy: "user", text: "ping" },
      { id: "msg-existing-agent", originatedBy: undefined, text: "pong" },
      { id: "msg-pi-user-u2", originatedBy: "pi_extension", text: "ping" },
      { id: "msg-pi-agent-a2", originatedBy: undefined, text: "pong again" },
    ]);
  });

  it("ignores trailing Pi session_info metadata when syncing terminal messages", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-session-info-sync-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "terminal prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "terminal answer" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "session_info", id: "info1", name: "Renamed terminal session", timestamp: "2026-05-01T00:00:03.000Z" }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-session-info-sync",
      title: "Terminal session info sync",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "ready",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<unknown> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("terminal-session-info-sync");

    expect(supervisor.get("terminal-session-info-sync")?.messages?.map((message) => ({ id: message.id, kind: message.kind, text: message.text }))).toEqual([
      { id: "msg-pi-user-u1", kind: "user_text", text: "terminal prompt" },
      { id: "msg-pi-agent-a1", kind: "agent_text", text: "terminal answer" },
    ]);
    expect(outcomes).toEqual([{ baselineFound: true, importedMessageCount: 2, activeLastMessageId: "a1", baselinePiMessageId: undefined }]);
  });

  it("keeps the active terminal sync path connected through custom transcript entries", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-custom-path-sync-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "old prompt", timestamp: 0 } }),
      JSON.stringify({ type: "custom_message", customType: "todo-write-context", id: "custom1", parentId: "u1", timestamp: "2026-05-01T00:00:01.500Z", content: "hidden context" }),
      JSON.stringify({ type: "message", id: "a1", parentId: "custom1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "terminal answer" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "custom", customType: "todo-write-overlay-state", id: "custom2", parentId: "a1", timestamp: "2026-05-01T00:00:02.500Z", content: "hidden overlay" }),
      JSON.stringify({ type: "message", id: "u2", parentId: "custom2", timestamp: "2026-05-01T00:00:03.000Z", message: { role: "user", content: "follow-up", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:04.000Z", message: { role: "assistant", content: [{ type: "text", text: "follow-up answer" }], timestamp: 0, stopReason: "stop" } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-custom-path-session",
      title: "Terminal custom path sync",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "old prompt",
      finalAnswer: "old prompt",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "msg-existing-user", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "old prompt" },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<unknown> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("terminal-custom-path-session", "u1");

    expect(supervisor.get("terminal-custom-path-session")?.messages?.map((message) => ({ id: message.id, kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { id: "msg-existing-user", kind: "user_text", text: "old prompt", originatedBy: "user" },
      { id: "msg-pi-agent-a1", kind: "agent_text", text: "terminal answer", originatedBy: undefined },
      { id: "msg-pi-user-u2", kind: "user_text", text: "follow-up", originatedBy: "pi_extension" },
      { id: "msg-pi-agent-a2", kind: "agent_text", text: "follow-up answer", originatedBy: undefined },
    ]);
    expect(outcomes).toEqual([{ baselineFound: true, importedMessageCount: 3, activeLastMessageId: "a2", baselinePiMessageId: "u1" }]);
  });

  it("emits a baseline-not-found terminalSessionSyncOutcome when the baseline is no longer on the active path", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-baseline-miss-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "only entry", timestamp: 0 } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "baseline-miss-session",
      title: "Baseline miss",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "prev",
      finalAnswer: "prev",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();
    const outcomes: Array<unknown> = [];
    supervisor.on("terminalSessionSyncOutcome", (_sessionId, outcome) => outcomes.push(outcome));

    await supervisor.syncTerminalSession("baseline-miss-session", "unknown-baseline-id");

    expect(outcomes).toEqual([{ baselineFound: false, importedMessageCount: 0, activeLastMessageId: "u1", baselinePiMessageId: "unknown-baseline-id" }]);
  });

  it("marks a cancelled session completed when terminal sync imports a recovery answer", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-cancelled-sync-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "old prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "old answer" }], timestamp: 0, stopReason: "stop" } }),
      JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:03.000Z", message: { role: "user", content: "terminal recovery request", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:04.000Z", message: { role: "assistant", content: [{ type: "text", text: "terminal recovery answer" }], timestamp: 0, stopReason: "stop" } }),
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "cancelled-terminal-sync-session",
      title: "Cancelled terminal sync",
      status: "cancelled",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Cancelled by user",
      finalAnswer: undefined,
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [
        { id: "msg-existing-user", kind: "user_text", createdAt: "2026-05-01T00:00:01.000Z", originatedBy: "user", text: "old prompt" },
        { id: "msg-system-cancelled", kind: "system", createdAt: "2026-05-01T00:00:02.500Z", text: "Cancelled by user" },
      ],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();

    await supervisor.syncTerminalSession("cancelled-terminal-sync-session", "a1");

    const synced = supervisor.get("cancelled-terminal-sync-session");
    expect(synced?.status).toBe("completed");
    expect(synced?.lastSummary).toBe("terminal recovery answer");
    expect(synced?.finalAnswer).toBe("terminal recovery answer");
    expect(synced?.messages?.map((message) => message.text).filter(Boolean)).toContain("terminal recovery request");
  });

  it("tails the Pi JSONL while a terminal session is active and patches status from user/assistant entries", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-tail-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "prior prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "prior answer" }], timestamp: 0, stopReason: "stop" } }),
      "",
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-tail-session",
      title: "Terminal tail",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "prior answer",
      finalAnswer: "prior answer",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-session", true);

    // User just typed a new prompt in the TUI; dock should flip to running.
    await appendFile(piSessionFile, JSON.stringify({ type: "message", id: "u2", parentId: "a1", timestamp: "2026-05-01T00:00:03.000Z", message: { role: "user", content: "new TUI prompt", timestamp: 0 } }) + "\n");
    await waitUntil(() => supervisor.get("terminal-tail-session")?.status === "running");

    // Pi finishes the turn; dock should flip back to completed.
    await appendFile(piSessionFile, JSON.stringify({ type: "message", id: "a2", parentId: "u2", timestamp: "2026-05-01T00:00:04.000Z", message: { role: "assistant", content: [{ type: "text", text: "TUI answer" }], timestamp: 0, stopReason: "stop" } }) + "\n");
    await waitUntil(() => supervisor.get("terminal-tail-session")?.status === "completed");

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-session", false);
  });

  it("flips to waiting_for_input when an ask_user_question toolCall is open in the tailed transcript", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-tail-aw-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, "");
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-tail-await",
      title: "Terminal tail awaiting",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "prev",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-await", true);

    // User prompt -> running.
    await appendFile(piSessionFile, JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:11.000Z", message: { role: "user", content: "please ask me", timestamp: 0 } }) + "\n");
    await waitUntil(() => supervisor.get("terminal-tail-await")?.status === "running");

    // Assistant opens ask_user_question (no toolResult yet) -> waiting_for_input.
    await appendFile(piSessionFile, JSON.stringify({
      type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:12.000Z",
      message: { role: "assistant", content: [{ type: "toolCall", name: "ask_user_question", arguments: {} }], timestamp: 0 },
    }) + "\n");
    await waitUntil(() => supervisor.get("terminal-tail-await")?.status === "waiting_for_input");

    // User answers -> the tool resolves; next assistant entry with no open toolCall -> completed.
    await appendFile(piSessionFile, JSON.stringify({
      type: "message", id: "a2", parentId: "a1", timestamp: "2026-05-01T00:00:13.000Z",
      message: { role: "assistant", content: [{ type: "text", text: "thanks!" }], timestamp: 0, stopReason: "stop" },
    }) + "\n");
    await waitUntil(() => supervisor.get("terminal-tail-await")?.status === "completed");

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-await", false);
  });

  it("stays in running when a non-blocking tool (bash) is the open toolCall in the tailed transcript", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-tail-bash-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, "");
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-tail-bash",
      title: "Terminal tail bash",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "prev",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-bash", true);
    await appendFile(piSessionFile, JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:11.000Z", message: { role: "user", content: "run a command", timestamp: 0 } }) + "\n");
    await waitUntil(() => supervisor.get("terminal-tail-bash")?.status === "running");

    await appendFile(piSessionFile, JSON.stringify({
      type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:12.000Z",
      message: { role: "assistant", content: [{ type: "toolCall", name: "bash", arguments: { command: "ls" } }], timestamp: 0 },
    }) + "\n");
    // Give the watcher a couple of beats; status should remain running, NOT waiting_for_input.
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(supervisor.get("terminal-tail-bash")?.status).toBe("running");

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-bash", false);
  });

  it("keeps cancelled status sticky against tail-derived running transitions", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-tail-cancelled-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, "");
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-tail-cancelled",
      title: "Terminal tail cancelled",
      status: "cancelled",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "Cancelled by user",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [],
    });
    const supervisor = new SessionSupervisor(new ManualRuntime(), store);
    await supervisor.load();

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-cancelled", true);
    await appendFile(piSessionFile, JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:11.000Z", message: { role: "user", content: "hi", timestamp: 0 } }) + "\n");
    // Give the tail watcher a couple of beats; status must not flip.
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(supervisor.get("terminal-tail-cancelled")?.status).toBe("cancelled");
    await supervisor.setTerminalSessionTailEnabled("terminal-tail-cancelled", false);
  });

  it("invalidates the attached runtime handle when the tailed Pi JSONL is rewritten so the next user input re-resumes from disk", async () => {
    // Regression: opening the Pi TUI overlay and running /compact rewrites the JSONL while
    // the agentd's in-memory Pi runtime still holds pre-compaction message ids and parent
    // chains. Without invalidation, the next HUD follow-up would be sent to the LLM with the
    // stale pre-TUI context AND Pi SDK would append the answer with a stale `parentId`,
    // orphaning the compaction summary fork when the user reopens the TUI. The tail watcher
    // must therefore signal the supervisor on truncation and the supervisor must drop the
    // handle so `runtimeHandleForUserInput` falls through to `tryResumeRuntimeHandle`.
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-terminal-tail-truncate-"));
    const piSessionFile = join(dir, "pi-session.jsonl");
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:00.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "u1", parentId: null, timestamp: "2026-05-01T00:00:01.000Z", message: { role: "user", content: "prior prompt", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "a1", parentId: "u1", timestamp: "2026-05-01T00:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "prior answer" }], timestamp: 0, stopReason: "stop" } }),
      "",
    ].join("\n"));
    const store = new SessionStore(dir);
    await store.save({
      id: "terminal-tail-truncate",
      title: "Terminal tail truncate",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      lastSummary: "prior answer",
      finalAnswer: "prior answer",
      logs: [`pi session: ${piSessionFile}`],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [],
    });

    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();

    // First follow-up resumes from disk because the daemon just started; this attaches the
    // in-memory handle that the truncation must invalidate.
    await supervisor.followUp("terminal-tail-truncate", "before TUI follow-up");
    expect(runtime.resumeCalls).toHaveLength(1);

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-truncate", true);

    // Simulate `pi --session ... /compact` rewriting the JSONL from the TUI process.
    await truncate(piSessionFile, 0);
    await new Promise((resolve) => setTimeout(resolve, 80));
    await writeFile(piSessionFile, [
      JSON.stringify({ type: "session", version: 3, id: "pi-session", timestamp: "2026-05-01T00:00:30.000Z", cwd: "/tmp/project" }),
      JSON.stringify({ type: "message", id: "compact-u", parentId: null, timestamp: "2026-05-01T00:00:31.000Z", message: { role: "user", content: "please compact", timestamp: 0 } }),
      JSON.stringify({ type: "message", id: "compact-a", parentId: "compact-u", timestamp: "2026-05-01T00:00:32.000Z", message: { role: "assistant", content: [{ type: "text", text: "compacted summary" }], timestamp: 0, stopReason: "stop" } }),
      "",
    ].join("\n"));
    await new Promise((resolve) => setTimeout(resolve, 200));

    await supervisor.setTerminalSessionTailEnabled("terminal-tail-truncate", false);

    // After the overlay closes, the next follow-up must re-resume from disk so the runtime
    // sees the post-compaction transcript instead of the cached pre-compaction state.
    await supervisor.followUp("terminal-tail-truncate", "after TUI follow-up");

    expect(runtime.resumeCalls).toHaveLength(2);
    expect(runtime.resumeCalls[1]).toEqual({ sessionFilePath: piSessionFile, cwd: "/tmp/project", sessionId: "terminal-tail-truncate" });
  });

  it("preserves persisted messages on daemon restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-message-hydrate-"));
    const store = new SessionStore(dir);
    await store.save({
      id: "persisted-message-session",
      title: "Persisted messages",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:10.000Z",
      logs: ["Picky handoff: investigate", "pi session: /tmp/pi-session.jsonl"],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [{ id: "msg-existing", kind: "user_text", createdAt: "2026-05-01T00:00:00.000Z", originatedBy: "user", text: "first steer" }],
    });

    const runtime = new ResumableRuntime();
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();
    await supervisor.steerPickleSession("persisted-message-session", "second steer");

    expect(supervisor.get("persisted-message-session")?.messages?.map((message) => message.kind)).toEqual(["user_text", "user_text"]);
    expect(supervisor.get("persisted-message-session")?.messages?.map((message) => message.text)).toEqual(["first steer", "second steer"]);
  });

  it("coalesces rapid thinking deltas before emitting message replacements", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-thinking-coalesce-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("thinking coalesce"));
    const events: Array<{ type: "append" | "replace"; kind?: string; text?: string }> = [];
    supervisor.on("messageAppended", (_sessionId, message) => events.push({ type: "append", kind: message.kind, text: message.text }));
    supervisor.on("messageReplaced", (_sessionId, _messageId, message) => events.push({ type: "replace", kind: message.kind, text: message.text }));

    for (let index = 0; index < 5; index += 1) runtime.handle?.emit({ type: "thinking_delta", delta: `step ${index} ` });

    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).some((message) => message.kind === "agent_thinking"));
    await waitUntil(() => events.some((event) => event.kind === "agent_thinking"));

    const thinkingEvents = events.filter((event) => event.kind === "agent_thinking");
    expect(thinkingEvents).toEqual([{ type: "append", kind: "agent_thinking", text: "step 0 step 1 step 2 step 3 step 4 " }]);
    expect(supervisor.get(session.id)?.thinkingPreview).toBe("step 0 step 1 step 2 step 3 step 4");
  });

  it("commits assistant text and thinking messages at runtime boundaries", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-message-runtime-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("runtime messages"));
    const events: Array<{ type: string; kind?: string; messageId?: string; seq: number }> = [];
    supervisor.on("messageAppended", (_sessionId, message, seq) => events.push({ type: "append", kind: message.kind, seq }));
    supervisor.on("messageReplaced", (_sessionId, messageId, _message, seq) => events.push({ type: "replace", messageId, seq }));
    supervisor.on("messageRemoved", (_sessionId, messageId, seq) => events.push({ type: "remove", messageId, seq }));

    runtime.handle?.emit({ type: "thinking_delta", delta: "thinking" });
    runtime.handle?.emit({ type: "thinking_delta", delta: " more" });
    runtime.handle?.emit({ type: "assistant_delta", delta: "Answer" });
    runtime.handle?.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    runtime.handle?.emit({ type: "assistant_delta", delta: " done" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => {
      const messages = supervisor.get(session.id)?.messages ?? [];
      return messages.filter((message) => message.kind === "agent_text").length === 2
        && messages.some((message) => message.kind === "agent_activity");
    });

    expect(events.map((event) => event.type)).toContain("append");
    expect(events.some((event) => event.type === "replace" || event.type === "remove")).toBe(true);
    expect(supervisor.get(session.id)?.messages?.map((message) => ({ kind: message.kind, text: message.text, activitySnapshot: message.activitySnapshot }))).toEqual([
      { kind: "agent_text", text: "Answer", activitySnapshot: undefined },
      { kind: "agent_text", text: " done", activitySnapshot: undefined },
      { kind: "agent_activity", text: undefined, activitySnapshot: { read: 0, bash: 1, edit: 0, write: 0, thinking: 1, other: 0 } },
    ]);
  });

  it("records extension questions, failed status, cancelled status, and pinned intro messages", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-message-terminal-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const questionSession = await supervisor.create(context("question"));

    runtime.handle?.emit({ type: "extension_ui", waitsForInput: true, request: { id: "question-message", sessionId: questionSession.id, method: "input", prompt: "Need input", createdAt: "2026-05-01T00:00:00.000Z" } });
    await waitUntil(() => supervisor.get(questionSession.id)?.messages?.[0]?.kind === "agent_question");

    const failedSession = await supervisor.create(context("failed"));
    runtime.handle?.emit({ type: "status", status: "failed", summary: "Runtime failed" });
    await waitUntil(() => supervisor.get(failedSession.id)?.messages?.some((message) => message.kind === "agent_error") === true);

    const cancelledSession = await supervisor.create(context("cancelled"));
    runtime.handle?.emit({ type: "status", status: "cancelled", summary: "Cancelled" });
    await waitUntil(() => supervisor.get(cancelledSession.id)?.messages?.some((message) => message.kind === "system") === true);

    const pinned = await supervisor.pinPickleSession(context("\nPinned goal\nMore"), "Pinned title");

    expect(supervisor.get(questionSession.id)?.messages?.[0]).toMatchObject({ id: "question-message", kind: "agent_question" });
    expect(supervisor.get(failedSession.id)?.messages).toMatchObject([{ kind: "agent_error", errorMessage: "Runtime failed" }]);
    expect(supervisor.get(cancelledSession.id)?.messages).toMatchObject([{ kind: "system", text: "Cancelled by user" }]);
    expect(pinned.messages?.map((message) => ({ kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { kind: "user_text", text: "Pinned goal", originatedBy: "pi_extension" },
      { kind: "system", text: "Pinned from idle Pi session", originatedBy: undefined },
      { kind: "agent_text", text: "Pinned from an idle Pi session. No Pickle run has been started yet.", originatedBy: undefined },
    ]);
  });

  it("rejects invalid follow-up transitions", async () => {
    const supervisor = await makeSupervisor();
    const session = await supervisor.create(context("cancel then follow"));
    await supervisor.abort(session.id);
    await expect(supervisor.followUp(session.id, "nope")).rejects.toThrow(/Cannot follow up/);
  });

  // ----- User memory CRUD -----

  it("persists a new user memory and exposes it via listUserMemories + the supervisor snapshot", async () => {
    const supervisor = await makeSupervisor();
    const result = await supervisor.addUserMemory("GitHub handle is jonghakseo");
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.memory.content).toBe("GitHub handle is jonghakseo");
    expect(result.memory.id).toMatch(/^[0-9a-f]{12}$/);

    const all = supervisor.listUserMemories();
    expect(all).toHaveLength(1);
    expect(all[0]?.id).toBe(result.memory.id);
  });

  it("round-trips user memories through the on-disk picky.json", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const supervisorA = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await supervisorA.load();
    const addResult = await supervisorA.addUserMemory("Treat \"이 페이지\" as the OpenAI Realtime guide");
    expect(addResult.ok).toBe(true);
    if (!addResult.ok) return;

    // Fresh supervisor over the same store should see the persisted memory.
    const supervisorB = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
    await supervisorB.load();
    expect(supervisorB.listUserMemories().map((m) => m.content)).toEqual([
      "Treat \"이 페이지\" as the OpenAI Realtime guide",
    ]);
  });

  it("rejects empty memory content", async () => {
    const supervisor = await makeSupervisor();
    const result = await supervisor.addUserMemory("   \n  ");
    expect(result.ok).toBe(false);
    expect(supervisor.listUserMemories()).toHaveLength(0);
  });

  it("rejects memories that exceed the per-item char limit", async () => {
    const supervisor = await makeSupervisor();
    const result = await supervisor.addUserMemory("x".repeat(501));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toMatch(/max 500/);
  });

  it("rejects adds once the item-count cap is reached", async () => {
    const supervisor = await makeSupervisor();
    for (let i = 0; i < 50; i += 1) {
      const result = await supervisor.addUserMemory(`memory ${i}`);
      expect(result.ok).toBe(true);
    }
    const overflow = await supervisor.addUserMemory("one too many");
    expect(overflow.ok).toBe(false);
    if (overflow.ok) return;
    expect(overflow.error).toMatch(/memory item limit/);
  });

  it("rejects adds once the total character budget would be exceeded", async () => {
    const supervisor = await makeSupervisor();
    // Each entry is 400 chars; 10 entries = 4000 chars (at the limit).
    for (let i = 0; i < 10; i += 1) {
      const result = await supervisor.addUserMemory("x".repeat(400));
      expect(result.ok).toBe(true);
    }
    const overflow = await supervisor.addUserMemory("y".repeat(50));
    expect(overflow.ok).toBe(false);
    if (overflow.ok) return;
    expect(overflow.error).toMatch(/budget/);
  });

  it("updates a memory in place, keeping the id and bumping updatedAt", async () => {
    const supervisor = await makeSupervisor();
    const added = await supervisor.addUserMemory("old content");
    expect(added.ok).toBe(true);
    if (!added.ok) return;
    const originalCreatedAt = added.memory.createdAt;
    await delay(5);
    const updated = await supervisor.updateUserMemory(added.memory.id, "new content");
    expect(updated.ok).toBe(true);
    if (!updated.ok) return;
    expect(updated.memory.id).toBe(added.memory.id);
    expect(updated.memory.content).toBe("new content");
    expect(updated.memory.createdAt).toBe(originalCreatedAt);
    expect(updated.memory.updatedAt >= originalCreatedAt).toBe(true);
    expect(supervisor.listUserMemories()).toHaveLength(1);
  });

  it("reports an error when updating an unknown memory id", async () => {
    const supervisor = await makeSupervisor();
    const result = await supervisor.updateUserMemory("missing", "hello");
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toMatch(/no memory with id/);
  });

  it("forgets a memory by id and returns the removed item", async () => {
    const supervisor = await makeSupervisor();
    const added = await supervisor.addUserMemory("remember me, but not for long");
    expect(added.ok).toBe(true);
    if (!added.ok) return;
    const removed = await supervisor.removeUserMemory(added.memory.id);
    expect(removed.ok).toBe(true);
    if (!removed.ok) return;
    expect(removed.removed.content).toBe("remember me, but not for long");
    expect(supervisor.listUserMemories()).toHaveLength(0);
  });

  it("reports an error when forgetting an unknown memory id", async () => {
    const supervisor = await makeSupervisor();
    const result = await supervisor.removeUserMemory("missing");
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toMatch(/no memory with id/);
  });

  it("notifies the main runtime to refresh instructions on every CRUD mutation", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    // Minimal stub that passes isMainRealtimeRuntime so the supervisor's
    // notifyUserMemoryChanged actually fires refreshUserMemoryInstructions.
    // We don't exercise any other realtime surface here.
    const refreshes: string[] = [];
    const realtimeRuntime = {
      async create(_prompt: BuiltPrompt, _options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
        throw new Error("create not used in this test");
      },
      async configureMainRealtimeAuth() {},
      async beginMainRealtimeVoiceTurn() {},
      async appendMainRealtimeInputAudio() {},
      async commitMainRealtimeVoiceTurn() {},
      async cancelMainRealtimeVoiceTurn() {},
      refreshUserMemoryInstructions() { refreshes.push("refresh"); },
    } as unknown as AgentRuntime;
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime: realtimeRuntime });
    await supervisor.load();

    const added = await supervisor.addUserMemory("alpha");
    expect(added.ok).toBe(true);
    if (!added.ok) return;
    await supervisor.updateUserMemory(added.memory.id, "alpha v2");
    await supervisor.removeUserMemory(added.memory.id);

    expect(refreshes).toHaveLength(3);
  });

  // ----- Pickle inspection -----

  it("inspectPickleSession returns the supervisor's in-memory snapshot for known ids and undefined for unknown ids", async () => {
    const supervisor = await makeSupervisor();
    const created = await supervisor.create(context("hand off please"));
    const found = supervisor.inspectPickleSession(created.id);
    expect(found?.id).toBe(created.id);
    expect(found?.title).toBe(created.title);

    expect(supervisor.inspectPickleSession("not-a-real-id")).toBeUndefined();
  });

  // ----- Unarchive -----

  it("setSessionArchived(false) flips archived back to false and clears archivedAt without touching status", async () => {
    const supervisor = await makeSupervisor();
    const created = await supervisor.create(context("task to archive"));
    const originalStatus = created.status;

    const archived = await supervisor.setSessionArchived(created.id, true);
    expect(archived.archived).toBe(true);
    expect(typeof archived.archivedAt).toBe("string");

    const restored = await supervisor.setSessionArchived(created.id, false);
    expect(restored.archived).toBe(false);
    expect(restored.archivedAt).toBeUndefined();
    // Status is preserved — unarchive only flips the dock visibility flag.
    expect(restored.status).toBe(originalStatus);
  });

  it("setSessionArchived is idempotent when called twice with the same flag", async () => {
    const supervisor = await makeSupervisor();
    const created = await supervisor.create(context("idempotent test"));
    const a = await supervisor.setSessionArchived(created.id, false);
    const b = await supervisor.setSessionArchived(created.id, false);
    expect(a.archived).toBe(false);
    expect(b.archived).toBe(false);
  });

  it("emits sessionArchivedAuthoritative on every setSessionArchived call so Picky can sync its local archive UserDefaults", async () => {
    // Regression: picky_unarchive_pickle calls setSessionArchived(false) but
    // the Picky session view model intentionally ignores the `archived` field
    // on plain `sessionUpdated` events (to avoid mid-flight unarchive flicker
    // when an unrelated update arrives while the user has just
    // archived/unarchived locally). The dedicated event is the only signal
    // Picky trusts to mutate its local manuallyArchivedSessionIDs set.
    const supervisor = await makeSupervisor();
    const created = await supervisor.create(context("emit auth event"));
    const events: Array<{ sessionId: string; archived: boolean }> = [];
    supervisor.on("sessionArchivedAuthoritative", (sessionId: string, archived: boolean) => {
      events.push({ sessionId, archived });
    });

    await supervisor.setSessionArchived(created.id, true);
    await supervisor.setSessionArchived(created.id, false);

    expect(events).toEqual([
      { sessionId: created.id, archived: true },
      { sessionId: created.id, archived: false },
    ]);
  });
});

describe("SessionSupervisor archived session purge", () => {
  const baseSession = (overrides: Partial<PickyAgentSession>): PickyAgentSession => ({
    id: "s",
    title: "t",
    status: "completed",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    logs: [], tools: [], artifacts: [], changedFiles: [],
    queuedSteers: [], queuedFollowUps: [],
    steeringMode: "one-at-a-time", followUpMode: "one-at-a-time",
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...overrides,
  });
  const purge = (sup: SessionSupervisor, now: number) =>
    (sup as unknown as { purgeStaleArchivedSessions: (n: number) => Promise<void> }).purgeStaleArchivedSessions(now);

  it("deletes archived terminal sessions older than 7 days", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    await store.save(baseSession({
      id: "old-archived",
      archived: true,
      archivedAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    const now = new Date("2026-01-09T00:00:00.000Z").getTime();
    await purge(supervisor, now);
    expect(supervisor.get("old-archived")).toBeUndefined();
    const reloaded = await store.loadAll();
    expect(reloaded.find((s) => s.id === "old-archived")).toBeUndefined();
  });

  it("retains archived terminal sessions within 7 days", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    const now = Date.now();
    await store.save(baseSession({
      id: "young-archived",
      archived: true,
      archivedAt: new Date(now - 4 * 24 * 60 * 60 * 1000).toISOString(),
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    await purge(supervisor, now);
    expect(supervisor.get("young-archived")).toBeDefined();
  });

  it("retains non-archived sessions regardless of age", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    await store.save(baseSession({
      id: "old-not-archived",
      archived: false,
      updatedAt: "2024-01-01T00:00:00.000Z",
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    await purge(supervisor, Date.now());
    expect(supervisor.get("old-not-archived")).toBeDefined();
  });

  it("falls back to updatedAt when archivedAt is missing (legacy data)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    await store.save(baseSession({
      id: "legacy",
      archived: true,
      updatedAt: "2026-01-01T00:00:00.000Z",
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    const now = new Date("2026-01-09T00:00:00.000Z").getTime();
    await purge(supervisor, now);
    expect(supervisor.get("legacy")).toBeUndefined();
  });

  it("deletes archived blocked sessions older than 7 days", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    await store.save(baseSession({
      id: "old-blocked",
      status: "blocked",
      archived: true,
      archivedAt: "2026-01-01T00:00:00.000Z",
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    const now = new Date("2026-01-09T00:00:00.000Z").getTime();
    await purge(supervisor, now);
    expect(supervisor.get("old-blocked")).toBeUndefined();
  });

  it("purges stale archived sessions automatically during load", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    const old = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
    await store.save(baseSession({
      id: "auto-purged",
      archived: true,
      archivedAt: old,
      updatedAt: old,
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    expect(supervisor.get("auto-purged")).toBeUndefined();
  });

  it("skips sessions with invalid ids without disrupting other purges", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-purge-test-"));
    const store = new SessionStore(dir);
    const archivedAt = Date.now() - 4 * 24 * 60 * 60 * 1000;
    await store.save(baseSession({
      id: "valid-old",
      archived: true,
      archivedAt: new Date(archivedAt).toISOString(),
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    (supervisor as unknown as { sessions: Map<string, PickyAgentSession> }).sessions.set(
      "",
      baseSession({ id: "", archived: true, archivedAt: new Date(archivedAt).toISOString() }),
    );
    const now = archivedAt + 8 * 24 * 60 * 60 * 1000;
    await purge(supervisor, now);
    expect(supervisor.get("valid-old")).toBeUndefined();
    expect((supervisor as unknown as { sessions: Map<string, PickyAgentSession> }).sessions.has("")).toBe(true);
  });
});

describe("SessionSupervisor deleteSession", () => {
  const baseDeleteSession = (overrides: Partial<PickyAgentSession>): PickyAgentSession => ({
    id: "s",
    title: "t",
    status: "completed",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    logs: [], tools: [], artifacts: [], changedFiles: [],
    queuedSteers: [], queuedFollowUps: [],
    steeringMode: "one-at-a-time", followUpMode: "one-at-a-time",
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...overrides,
  });

  it("removes an archived terminal session from disk and the in-memory map", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-delete-test-"));
    const store = new SessionStore(dir);
    await store.save(baseDeleteSession({
      id: "delete-me",
      archived: true,
      archivedAt: "2026-01-02T00:00:00.000Z",
    }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();

    await supervisor.deleteSession("delete-me");

    expect(supervisor.get("delete-me")).toBeUndefined();
    const reloaded = await store.loadAll();
    expect(reloaded.find((s) => s.id === "delete-me")).toBeUndefined();
  });

  it("is a no-op for unknown ids", async () => {
    const supervisor = await makeSupervisor();
    await expect(supervisor.deleteSession("never-existed")).resolves.toBeUndefined();
  });

  it("refuses to delete a session that is not archived", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-delete-test-"));
    const store = new SessionStore(dir);
    await store.save(baseDeleteSession({ id: "unarchived", archived: false }));
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();

    await expect(supervisor.deleteSession("unarchived")).rejects.toThrow(/not archived/);
    expect(supervisor.get("unarchived")).toBeDefined();
  });

  it("refuses to delete a session that is not in a terminal state", async () => {
    const supervisor = await makeSupervisor();
    // Inject a running session directly into the in-memory map. We bypass
    // store.save + load because load() rewrites archived+non-terminal sessions
    // to `cancelled` for crash recovery, which would mask the running case we
    // want to assert here.
    (supervisor as unknown as { sessions: Map<string, PickyAgentSession> }).sessions.set(
      "running",
      baseDeleteSession({
        id: "running",
        status: "running",
        archived: true,
        archivedAt: "2026-01-02T00:00:00.000Z",
      }),
    );
    await expect(supervisor.deleteSession("running")).rejects.toThrow(/terminal state/);
    expect(supervisor.get("running")).toBeDefined();
  });

  describe("reloadPlugins", () => {
    it("sends /reload via followUp to every idle Pickle session", async () => {
      const dir = await mkdtemp(join(tmpdir(), "picky-agentd-reload-idle-"));
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
      await supervisor.load();
      const pickle = await supervisor.createPickleFromHandoff(context("idle pickle"), { title: "Idle", instructions: "Investigate idle" });
      // Pickle starts as `running` after createPickleFromHandoff because the
      // supervisor immediately delivers the seed prompt. Park it back at
      // waiting_for_input so reloadPlugins treats it as idle and routes the
      // request through the followUp path instead of the abort path.
      runtime.handle!.isStreaming = false;
      await (supervisor as unknown as { patch: (id: string, p: Partial<PickyAgentSession>) => Promise<void> }).patch(pickle.id, { status: "waiting_for_input" });

      const summary = await supervisor.reloadPlugins();

      expect(summary).toEqual({
        pickyReloaded: false,
        pickleReloadedCount: 1,
        pickleAbortedCount: 0,
        pickleDeferredCount: 0,
      });
      const reloadFollowUp = runtime.handle!.followUps.find((prompt) => prompt.text === "/reload");
      expect(reloadFollowUp).toBeDefined();
    });

    it("aborts streaming Pickle sessions without sending /reload", async () => {
      const dir = await mkdtemp(join(tmpdir(), "picky-agentd-reload-streaming-"));
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
      await supervisor.load();
      const pickle = await supervisor.createPickleFromHandoff(context("busy pickle"), { title: "Busy", instructions: "Investigate busy" });
      runtime.handle!.isStreaming = true;
      // Drop the createPickleFromHandoff seed follow-up so we can assert that
      // reloadPlugins did NOT add a /reload follow-up.
      runtime.handle!.followUps = [];

      const summary = await supervisor.reloadPlugins();

      expect(summary).toEqual({
        pickyReloaded: false,
        pickleReloadedCount: 0,
        pickleAbortedCount: 1,
        pickleDeferredCount: 0,
      });
      expect(runtime.handle!.aborts).toBe(1);
      expect(runtime.handle!.followUps.find((prompt) => prompt.text === "/reload")).toBeUndefined();
      expect(supervisor.get(pickle.id)?.status).toBe("cancelled");
    });

    it("defers reload for compacting Pickle sessions and drains after compaction", async () => {
      const dir = await mkdtemp(join(tmpdir(), "picky-agentd-reload-compacting-"));
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
      await supervisor.load();
      const pickle = await supervisor.createPickleFromHandoff(context("compacting pickle"), { title: "Compacting", instructions: "Investigate compacting" });
      // Compaction-in-progress: streaming false but compacting true. Park the
      // session status away from `running` so the abort branch doesn't grab
      // it before the compaction check.
      runtime.handle!.isStreaming = false;
      runtime.handle!.isCompacting = true;
      await (supervisor as unknown as { patch: (id: string, p: Partial<PickyAgentSession>) => Promise<void> }).patch(pickle.id, { status: "waiting_for_input" });
      runtime.handle!.followUps = [];

      const summary = await supervisor.reloadPlugins();

      expect(summary).toEqual({
        pickyReloaded: false,
        pickleReloadedCount: 0,
        pickleAbortedCount: 0,
        pickleDeferredCount: 1,
      });
      // No /reload yet — compaction is still in flight.
      expect(runtime.handle!.followUps.find((prompt) => prompt.text === "/reload")).toBeUndefined();

      // Compaction finishes; emit any runtime event so the supervisor's
      // post-event drain runs and discovers the cleared compacting flag.
      runtime.handle!.isCompacting = false;
      runtime.handle!.emit({ type: "log", line: "compact completed" });
      await settle();
      await settle();

      expect(runtime.handle!.followUps.find((prompt) => prompt.text === "/reload")).toBeDefined();
    });

    it("retains deferred reload when compaction ends while streaming", async () => {
      const dir = await mkdtemp(join(tmpdir(), "picky-agentd-reload-compacting-streaming-"));
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
      await supervisor.load();
      const pickle = await supervisor.createPickleFromHandoff(context("compacting streaming pickle"), { title: "Compacting Streaming", instructions: "Investigate compacting streaming" });
      runtime.handle!.isStreaming = false;
      runtime.handle!.isCompacting = true;
      await (supervisor as unknown as { patch: (id: string, p: Partial<PickyAgentSession>) => Promise<void> }).patch(pickle.id, { status: "waiting_for_input" });
      runtime.handle!.followUps = [];

      const summary = await supervisor.reloadPlugins();

      expect(summary.pickleDeferredCount).toBe(1);
      runtime.handle!.isCompacting = false;
      runtime.handle!.isStreaming = true;
      runtime.handle!.emit({ type: "log", line: "compact completed but turn started" });
      await settle();
      await settle();
      expect(runtime.handle!.followUps.find((prompt) => prompt.text === "/reload")).toBeUndefined();

      runtime.handle!.isStreaming = false;
      runtime.handle!.emit({ type: "log", line: "turn completed" });
      await settle();
      await settle();
      expect(runtime.handle!.followUps.find((prompt) => prompt.text === "/reload")).toBeDefined();
    });

    it("clears pending post-compaction reload on abort", async () => {
      const dir = await mkdtemp(join(tmpdir(), "picky-agentd-reload-compacting-abort-"));
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
      await supervisor.load();
      const pickle = await supervisor.createPickleFromHandoff(context("aborted compacting pickle"), { title: "Aborted Compacting", instructions: "Investigate aborted compacting" });
      runtime.handle!.isStreaming = false;
      runtime.handle!.isCompacting = true;
      await (supervisor as unknown as { patch: (id: string, p: Partial<PickyAgentSession>) => Promise<void> }).patch(pickle.id, { status: "waiting_for_input" });
      runtime.handle!.followUps = [];

      const summary = await supervisor.reloadPlugins();

      expect(summary.pickleDeferredCount).toBe(1);
      await supervisor.abort(pickle.id);
      runtime.handle!.isCompacting = false;
      runtime.handle!.emit({ type: "log", line: "compact completed after abort" });
      await settle();
      await settle();

      expect(runtime.handle!.followUps.find((prompt) => prompt.text === "/reload")).toBeUndefined();
    });

    it("skips terminal Pickle sessions", async () => {
      const dir = await mkdtemp(join(tmpdir(), "picky-agentd-reload-terminal-"));
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
      await supervisor.load();
      const pickle = await supervisor.createPickleFromHandoff(context("old pickle"), { title: "Old", instructions: "Done" });
      await supervisor.abort(pickle.id);
      runtime.handle!.followUps = [];
      runtime.handle!.aborts = 0;

      const summary = await supervisor.reloadPlugins();

      expect(summary).toEqual({
        pickyReloaded: false,
        pickleReloadedCount: 0,
        pickleAbortedCount: 0,
        pickleDeferredCount: 0,
      });
      expect(runtime.handle!.aborts).toBe(0);
      expect(runtime.handle!.followUps).toEqual([]);
    });
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

  constructor(private readonly slashCommands: RuntimeSlashCommand[] = []) {}

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    this.handle.slashCommands = [...this.slashCommands];
    return this.handle;
  }

  async resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.resumeCalls.push({ sessionFilePath, cwd: options.cwd, sessionId: options.sessionId });
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    this.handle.slashCommands = [...this.slashCommands];
    return this.handle;
  }
}

class DeferredResumeRuntime implements AgentRuntime {
  handle?: ManualHandle;
  resumeCalls: Array<{ sessionFilePath: string; cwd?: string; sessionId?: string }> = [];
  private resolveResume?: () => void;

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return this.handle;
  }

  async resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.resumeCalls.push({ sessionFilePath, cwd: options.cwd, sessionId: options.sessionId });
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    return await new Promise<RuntimeSessionHandle>((resolve) => {
      this.resolveResume = () => resolve(this.handle!);
    });
  }

  resolvePendingResume(): void {
    this.resolveResume?.();
    this.resolveResume = undefined;
  }
}

class InitialQueueRuntime implements AgentRuntime {
  handle?: ManualHandle;

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    this.handle.queuedSteerTexts = ["initial steer"];
    this.handle.queuedFollowUpTexts = ["initial follow-up"];
    this.handle.steeringMode = "all";
    this.handle.followUpMode = "all";
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

class DeferredCreateRuntime implements AgentRuntime {
  handles: ManualHandle[] = [];
  createCalls = 0;
  createPrompts: BuiltPrompt[] = [];
  private pendingCreates: Array<{ handle: ManualHandle; resolve: (handle: RuntimeSessionHandle) => void; reject: (error: unknown) => void }> = [];

  async create(prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.createCalls += 1;
    this.createPrompts.push(prompt);
    const handle = new ManualHandle(options.sessionId ?? "manual");
    this.handles.push(handle);
    return await new Promise<RuntimeSessionHandle>((resolve, reject) => {
      this.pendingCreates.push({ handle, resolve, reject });
    });
  }

  resolveAll(): void {
    for (const pending of this.pendingCreates.splice(0)) pending.resolve(pending.handle);
  }

  rejectAll(error: unknown): void {
    for (const pending of this.pendingCreates.splice(0)) pending.reject(error);
  }
}

class DelayedFirstMainStateStore extends SessionStore {
  firstMainSaveStarted = false;
  private releaseFirstSave?: () => void;

  async saveMainAgentState(state: PickyMainAgentState): Promise<void> {
    const snapshot = JSON.parse(JSON.stringify(state)) as PickyMainAgentState;
    if (!this.firstMainSaveStarted && snapshot.messages.length === 1) {
      this.firstMainSaveStarted = true;
      await new Promise<void>((resolve) => { this.releaseFirstSave = resolve; });
    }
    await super.saveMainAgentState(snapshot);
  }

  releaseFirstMainSave(): void {
    this.releaseFirstSave?.();
    this.releaseFirstSave = undefined;
  }
}

/// Mimics the real pi-sdk-runtime prewarm path: createHandle resolves with the handle
/// already populated (e.g. pi 0.74's eager sessionFile field), and reportDiagnostics is
/// scheduled via setTimeout(0). The supervisor must subscribe BEFORE this timer fires or
/// the "pi session: <path>" log event is dropped on the floor.
class RacingPrewarmRuntime implements AgentRuntime {
  handle?: ManualHandle;
  prewarmCalls = 0;

  constructor(private readonly sessionFilePath: string) {}

  prewarm = async (options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> => {
    this.prewarmCalls += 1;
    const handle = new ManualHandle(options.sessionId ?? "racing");
    handle.sessionFilePath = this.sessionFilePath;
    this.handle = handle;
    setTimeout(() => handle.emit({ type: "log", line: `pi session: ${this.sessionFilePath}` }), 0);
    return handle;
  };

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    const handle = new ManualHandle(options.sessionId ?? "racing");
    this.handle = handle;
    return handle;
  }
}

class DeferredPrewarmRuntime implements AgentRuntime {
  handle?: ManualHandle;
  createCalls = 0;
  prewarmCalls = 0;
  private resolvePrewarm?: () => void;
  private rejectPrewarm?: (error: unknown) => void;

  prewarm = async (options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> => {
    this.prewarmCalls += 1;
    const handle = new ManualHandle(options.sessionId ?? "manual");
    this.handle = handle;
    return new Promise<RuntimeSessionHandle>((resolve, reject) => {
      this.resolvePrewarm = () => resolve(handle);
      this.rejectPrewarm = reject;
    });
  };

  resolvePendingPrewarm(): void {
    this.resolvePrewarm?.();
    this.resolvePrewarm = undefined;
    this.rejectPrewarm = undefined;
  }

  rejectPendingPrewarm(error: unknown): void {
    this.rejectPrewarm?.(error);
    this.resolvePrewarm = undefined;
    this.rejectPrewarm = undefined;
  }

  hasPendingPrewarm(): boolean {
    return Boolean(this.resolvePrewarm || this.rejectPrewarm);
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
  /** Initial prompts captured by `create`, in invocation order. Useful for asserting on the very
   * first message the runtime received before any follow-up calls. */
  createPrompts: BuiltPrompt[] = [];
  thinkingLevels: string[] = [];
  ttsEnabledCalls: boolean[] = [];
  modelPatterns: Array<string | undefined> = [];
  prewarmCalls = 0;
  prewarmOptions: Array<{ cwd?: string; sessionId?: string }> = [];
  prewarm?: (options: { cwd?: string; sessionId?: string }) => Promise<RuntimeSessionHandle>;
  private readonly assistantRunMetadata?: RuntimeAssistantRunMetadata;

  constructor(options: { supportsPrewarm?: boolean; assistantRunMetadata?: RuntimeAssistantRunMetadata } = {}) {
    this.assistantRunMetadata = options.assistantRunMetadata;
    if (options.supportsPrewarm) {
      this.prewarm = async (prewarmOptions) => {
        this.prewarmCalls += 1;
        this.prewarmOptions.push(prewarmOptions);
        this.handle = new ManualHandle(prewarmOptions.sessionId ?? "manual");
        this.handle.assistantRunMetadata = this.assistantRunMetadata;
        return this.handle;
      };
    }
  }

  async create(prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.createCalls += 1;
    this.createPrompts.push(prompt);
    this.handle = new ManualHandle(options.sessionId ?? "manual");
    this.handle.assistantRunMetadata = this.assistantRunMetadata;
    return this.handle;
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevels.push(level);
  }

  setModelPattern(pattern?: string): boolean {
    const normalized = pattern?.trim() || undefined;
    const previous = this.modelPatterns.at(-1);
    this.modelPatterns.push(normalized);
    return previous !== normalized;
  }

  setMainAgentTTSEnabled(enabled: boolean): void {
    this.ttsEnabledCalls.push(enabled);
  }
}

class ManualHandle implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  followUps: BuiltPrompt[] = [];
  /** Subset of follow-up prompts Pi would have queued (mirrors `_followUpMessages` when isStreaming). */
  queuedFollowUpTexts: string[] = [];
  interrupts: BuiltPrompt[] = [];
  bootstrapInjections: Array<{ user: string; assistant: string }> = [];
  extensionUiAnswers: Array<{ requestId: string; value: unknown; options?: AnswerExtensionUiOptions }> = [];
  /** Request ids whose runtime-side dialog has already been discarded; mirrors the bridge throwing "Unknown extension UI request". */
  stalePendingRequestIds = new Set<string>();
  thinkingLevels: string[] = [];
  modelPatterns: Array<string | undefined> = [];
  userBashExecutions: Array<{ command: string; excludeFromContext?: boolean }> = [];
  newSessionCalls = 0;
  sessionFilePath?: string;
  slashCommands: RuntimeSlashCommand[] = [];
  assistantRunMetadata?: RuntimeAssistantRunMetadata;
  onFollowUp?: (handle: ManualHandle, prompt: BuiltPrompt) => void;
  onSteer?: (handle: ManualHandle, prompt: BuiltPrompt) => void;
  onUserBash?: (handle: ManualHandle, command: string, options?: { excludeFromContext?: boolean; onOutputChunk?: (chunk: string) => void }) => void | Promise<void>;
  constructor(readonly id: string) {}
  async followUp(prompt: BuiltPrompt): Promise<void> {
    this.followUps.push(prompt);
    if (this.isStreaming) {
      // Mirror Pi's queued path: track the queued text and emit the matching queue_update so the
      // supervisor sees a real Pi-like enqueue/dequeue lifecycle.
      this.queuedFollowUpTexts.push(prompt.text);
      this.emit({ type: "queue_update", steering: [...this.steers], followUp: [...this.queuedFollowUpTexts] });
    }
    this.onFollowUp?.(this, prompt);
  }
  async interrupt(prompt: BuiltPrompt): Promise<void> {
    this.interrupts.push(prompt);
  }
  steers: string[] = [];
  steerPrompts: BuiltPrompt[] = [];
  /** Subset of steer prompts Pi would have queued (mirrors `_steeringMessages` when isStreaming). */
  queuedSteerTexts: string[] = [];
  steerOutcome: { handledSynchronously: boolean } = { handledSynchronously: false };
  aborts = 0;
  async steer(prompt: BuiltPrompt): Promise<{ handledSynchronously: boolean }> {
    this.steerPrompts.push(prompt);
    this.steers.push(prompt.text);
    if (this.isStreaming) {
      this.queuedSteerTexts.push(prompt.text);
      this.emit({ type: "queue_update", steering: [...this.queuedSteerTexts], followUp: [...this.queuedFollowUpTexts] });
    }
    this.onSteer?.(this, prompt);
    return this.steerOutcome;
  }
  async abort(): Promise<void> {
    this.aborts += 1;
  }
  async executeUserBash(command: string, options?: { excludeFromContext?: boolean; onOutputChunk?: (chunk: string) => void }): Promise<{ output: string; exitCode: number; cancelled: boolean; truncated: boolean }> {
    this.userBashExecutions.push({ command, excludeFromContext: options?.excludeFromContext });
    this.emit({ type: "tool", toolCallId: `manual-bash-${this.userBashExecutions.length}`, name: "bash", status: "running", preview: command });
    if (this.onUserBash) {
      await this.onUserBash(this, command, options);
    } else {
      options?.onOutputChunk?.(`${command} output\n`);
    }
    this.emit({ type: "tool", toolCallId: `manual-bash-${this.userBashExecutions.length}`, name: "bash", status: "succeeded", preview: command, resultPreview: "ok" });
    return { output: `${command} output\n`, exitCode: 0, cancelled: false, truncated: false };
  }
  async newSession(): Promise<{ cancelled: boolean }> {
    this.newSessionCalls += 1;
    this.sessionFilePath = `/tmp/manual-new-session-${this.newSessionCalls}.jsonl`;
    this.emit({ type: "session_replaced", reason: "new", cwd: "/tmp/project", sessionFilePath: this.sessionFilePath });
    this.emit({ type: "status", status: "completed", summary: "New session started", noTurnRan: true, preserveSessionState: true });
    return { cancelled: false };
  }
  async answerExtensionUi(requestId: string, value: unknown, options?: AnswerExtensionUiOptions): Promise<void> {
    this.extensionUiAnswers.push({ requestId, value, options });
    if (this.stalePendingRequestIds.has(requestId)) {
      if (options?.ignoreUnknown) return;
      throw new Error(`Unknown extension UI request: ${requestId}`);
    }
  }
  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    this.bootstrapInjections.push(messages);
  }
  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevels.push(level);
  }
  async setModel(pattern?: string): Promise<RuntimeAssistantRunMetadata | undefined> {
    const normalized = pattern?.trim() || undefined;
    this.modelPatterns.push(normalized);
    this.assistantRunMetadata = normalized ? { model: normalized } : undefined;
    return this.assistantRunMetadata;
  }
  getAssistantRunMetadata(): RuntimeAssistantRunMetadata | undefined {
    return this.assistantRunMetadata;
  }
  clearQueue(): { steering: string[]; followUp: string[] } {
    const result = { steering: [...this.queuedSteerTexts], followUp: [...this.queuedFollowUpTexts] };
    this.queuedSteerTexts = [];
    this.queuedFollowUpTexts = [];
    this.emit({ type: "queue_update", steering: [], followUp: [] });
    return result;
  }
  getSteeringMessages(): readonly string[] {
    return this.queuedSteerTexts;
  }
  getFollowUpMessages(): readonly string[] {
    return this.queuedFollowUpTexts;
  }
  steeringMode: "one-at-a-time" | "all" = "one-at-a-time";
  followUpMode: "one-at-a-time" | "all" = "one-at-a-time";
  /**
   * Mirrors Pi's `session.isStreaming`. Tests can set this to `true` to exercise the queued path
   * (where Pi would enqueue follow-up/steer prompts and emit `queue_update` events) and leave it
   * `false` to exercise the direct path (where Pi runs the prompt inline without enqueueing).
   */
  isStreaming = false;
  /** Mirrors Pi's compacting flag so plugin-reload tests can simulate the
   * supervisor's `pendingPostCompactionReloadIds` deferral path. */
  isCompacting = false;
  listSlashCommands(): RuntimeSlashCommand[] {
    return this.slashCommands;
  }
  getSessionFilePath(): string | undefined {
    return this.sessionFilePath;
  }
  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

function userTexts(session: PickyAgentSession | undefined): string[] {
  return (session?.messages ?? []).filter((message) => message.kind === "user_text").map((message) => message.text ?? "");
}

function commandReceipts(session: PickyAgentSession | undefined): Array<{ command: string; status: string; detail: string | undefined }> {
  return (session?.messages ?? [])
    .filter((message) => message.kind === "command_receipt")
    .map((message) => ({
      command: message.commandReceipt?.command ?? "",
      status: message.commandReceipt?.status ?? "",
      detail: message.commandReceipt?.detail,
    }));
}

async function settle(): Promise<void> {
  await delay(10);
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for condition");
    await delay(10);
  }
}

async function waitForPendingPrewarm(runtime: DeferredPrewarmRuntime): Promise<void> {
  await waitUntil(() => runtime.hasPendingPrewarm());
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
