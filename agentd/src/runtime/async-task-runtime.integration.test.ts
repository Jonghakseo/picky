import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { afterEach, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema, type AsyncTaskHostMessage, type AsyncCompletionDelivery } from "../domain/async-task-contract.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "./types.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); vi.unstubAllEnvs(); });
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "picky-w3-sdk-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "home/.pi/agent"); await mkdir(agentDir, { recursive: true });
  vi.stubEnv("HOME", join(root, "home")); vi.stubEnv("PI_CODING_AGENT_DIR", agentDir); vi.stubEnv("PI_OFFLINE", "1");
  let api!: ExtensionAPI;
  let session!: AgentSession;
  let handle!: RuntimeSessionHandle;
  let host!: Extract<AsyncTaskHostMessage, { type: "host-state" }>;
  const requests: unknown[] = [];
  const frames: AsyncTaskHostMessage[] = [];
  const runtime = new PiSdkRuntime({ agentDir, modelPattern: "w3-offline/finite",
    createServices: (options) => createAgentSessionServices({ ...options, settingsManager: SettingsManager.inMemory({ packages: [], compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 100 } }) }),
    createSessionFromServices: async (options) => { const result = await createAgentSessionFromServices({ ...options, noTools: "builtin" }); session = result.session; return result; },
    resourceLoaderOptions: { noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi) => {
      api = pi;
      pi.registerTool({ name: "bash_async", label: "Finite fixture", description: "Finite fixture", parameters: Type.Object({}), async execute() { return { content: [{ type: "text", text: "fixture" }], details: {} }; } });
      pi.events.on(ASYNC_TASK_CONTRACT, (data) => { const frame = AsyncTaskHostMessageSchema.parse(data); frames.push(frame); if (frame.type === "host-state") host = frame; });
      pi.on("session_start", (_event, context) => {
        pi.events.emit(ASYNC_TASK_CONTRACT, { contract: ASYNC_TASK_CONTRACT, type: "host-query", requestId: "discover", sessionId: null, runtimeInstanceId: null, piSessionId: context.sessionManager.getSessionId(), providerId: "bash-async", providerInstanceId: "fixture-instance", providerRevision: 0, controlGeneration: 0 });
      });
      pi.registerProvider("w3-offline", { baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "w3-offline", models: [{ id: "finite", name: "Finite", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }], streamSimple(model, context) {
        requests.push(JSON.parse(JSON.stringify(context)));
        const stream = createAssistantMessageEventStream();
        const message: AssistantMessage = { role: "assistant", content: [{ type: "text", text: "Finite reply" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() };
        stream.push({ type: "start", partial: message }); stream.push({ type: "done", reason: "stop", message }); stream.end(); return stream;
      } });
    }] },
  });
  const prewarm = runtime.prewarm.bind(runtime);
  vi.spyOn(runtime, "prewarm").mockImplementation(async (options) => { handle = await prewarm(options); return handle; });
  const store = new SessionStore(join(root, "store"));
  const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => "session-sdk", enableAsyncTasksForSession: () => true });
  const pending = new Set<Promise<void>>();
  const eventTarget = supervisor as unknown as { applyRuntimeEvent(id: string, event: RuntimeEvent): Promise<void> };
  const applyEvent = eventTarget.applyRuntimeEvent.bind(supervisor);
  vi.spyOn(eventTarget, "applyRuntimeEvent").mockImplementation((id, event) => {
    const work = applyEvent(id, event); pending.add(work);
    void work.finally(() => pending.delete(work)).catch(() => undefined);
    return work;
  });
  await supervisor.load();
  await supervisor.createEmptyPickleSession({ id: "ctx", source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] });
  cleanups.push(async () => {
    await handle.dispose?.();
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  });
  await vi.waitFor(() => expect(host?.supported).toBe(true));
  const owner = { sessionId: host.sessionId, piSessionId: host.piSessionId, runtimeInstanceId: host.runtimeInstanceId, providerId: host.providerId, providerInstanceId: host.providerInstanceId };
  const send = (data: object) => api.events.emit(ASYNC_TASK_CONTRACT, { ...owner, contract: ASYNC_TASK_CONTRACT, requestId: "fixture-request", providerRevision: 0, controlGeneration: 0, ...data });
  send({ type: "provider-ready", providerVersion: "fixture", contractVersion: 1, snapshotReady: true, capabilities: { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true } });
  send({ type: "snapshot", watermark: 0, detail: { tasks: [], tickets: [] } });
  await vi.waitFor(() => expect(handle.asyncTasks?.coverage().tracking).toBe("ready"));
  async function completion(id: string) {
    const task = { ...owner, taskId: id, rootTaskId: id, kind: "bash", title: "Finite", execution: "queued", presence: "settled", registration: "reserved", providerRevision: 1, controlGeneration: 0, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    send({ type: "task-register", requestId: `register-${id}`, providerRevision: 1, task });
    await vi.waitFor(() => expect(frames.some((frame) => frame.type === "task-register-result" && frame.taskId === id && frame.outcome === "accepted")).toBe(true));
    const registered = handle.asyncTasks!.snapshot().tasks.find((task) => task.taskId === id)!;
    const delivery: AsyncCompletionDelivery = { ...owner, deliveryId: `delivery-${id}`, completionIds: [`completion-${id}`], taskIds: [id], controlGeneration: 0 };
    send({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...registered, providerRevision: 2, execution: "succeeded", presence: "settled", registration: "spawned" }], tickets: [{ ...owner, completionId: `completion-${id}`, rootTaskId: id, target: "model", state: "submitted", deliveryId: delivery.deliveryId, controlGeneration: 0 }] } });
    await vi.waitFor(() => expect(handle.asyncTasks!.snapshot().tickets.some((ticket) => ticket.completionId === `completion-${id}`)).toBe(true));
    return { role: "custom" as const, customType: "fixture-completion", content: `RESULT ${id}`, display: true, details: { asyncTasks: delivery }, timestamp: Date.now() };
  }
  return { handle, session, supervisor, store, requests, completion, frames, api, send };
}

it("correlates real PiSdkRuntime context with persisted model consumption, not passive append", async () => {
  const f = await fixture();
  const message = await f.completion("one");
  await f.session.sendCustomMessage(message, { triggerTurn: false });
  expect(f.requests).toEqual([]);
  expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("submitted");
  await f.handle.followUp({ text: "Process result", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("handled"));
  expect(f.requests).toHaveLength(1);
  expect(JSON.stringify(f.requests)).toContain("RESULT one");
  expect(JSON.stringify(f.requests)).not.toContain("delivery-one");
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]).toMatchObject({ state: "handled", cycleId: expect.any(String) });
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(1);
}, 15_000);

it("fences an old completion after close and reopen, then admits a later authorized prompt", async () => {
  const f = await fixture();
  const message = await f.completion("stale");
  await f.handle.asyncTasks!.closeAdmission();
  await f.handle.asyncTasks!.reopenAdmission();
  await f.session.sendCustomMessage(message, { triggerTurn: true, deliverAs: "followUp" });
  await f.session.waitForIdle();
  expect(f.requests).toEqual([]);
  expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).not.toBe("handled");
  await f.handle.followUp({ text: "New authorized work", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
  expect(JSON.stringify(f.requests)).not.toContain("RESULT stale");
}, 15_000);


it("does not consume a result on a concurrent compacted branch and can process its retained payload afterwards", async () => {
  const f = await fixture();
  await f.handle.followUp({ text: "Seed transcript", imagePaths: [] });
  await f.session.waitForIdle();
  const message = await f.completion("compacting");
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>((resolve) => { enter = resolve; });
  const held = new Promise<void>((resolve) => { release = resolve; });
  f.api.on("session_before_compact", async (event) => {
    enter(); await held;
    return { compaction: { summary: "Offline summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
  });
  const compact = f.session.compact();
  await Promise.race([entered, compact.then(() => { throw new Error("Compaction bypassed the test hold"); })]);
  try {
    await f.session.sendCustomMessage(message, { triggerTurn: true });
    expect(f.requests).toHaveLength(1);
    expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("submitted");
  } finally { release(); await compact; }
  await f.session.waitForIdle();
  await f.session.sendCustomMessage(message, { triggerTurn: true });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("handled"));
  expect(f.requests).toHaveLength(2);
  expect(JSON.stringify(f.requests.at(-1))).toContain("RESULT compacting");
}, 15_000);

it("persists late task exit despite the old-turn abort guard and ignores a replayed pending ticket after handling", async () => {
  const f = await fixture();
  const message = await f.completion("late");
  await f.handle.abort();
  const task = f.handle.asyncTasks!.snapshot().tasks[0]!;
  f.send({ type: "task-update", providerRevision: 3, detail: { tasks: [{ ...task, providerRevision: 3, progress: "exit observed after parent abort" }], tickets: f.handle.asyncTasks!.snapshot().tickets } });
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tasks[0]?.progress).toBe("exit observed after parent abort"));
  await f.session.sendCustomMessage(message, { triggerTurn: true });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("handled"));
  f.send({ type: "snapshot", providerRevision: 3, watermark: 3, detail: { tasks: f.handle.asyncTasks!.snapshot().tasks, tickets: f.handle.asyncTasks!.snapshot().tickets.map((ticket) => ({ ...ticket, state: "pending" })) } });
  await f.handle.asyncTasks!.closeAdmission();
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled");
}, 15_000);


it("consumes two result batches in one actual request exactly once", async () => {
  const f = await fixture();
  const first = await f.completion("batch-a"), second = await f.completion("batch-b");
  await f.session.sendCustomMessage(first, { triggerTurn: false });
  await f.session.sendCustomMessage(second, { triggerTurn: false });
  await f.handle.followUp({ text: "Process both results", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tickets.map((ticket) => ticket.state)).toEqual(["handled", "handled"]));
  const cycles = f.handle.asyncTasks!.snapshot().tickets.map((ticket) => ticket.cycleId);
  expect(new Set(cycles).size).toBe(1);
  expect(f.requests).toHaveLength(1);
  await f.session.sendCustomMessage(first, { triggerTurn: true });
  await f.session.waitForIdle();
  expect(f.handle.asyncTasks!.snapshot().tickets.map((ticket) => ticket.cycleId)).toEqual(cycles);
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(2);
}, 15_000);

it("closes the provider dispatch fence synchronously while a processing save is still pending", async () => {
  const f = await fixture();
  const message = await f.completion("save-race");
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>((resolve) => { enter = resolve; });
  const held = new Promise<void>((resolve) => { release = resolve; });
  const save = f.store.save.bind(f.store);
  let delayed = false;
  vi.spyOn(f.store, "save").mockImplementation(async (state) => {
    if (!delayed && state.completionTickets?.some((ticket) => ticket.state === "processing")) { delayed = true; enter(); await held; }
    await save(state);
  });
  const delivery = f.session.sendCustomMessage(message, { triggerTurn: true });
  await entered;
  const closed = f.handle.asyncTasks!.closeAdmission();
  release();
  await Promise.all([closed, delivery]);
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("pending"));
  expect(f.requests).toEqual([]);
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toEqual([]);
}, 15_000);


it("rejects SDK deferred agent_settled delivery even when clearQueue and abort do not remove it", async () => {
  const f = await fixture();
  const message = await f.completion("deferred");
  let once = false;
  let stop: Promise<void> | undefined;
  let closed: Promise<unknown> | undefined;
  f.api.on("agent_settled", () => {
    if (once) return;
    once = true;
    f.api.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
    closed = f.handle.asyncTasks!.closeAdmission();
    f.session.clearQueue();
    stop = f.session.abort();
  });
  await f.handle.followUp({ text: "Initial work before deferred completion", imagePaths: [] });
  await f.session.waitForIdle();
  await Promise.all([stop, closed]);
  expect(once).toBe(true);
  expect(f.requests).toHaveLength(1);
  expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("submitted");
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toEqual([]);
}, 15_000);


it("renegotiates a fresh runtime identity after a real SDK resource reload", async () => {
  const f = await fixture();
  const previous = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  await f.handle.followUp({ text: "/reload", imagePaths: [] });
  await vi.waitFor(() => expect(f.handle.asyncTasks!.coverage().runtimeInstanceId).not.toBe(previous));
  const current = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  await vi.waitFor(() => expect(f.frames.some((frame) => frame.type === "host-state" && frame.runtimeInstanceId === current && frame.supported)).toBe(true));
  expect(f.handle.asyncTasks!.coverage().tracking).toBe("reconciling");
  await f.handle.followUp({ text: "Authorized work after reload", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
}, 15_000);
