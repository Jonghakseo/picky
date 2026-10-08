import { once } from "node:events";
import WebSocket from "ws";
import { AgentdServer } from "./server.js";
import { PROTOCOL_VERSION, type EventEnvelope } from "./protocol.js";
import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createEventBus } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
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
}, 20_000); // The production ownership fence waits up to 12 seconds for actual resource exit.

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

it("stops only the response over the wire and leaves background tasks running", async () => {
  const f = await fixture(); await f.addTask();
  const server = new AgentdServer({ port: 0, token: "response-abort", supervisor: f.supervisor });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=response-abort`);
  const events: EventEnvelope[] = [];
  ws.on("message", (data) => events.push(JSON.parse(String(data)) as EventEnvelope));
  try {
    await once(ws, "open");
    ws.send(JSON.stringify({ id: "abort-response", protocolVersion: PROTOCOL_VERSION, type: "abort", sessionId: "session-1", scope: "response" }));
    await vi.waitFor(() => expect(f.supervisor.get("session-1")?.messages?.some((message) => message.text === "Cancelled by user")).toBe(true));
    await f.supervisor.withSessionProjectionBarrier("session-1", async () => {});
    // The Pickle's whole-work status stays running while its background task runs.
    expect(f.supervisor.get("session-1")?.status).toBe("running");
    expect(events.some((event) => event.type === "asyncTaskCommandResult")).toBe(false);
    expect(f.calls.map((call) => call.action)).not.toContain("cancel");
    const disk = await f.store.loadReadOnly("session-1");
    expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "running", presence: "active" });
    expect(disk?.asyncControl?.admissionState).not.toBe("closed");
    expect(disk?.asyncWorkSummary?.activeRootCount).toBe(1);
  } finally {
    ws.close(); await server.stop();
  }
});

it("stops background tasks over the wire while a response-only abort is still pending", async () => {
  const f = await fixture(); await f.addTask();
  f.handle.isStreaming = true;
  let releaseResponseAbort!: () => void;
  const responseAbortGate = new Promise<void>((resolve) => { releaseResponseAbort = resolve; });
  let responseAbortEntered = false;
  const originalAbort = f.handle.abort.bind(f.handle);
  vi.spyOn(f.handle, "abort").mockImplementation(async () => {
    // Only the first runtime abort waits; a full stop can still stop the model.
    if (!responseAbortEntered) {
      responseAbortEntered = true;
      await responseAbortGate;
    }
    f.handle.isStreaming = false;
    await originalAbort();
  });
  const server = new AgentdServer({ port: 0, token: "overlapping-abort", supervisor: f.supervisor });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=overlapping-abort`);
  const events: EventEnvelope[] = [];
  const sentCommandIDs: string[] = [];
  ws.on("message", (data) => events.push(JSON.parse(String(data)) as EventEnvelope));
  try {
    await once(ws, "open");
    ws.send(JSON.stringify({ id: "abort-response", protocolVersion: PROTOCOL_VERSION, type: "abort", sessionId: "session-1", scope: "response" }));
    sentCommandIDs.push("abort-response");
    await vi.waitFor(() => expect(responseAbortEntered).toBe(true));

    ws.send(JSON.stringify({ id: "abort-all", protocolVersion: PROTOCOL_VERSION, type: "abort", sessionId: "session-1" }));
    sentCommandIDs.push("abort-all");
    let fullStopFrameReceived = false;
    ws.once("pong", () => { fullStopFrameReceived = true; });
    // Pong proves receipt of the preceding abort frame without requiring one
    // command to finish before the other, so serialized execution is valid too.
    ws.ping();
    await vi.waitFor(() => expect(fullStopFrameReceived).toBe(true));
    expect(events).not.toContainEqual(expect.objectContaining({ type: "ack", commandId: "abort-response" }));
    releaseResponseAbort();

    await vi.waitFor(() => {
      expect(events).toEqual(expect.arrayContaining([
        expect.objectContaining({ type: "asyncTaskCommandResult", result: expect.objectContaining({ requestId: "abort-all", outcome: "settled" }) }),
        expect.objectContaining({ type: "ack", commandId: "abort-all" }),
        expect.objectContaining({ type: "ack", commandId: "abort-response" }),
      ]));
    });
    expect(events.filter((event) => event.type === "error")).toEqual([]);
    expect(f.calls).toContainEqual(expect.objectContaining({ action: "cancel", taskId: "task-1" }));
    const stopped = await f.store.loadReadOnly("session-1");
    expect(stopped?.asyncTasks?.[0]).toMatchObject({ execution: "cancelled", presence: "settled" });
    expect(stopped?.completionTickets?.[0]?.state).toBe("suppressed");
    expect(stopped?.asyncControl?.admissionState).toBe("closed");
    expect(stopped?.asyncWorkSummary?.activeRootCount).toBe(0);
  } finally {
    releaseResponseAbort();
    try {
      // Finish every request before afterEach removes the temporary store.
      await vi.waitFor(() => {
        for (const commandId of sentCommandIDs) {
          expect(events.some((event) => (event.type === "ack" || event.type === "error") && event.commandId === commandId)).toBe(true);
        }
      });
    } finally {
      ws.close(); await server.stop();
    }
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

it("continues past a failed stop on the next user input while the unproven work stays visible", async () => {
  const f = await fixture({ fail: "cancel" }); await f.addTask();
  const failed = await f.supervisor.asyncControls.stop("session-1", "failed-stop");
  expect(failed.outcome).toBe("blocked_cleanup");
  expect(f.supervisor.get("session-1")?.status).toBe("blocked");

  await f.supervisor.steer("session-1", "Continue without that task");

  const disk = await f.store.loadReadOnly("session-1");
  expect(disk?.status).not.toBe("blocked");
  expect(disk?.asyncControl?.admissionState).toBe("open");
  expect(disk?.asyncControl?.acknowledgedRoots).toEqual([expect.objectContaining({ rootTaskId: "task-1", runtimeInstanceId: f.owner.runtimeInstanceId })]);
  // Cleanup was never proven: the task stays listed as unsettled and still withholds release.
  expect(disk?.asyncTasks?.find((task) => task.taskId === "task-1")?.presence).toBe("active");
  expect(disk?.asyncWorkSummary).toMatchObject({ attentionCount: 0, canReleaseRuntime: false });
  expect(disk?.asyncControlJournal?.find((entry) => entry.result.operationId === failed.operationId)?.resolvedBy).toBeDefined();
  // Input stays open afterwards instead of reentering the failed-stop fence.
  await f.supervisor.steer("session-1", "And one more instruction");
}, 20_000);

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

it("protects automatic replacement while explicitly deleting archived connected work", async () => {
  const f = await fixture(); await f.addTask(false);
  for (const text of ["/new", "/reload"]) await expect(f.supervisor.followUp("session-1", text)).rejects.toThrow(/Async|async/);
  await expect(f.supervisor.rewindToEntry("session-1", "entry")).rejects.toThrow(/Async|async/);
  expect((await f.supervisor.reloadPlugins()).pickleDeferredCount).toBe(1);
  await expect(f.supervisor.syncTerminalSession("session-1")).rejects.toThrow("Terminal sync blocked");
  await f.supervisor.setSessionArchived("session-1", true, "continue");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("active");
  await f.supervisor.deleteSession("session-1");
  expect(await f.store.loadReadOnly("session-1")).toBeUndefined();
});

it("does not count async-tracked Pickles without a live runtime as deferred plugin reloads", async () => {
  const f = await fixture(); await f.addTask(false);
  // An app restart leaves persisted async state but no runtime handle; there is nothing to reload.
  const restarted = new SessionSupervisor(new MockRuntime(), f.store, { sessionIdFactory: () => "session-2", enableAsyncTasksForSession: () => true });
  await restarted.load();
  expect(await restarted.reloadPlugins()).toMatchObject({ pickleReloadedCount: 0, pickleDeferredCount: 0 });
  expect((await f.store.loadReadOnly("session-1"))?.logs).not.toContain("plugins reload blocked by outstanding async work or coverage");
});

it("keeps an archived Pickle when explicit deletion cannot confirm connected task cleanup", async () => {
  const f = await fixture({ fail: "cancel" }); await f.addTask(false);
  await f.supervisor.setSessionArchived("session-1", true, "continue");
  await expect(f.supervisor.deleteSession("session-1")).rejects.toThrow(/cleanup|cancel|settled/i);
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("active");
  expect(f.supervisor.get("session-1")?.archived).toBe(true);
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
  await restarted.deleteSession("session-1");
  expect(await f.store.loadReadOnly("session-1")).toBeUndefined();
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
  await expect(f.supervisor.deleteSession("session-1")).rejects.toThrow(/cleanup|grant|timed out/i);
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]).toMatchObject({ registration: "approved", presence: "settled" });
}, 20000);

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

it("commits quiescent archive membership with a new closed admission generation and reopens on fresh input", async () => {
  const f = await fixture();
  const before = f.supervisor.asyncControls.context("session-1");
  await f.supervisor.setSessionArchived("session-1", true, undefined, "quiet-archive");
  const disk = await f.store.loadReadOnly("session-1");
  expect(disk).toMatchObject({ archived: true, asyncArchiveIntentId: "quiet-archive", asyncControl: { admissionState: "closed", controlGeneration: before.controlGeneration + 1 } });
  expect(f.projected.at(-1)?.asyncControl).toEqual(disk?.asyncControl);
  await f.register("late-task");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks ?? []).toEqual([]);
  await f.supervisor.setSessionArchived("session-1", false);
  expect((await f.store.loadReadOnly("session-1"))?.asyncControl?.admissionState).toBe("closed");
  await f.supervisor.steer("session-1", "fresh explicit input");
  await f.register("fresh-task");
  expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.registration).toBe("approved");
  expect(f.supervisor.asyncControls.context("session-1").controlGeneration).toBeGreaterThan(before.controlGeneration + 1);
});

it("does not commit an archive admission cut when its final storage write fails and keeps exact retry", async () => {
  const f = await fixture();
  const before = f.supervisor.asyncControls.context("session-1");
  const save = f.store.save.bind(f.store);
  let failed = false;
  vi.spyOn(f.store, "save").mockImplementation(async state => {
    if (!failed && state.archived === true && state.asyncControlJournal?.some(entry => entry.result.requestId === "failed-archive:execute" && entry.result.outcome === "settled")) {
      failed = true; throw new Error("final archive write unavailable");
    }
    await save(state);
  });
  await expect(f.supervisor.setSessionArchived("session-1", true, undefined, "failed-archive")).rejects.toThrow("final archive write unavailable");
  const disk = await f.store.loadReadOnly("session-1");
  expect(failed).toBe(true);
  expect(disk?.archived).not.toBe(true);
  expect(disk?.asyncControl).toMatchObject({ admissionState: "open", controlGeneration: before.controlGeneration });
  const failedResult = disk?.asyncControlJournal?.find(entry => entry.result.requestId === "failed-archive:execute")?.result;
  expect(failedResult?.outcome).toBe("blocked_cleanup");
  await expect(f.supervisor.setSessionArchived("session-1", true, undefined, "failed-archive")).rejects.toThrow("final archive write unavailable");
  expect((await f.store.loadReadOnly("session-1"))?.asyncControlJournal?.find(entry => entry.result.requestId === "failed-archive:execute")?.result).toEqual(failedResult);
  await f.supervisor.setSessionArchived("session-1", true, "continue", "fresh-archive");
  expect((await f.store.loadReadOnly("session-1"))?.archived).toBe(true);
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

async function settledAsyncPickle() {
  const f = await fixture();
  f.handle.emit({ type: "status", status: "completed", summary: "Finished" });
  await vi.waitFor(() => expect(f.supervisor.get("session-1")?.status).toBe("completed"));
  // Mirror a live Pickle whose response cycle and work episode have both settled.
  const cycleId = "cycle-1";
  await (f.supervisor as unknown as { commitSession(id: string, build: (current: PickyAgentSession) => PickyAgentSession): Promise<unknown> }).commitSession("session-1", (current) => ({ ...current,
    agentCycle: { cycleId, runtimeInstanceId: f.owner.runtimeInstanceId, phase: "settled", controlGeneration: 0, outcome: "completed" },
    asyncWorkSummary: { ...current.asyncWorkSummary!, episode: { id: cycleId, settled: true, finalizedCycleId: cycleId, outcome: "completed" } } }));
  expect(f.supervisor.get("session-1")?.status).toBe("completed");
  return { ...f, session: () => f.supervisor.get("session-1")! };
}

async function plainCompletedPickle() {
  const root = await mkdtemp(join(tmpdir(), "picky-plain-")); roots.push(root);
  const handle = new MockRuntimeSession("session-1");
  const runtime: AgentRuntime = { create: new MockRuntime().create, prewarm: async () => handle };
  const supervisor = new SessionSupervisor(runtime, new SessionStore(root), { sessionIdFactory: () => "session-1" });
  await supervisor.load();
  await supervisor.createEmptyPickleSession({ id: "context-1", source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] });
  handle.emit({ type: "status", status: "completed", summary: "Finished" });
  await vi.waitFor(() => expect(supervisor.get("session-1")?.status).toBe("completed"));
  return { supervisor, handle, session: () => supervisor.get("session-1")! };
}

type CompletedPickle = Awaited<ReturnType<typeof plainCompletedPickle>>;
const completedPickleKinds: [string, () => Promise<CompletedPickle>][] = [
  ["plain Pickle", plainCompletedPickle],
  ["settled async Pickle", settledAsyncPickle],
];
const receivedAt = "2026-05-01T00:00:00.000Z";

/** Mirrors PiSdkRuntimeSession: an inline extension command emits its effects, then a no-turn completion. */
function runsWithoutTurn(f: CompletedPickle, effects: (handle: MockRuntimeSession) => void): void {
  Object.assign(f.handle, { followUp: async () => {
    effects(f.handle);
    f.handle.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
  } });
}

// Work that reaches a completed Pickle without starting a Pi turn. Each row asserts what the user
// sees, for a plain Pickle and for an async-task Pickle whose status folds back to its settled
// episode. Add a row whenever a new no-turn command, extension UI surface, or runtime snapshot
// event is introduced; a terminal guard that treats it as late turn output fails here.
const noTurnWorkContract: { name: string; run(f: CompletedPickle): Promise<void>; expectVisible(f: CompletedPickle): Promise<void> }[] = [
  {
    name: "/name renames the Pickle",
    async run(f) {
      runsWithoutTurn(f, (handle) => handle.emit({ type: "session_info", name: "새 이름" }));
      await f.supervisor.followUp("session-1", "/name 새 이름");
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().title).toBe("새 이름"));
      await vi.waitFor(() => expect(f.session().status).toBe("completed"));
    },
  },
  {
    name: "an extension command notify becomes a visible message",
    async run(f) {
      runsWithoutTurn(f, (handle) => handle.emit({ type: "extension_ui", waitsForInput: false, request: { id: "ui-notify", sessionId: "session-1", method: "notify", prompt: "✓ delay-1 예약됨", notifyType: "info", createdAt: receivedAt } }));
      await f.supervisor.followUp("session-1", "/delay 1h 확인");
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().messages?.some((message) => message.kind === "system" && message.text === "✓ delay-1 예약됨")).toBe(true));
      await vi.waitFor(() => expect(f.session().status).toBe("completed"));
    },
  },
  {
    name: "an extension command dialog waits for the user",
    async run(f) {
      // Pi keeps the command handler pending until the dialog is answered.
      Object.assign(f.handle, { followUp: () => new Promise<void>(() => {
        f.handle.emit({ type: "extension_ui", waitsForInput: true, request: { id: "ui-select", sessionId: "session-1", method: "select", title: "예약된 delay를 선택하세요", options: ["delay-1"], createdAt: receivedAt } });
      }) });
      await f.supervisor.followUp("session-1", "/delay-list");
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().pendingExtensionUiRequest?.id).toBe("ui-select"));
      expect(f.session().status).toBe("waiting_for_input");
      expect(f.session().messages?.some((message) => message.kind === "agent_question" && message.question?.id === "ui-select")).toBe(true);
    },
  },
  {
    name: "a long extension command stays running until it finishes",
    async run(f) {
      let finish!: () => void;
      Object.assign(f.handle, { followUp: () => new Promise<void>((resolve) => { finish = () => {
        f.handle.emit({ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true });
        resolve();
      }; }) });
      await f.supervisor.followUp("session-1", "/long-extension-command");
      await vi.waitFor(() => expect(finish).toBeDefined());
      expect(f.session().status).toBe("running");
      finish();
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().status).toBe("completed"));
    },
  },
  {
    name: "user bash stays running while it executes and applies its context usage",
    async run(f) {
      let statusDuringBash: string | undefined;
      Object.assign(f.handle, { executeUserBash: async () => {
        statusDuringBash = f.session().status;
        f.handle.emit({ type: "context_usage", usage: { tokens: 4242, contextWindow: 200000, percent: 2.1 } });
        return { output: "ok\n", exitCode: 0, cancelled: false, truncated: false };
      } });
      await f.supervisor.followUp("session-1", "!echo ok");
      expect(statusDuringBash).toBe("running");
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().status).toBe("completed"));
      expect(f.session().contextUsage).toEqual({ tokens: 4242, contextWindow: 200000, percent: 2.1 });
    },
  },
  {
    name: "a follow-up delivery failure is reported",
    async run(f) {
      Object.assign(f.handle, { followUp: async () => { throw new Error("No API key for provider"); } });
      await f.supervisor.followUp("session-1", "continue");
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().lastSummary).toBe("Follow-up failed: No API key for provider"));
    },
  },
  {
    name: "a context usage snapshot after completion updates the header",
    async run(f) {
      f.handle.emit({ type: "context_usage", usage: { tokens: 1500, contextWindow: 200000, percent: 0.75 } });
    },
    async expectVisible(f) {
      await vi.waitFor(() => expect(f.session().contextUsage?.tokens).toBe(1500));
      expect(f.session().status).toBe("completed");
    },
  },
];

describe.each(completedPickleKinds)("no-turn work on a completed %s", (_kind, completedPickle) => {
  it.each(noTurnWorkContract)("$name", async (scenario) => {
    const f = await completedPickle();
    await scenario.run(f);
    await scenario.expectVisible(f);
  });
});

it("surfaces a follow-up delivery failure on a settled async Pickle", async () => {
  const f = await settledAsyncPickle();
  Object.assign(f.handle, { followUp: async () => { throw new Error("No API key for provider"); } });

  await f.supervisor.followUp("session-1", "continue");

  await vi.waitFor(() => expect(f.session().messages?.at(-1)).toMatchObject({ kind: "agent_error", errorMessage: "Follow-up failed: No API key for provider" }));
  expect(f.session().lastSummary).toBe("Follow-up failed: No API key for provider");
});
