import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createEventBus } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema, type AsyncTask, type AsyncTaskHostMessage } from "../domain/async-task-contract.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { AsyncTaskHostBridge } from "./async-task-host-bridge.js";
import { MockRuntime } from "./mock-runtime.js";
import type { AgentRuntime, RuntimeCreateOptions } from "./types.js";

const roots: string[] = [];
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });
const capabilities = { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true };
function deferred() { let resolve!: () => void; const promise = new Promise<void>((done) => { resolve = done; }); return { promise, resolve }; }
async function fixture(fixtureOptions: { early?: boolean; missing?: boolean; drain?: boolean | (() => boolean); qualified?: boolean } = {}) {
  const root = await mkdtemp(join(tmpdir(), "picky-w3-bridge-")); roots.push(root);
  const store = new SessionStore(root);
  const mock = new MockRuntime();
  const bus = createEventBus();
  const frames: AsyncTaskHostMessage[] = [];
  bus.on(ASYNC_TASK_CONTRACT, (data) => frames.push(AsyncTaskHostMessageSchema.parse(data)));
  let bridge!: AsyncTaskHostBridge;
  const runtime: AgentRuntime = {
    create: mock.create.bind(mock),
    prewarm: async (options: RuntimeCreateOptions) => {
      bridge = new AsyncTaskHostBridge(bus, options.sessionId!, options.asyncTaskHost!, () => {}, 15, fixtureOptions.drain, fixtureOptions.qualified);
      if (optionsEarly) bus.emit(ASYNC_TASK_CONTRACT, { ...base, sessionId: null, runtimeInstanceId: null, type: "host-query" });
      await bridge.bind("pi-1", optionsMissing ? ["bash_async", "subagent"] : ["bash_async"]);
      return mock.prewarm();
    },
  };
  const optionsEarly = fixtureOptions.early;
  const optionsMissing = fixtureOptions.missing;
  const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => "session-1", enableAsyncTasksForSession: () => true });
  await supervisor.load();
  await supervisor.createEmptyPickleSession({ id: "context-1", source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] });
  const owner = { ...base, runtimeInstanceId: bridge.runtimeInstanceId };
  const send = (data: object) => bus.emit(ASYNC_TASK_CONTRACT, { ...owner, ...data });
  if (!optionsEarly) send({ type: "host-query", sessionId: null, runtimeInstanceId: null });
  await bridge.drain();
  send({ type: "provider-ready", providerVersion: "1", contractVersion: 1, snapshotReady: true, capabilities });
  send({ type: "snapshot", watermark: 0, detail: { tasks: [], tickets: [] } });
  await bridge.drain();
  const task = (id = "task-1"): AsyncTask => ({ sessionId: owner.sessionId, piSessionId: owner.piSessionId, runtimeInstanceId: owner.runtimeInstanceId, providerId: owner.providerId, providerInstanceId: owner.providerInstanceId, taskId: id, rootTaskId: id, kind: "bash", title: "Finite", execution: "queued", presence: "settled", registration: "reserved", providerRevision: 1, controlGeneration: 0, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
  return { store, supervisor, bridge, frames, send, task };
}
const base = { contract: ASYNC_TASK_CONTRACT, requestId: "request-1", sessionId: "session-1", piSessionId: "pi-1", runtimeInstanceId: "runtime-1", providerId: "bash-async", providerInstanceId: "provider-1", providerRevision: 0, controlGeneration: 0 };

describe("durable async task host", () => {
  it.each(["close", "replace", "dispose"] as const)("invalidates admission before %s persistence and never revives its signal", async action => {
    const f = await fixture();
    const signal = f.bridge.admissionSignal;
    expect(signal.aborted).toBe(false);
    const entered = deferred(), release = deferred();
    const save = f.store.save.bind(f.store);
    vi.spyOn(f.store, "save").mockImplementationOnce(async state => {
      entered.resolve(); await release.promise; return save(state);
    });
    const work = action === "close" ? f.bridge.closeAdmission() : action === "replace" ? f.bridge.bind("pi-2", ["bash_async"]) : f.bridge.dispose();
    try {
      expect(signal.aborted).toBe(true);
      await entered.promise;
      expect(f.bridge.admissionOpen).toBe(false);
    } finally { release.resolve(); await work; }
    if (action === "close") await f.bridge.reopenAdmission();
    expect(signal.aborted).toBe(true);
    if (action !== "dispose") {
      expect(f.bridge.admissionSignal.aborted).toBe(false);
      expect(f.bridge.admissionSignal).not.toBe(signal);
    }
  });

  it("reconciles missing snapshot resources as unknown, and saves tombstones before observer disposal", async () => {
    const f = await fixture();
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 }); await f.bridge.drain();
    const task = f.bridge.snapshot().tasks[0]!;
    f.send({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...task, registration: "spawned", execution: "running", presence: "active", providerRevision: 2 }], tickets: [] } });
    await f.bridge.drain();
    expect(f.bridge.snapshot().tasks[0]?.presence).toBe("active");
    f.send({ type: "snapshot", watermark: 3, providerRevision: 3, detail: { tasks: [], tickets: [] } }); await f.bridge.drain();
    expect(f.bridge.snapshot().tasks[0]?.presence).toBe("unknown");
    await f.bridge.dispose();
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("unknown");
  });
  it("rotates runtime identity on replacement but still accepts known old resource exit", async () => {
    const f = await fixture();
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 }); await f.bridge.drain();
    const task = f.bridge.snapshot().tasks[0]!;
    await f.bridge.bind("pi-2", ["bash_async"]);
    expect(f.bridge.runtimeInstanceId).not.toBe(task.runtimeInstanceId);
    expect(f.bridge.coverage().tracking).toBe("reconciling");
    f.send({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...task, execution: "succeeded", presence: "settled", registration: "spawned", providerRevision: 2 }], tickets: [] } });
    await f.bridge.drain();
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]?.presence).toBe("settled");
  });

  it("drains existing work to persisted settlement while rejecting new starts, even after input reopens", async () => {
    let draining = false;
    const f = await fixture({ drain: () => draining });
    expect(f.bridge.coverage().tracking).toBe("ready");
    const existing = f.task("existing");
    await f.bridge.owner.transact((state) => ({ ...state, tasks: [{ ...existing, registration: "spawned", execution: "running", presence: "active" }] }));
    draining = true;
    f.send({ type: "task-register", task: f.task("new"), providerRevision: 1 }); await f.bridge.drain();
    expect(f.frames.find((frame) => frame.type === "task-register-result" && frame.taskId === "new")).toMatchObject({ outcome: "rejected" });
    expect(f.bridge.snapshot().tasks.map((task) => task.taskId)).toEqual(["existing"]);
    f.send({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...f.task("new"), registration: "abandoned", execution: "cancelled", presence: "settled", providerRevision: 2 }], tickets: [] } });
    await f.bridge.drain();
    expect(f.bridge.coverage().tracking).toBe("ready");
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.map((task) => task.taskId)).toEqual(["existing"]);
    await f.bridge.reopenAdmission();
    f.send({ type: "task-register", task: f.task("new-again"), providerRevision: 2, controlGeneration: f.bridge.generation }); await f.bridge.drain();
    expect(f.frames.find((frame) => frame.type === "task-register-result" && frame.taskId === "new-again")).toMatchObject({ outcome: "rejected" });
    f.send({ type: "task-update", providerRevision: 3, controlGeneration: f.bridge.generation, detail: {
      tasks: [{ ...existing, registration: "spawned", execution: "succeeded", presence: "settled", providerRevision: 3 }],
      tickets: [{ sessionId: existing.sessionId, piSessionId: existing.piSessionId, runtimeInstanceId: existing.runtimeInstanceId, providerId: existing.providerId, providerInstanceId: existing.providerInstanceId, completionId: "existing-completion", rootTaskId: existing.taskId, target: "model", state: "pending", controlGeneration: existing.controlGeneration }],
    } });
    await f.bridge.drain();
    const persisted = await f.store.loadReadOnly("session-1");
    expect(persisted?.asyncTasks?.[0]).toMatchObject({ taskId: "existing", execution: "succeeded", presence: "settled" });
    expect(persisted?.completionTickets?.[0]).toMatchObject({ completionId: "existing-completion", state: "pending" });
    expect(f.bridge.coverage().tracking).toBe("ready");
    draining = false;
    f.send({ type: "task-register", task: { ...f.task("reopened"), controlGeneration: f.bridge.generation }, providerRevision: 4, controlGeneration: f.bridge.generation }); await f.bridge.drain();
    expect(f.frames.find((frame) => frame.type === "task-register-result" && frame.taskId === "reopened")).toMatchObject({ outcome: "accepted" });
  });
  it("rejects legacy provider discovery when no capsule is qualified, never asserting empty coverage", async () => {
    const f = await fixture({ qualified: false });
    expect(f.bridge.coverage().tracking).toBe("unsupported");
    expect(f.frames.find((frame) => frame.type === "host-state")).toMatchObject({ supported: false });
    expect(f.bridge.coverage().readyProviders).toEqual([]);
  });
  it("buffers construction-time discovery and leaves missing producer coverage reconciling", async () => {
    const f = await fixture({ early: true, missing: true });
    expect(f.frames.some((frame) => frame.type === "host-state" && frame.supported)).toBe(true);
    expect(f.bridge.coverage()).toMatchObject({ tracking: "reconciling", expectedProviders: ["bash-async", "subagent"], readyProviders: ["bash-async"] });
  });
  it("waits for the real supervisor save before granting, then recovers the same grant by query", async () => {
    const f = await fixture();
    const entered = deferred(), release = deferred();
    const save = f.store.save.bind(f.store);
    vi.spyOn(f.store, "save").mockImplementationOnce(async (state) => { entered.resolve(); await release.promise; return save(state); });
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 });
    await entered.promise;
    expect(f.frames.filter((frame) => frame.type === "task-register-result")).toEqual([]);
    expect(f.supervisor.get("session-1")?.asyncTasks).toEqual([]);
    release.resolve(); await f.bridge.drain();
    const first = f.frames.find((frame) => frame.type === "task-register-result");
    expect(first).toMatchObject({ registration: "approved", outcome: "accepted", grantId: expect.any(String) });
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks?.[0]).toMatchObject({ registration: "approved", presence: "unknown" });
    f.send({ type: "registration-query", taskId: "task-1", requestId: "query-1" });
    f.send({ type: "task-register", task: f.task(), requestId: "retry-1", providerRevision: 1 });
    await f.bridge.drain();
    expect(f.frames.filter((frame) => frame.type === "task-register-result").map((frame) => frame.grantId)).toEqual([first && "grantId" in first ? first.grantId : undefined, first && "grantId" in first ? first.grantId : undefined, first && "grantId" in first ? first.grantId : undefined]);
    expect(f.supervisor.get("session-1")?.asyncTasks).toHaveLength(1);
  });
  it("does not advance memory, disk, or projection when registration save fails", async () => {
    const f = await fixture();
    const before = structuredClone(f.supervisor.get("session-1"));
    const disk = await f.store.loadReadOnly("session-1");
    const projections: unknown[] = [];
    f.supervisor.on("sessionProjectionTransaction", (value) => projections.push(value));
    const admissionSignal = f.bridge.admissionSignal;
    vi.spyOn(f.store, "save").mockRejectedValueOnce(new Error("disk full"));
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 });
    await f.bridge.drain();
    expect(f.frames.filter((frame) => frame.type === "task-register-result")).toEqual([]);
    expect(f.supervisor.get("session-1")).toEqual(before);
    expect(await f.store.loadReadOnly("session-1")).toEqual(disk);
    expect(projections).toEqual([]);
    expect(f.bridge.coverage().tracking).toBe("unsupported");
    expect(admissionSignal.aborted).toBe(true);
  });
  it("persists an abandon-before-register tombstone and never gives a late grant", async () => {
    const f = await fixture();
    f.send({ type: "registration-abandon", taskId: "task-1", neverSpawned: true });
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 });
    f.send({ type: "registration-query", taskId: "task-1" });
    await f.bridge.drain();
    expect(f.frames.filter((frame) => frame.type === "task-register-result").map((frame) => frame.registration)).toEqual(["abandoned", "abandoned", "abandoned"]);
    expect((await f.store.loadReadOnly("session-1"))?.asyncControl?.operations).toHaveLength(1);
    expect(f.bridge.snapshot().tasks).toEqual([]);
  });
  it("keeps resource exit observable after admission closes and refuses old-instance admission", async () => {
    const f = await fixture();
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 }); await f.bridge.drain();
    const registered = f.bridge.snapshot().tasks[0]!;
    await f.bridge.closeAdmission();
    f.send({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...registered, providerRevision: 2, execution: "succeeded", presence: "settled", registration: "spawned" }], tickets: [] } });
    f.send({ type: "task-register", runtimeInstanceId: "old", task: { ...f.task("old-task"), runtimeInstanceId: "old" } });
    await f.bridge.drain();
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks).toMatchObject([{ presence: "settled", execution: "succeeded" }]);
    expect(f.bridge.snapshot().tasks).toHaveLength(1);
  });
  it("does not hold the supervisor write chain while waiting for a provider control reply", async () => {
    const f = await fixture();
    const owner = { ...base, runtimeInstanceId: f.bridge.runtimeInstanceId };
    const pending = f.bridge.control(owner, "detail", { taskId: "task-1" });
    const rejection = expect(pending).rejects.toThrow("outcome unknown");
    f.send({ type: "task-register", task: f.task(), providerRevision: 1 });
    await f.bridge.drain();
    expect((await f.store.loadReadOnly("session-1"))?.asyncTasks).toHaveLength(1);
    await rejection;
  });
});


it("never renews an old grant across admission generations or lost provider coverage", async () => {
  const f = await fixture();
  f.send({ type: "task-register", task: f.task(), providerRevision: 1 }); await f.bridge.drain();
  const grant = f.bridge.snapshot().tasks[0]!.grantId;
  const query = async (generation: number, register = false) => {
    const count = f.frames.filter((frame) => frame.type === "task-register-result").length;
    f.send(register ? { type: "task-register", task: f.task(), providerRevision: 1, controlGeneration: generation } : { type: "registration-query", taskId: "task-1", controlGeneration: generation });
    await f.bridge.drain();
    expect(f.frames.filter((frame) => frame.type === "task-register-result")).toHaveLength(count + 1);
    return f.frames.filter((frame) => frame.type === "task-register-result").at(-1)!;
  };
  expect(await query(0)).toMatchObject({ outcome: "accepted", grantId: grant, controlGeneration: 0 });
  await f.bridge.closeAdmission();
  for (const register of [false, true]) expect(await query(0, register)).toMatchObject({ outcome: "stale", controlGeneration: 0 });
  await f.bridge.reopenAdmission();
  for (const generation of [0, 2]) for (const register of [false, true]) {
    expect(await query(generation, register)).toMatchObject({ outcome: "stale", controlGeneration: 0 });
  }
  expect(f.bridge.snapshot().tasks[0]?.grantId).toBe(grant);
});

it("withholds execution permission until provider snapshot coverage is restored", async () => {
  const f = await fixture();
  f.send({ type: "task-register", task: f.task(), providerRevision: 1 }); await f.bridge.drain();
  for (const snapshotReady of [false, true]) {
    f.send({ type: "provider-ready", providerVersion: "1", contractVersion: 1, snapshotReady, capabilities });
    f.send({ type: "registration-query", taskId: "task-1" }); await f.bridge.drain();
    expect(f.frames.filter((frame) => frame.type === "task-register-result").at(-1)).toMatchObject({ outcome: "rejected" });
  }
  f.send({ type: "snapshot", watermark: 0, detail: { tasks: [], tickets: [] } });
  f.send({ type: "registration-query", taskId: "task-1" }); await f.bridge.drain();
  expect(f.frames.filter((frame) => frame.type === "task-register-result").at(-1)).toMatchObject({ outcome: "accepted", controlGeneration: 0 });
  vi.spyOn(f.store, "save").mockRejectedValueOnce(new Error("disk unavailable"));
  f.send({ type: "task-register", task: f.task("other-task"), providerRevision: 1 }); await f.bridge.drain();
  expect(f.bridge.coverage().tracking).toBe("unsupported");
  f.send({ type: "registration-query", taskId: "task-1" }); await f.bridge.drain();
  expect(f.frames.filter((frame) => frame.type === "task-register-result").at(-1)).toMatchObject({ outcome: "rejected", controlGeneration: 0 });
});
