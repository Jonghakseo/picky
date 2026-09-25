import { once } from "node:events";
import WebSocket from "ws";
import { AgentdServer } from "./server.js";
import { PROTOCOL_VERSION, type EventEnvelope } from "./protocol.js";
import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createEventBus } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema, type AsyncTask, type AsyncTaskCommand, type AsyncTaskHostMessage } from "./domain/async-task-contract.js";
import { AsyncTaskHostBridge } from "./runtime/async-task-host-bridge.js";
import { MockRuntime, MockRuntimeSession } from "./runtime/mock-runtime.js";
import type { AgentRuntime } from "./runtime/types.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import type { PickyAgentSession } from "./protocol.js";

const roots: string[] = [];
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(roots.splice(0).map((path) => rm(path, { recursive: true, force: true }))); });
const capabilities = { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true };
type Control = Extract<AsyncTaskHostMessage, { type: "control-request" }>;
async function fixture(options: { missing?: boolean; fail?: "suppressDelivery" | "cancel"; unresolved?: boolean; noReply?: "closeAdmission" | "suppressDelivery" } = {}) {
  const root = await mkdtemp(join(tmpdir(), "picky-w5a-")); roots.push(root);
  const store = new SessionStore(root);
  const bus = createEventBus();
  const handle = new MockRuntimeSession("session-1");
  let bridge!: AsyncTaskHostBridge;
  const runtime: AgentRuntime = { create: new MockRuntime().create, prewarm: async (input) => {
    bridge = new AsyncTaskHostBridge(bus, input.sessionId!, input.asyncTaskHost!, () => {}, 40);
    await bridge.bind("pi-1", options.missing ? ["bash_async", "subagent"] : ["bash_async"]);
    return Object.assign(handle, { asyncTasks: bridge });
  } };
  const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => "session-1", enableAsyncTasksForSession: () => true });
  const projected: PickyAgentSession[] = [];
  supervisor.on("sessionProjectionTransaction", (_id, _before, after) => projected.push(after));
  await supervisor.load();
  await supervisor.createEmptyPickleSession({ id: "context-1", source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] });
  const owner = { sessionId: "session-1", piSessionId: "pi-1", runtimeInstanceId: bridge.runtimeInstanceId, providerId: "bash-async", providerInstanceId: "provider-1" };
  let revision = 0;
  let tasks: AsyncTask[] = [];
  let tickets: NonNullable<PickyAgentSession["completionTickets"]> = [];
  const send = (data: object) => bus.emit(ASYNC_TASK_CONTRACT, { ...owner, contract: ASYNC_TASK_CONTRACT, requestId: "provider", providerRevision: revision, controlGeneration: bridge.generation, ...data });
  const update = () => { revision++; tasks = tasks.map((task) => ({ ...task, providerRevision: revision })); send({ type: "task-update", detail: { tasks, tickets } }); };
  send({ type: "host-query", sessionId: null, runtimeInstanceId: null }); await bridge.drain();
  send({ type: "provider-ready", providerVersion: "1", contractVersion: 1, snapshotReady: true, capabilities });
  send({ type: "snapshot", watermark: revision, detail: { tasks, tickets } }); await bridge.drain();
  const calls: Control[] = [];
  const persistedAtClose: PickyAgentSession[] = [];
  let hold: Promise<void> | undefined;
  bus.on(ASYNC_TASK_CONTRACT, (data) => {
    const message = AsyncTaskHostMessageSchema.parse(data);
    if (message.type !== "control-request") return;
    calls.push(message);
    void (async () => {
      if (message.action === "closeAdmission") {
        persistedAtClose.push((await store.loadReadOnly("session-1"))!);
        if (hold) await hold;
      }
      if (message.action === "cancel" && options.fail !== "cancel" && !options.unresolved) { tasks = tasks.map((task) => task.taskId === message.taskId ? { ...task, execution: "cancelled", presence: "settled" } : task); update(); }
      if (message.action === "suppressDelivery" && options.fail !== "suppressDelivery") { tickets = tickets.map((ticket) => ticket.deliveryId && message.deliveryIds.includes(ticket.deliveryId) ? { ...ticket, state: "suppressed" } : ticket); update(); }
      if (options.noReply === message.action) return;
      send({ type: "control-result", requestId: message.requestId, outcome: options.fail === message.action ? message.action === "cancel" ? "blocked_cleanup" : "blocked_delivery" : "settled",
        admissionClosed: true, submittedDeliveryIds: tickets.flatMap((ticket) => ticket.deliveryId ? [ticket.deliveryId] : []) });
    })();
  });
  const register = async (id = "task-1") => {
    const task: AsyncTask = { ...owner, taskId: id, rootTaskId: id, kind: "bash", title: "Finite child", registration: "reserved", execution: "queued", presence: "settled", providerRevision: ++revision, controlGeneration: bridge.generation, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    send({ type: "task-register", task }); await bridge.drain();
  };
  const addTask = async (delivery = true, id = "task-1") => {
    await register(id);
    tasks = bridge.snapshot().tasks.map((task) => task.taskId === id ? { ...task, registration: "spawned", execution: "running", presence: "active" } : task);
    if (delivery) tickets = [{ ...owner, completionId: "completion-1", rootTaskId: "task-1", target: "model", state: "submitted", deliveryId: "delivery-1", controlGeneration: bridge.generation }];
    update(); await bridge.drain();
  };
  const settleUnconsumedGrant = async () => {
    tasks = bridge.snapshot().tasks.map((task) => ({ ...task, execution: "succeeded", presence: "settled" }));
    update(); await bridge.drain();
  };
  const command = <T extends AsyncTaskCommand["type"]>(type: T, fields: Omit<Extract<AsyncTaskCommand, { type: T }>, "type" | "requestId" | "sessionId" | "daemonInstanceId" | "runtimeInstanceId" | "workRevision" | "controlGeneration">, requestId: string = type): Extract<AsyncTaskCommand, { type: T }> => {
    const context = supervisor.asyncControls.context("session-1");
    return { type, requestId, sessionId: "session-1", daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: owner.runtimeInstanceId, workRevision: context.workRevision, controlGeneration: context.controlGeneration, ...fields } as Extract<AsyncTaskCommand, { type: T }>;
  };
  const archive = async () => {
    const prepared = await supervisor.executeAsyncTaskCommand(command("prepareSessionArchive", { archiveIntentId: "intent-1" }));
    const executed = await supervisor.executeAsyncTaskCommand(command("executeSessionArchive", { archiveIntentId: "intent-1", preparationId: prepared.preparationId!, mode: "continue" }));
    expect(executed.outcome).toBe("settled");
  };
  return { root, settleUnconsumedGrant, setFailure: (fail?: "suppressDelivery" | "cancel") => { options.fail = fail; }, supervisor, store, bridge, owner, calls, persistedAtClose, projected, handle, addTask, command, archive, register, holdClose: (promise: Promise<void>) => { hold = promise; } };
}

it("persists the cut before provider effects and returns the same stopped result after a lost ACK", async () => {
  const f = await fixture(); await f.addTask();
  const first = await f.supervisor.asyncControls.stop("session-1", "stop-1");
  const count = f.calls.length;
  const retry = await f.supervisor.asyncControls.stop("session-1", "stop-1");
  expect(first.outcome).toBe("settled"); expect(retry).toEqual(first); expect(f.calls).toHaveLength(count);
  expect(f.persistedAtClose[0]?.asyncControl).toMatchObject({ admissionState: "closed", controlGeneration: 1, operations: [{ outcome: "accepted" }] });
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "cancelled", presence: "settled" });
  expect(disk?.completionTickets?.[0]?.state).toBe("suppressed");
  expect(disk?.asyncControlJournal?.[0]?.result).toEqual(first);
  expect(f.projected.at(-1)?.asyncControl?.operations[0]?.outcome).toBe("settled");
  expect(disk?.asyncWorkSummary?.workRevision).toBe(first.workRevision);
});

it.each(["suppressDelivery", "cancel"] as const)("retains blocked %s and refuses stop-then-archive", async (fail) => {
  const f = await fixture({ fail }); await f.addTask();
  const prepared = await f.supervisor.executeAsyncTaskCommand(f.command("prepareSessionArchive", { archiveIntentId: "intent-1" }));
  const result = await f.supervisor.executeAsyncTaskCommand(f.command("executeSessionArchive", { archiveIntentId: "intent-1", preparationId: prepared.preparationId!, mode: "stopThenArchive" }));
  expect(result.outcome).toBe(fail === "cancel" ? "blocked_cleanup" : "blocked_delivery");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.archived).not.toBe(true); expect(disk?.status).toBe("blocked");
  expect(disk?.asyncTasks?.[0]?.presence).toBe(fail === "cancel" ? "active" : "settled");
  expect(disk?.asyncControlJournal?.at(-1)?.result).toEqual(result);
  expect(f.projected.at(-1)?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
});

it("does not equate a settled control reply with actual resource exit", async () => {
  const f = await fixture({ unresolved: true }); await f.addTask(false);
  expect((await f.supervisor.asyncControls.stop("session-1", "stop-unknown")).outcome).toBe("blocked_cleanup");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("active");
});

it("binds a zero-root release to the owner and persists prepare/cancel for exact retry", async () => {
  const f = await fixture(); await f.archive();
  const command = f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 7 });
  const prepared = await f.supervisor.executeAsyncTaskCommand(command);
  expect(prepared.outcome).toBe("settled");
  expect(prepared.releaseApproval).toMatchObject({ childGeneration: 7, runtimeInstanceId: f.owner.runtimeInstanceId, archiveIntentId: "intent-1" });
  expect(await f.supervisor.executeAsyncTaskCommand(command)).toEqual(prepared);
  const cancel = f.command("cancelRuntimeRelease", { releaseToken: prepared.releaseApproval!.releaseToken });
  const cancelled = await f.supervisor.executeAsyncTaskCommand(cancel);
  expect(cancelled.outcome).toBe("settled");
  expect(await f.supervisor.executeAsyncTaskCommand(cancel)).toEqual(cancelled);
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncControl?.releasePrepared).toBeUndefined();
  expect(disk?.asyncControl?.admissionState).toBe("closed");
  expect(f.projected.at(-1)?.asyncControl?.releasePrepared).toBeUndefined();
});

it("denies empty release when an expected provider has not supplied coverage", async () => {
  const f = await fixture({ missing: true }); await f.archive();
  const result = await f.supervisor.executeAsyncTaskCommand(f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 1 }));
  expect(result.outcome).toBe("rejected");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncControl?.releasePrepared).toBeUndefined();
  expect(disk?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
});

it("rejects stale preparation revision, owner and reused request content", async () => {
  const f = await fixture();
  const command = f.command("prepareSessionArchive", { archiveIntentId: "intent-1" });
  const result = await f.supervisor.executeAsyncTaskCommand(command);
  await expect(f.supervisor.executeAsyncTaskCommand({ ...command, archiveIntentId: "different" })).rejects.toThrow("reused");
  await expect(f.supervisor.executeAsyncTaskCommand({ ...command, requestId: "wrong-owner", runtimeInstanceId: "replacement" })).rejects.toThrow("owner changed");
  const execute = f.command("executeSessionArchive", { archiveIntentId: "intent-1", preparationId: result.preparationId!, mode: "continue" });
  await f.addTask(false);
  expect((await f.supervisor.executeAsyncTaskCommand(execute)).outcome).toBe("stale");
  expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
});

it("allows tracked stop of an archived Pickle without allowing follow-up", async () => {
  const f = await fixture(); await f.addTask(false); await f.archive();
  await expect(f.supervisor.abort("session-1")).resolves.toMatchObject({ archived: true });
  await expect(f.supervisor.followUp("session-1", "resume")).rejects.toThrow(/archived|fenced/);
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("settled");
});

it("fences late registration while the generation save is pending, without locking provider effects inside the writer", async () => {
  const f = await fixture();
  let entered!: () => void; let release!: () => void;
  const saving = new Promise<void>((resolve) => { entered = resolve; });
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const save = f.store.save.bind(f.store);
  vi.spyOn(f.store, "save").mockImplementation(async (session) => {
    if (session.asyncControl?.controlGeneration === 1 && session.asyncControl.admissionState === "closed" && !f.persistedAtClose.length) {
      entered(); await gate;
    }
    await save(session);
  });
  const stop = f.supervisor.asyncControls.stop("session-1", "race-stop");
  await saving;
  const late = f.register("late-task");
  release(); await late;
  expect((await stop).outcome).toBe("settled");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks ?? []).toEqual([]);
  expect(f.calls.some((call) => call.action === "closeAdmission")).toBe(true);
});

it("cancels one task without cancelling or suppressing an unrelated root", async () => {
  const f = await fixture(); await f.addTask(); await f.addTask(false, "task-2");
  const result = await f.supervisor.executeAsyncTaskCommand(f.command("cancelAsyncTask", { owner: f.owner, taskId: "task-1" }));
  expect(result.outcome).toBe("settled");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncTasks?.find((task) => task.taskId === "task-1")?.presence).toBe("settled");
  expect(disk?.asyncTasks?.find((task) => task.taskId === "task-2")?.presence).toBe("active");
  expect(disk?.asyncControl?.admissionState).toBe("open");
  expect(disk?.completionTickets?.[0]?.state).toBe("submitted");
  expect(disk?.asyncWorkSummary?.activeRootCount).toBe(1);
});

it("does not suppress a pending result to manufacture a release approval", async () => {
  const f = await fixture(); await f.addTask(); await f.archive();
  const result = await f.supervisor.executeAsyncTaskCommand(f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 1 }));
  expect(result.outcome).toBe("rejected");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncControl?.admissionState).toBe("open");
  expect(disk?.completionTickets?.[0]?.state).toBe("submitted");
  expect(disk?.asyncControl?.releasePrepared).toBeUndefined();
});

it("rechecks local unarchive after provider closure before persisting release authority", async () => {
  const f = await fixture(); await f.archive();
  let resume!: () => void;
  f.holdClose(new Promise<void>((resolve) => { resume = resolve; }));
  const preparing = f.supervisor.executeAsyncTaskCommand(f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 1 }));
  await vi.waitFor(() => expect(f.persistedAtClose.length).toBe(1), { interval: 1, timeout: 200 });
  await f.supervisor.setSessionArchived("session-1", false);
  resume();
  expect((await preparing).outcome).toBe("stale");
  expect((await f.store.loadReadOnly("session-1"))?.asyncControl?.releasePrepared).toBeUndefined();
});

it("serves context and correlated operations through the real WebSocket dispatcher, including legacy abort", async () => {
  const f = await fixture(); await f.addTask();
  const server = new AgentdServer({ port: 0, token: "w5a-test", supervisor: f.supervisor });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=w5a-test`);
  const events: EventEnvelope[] = [];
  ws.on("message", (data) => events.push(JSON.parse(String(data)) as EventEnvelope));
  try {
    await once(ws, "open");
    ws.send(JSON.stringify({ id: "context-request", protocolVersion: PROTOCOL_VERSION, type: "getAsyncControlContext", sessionId: "session-1" }));
    await vi.waitFor(() => expect(events.some((event) => event.type === "asyncControlContext" && event.requestId === "context-request")).toBe(true));
    const context = events.find((event) => event.type === "asyncControlContext");
    expect(context).toMatchObject({ requiresArchiveChoice: true, daemonInstanceId: f.supervisor.asyncControls.daemonInstanceId, runtimeInstanceId: f.owner.runtimeInstanceId });
    ws.send(JSON.stringify({ id: "abort-wire", protocolVersion: PROTOCOL_VERSION, type: "abort", sessionId: "session-1" }));
    await vi.waitFor(() => expect(events.some((event) => event.type === "asyncTaskCommandResult" && event.result.requestId === "abort-wire")).toBe(true));
    const stopped = events.find((event) => event.type === "asyncTaskCommandResult" && event.result.requestId === "abort-wire");
    expect(stopped).toMatchObject({ result: { outcome: "settled" } });
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("settled");
    const command = f.command("prepareSessionArchive", { archiveIntentId: "wire-intent" }, "wire-prepare");
    ws.send(JSON.stringify({ id: "wire-envelope", protocolVersion: PROTOCOL_VERSION, type: "asyncTaskCommand", command }));
    await vi.waitFor(() => expect(events.some((event) => event.type === "asyncTaskCommandResult" && event.result.requestId === "wire-prepare")).toBe(true));
    expect((await f.store.loadReadOnly("session-1"))?.asyncControlJournal?.at(-1)?.result.outcome).toBe("settled");
  } finally {
    ws.close(); await server.stop();
  }
});

it("persists an unknown delivery outcome on lost close ACK while still stopping observed execution", async () => {
  const f = await fixture({ noReply: "closeAdmission" }); await f.addTask(false);
  const result = await f.supervisor.asyncControls.stop("session-1", "lost-close");
  expect(result.outcome).toBe("blocked_delivery");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncControl?.admissionState).toBe("closed");
  expect(disk?.asyncTasks?.[0]?.presence).toBe("settled");
  expect(disk?.status).toBe("blocked");
  expect(disk?.asyncControlJournal?.at(-1)?.result).toEqual(result);
});

it("does not send provider effects when the durable generation cut fails", async () => {
  const f = await fixture(); await f.addTask(false);
  const save = f.store.save.bind(f.store);
  vi.spyOn(f.store, "save").mockImplementation(async (session) => {
    if (session.asyncControl?.controlGeneration === 1) throw new Error("disk cut unavailable");
    await save(session);
  });
  const result = await f.supervisor.asyncControls.stop("session-1", "cut-failure");
  expect(result.outcome).toBe("blocked_cleanup"); expect(f.calls).toEqual([]);
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("active");
});

it("returns owner-scoped task detail without mutating the persisted task family", async () => {
  const f = await fixture(); await f.addTask();
  const before = await f.store.loadReadOnly("session-1");
  const detail = await f.supervisor.executeAsyncTaskCommand(f.command("asyncTaskDetail", { owner: f.owner, taskId: "task-1", limit: 100 }));
  expect(detail.outcome).toBe("settled");
  expect(detail.detail?.tasks).toEqual(before?.asyncTasks);
  expect(detail.detail?.tickets).toEqual(before?.completionTickets);
  expect(await f.store.loadReadOnly("session-1")).toEqual(before);
});

it("revokes release on unarchive and reopens only on explicit fresh input", async () => {
  const f = await fixture(); await f.archive();
  const prepared = await f.supervisor.executeAsyncTaskCommand(f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 1 }));
  expect(prepared.outcome).toBe("settled");
  await expect(f.supervisor.steer("session-1", "must not run")).rejects.toThrow(/archived|fenced/);
  await f.supervisor.setSessionArchived("session-1", false);
  const restored = await f.store.loadReadOnly("session-1");
  expect(restored?.asyncControl?.releasePrepared).toBeUndefined();
  expect(restored?.asyncControl?.admissionState).toBe("closed");
  await f.supervisor.steer("session-1", "fresh explicit input");
  expect((await f.store.loadReadOnly("session-1"))?.asyncControl?.admissionState).toBe("open");
  expect(f.handle.getSteeringMessages().join(" ")).toContain("fresh explicit input");
});

it("does not release across a user input accepted before the admission cut", async () => {
  const f = await fixture();
  let resume!: () => void; let entered!: () => void;
  const pending = new Promise<void>((resolve) => { resume = resolve; });
  const started = new Promise<void>((resolve) => { entered = resolve; });
  vi.spyOn(f.handle, "followUp").mockImplementation(async () => { entered(); await pending; });
  const input = f.supervisor.followUp("session-1", "accepted earlier");
  await started; await f.archive();
  const release = await f.supervisor.executeAsyncTaskCommand(f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 1 }));
  expect(release.outcome).toBe("rejected");
  expect((await f.store.loadReadOnly("session-1"))?.asyncControl?.releasePrepared).toBeUndefined();
  resume(); await input;
  await vi.waitFor(async () => {
    const disk = await f.store.loadReadOnly("session-1");
    expect(disk?.messages?.some((message) => message.kind === "user_text" && message.text === "accepted earlier")).toBe(true);
  }, { interval: 1, timeout: 500 });
});

it("rechecks archive revision in the final writer when a grant arrives during confirmation", async () => {
  const f = await fixture();
  const preparation = await f.supervisor.executeAsyncTaskCommand(f.command("prepareSessionArchive", { archiveIntentId: "intent-1" }));
  let enter!: () => void; let release!: () => void;
  const saving = new Promise<void>((resolve) => { enter = resolve; });
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const save = f.store.save.bind(f.store);
  vi.spyOn(f.store, "save").mockImplementation(async (session) => {
    if (session.asyncControl?.operations.some((operation) => operation.requestId === "executeSessionArchive" && operation.outcome === "accepted")) { enter(); await gate; }
    await save(session);
  });
  const archive = f.supervisor.executeAsyncTaskCommand(f.command("executeSessionArchive", { archiveIntentId: "intent-1", preparationId: preparation.preparationId!, mode: "continue" }));
  await saving;
  const registration = f.register("new-grant");
  release(); await registration;
  expect((await archive).outcome).toBe("stale");
  expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
});

it("does not let an older archive intent authorize a later rearchive", async () => {
  const f = await fixture(); await f.archive();
  await f.supervisor.setSessionArchived("session-1", false);
  await f.supervisor.setSessionArchived("session-1", true);
  const release = await f.supervisor.executeAsyncTaskCommand(f.command("prepareRuntimeRelease", { archiveIntentId: "intent-1", childGeneration: 1 }));
  expect(release.outcome).toBe("stale");
  expect((await f.store.loadReadOnly("session-1"))?.asyncControl?.releasePrepared).toBeUndefined();
});

it("commits stop-then-archive only after task cleanup and delivery suppression are persisted", async () => {
  const f = await fixture(); await f.addTask();
  const preparation = await f.supervisor.executeAsyncTaskCommand(f.command("prepareSessionArchive", { archiveIntentId: "intent-1" }));
  const result = await f.supervisor.executeAsyncTaskCommand(f.command("executeSessionArchive", { archiveIntentId: "intent-1", preparationId: preparation.preparationId!, mode: "stopThenArchive" }));
  expect(result.outcome).toBe("settled");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk).toMatchObject({ archived: true, asyncArchiveIntentId: "intent-1" });
  expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "cancelled", presence: "settled" });
  expect(disk?.completionTickets?.[0]?.state).toBe("suppressed");
  expect(f.projected.at(-1)).toMatchObject({ archived: true, asyncControl: { admissionState: "closed" } });
  expect(disk?.asyncControlJournal?.at(-1)?.result).toEqual(result);
});

it("reconciles a failed stop with real subsequent cleanup without erasing its original result", async () => {
  const f = await fixture({ fail: "cancel" }); await f.addTask();
  const failed = await f.supervisor.asyncControls.stop("session-1", "failed-stop");
  expect(failed.outcome).toBe("blocked_cleanup");
  f.setFailure(undefined);
  const retry = await f.supervisor.asyncControls.stop("session-1", "retry-stop");
  expect(retry.outcome).toBe("settled");
  expect(await f.supervisor.asyncControls.stop("session-1", "failed-stop")).toEqual(failed);
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncControlJournal?.find((entry) => entry.result.operationId === failed.operationId)).toMatchObject({ result: failed, resolvedBy: retry.operationId });
  expect(disk?.asyncWorkSummary?.canReleaseRuntime).toBe(true);
  await f.supervisor.steer("session-1", "Run a fresh task");
  await f.addTask(false, "new-task");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.find((task) => task.taskId === "new-task")?.registration).toBe("spawned");
  expect((await f.store.loadReadOnly("session-1"))?.completionTickets?.[0]?.state).toBe("suppressed");
});

it("routes legacy archive through the same owner choice and settled state", async () => {
  const f = await fixture(); await f.addTask();
  await expect(f.supervisor.setSessionArchived("session-1", true)).rejects.toThrow("Archive choice required");
  expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
  await f.supervisor.setSessionArchived("session-1", true, "stopThenArchive", "legacy-archive");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk).toMatchObject({ archived: true, asyncArchiveIntentId: "legacy-archive" });
  expect(disk?.asyncTasks?.[0]?.presence).toBe("settled");
  const effects = f.calls.length;
  await f.supervisor.setSessionArchived("session-1", true, "stopThenArchive", "legacy-archive");
  expect(f.calls).toHaveLength(effects);
});

it("protects reload, new, rewind, plugin reload, terminal sync and deletion without losing the resource observer", async () => {
  const f = await fixture(); await f.addTask(false);
  for (const text of ["/new", "/reload"]) await expect(f.supervisor.followUp("session-1", text)).rejects.toThrow(/Async|async/);
  await expect(f.supervisor.rewindToEntry("session-1", "entry")).rejects.toThrow(/Async|async/);
  expect((await f.supervisor.reloadPlugins()).pickleDeferredCount).toBe(1);
  await expect(f.supervisor.syncTerminalSession("session-1")).rejects.toThrow("Terminal sync blocked");
  await f.supervisor.setSessionArchived("session-1", true, "continue");
  await expect(f.supervisor.deleteSession("session-1")).rejects.toThrow();
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("active");
  expect((await f.supervisor.asyncControls.stop("session-1", "stop-after-guards")).outcome).toBe("settled");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("settled");
});

it("retains archived old-owner work across restart and TTL even when optional control metadata is absent", async () => {
  const f = await fixture(); await f.addTask(false);
  const original = f.supervisor.get("session-1")!;
  await f.store.save({ ...original, archived: true, archivedAt: "2020-01-01T00:00:00.000Z", status: "completed", asyncControl: undefined });
  const restarted = new SessionSupervisor(new MockRuntime(), f.store);
  await restarted.load();
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.asyncTasks?.[0]).toMatchObject({ presence: "unknown", execution: "interrupted" });
  expect(disk?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  await expect(restarted.deleteSession("session-1")).rejects.toThrow();
  expect(await f.store.loadReadOnly("session-1")).toBeDefined();
});

it("keeps the archived record and runtime ownership when final disposal fails", async () => {
  const f = await fixture(); await f.archive();
  vi.spyOn(f.handle, "dispose").mockRejectedValue(new Error("external teardown failed"));
  await expect(f.supervisor.deleteSession("session-1")).rejects.toThrow("teardown did not complete");
  expect((await f.store.loadReadOnly("session-1"))?.archived).toBe(true);
  expect(f.supervisor.asyncControls.context("session-1").runtimeInstanceId).toBe(f.owner.runtimeInstanceId);
});

it("does not discard a reserved grant merely because its presence is settled", async () => {
  const f = await fixture(); await f.register("unlaunched-grant"); await f.settleUnconsumedGrant();
  await expect(f.supervisor.setSessionArchived("session-1", true)).rejects.toThrow("Archive choice required");
  await expect(f.supervisor.followUp("session-1", "/new")).rejects.toThrow();
  await f.supervisor.setSessionArchived("session-1", true, "continue");
  await expect(f.supervisor.deleteSession("session-1")).rejects.toThrow();
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]).toMatchObject({ registration: "approved", presence: "settled" });
});

it("retains original resource observers when the external JSONL tail advances", async () => {
  const f = await fixture(); await f.addTask(false);
  const file = join(f.root, "terminal.jsonl");
  await writeFile(file, JSON.stringify({ type: "session", version: 3, id: "pi-1", cwd: f.root, timestamp: new Date().toISOString() }) + "\n");
  f.handle.emit({ type: "log", line: `pi session: ${file}` });
  await vi.waitFor(() => expect(f.supervisor.get("session-1")?.piSessionFilePath).toBe(file));
  await f.supervisor.setTerminalSessionTailEnabled("session-1", true);
  try {
    await appendFile(file, JSON.stringify({ type: "message", id: "external", timestamp: new Date().toISOString(), message: { role: "assistant", content: [{ type: "text", text: "External terminal reply" }], stopReason: "stop" } }) + "\n");
    await vi.waitFor(() => expect(f.supervisor.get("session-1")?.lastSummary).toContain("Terminal transcript changed"));
    expect(f.supervisor.asyncControls.context("session-1").runtimeInstanceId).toBe(f.owner.runtimeInstanceId);
    expect((await f.supervisor.asyncControls.stop("session-1", "after-tail-conflict")).outcome).toBe("settled");
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("settled");
  } finally { await f.supervisor.setTerminalSessionTailEnabled("session-1", false); }
});

it("permits plain archive of a completed Pickle while the live owner reports no required choice", async () => {
  const f = await fixture();
  f.handle.emit({ type: "status", status: "completed", summary: "Finished" });
  await vi.waitFor(() => expect(f.supervisor.get("session-1")?.status).toBe("completed"));
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(false);
  await f.supervisor.setSessionArchived("session-1", true);
  expect((await f.store.loadReadOnly("session-1"))?.archived).toBe(true);
  expect(f.projected.at(-1)?.archived).toBe(true);
});

it("requires archive choice for missing provider coverage and for a lost owner", async () => {
  const f = await fixture({ missing: true });
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(true);
  await expect(f.supervisor.setSessionArchived("session-1", true)).rejects.toThrow("Archive choice required");
  expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
  const restarted = new SessionSupervisor(new MockRuntime(), f.store);
  await restarted.load();
  expect(restarted.asyncControls.context("session-1")).toMatchObject({ requiresArchiveChoice: true, tracking: "unsupported" });
});

it("requires archive choice during an admitted input lease before any model or persisted queue activity", async () => {
  const f = await fixture();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const before = await f.store.loadReadOnly("session-1");
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(false);
  const input = f.supervisor.asyncControls.input("session-1", () => gate);
  try {
    expect((await f.store.loadReadOnly("session-1"))?.revision).toBe(before?.revision);
    expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(true);
    await expect(f.supervisor.setSessionArchived("session-1", true)).rejects.toThrow("Archive choice required");
    expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
  } finally { release(); await input; }
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(false);
  await f.supervisor.setSessionArchived("session-1", true);
  expect((await f.store.loadReadOnly("session-1"))?.archived).toBe(true);
});

it("rejects an implicit archive's captured revision after new work changes the owner choice", async () => {
  const f = await fixture();
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(false);
  const captured = f.command("prepareSessionArchive", { archiveIntentId: "implicit-archive" });
  await f.addTask(false);
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(true);
  expect((await f.supervisor.executeAsyncTaskCommand(captured)).outcome).toBe("stale");
  await expect(f.supervisor.setSessionArchived("session-1", true)).rejects.toThrow("Archive choice required");
  expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
});

it("rejects implicit archive when an input lease arrives during the preparation write", async () => {
  const f = await fixture();
  let entered!: () => void; let resumeSave!: () => void; let resumeInput!: () => void;
  const saving = new Promise<void>((resolve) => { entered = resolve; });
  const saveGate = new Promise<void>((resolve) => { resumeSave = resolve; });
  const inputGate = new Promise<void>((resolve) => { resumeInput = resolve; });
  const save = f.store.save.bind(f.store);
  vi.spyOn(f.store, "save").mockImplementation(async (session) => {
    if (session.asyncControl?.operations.some((operation) => operation.requestId === "implicit-race:prepare" && operation.outcome === "accepted")) { entered(); await saveGate; }
    await save(session);
  });
  expect(f.supervisor.asyncControls.context("session-1").requiresArchiveChoice).toBe(false);
  const archive = f.supervisor.setSessionArchived("session-1", true, undefined, "implicit-race").then(() => "archived", (error: Error) => error.message);
  await saving;
  const revision = f.supervisor.asyncControls.context("session-1").workRevision;
  const input = f.supervisor.asyncControls.input("session-1", () => inputGate);
  try {
    expect(f.supervisor.asyncControls.context("session-1").workRevision).toBe(revision);
    resumeSave();
    const outcome = await archive;
    const disk = await f.store.loadReadOnly("session-1");
    console.log("implicit archive lease race", { outcome, diskArchived: disk?.archived === true, projectedArchived: f.projected.at(-1)?.archived === true });
    expect(disk?.archived).not.toBe(true);
    expect(f.projected.at(-1)?.archived).not.toBe(true);
    expect(outcome).toContain("Archive choice required");
  } finally { resumeSave(); resumeInput(); await input; }
});

it.each([true, false, undefined])("checks final archive writer leases with requireQuiescence=%s and preserves exact retry", async (requireQuiescence) => {
  const f = await fixture();
  const fields = requireQuiescence === undefined ? {} : { requireQuiescence };
  const prepareCommand = f.command("prepareSessionArchive", { archiveIntentId: "writer-race", ...fields });
  const prepared = await f.supervisor.executeAsyncTaskCommand(prepareCommand);
  expect(prepared.outcome).toBe("settled");
  expect(await f.supervisor.executeAsyncTaskCommand(prepareCommand)).toEqual(prepared);
  let entered!: () => void; let resumeSave!: () => void; let resumeInput!: () => void;
  const saving = new Promise<void>((resolve) => { entered = resolve; });
  const saveGate = new Promise<void>((resolve) => { resumeSave = resolve; });
  const inputGate = new Promise<void>((resolve) => { resumeInput = resolve; });
  const save = f.store.save.bind(f.store);
  vi.spyOn(f.store, "save").mockImplementation(async (session) => {
    if (session.asyncControl?.operations.some((operation) => operation.requestId === "writer-execute" && operation.outcome === "accepted")) { entered(); await saveGate; }
    await save(session);
  });
  const command = f.command("executeSessionArchive", { archiveIntentId: "writer-race", preparationId: prepared.preparationId!, mode: "continue", ...fields }, "writer-execute");
  const archive = f.supervisor.executeAsyncTaskCommand(command);
  await saving;
  const revision = f.supervisor.asyncControls.context("session-1").workRevision;
  const input = f.supervisor.asyncControls.input("session-1", () => inputGate);
  try {
    expect(f.supervisor.asyncControls.context("session-1").workRevision).toBe(revision);
    resumeSave();
    const result = await archive;
    const disk = await f.store.loadReadOnly("session-1");
    console.log("final archive writer lease race", { requireQuiescence, outcome: result.outcome, diskArchived: disk?.archived === true, projectedArchived: f.projected.at(-1)?.archived === true });
    expect(result.outcome).toBe(requireQuiescence ? "rejected" : "settled");
    expect(disk?.archived === true).toBe(!requireQuiescence);
    expect(f.projected.at(-1)?.archived === true).toBe(!requireQuiescence);
    expect(disk?.asyncControlJournal?.find((entry) => entry.result.requestId === command.requestId)?.result).toEqual(result);
    resumeInput(); await input;
    expect(await f.supervisor.executeAsyncTaskCommand(command)).toEqual(result);
    await expect(f.supervisor.executeAsyncTaskCommand({ ...command, requireQuiescence: !requireQuiescence })).rejects.toThrow("different input");
  } finally { resumeSave(); resumeInput(); await input; }
});

it.each([false, undefined])("does not downgrade a quiescent preparation to requireQuiescence=%s", async (requireQuiescence) => {
  const f = await fixture();
  const command = f.command("prepareSessionArchive", { archiveIntentId: "implicit", requireQuiescence: true });
  const preparation = await f.supervisor.executeAsyncTaskCommand(command);
  expect(preparation.outcome).toBe("settled");
  await expect(f.supervisor.executeAsyncTaskCommand({ ...command, requireQuiescence: false })).rejects.toThrow("different input");
  const execute = f.command("executeSessionArchive", { archiveIntentId: "implicit", preparationId: preparation.preparationId!, mode: "continue", ...(requireQuiescence === undefined ? {} : { requireQuiescence }) });
  const result = await f.supervisor.executeAsyncTaskCommand(execute);
  expect(result.outcome).toBe("rejected");
  expect(result.reason).toContain("requires quiescence");
  expect(await f.supervisor.executeAsyncTaskCommand(execute)).toEqual(result);
  expect((await f.store.loadReadOnly("session-1"))?.archived).not.toBe(true);
  expect(f.projected.at(-1)?.archived).not.toBe(true);
});

it("retains implicit preparation intent when legacy archive resumes with explicit continue", async () => {
  const f = await fixture();
  const preparation = await f.supervisor.executeAsyncTaskCommand(f.command("prepareSessionArchive", { archiveIntentId: "legacy-resume", requireQuiescence: true }, "legacy-resume:prepare"));
  expect(preparation.outcome).toBe("settled");
  let resume!: () => void;
  const gate = new Promise<void>((resolve) => { resume = resolve; });
  const input = f.supervisor.asyncControls.input("session-1", () => gate);
  try {
    await expect(f.supervisor.setSessionArchived("session-1", true, "continue", "legacy-resume")).rejects.toThrow("Archive choice required");
    const disk = await f.store.loadReadOnly("session-1");
    expect(disk?.archived).not.toBe(true);
    expect(f.projected.at(-1)?.archived).not.toBe(true);
    const execute = disk?.asyncControlJournal?.find((entry) => entry.result.requestId === "legacy-resume:execute");
    expect(JSON.parse(execute!.fingerprint)).toMatchObject({ requireQuiescence: true });
  } finally { resume(); await input; }
});
