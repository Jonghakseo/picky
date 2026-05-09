import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickyContextPacket } from "./protocol.js";
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
    expect(supervisor.get(session.id)?.messages?.some((message) => message.kind === "system" && message.text?.includes("Ran `!pwd`"))).toBe(true);
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
    expect(supervisor.get(session.id)?.messages?.some((message) => message.kind === "system" && message.text?.includes("Ran `!!printenv SECRET`"))).toBe(true);
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
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 1);

    expect(supervisor.get(session.id)?.activitySummary).toMatchObject({ read: 0, bash: 1, edit: 0, write: 0, thinking: 0, other: 0 });
    expect(events.map((event) => event.seq)).toEqual([1]);
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
    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 0, bash: 1, edit: 1, write: 0, thinking: 0, other: 0 });
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

  it("dedupes tool calls per turn but keeps cumulative activity across follow-ups", async () => {
    const runtime = new ManualRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-activity-followup-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("activity follow-up"));

    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 1);

    await supervisor.followUp(session.id, "next turn");
    runtime.handle!.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    await waitUntil(() => supervisor.get(session.id)?.activitySummary?.bash === 2);

    expect(supervisor.get(session.id)?.activitySummary).toEqual({ read: 0, bash: 2, edit: 0, write: 0, thinking: 0, other: 0 });
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
    const runtime = new ManualRuntime({ supportsPrewarm: true });
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
    expect(supervisor.isPickleSession(session.id)).toBe(true);
    expect(supervisor.listPickleSessions().map((pickle) => pickle.id)).toEqual([session.id]);
    expect(session.logs).toContain("manual pickle: waiting for first instruction");

    const steered = await supervisor.steerPickleSession(session.id, "첫 작업 시작해줘");
    expect(steered.status).toBe("running");
    expect(runtime.handle?.interrupts).toEqual([]);
    expect(runtime.handle?.steers).toEqual(["첫 작업 시작해줘"]);
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

  it("uses the handoff cwd override for Pickle session metadata, prompt context, and runtime cwd", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new RecordingRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();

    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "피클 조사", instructions: "Investigate", cwd: "  /tmp/override-project  " });

    expect(pickle.cwd).toBe("/tmp/override-project");
    expect(pickle.logs).toContain("Picky handoff cwd: /tmp/override-project");
    expect(runtime.creates[0].options.cwd).toBe("/tmp/override-project");
    expect(runtime.creates[0].prompt.text).toContain("- CWD: /tmp/override-project");
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
    expect(runtime.handle?.extensionUiAnswers).toEqual([{ requestId: "ui-follow", value: { cancelled: true } }]);
    expect(updated.pendingExtensionUiRequest).toBeUndefined();
    expect(updated.messages?.find((message) => message.id === "ui-follow")?.cancelledAt).toBeDefined();
    expect(runtime.handle?.followUps.map((prompt) => prompt.text)).toContain("continue instead");
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
    expect(runtime.handle?.extensionUiAnswers).toEqual([{ requestId: "ui-steer", value: { cancelled: true } }]);
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
    expect(runtime.handle?.steerPrompts[0]?.text).toContain("## User steering instruction\nuse this screenshot");
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

  it("resets the same Pickle card when /new replaces the underlying Pi session", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const runtime = new ManualRuntime();
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const pickle = await supervisor.createPickleFromHandoff(context("pickle request"), { title: "기존 작업", instructions: "Investigate the request" });

    runtime.handle?.emit({ type: "assistant_delta", delta: "기존 답변" });
    runtime.handle?.emit({ type: "tool", toolCallId: "tool-1", name: "bash", status: "running", preview: "old tool" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
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

    runtime.handle?.emit({ type: "assistant_delta", delta: "완료 답변" });
    runtime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("완료 답변");

    runtime.handle?.emit({ type: "status", status: "running", summary: "Compacting session…", compactionStarted: true, compactionReason: "threshold" });
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Compacting session…");

    runtime.handle?.emit({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, compactionReason: "threshold" });
    await settle();
    const updated = supervisor.get(pickle.id)!;
    expect(updated.status).toBe("completed");
    expect(updated.lastSummary).toBe("Session compacted");
    expect((updated.messages ?? []).some((message) => message.kind === "system" && message.text === "Session compacted")).toBe(true);
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
    await settle();
    expect(supervisor.get(pickle.id)?.status).toBe("completed");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Session compacted");
    expect((supervisor.get(pickle.id)?.messages ?? []).some((message) => message.kind === "system" && message.text === "Session compacted")).toBe(true);

    await supervisor.followUp(pickle.id, "/name 컴팩션 후 이름");
    await settle();

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
    await settle();

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
    await settle();

    expect(supervisor.get(session.id)).toMatchObject({
      status: aborted.status,
      tools: aborted.tools,
      thinkingPreview: aborted.thinkingPreview,
      queuedSteers: aborted.queuedSteers,
    });
    expect(supervisor.get(session.id)?.pendingExtensionUiRequest).toBeUndefined();
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

  it("strips Picky point tags and emits pointer overlays sequentially", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const pointerContext: PickyContextPacket = {
      ...context("어디 눌러?"),
      screenshots: [
        {
          id: "shot-1",
          label: "screen 1 — cursor is on this screen",
          path: "/tmp/shot-1.jpg",
          screenId: "screen1",
          bounds: { x: 0, y: 0, width: 300, height: 400 },
          screenshotWidthInPixels: 600,
          screenshotHeightInPixels: 800,
          isCursorScreen: true,
        },
        {
          id: "shot-2",
          label: "screen 2 — secondary screen",
          path: "/tmp/shot-2.jpg",
          screenId: "screen2",
          bounds: { x: 300, y: 0, width: 300, height: 400 },
          screenshotWidthInPixels: 600,
          screenshotHeightInPixels: 800,
        },
      ],
    };
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    const overlays: Array<{ screenId?: string; x: number; y: number; label?: string }> = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));
    supervisor.on("pointerOverlayRequested", (request) => overlays.push({ screenId: request.screenId, x: request.x, y: request.y, label: request.label }));

    await supervisor.route(pointerContext);
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "먼저 검색창, 그다음 저장 버튼이에요. [POINT:100,200:검색창:screen1] [POINT:700,900:저장:screen2]" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toEqual([{ contextId: "context-어디 눌러?", text: "먼저 검색창, 그다음 저장 버튼이에요." }]);
    expect(supervisor.listMainMessages().at(-1)).toMatchObject({ role: "assistant", text: "먼저 검색창, 그다음 저장 버튼이에요." });
    expect(overlays).toEqual([{ screenId: "screen1", x: 100, y: 200, label: "검색창" }]);

    await delay(1_050);

    expect(overlays).toEqual([
      { screenId: "screen1", x: 100, y: 200, label: "검색창" },
      { screenId: "screen2", x: 600, y: 800, label: "저장" },
    ]);
  });

  it("strips POINT none without emitting pointer overlays", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
    const sideRuntime = new ManualRuntime();
    const mainRuntime = new ManualRuntime();
    const supervisor = new SessionSupervisor(sideRuntime, new SessionStore(dir), { mainRuntime });
    const replies: Array<{ contextId: string; text: string }> = [];
    const overlays: unknown[] = [];
    supervisor.on("quickReply", (contextId, text) => replies.push({ contextId, text }));
    supervisor.on("pointerOverlayRequested", (request) => overlays.push(request));

    await supervisor.route(context("HTML이 뭐야?"));
    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "HTML은 웹페이지의 구조를 만드는 언어예요. [POINT:none]" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

    expect(replies).toEqual([{ contextId: "context-HTML이 뭐야?", text: "HTML은 웹페이지의 구조를 만드는 언어예요." }]);
    expect(overlays).toEqual([]);
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

  it("bakes the configured Picky extra instructions into the bootstrap pair, not per-turn prompts", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-extra-instructions-"));
    const mainRuntime = new ManualRuntime({ supportsPrewarm: true });
    const supervisor = new SessionSupervisor(new ManualRuntime(), new SessionStore(dir), { mainRuntime });

    supervisor.setMainAgentExtraInstructions("  항상 존대말로 답해주세요  ");
    await supervisor.prewarmMainAgent("/tmp/project");

    expect(mainRuntime.handle?.bootstrapInjections).toHaveLength(1);
    const injectedUser = mainRuntime.handle!.bootstrapInjections[0]!.user;
    expect(injectedUser).toContain("## User-provided Picky instructions");
    expect(injectedUser).toContain("항상 존대말로 답해주세요");

    // Per-turn prompt stays free of the user-additional block; only the bootstrap carries it.
    await supervisor.route(context("첫 질문"));
    await settle();
    const turnPromptText = mainRuntime.handle?.followUps.at(-1)?.text ?? "";
    expect(turnPromptText).toContain("# Picky turn");
    expect(turnPromptText).not.toContain("User-provided Picky instructions");
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
    expect(injection.user).toContain("마크다운");
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
    expect(mainRuntime.handle?.followUps[0]?.text).toContain(`Pickle session: ${pickleSession.id}`);
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
    await settle();

    expect(mainRuntime.handle?.followUps).toHaveLength(1);
    expect(mainRuntime.handle?.followUps[0]?.text).toContain(`Pickle session: ${pickleSession.id}`);

    mainRuntime.handle?.emit({ type: "assistant_delta", delta: "바로 끝났어요" });
    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await settle();

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
    await settle();

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
    await settle();
    expect(userTexts(supervisor.get(session.id))).toEqual(["queued one", "queued two"]);
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
    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).length === 3);

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
  /** Initial prompts captured by `create`, in invocation order. Useful for asserting on the very
   * first message the runtime received before any follow-up calls. */
  createPrompts: BuiltPrompt[] = [];
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

  async create(prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.createCalls += 1;
    this.createPrompts.push(prompt);
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
  /** Subset of follow-up prompts Pi would have queued (mirrors `_followUpMessages` when isStreaming). */
  queuedFollowUpTexts: string[] = [];
  interrupts: BuiltPrompt[] = [];
  bootstrapInjections: Array<{ user: string; assistant: string }> = [];
  extensionUiAnswers: Array<{ requestId: string; value: unknown }> = [];
  thinkingLevels: string[] = [];
  userBashExecutions: Array<{ command: string; excludeFromContext?: boolean }> = [];
  newSessionCalls = 0;
  sessionFilePath?: string;
  slashCommands: RuntimeSlashCommand[] = [];
  onFollowUp?: (handle: ManualHandle, prompt: BuiltPrompt) => void;
  onSteer?: (handle: ManualHandle, prompt: BuiltPrompt) => void;
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
  async executeUserBash(command: string, options?: { excludeFromContext?: boolean }): Promise<{ output: string; exitCode: number; cancelled: boolean; truncated: boolean }> {
    this.userBashExecutions.push({ command, excludeFromContext: options?.excludeFromContext });
    this.emit({ type: "tool", toolCallId: `manual-bash-${this.userBashExecutions.length}`, name: "bash", status: "running", preview: command });
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
  async answerExtensionUi(requestId: string, value: unknown): Promise<void> {
    this.extensionUiAnswers.push({ requestId, value });
  }
  async injectInitialBootstrap(messages: { user: string; assistant: string }): Promise<void> {
    this.bootstrapInjections.push(messages);
  }
  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevels.push(level);
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

async function delay(milliseconds: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function makeSupervisor(): Promise<SessionSupervisor> {
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-test-"));
  const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
  await supervisor.load();
  return supervisor;
}
