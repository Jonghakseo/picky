import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventEmitter } from "node:events";
import { awaitPickleSessionTerminal } from "../application/pickle-terminal-waiter.js";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { afterEach, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema, type AsyncTaskHostMessage, type AsyncCompletionDelivery } from "../domain/async-task-contract.js";
import { PickyAgentSessionSchema, type PickyAgentSession, type PickySessionProjectionMutation } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "./types.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); vi.unstubAllEnvs(); });
async function fixture(options: { onTool?: () => Promise<void>; failModel?: boolean } = {}) {
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
    createServices: (options) => createAgentSessionServices({ ...options, settingsManager: SettingsManager.inMemory({ packages: [], retry: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 100 } }) }),
    createSessionFromServices: async (options) => { const result = await createAgentSessionFromServices({ ...options, noTools: "builtin" }); session = result.session; return result; },
    resourceLoaderOptions: { noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi) => {
      api = pi;
      pi.registerCommand("fixture-no-turn", { description: "Offline command", handler: async () => {} });
      pi.registerTool({ name: "bash_async", label: "Finite fixture", description: "Finite fixture", parameters: Type.Object({}), async execute() { await options.onTool?.(); return { content: [{ type: "text", text: "fixture" }], details: {} }; } });
      pi.events.on(ASYNC_TASK_CONTRACT, (data) => { const frame = AsyncTaskHostMessageSchema.parse(data); frames.push(frame); if (frame.type === "host-state") host = frame; });
      pi.on("session_start", (_event, context) => {
        pi.events.emit(ASYNC_TASK_CONTRACT, { contract: ASYNC_TASK_CONTRACT, type: "host-query", requestId: "discover", sessionId: null, runtimeInstanceId: null, piSessionId: context.sessionManager.getSessionId(), providerId: "bash-async", providerInstanceId: "fixture-instance", providerRevision: 0, controlGeneration: 0 });
      });
      pi.registerProvider("w3-offline", { baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "w3-offline", models: [{ id: "finite", name: "Finite", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }], streamSimple(model, context) {
        requests.push(JSON.parse(JSON.stringify(context)));
        const stream = createAssistantMessageEventStream();
        const toolCall = options.onTool !== undefined && requests.length === 1;
        const message: AssistantMessage = { role: "assistant", content: toolCall ? [{ type: "toolCall", id: "fixture-tool", name: "bash_async", arguments: {} }] : [{ type: "text", text: "Finite reply" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: options.failModel ? "error" : toolCall ? "toolUse" : "stop", ...(options.failModel ? { errorMessage: "Finite model failure" } : {}), timestamp: Date.now() };
        stream.push({ type: "start", partial: message });
        if (options.failModel) stream.push({ type: "error", reason: "error", error: message });
        else stream.push({ type: "done", reason: toolCall ? "toolUse" : "stop", message });
        stream.end(); return stream;
      } });
    }] },
  });
  const prewarm = runtime.prewarm.bind(runtime);
  vi.spyOn(runtime, "prewarm").mockImplementation(async (options) => {
    handle = await prewarm(options);
    const created = handle; cleanups.push(async () => { await created.dispose?.(); });
    return handle;
  });
  const store = new SessionStore(join(root, "store"));
  const notifications: string[] = [];
  let sessionNumber = 0;
  const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => sessionNumber++ === 0 ? "session-sdk" : `session-other-${sessionNumber}`, enableAsyncTasksForSession: (id) => id === "session-sdk",
    forwardPickleCompletionToPrimary: async ({ completionId }) => { notifications.push(completionId); } });
  const events: RuntimeEvent[] = [];
  const projections: PickyAgentSession[] = [];
  const transactions: PickySessionProjectionMutation[][] = [];
  supervisor.on("sessionProjectionTransaction", (_id, _before, after, mutations) => {
    projections.push(structuredClone(after)); transactions.push(structuredClone([...mutations]));
  });
  const pending = new Set<Promise<void>>();
  const eventTarget = supervisor as unknown as { applyRuntimeEvent(id: string, event: RuntimeEvent): Promise<void> };
  const applyEvent = eventTarget.applyRuntimeEvent.bind(supervisor);
  vi.spyOn(eventTarget, "applyRuntimeEvent").mockImplementation((id, event) => {
    events.push(event);
    const work = applyEvent(id, event); pending.add(work);
    void work.finally(() => pending.delete(work)).catch(() => undefined);
    return work;
  });
  await supervisor.load();
  await supervisor.createEmptyPickleSession({ id: "ctx", source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] });
  cleanups.push(async () => {
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  });
  await vi.waitFor(() => expect(host?.supported).toBe(true));
  const fixtureApi = api;
  const fixtureHandle = handle;
  const owner = { sessionId: host.sessionId, piSessionId: host.piSessionId, runtimeInstanceId: host.runtimeInstanceId, providerId: host.providerId, providerInstanceId: host.providerInstanceId };
  const send = (data: object) => fixtureApi.events.emit(ASYNC_TASK_CONTRACT, { ...owner, contract: ASYNC_TASK_CONTRACT, requestId: "fixture-request", providerRevision: 0, controlGeneration: 0, ...data });
  send({ type: "provider-ready", providerVersion: "fixture", contractVersion: 1, snapshotReady: true, capabilities: { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true } });
  send({ type: "snapshot", watermark: 0, detail: { tasks: [], tickets: [] } });
  await vi.waitFor(() => expect(handle.asyncTasks?.coverage().tracking).toBe("ready"));
  async function completion(id: string, outcome: { execution: "succeeded" | "failed"; presence: "settled" | "active" | "unknown" } = { execution: "succeeded", presence: "settled" }) {
    const task = { ...owner, taskId: id, rootTaskId: id, kind: "bash", title: "Finite", execution: "queued", presence: "settled", registration: "reserved", providerRevision: 1, controlGeneration: 0, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    send({ type: "task-register", requestId: `register-${id}`, providerRevision: 1, task });
    await vi.waitFor(() => expect(frames.some((frame) => frame.type === "task-register-result" && frame.taskId === id && frame.outcome === "accepted")).toBe(true));
    const registered = fixtureHandle.asyncTasks!.snapshot().tasks.find((task) => task.taskId === id)!;
    const delivery: AsyncCompletionDelivery = { ...owner, deliveryId: `delivery-${id}`, completionIds: [`completion-${id}`], taskIds: [id], controlGeneration: 0 };
    send({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...registered, providerRevision: 2, ...outcome, registration: "spawned" }], tickets: [{ ...owner, completionId: `completion-${id}`, rootTaskId: id, target: "model", state: "submitted", deliveryId: delivery.deliveryId, controlGeneration: 0 }] } });
    await vi.waitFor(() => expect(fixtureHandle.asyncTasks!.snapshot().tickets.some((ticket) => ticket.completionId === `completion-${id}`)).toBe(true));
    return { role: "custom" as const, customType: "fixture-completion", content: `RESULT ${id}`, display: true, details: { asyncTasks: delivery }, timestamp: Date.now() };
  }
  async function drainEvents() {
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  }
  return { handle, session, supervisor, store, requests, completion, frames, api, send, events, projections, transactions, notifications,
    drainEvents, emitRuntime: (event: RuntimeEvent) => eventTarget.applyRuntimeEvent("session-sdk", event) };
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


it("reports settlement save failure without acknowledging or replaying the model, then retries only persistence", async () => {
  const f = await fixture();
  const message = await f.completion("save-failure");
  const save = f.store.save.bind(f.store);
  let failures = 0;
  const spy = vi.spyOn(f.store, "save").mockImplementation(async (state) => {
    if (state.completionTickets?.some((ticket) => ticket.state === "handled") && failures++ < 2) throw new Error("settlement disk unavailable");
    await save(state);
  });
  await f.session.sendCustomMessage(message, { triggerTurn: true });
  await f.session.waitForIdle();
  try {
    await vi.waitFor(() => expect(f.events.some((event) => event.type === "log" && event.line.includes("Async task persistence blocked"))).toBe(true));
    const assertBlocked = async () => {
      expect(f.requests).toHaveLength(1);
      expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("processing");
      expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("processing");
      expect(f.supervisor.get("session-sdk")?.completionTickets?.[0]?.state).toBe("processing");
      expect(f.frames.filter((frame) => frame.type === "completion-observed")).toEqual([]);
      expect(f.projections.some((state) => state.completionTickets?.some((ticket) => ticket.state === "handled"))).toBe(false);
    };
    await assertBlocked();
    await expect(f.handle.asyncTasks!.retryPersistence()).rejects.toThrow("settlement disk unavailable");
    await assertBlocked();
    await f.handle.followUp({ text: "Still blocked", imagePaths: [] });
    await f.session.waitForIdle();
    await assertBlocked();
    await f.handle.asyncTasks!.retryPersistence();
    expect(f.requests).toHaveLength(1);
    expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled");
    expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(1);
    await f.handle.asyncTasks!.retryPersistence();
    expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(1);
    await f.handle.followUp({ text: "Work after recovery", imagePaths: [] });
    await f.session.waitForIdle();
    expect(f.requests).toHaveLength(2);
  } finally { spy.mockRestore(); }
}, 15_000);


it("retains failed compaction bookkeeping for persistence-only recovery before a later model request", async () => {
  const f = await fixture();
  await f.handle.followUp({ text: "Seed compaction", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().cycle?.phase).toBe("settled"));
  f.api.on("session_before_compact", async (event) => ({ compaction: { summary: "Offline summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } }));
  const save = f.store.save.bind(f.store);
  let failed = false;
  const spy = vi.spyOn(f.store, "save").mockImplementation(async (state) => {
    if (!failed && state.agentCycle?.phase === "compacting") { failed = true; throw new Error("compaction disk unavailable"); }
    await save(state);
  });
  try {
    await f.session.compact();
    await vi.waitFor(() => expect(f.events.some((event) => event.type === "log" && event.line.includes("compaction disk unavailable"))).toBe(true));
    expect(f.requests).toHaveLength(1);
    expect((await f.store.loadReadOnly("session-sdk"))?.agentCycle?.phase).toBe("settled");
    expect(f.handle.asyncTasks!.snapshot().cycle?.phase).toBe("settled");
    expect(f.projections.some((state) => state.agentCycle?.phase === "compacting")).toBe(false);
    await f.handle.followUp({ text: "Blocked by bookkeeping", imagePaths: [] });
    await f.session.waitForIdle();
    expect(f.requests).toHaveLength(1);
    await f.handle.asyncTasks!.retryPersistence();
    expect((await f.store.loadReadOnly("session-sdk"))?.agentCycle?.phase).toBe("idle");
    expect(f.requests).toHaveLength(1);
    await f.handle.followUp({ text: "Continue after bookkeeping", imagePaths: [] });
    await f.session.waitForIdle();
    expect(f.requests).toHaveLength(2);
  } finally { spy.mockRestore(); }
}, 15_000);

it("keeps a zero-execution ticket gap running, finalizes each cycle, and notifies once per work episode", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  const result = await f.completion("gap");
  const waiterReplies: PickyAgentSession[] = [];
  awaitPickleSessionTerminal(f.supervisor, new EventEmitter(), "session-sdk", (session) => waiterReplies.push(session));
  await f.handle.followUp({ text: "Start while result delivery is pending", imagePaths: [] });
  await f.session.waitForIdle();
  await f.drainEvents();
  const first = PickyAgentSessionSchema.parse(await f.store.loadReadOnly("session-sdk"));
  expect(first).toMatchObject({ status: "running", asyncWorkSummary: { activeRootCount: 0, pendingCompletionCount: 1, canReleaseRuntime: false, episode: { settled: false } } });
  expect(first.messages?.filter((message) => message.kind === "agent_text")).toHaveLength(1);
  expect(f.notifications).toEqual([]);
  expect(waiterReplies).toEqual([]);
  const episodeId = first.asyncWorkSummary?.episode?.id;
  await f.supervisor.followUp("session-sdk", "/fixture-no-turn");
  await vi.waitFor(() => expect(f.events.some((event) => event.type === "status" && event.noTurnRan)).toBe(true));
  await f.drainEvents();
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary?.episode?.id).toBe(episodeId);
  expect(f.requests).toHaveLength(1);
  expect(f.notifications).toEqual([]);
  await f.session.sendCustomMessage(result, { triggerTurn: true });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.status).toBe("completed"));
  await f.drainEvents();
  const completed = await f.store.loadReadOnly("session-sdk");
  expect(completed).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: true, episode: { id: episodeId, settled: true } } });
  expect(completed?.messages?.filter((message) => message.kind === "agent_text")).toHaveLength(2);
  expect(waiterReplies).toHaveLength(1);
  expect(waiterReplies[0]?.asyncWorkSummary?.episode?.settled).toBe(true);
  expect(f.notifications).toHaveLength(1);
  expect(f.projections.filter((session) => session.status === "completed").every((session) => session.completionTickets?.every((ticket) => ticket.state === "handled"))).toBe(true);
  const terminal = f.events.filter((event) => event.type === "status" && event.status === "completed" && event.cycleId).at(-1)!;
  await f.emitRuntime(terminal);
  expect((await f.store.loadReadOnly("session-sdk"))?.messages).toEqual(completed?.messages);
  expect(f.notifications).toHaveLength(1);
  await f.supervisor.followUp("session-sdk", "A new episode");
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.notifications).toHaveLength(2));
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary?.episode?.id).not.toBe(episodeId);
}, 15_000);

it("settles from a late resource exit atomically without replaying the last response", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  const result = await f.completion("resource", { execution: "failed", presence: "unknown" });
  let task = f.handle.asyncTasks!.snapshot().tasks[0]!;
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.status).toBe("blocked"));
  await f.session.sendCustomMessage(result, { triggerTurn: true });
  await f.session.waitForIdle();
  await f.drainEvents();
  const blocked = await f.store.loadReadOnly("session-sdk");
  expect(blocked).toMatchObject({ status: "blocked", asyncWorkSummary: { uncertainExecutionCount: 1, pendingCompletionCount: 0 } });
  expect(f.notifications).toEqual([]);
  task = f.handle.asyncTasks!.snapshot().tasks[0]!;
  const start = f.transactions.length;
  f.send({ type: "task-update", providerRevision: 4, detail: { tasks: [{ ...task, providerRevision: 4, presence: "settled" }], tickets: [] } });
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")).toMatchObject({ status: "completed", asyncWorkSummary: { episode: { settled: true } } }));
  expect(f.notifications).toHaveLength(1);
  const completed = await f.store.loadReadOnly("session-sdk");
  expect(completed).toMatchObject({ status: "completed", lastSummary: "Finite reply", asyncWorkSummary: { uncertainExecutionCount: 0, canReleaseRuntime: true } });
  expect(completed?.messages).toEqual(blocked?.messages);
  expect(f.transactions.slice(start).some((mutations) => mutations.some((mutation) => mutation.type === "asyncTaskDetailSet") && mutations.some((mutation) => mutation.type === "metaPatch" && mutation.patch.status === "completed"))).toBe(true);
}, 15_000);

it("keeps progress-only task updates out of scalar projection and workRevision", async () => {
  const f = await fixture();
  await f.completion("progress");
  await f.drainEvents();
  const before = await f.store.loadReadOnly("session-sdk");
  const start = f.transactions.length;
  const task = f.handle.asyncTasks!.snapshot().tasks[0]!;
  f.send({ type: "task-update", providerRevision: 3, detail: { tasks: [{ ...task, providerRevision: 3, progress: "new output", updatedAt: new Date().toISOString() }], tickets: f.handle.asyncTasks!.snapshot().tickets } });
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.asyncTasks?.[0]?.progress).toBe("new output"));
  await f.drainEvents();
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary?.workRevision).toBe(before?.asyncWorkSummary?.workRevision);
  expect(f.transactions.slice(start).flat().some((mutation) => mutation.type === "metaPatch")).toBe(false);
}, 15_000);

it("never publishes completed between actual SDK deferred result cycles", async () => {
  const f = await fixture();
  const result = await f.completion("deferred-aggregate");
  let once = false;
  f.api.on("agent_settled", () => {
    if (once) return;
    once = true;
    f.api.sendMessage(result, { triggerTurn: true, deliverAs: "followUp" });
  });
  await f.handle.followUp({ text: "Start deferred work", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.status).toBe("completed"));
  await f.drainEvents();
  expect(f.requests).toHaveLength(2);
  expect(f.projections.filter((state) => state.status === "completed").every((state) => state.completionTickets?.[0]?.state === "handled" && state.asyncWorkSummary?.episode?.finalizedCycleId === state.agentCycle?.cycleId)).toBe(true);
  expect((await f.store.loadReadOnly("session-sdk"))?.messages?.filter((message) => message.kind === "agent_text")).toHaveLength(2);
}, 15_000);

it("retains a failed response commit for persistence-only recovery without model replay", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  const save = f.store.save.bind(f.store);
  const spy = vi.spyOn(f.store, "save").mockImplementation(async (state) => {
    if (state.asyncWorkSummary?.episode?.finalizedCycleId) throw new Error("response disk unavailable");
    await save(state);
  });
  await f.handle.followUp({ text: "Persist this response", imagePaths: [] });
  await f.session.waitForIdle();
  await f.drainEvents();
  const failed = await f.store.loadReadOnly("session-sdk");
  expect(failed?.asyncWorkSummary?.episode?.finalizedCycleId).toBeUndefined();
  expect(failed?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  expect(failed?.messages?.filter((message) => message.kind === "agent_text")).toEqual([]);
  expect(f.notifications).toEqual([]);
  expect(f.projections.some((state) => state.asyncWorkSummary?.episode?.settled)).toBe(false);
  await f.emitRuntime({ type: "status", status: "completed", cycleId: "stale-cycle", finalAnswer: "Wrong response" });
  await expect(f.supervisor.followUp("session-sdk", "Must not discard the response")).rejects.toThrow("retryAsyncWorkPersistence");
  spy.mockRestore();
  await f.supervisor.retryAsyncWorkPersistence("session-sdk");
  const recovered = await f.store.loadReadOnly("session-sdk");
  expect(recovered).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: true, episode: { settled: true, finalizedCycleId: recovered?.agentCycle?.cycleId } } });
  expect(recovered?.messages?.filter((message) => message.kind === "agent_text").map((message) => message.text)).toEqual(["Finite reply"]);
  expect(f.notifications).toHaveLength(1);
  expect(f.requests).toHaveLength(1);
  await f.supervisor.retryAsyncWorkPersistence("session-sdk");
  expect((await f.store.loadReadOnly("session-sdk"))?.messages).toEqual(recovered?.messages);
  expect(f.notifications).toHaveLength(1);
}, 15_000);

it("preserves an owned question through response finalization and settles only on its cancellation", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  const result = await f.completion("question");
  await f.emitRuntime({ type: "extension_ui", waitsForInput: true, request: { id: "owned-question", sessionId: "session-sdk", createdAt: new Date().toISOString(), method: "select", title: "Choose", options: ["Continue"] } });
  await f.session.sendCustomMessage(result, { triggerTurn: true });
  await f.session.waitForIdle();
  await f.drainEvents();
  const waiting = await f.store.loadReadOnly("session-sdk");
  expect(waiting).toMatchObject({ status: "waiting_for_input", pendingExtensionUiRequest: { id: "owned-question" }, asyncWorkSummary: { canReleaseRuntime: false } });
  expect(waiting?.messages?.find((message) => message.id === "owned-question")?.cancelledAt).toBeUndefined();
  expect(waiting?.messages?.filter((message) => message.kind === "agent_text")).toHaveLength(1);
  expect(f.notifications).toEqual([]);
  await f.emitRuntime({ type: "extension_ui_cancelled", requestId: "another-question" });
  expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("waiting_for_input");
  await f.emitRuntime({ type: "extension_ui_cancelled", requestId: "owned-question" });
  expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed");
  expect(f.notifications).toHaveLength(1);
}, 15_000);

it("keeps queued runtime work pending after the response and settles on queue clear without replay", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  const result = await f.completion("queue");
  let queued = ["Pending user input"];
  const queue = vi.spyOn(f.handle, "getFollowUpMessages").mockImplementation(() => queued);
  try {
    await f.emitRuntime({ type: "queue_update", steering: [], followUp: queued });
    await f.session.sendCustomMessage(result, { triggerTurn: true });
    await f.session.waitForIdle();
    await f.drainEvents();
    const pending = await f.store.loadReadOnly("session-sdk");
    expect(pending).toMatchObject({ status: "running", asyncWorkSummary: { pendingCompletionCount: 0, canReleaseRuntime: false } });
    expect(f.notifications).toEqual([]);
    queued = [];
    await f.supervisor.clearQueue("session-sdk", "all");
    const completed = await f.store.loadReadOnly("session-sdk");
    expect(completed?.status).toBe("completed");
    expect(completed?.messages).toEqual(pending?.messages);
    expect(f.notifications).toHaveLength(1);
  } finally { queue.mockRestore(); }
}, 15_000);

it("does not settle during actual SDK input preflight even after another result cycle ends", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  const result = await f.completion("preflight");
  let entered = false;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  f.api.on("input", async (event) => {
    if (event.text.includes("held-user-input")) { entered = true; await gate; }
    return { action: "continue" };
  });
  const input = f.supervisor.followUp("session-sdk", "held-user-input");
  try {
    await vi.waitFor(() => expect(entered).toBe(true));
    await f.session.sendCustomMessage(result, { triggerTurn: true });
    await f.drainEvents();
    const waiting = await f.store.loadReadOnly("session-sdk");
    expect(waiting?.status).toBe("running");
    expect(waiting?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
    expect(f.notifications).toEqual([]);
  } finally { release(); await input; }
  await vi.waitFor(() => expect(f.requests).toHaveLength(2));
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.status).toBe("completed"));
  await f.session.waitForIdle();
  await f.drainEvents();
  expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed");
  expect(f.notifications).toHaveLength(1);
  expect(f.requests).toHaveLength(2);
}, 15_000);

it("isolates unsupported coverage from the main agent and an untracked Pickle", async () => {
  const f = await fixture();
  await f.handle.followUp({ text: "Tracked work", imagePaths: [] });
  await f.session.waitForIdle();
  await f.drainEvents();
  const other = await f.supervisor.createEmptyPickleSession({ id: "other-context", source: "text", capturedAt: new Date().toISOString(), cwd: f.supervisor.get("session-sdk")!.cwd, screenshots: [], inkMarks: [], warnings: [] });
  await f.supervisor.prewarmMainAgent(other.cwd);
  await f.drainEvents();
  const otherBefore = await f.store.loadReadOnly(other.id);
  const mainBefore = structuredClone(f.supervisor.listMainMessages());
  const previous = f.handle.asyncTasks!.coverage();
  const coverage = { ...previous, tracking: "unsupported" as const };
  const spy = vi.spyOn(f.handle.asyncTasks!, "coverage").mockReturnValue(coverage);
  try {
    await f.emitRuntime({ type: "async_task_coverage", coverage });
    expect((await f.store.loadReadOnly("session-sdk"))).toMatchObject({ status: "blocked", asyncWorkSummary: { tracking: "unsupported", canReleaseRuntime: false, attentionCount: 1 } });
    expect(await f.store.loadReadOnly(other.id)).toEqual(otherBefore);
    expect(otherBefore?.asyncWorkSummary).toBeUndefined();
    expect(f.supervisor.listMainMessages()).toEqual(mainBefore);
  } finally { spy.mockRestore(); }
}, 15_000);

it("keeps fast completion pending before the real SDK tool result and consumes it on the continuation", async () => {
  let registered = false;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  let f!: Awaited<ReturnType<typeof fixture>>;
  f = await fixture({ onTool: async () => {
    const result = await f.completion("fast");
    registered = true;
    await gate;
    f.api.sendMessage(result, { triggerTurn: true, deliverAs: "followUp" });
  } });
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  await f.handle.followUp({ text: "Run the finite tool", imagePaths: [] });
  try {
    await vi.waitFor(() => expect(registered).toBe(true));
    const beforeResult = await f.store.loadReadOnly("session-sdk");
    expect(beforeResult).toMatchObject({ status: "running", asyncWorkSummary: { activeRootCount: 0, pendingCompletionCount: 1, canReleaseRuntime: false } });
    expect(beforeResult?.tools.some((tool) => tool.status === "running")).toBe(true);
    expect(f.notifications).toEqual([]);
  } finally { release(); }
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.status).toBe("completed"));
  await f.drainEvents();
  const completed = await f.store.loadReadOnly("session-sdk");
  expect(completed?.completionTickets?.[0]?.state).toBe("handled");
  expect(completed?.tools.every((tool) => tool.status === "succeeded")).toBe(true);
  expect(completed?.messages?.filter((message) => message.kind === "agent_text")).toHaveLength(1);
  expect(f.notifications).toHaveLength(1);
  expect(JSON.stringify(f.requests.at(-1))).toContain("RESULT fast");
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(1);
}, 15_000);

it("settles standalone SDK compaction without inventing a response cycle or notifying again", async () => {
  const f = await fixture();
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  await f.handle.followUp({ text: "Seed standalone compaction", imagePaths: [] });
  await f.session.waitForIdle();
  await f.drainEvents();
  const before = await f.store.loadReadOnly("session-sdk");
  f.api.on("session_before_compact", async (event) => ({ compaction: { summary: "Offline summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } }));
  await f.session.compact();
  await f.drainEvents();
  const after = await f.store.loadReadOnly("session-sdk");
  expect(after).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: true, episode: before?.asyncWorkSummary?.episode } });
  expect(after?.agentCycle?.cycleId).toBe(before?.agentCycle?.cycleId);
  expect(f.requests).toHaveLength(1);
  expect(f.notifications).toHaveLength(1);
}, 15_000);

it("finalizes a real failed SDK response but keeps its surviving work blocked", async () => {
  const f = await fixture({ failModel: true });
  await f.supervisor.setNotifyMainOnCompletion("session-sdk", true);
  await f.completion("surviving-resource", { execution: "failed", presence: "active" });
  await f.handle.followUp({ text: "Finite failed response", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.asyncWorkSummary?.episode?.outcome).toBe("failed"));
  await f.drainEvents();
  expect(await f.store.loadReadOnly("session-sdk")).toMatchObject({ status: "blocked", lastSummary: "Agent failed with unfinished work", asyncWorkSummary: { activeRootCount: 1, pendingCompletionCount: 1, canReleaseRuntime: false, episode: { settled: false } } });
  expect(f.notifications).toEqual([]);
  expect(f.requests).toHaveLength(1);
}, 15_000);
