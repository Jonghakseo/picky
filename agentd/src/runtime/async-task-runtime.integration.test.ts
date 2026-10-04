import { appendFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventEmitter, once } from "node:events";
import WebSocket from "ws";
import { AgentdServer } from "../server.js";
import { awaitPickleSessionTerminal } from "../application/pickle-terminal-waiter.js";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { afterEach, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema, type AsyncTaskHostMessage, type AsyncCompletionDelivery } from "../domain/async-task-contract.js";
import { PROTOCOL_VERSION, PickyAgentSessionSchema, type EventEnvelope, type PickyAgentSession, type PickySessionProjectionMutation } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "./types.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); vi.unstubAllEnvs(); });
async function fixture(options: { onTool?: () => Promise<void>; failModel?: boolean; readyOnDiscovery?: boolean; deferReady?: boolean; holdCloseAck?: boolean; captureSaved?: boolean; acceptCancel?: boolean } = {}) {
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
  let acknowledgeClose!: () => void;
  const closeAcknowledged = new Promise<void>((resolve) => { acknowledgeClose = resolve; });
  const runtime = new PiSdkRuntime({ agentDir, modelPattern: "w3-offline/finite",
    createServices: (options) => createAgentSessionServices({ ...options, settingsManager: SettingsManager.inMemory({ packages: [], retry: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 100 } }) }),
    createSessionFromServices: async (options) => { const result = await createAgentSessionFromServices({ ...options, noTools: "builtin" }); session = result.session; return result; },
    resourceLoaderOptions: { noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi) => {
      api = pi;
      pi.registerCommand("fixture-no-turn", { description: "Offline command", handler: async () => {} });
      pi.registerTool({ name: "bash_async", label: "Finite fixture", description: "Finite fixture", parameters: Type.Object({}), async execute() { await options.onTool?.(); return { content: [{ type: "text", text: "fixture" }], details: {} }; } });
      pi.events.on(ASYNC_TASK_CONTRACT, (data) => {
        const frame = AsyncTaskHostMessageSchema.parse(data);
        frames.push(frame);
        const envelope = { contract: frame.contract, sessionId: frame.sessionId, piSessionId: frame.piSessionId, runtimeInstanceId: frame.runtimeInstanceId, providerId: frame.providerId, providerInstanceId: frame.providerInstanceId, requestId: frame.requestId, providerRevision: frame.providerRevision, controlGeneration: frame.controlGeneration };
        if (frame.type === "host-state") {
          host = frame;
          if (options.readyOnDiscovery && frame.supported) pi.events.emit(ASYNC_TASK_CONTRACT, { ...envelope, type: "provider-ready", providerVersion: "fixture", contractVersion: 1, snapshotReady: true, capabilities: { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true } });
        }
        if (options.readyOnDiscovery && frame.type === "snapshot-request") pi.events.emit(ASYNC_TASK_CONTRACT, { ...envelope, type: "snapshot", watermark: frame.providerRevision, detail: { tasks: [], tickets: [] } });
        if (options.readyOnDiscovery && frame.type === "control-request" && frame.action === "cancel" && options.acceptCancel) {
          pi.events.emit(ASYNC_TASK_CONTRACT, { ...envelope, type: "control-result", outcome: "accepted", admissionClosed: true, submittedDeliveryIds: [] });
        }
        if (options.readyOnDiscovery && frame.type === "control-request" && frame.action === "closeAdmission") {
          const ack = () => pi.events.emit(ASYNC_TASK_CONTRACT, { ...envelope, type: "control-result", outcome: "settled", admissionClosed: true, submittedDeliveryIds: [] });
          if (options.holdCloseAck) void closeAcknowledged.then(ack); else ack();
        }
      });
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
  const resume = runtime.resume.bind(runtime);
  vi.spyOn(runtime, "resume").mockImplementation(async (path, options) => {
    handle = await resume(path, options);
    const created = handle; cleanups.push(async () => { await created.dispose?.(); });
    return handle;
  });
  const store = new SessionStore(join(root, "store"));
  const saved: PickyAgentSession[] = [];
  const save = store.save.bind(store);
  if (options.captureSaved) vi.spyOn(store, "save").mockImplementation(async (state) => {
    await save(state);
    saved.push(PickyAgentSessionSchema.parse(await store.loadReadOnly(state.id)));
  });
  const notifications: string[] = [];
  let sessionNumber = 0;
  const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => sessionNumber++ === 0 ? "session-sdk" : `session-other-${sessionNumber}`, enableAsyncTasksForSession: (id) => id === "session-sdk",
    forwardPickleCompletionToPrimary: async ({ completionId }) => { notifications.push(completionId); } });
  const events: RuntimeEvent[] = [];
  const projections: PickyAgentSession[] = [];
  const snapshots: PickyAgentSession[] = [];
  const transactions: PickySessionProjectionMutation[][] = [];
  supervisor.on("sessionProjectionSnapshot", (state) => snapshots.push(structuredClone(state)));
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
  const owner = { sessionId: host.sessionId, piSessionId: host.piSessionId, runtimeInstanceId: host.runtimeInstanceId, providerId: host.providerId, providerInstanceId: host.providerInstanceId };
  const send = (data: object) => fixtureApi.events.emit(ASYNC_TASK_CONTRACT, { ...owner, contract: ASYNC_TASK_CONTRACT, requestId: "fixture-request", providerRevision: 0, controlGeneration: 0, ...data });
  const ready = async () => {
    send({ type: "provider-ready", providerVersion: "fixture", contractVersion: 1, snapshotReady: true, capabilities: { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true } });
    send({ type: "snapshot", watermark: 0, detail: { tasks: [], tickets: [] } });
    await vi.waitFor(() => expect(handle.asyncTasks?.coverage().tracking).toBe("ready"));
    await drainEvents();
  };
  if (!options.readyOnDiscovery && !options.deferReady) await ready();
  if (options.readyOnDiscovery) await vi.waitFor(() => expect(handle.asyncTasks?.coverage().tracking).toBe("ready"));
  async function completion(id: string, outcome: { execution: "succeeded" | "failed" | "running"; presence: "settled" | "active" | "unknown" } = { execution: "succeeded", presence: "settled" }) {
    const activeOwner = { sessionId: host.sessionId, piSessionId: host.piSessionId, runtimeInstanceId: host.runtimeInstanceId, providerId: host.providerId, providerInstanceId: host.providerInstanceId };
    const generation = handle.asyncTasks!.snapshot().control?.controlGeneration ?? 0;
    const sendCurrent = (data: object) => api.events.emit(ASYNC_TASK_CONTRACT, { ...activeOwner, contract: ASYNC_TASK_CONTRACT, requestId: "fixture-request", providerRevision: 0, controlGeneration: generation, ...data });
    const task = { ...activeOwner, taskId: id, rootTaskId: id, kind: "bash", title: "Finite", execution: "queued", presence: "settled", registration: "reserved", providerRevision: 1, controlGeneration: generation, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    sendCurrent({ type: "task-register", requestId: `register-${id}`, providerRevision: 1, task });
    await vi.waitFor(() => expect(frames.some((frame) => frame.type === "task-register-result" && frame.taskId === id && frame.outcome === "accepted")).toBe(true));
    const registered = handle.asyncTasks!.snapshot().tasks.find((entry) => entry.taskId === id)!;
    const delivery: AsyncCompletionDelivery = { ...activeOwner, deliveryId: `delivery-${id}`, completionIds: [`completion-${id}`], taskIds: [id], controlGeneration: generation };
    sendCurrent({ type: "task-update", providerRevision: 2, detail: { tasks: [{ ...registered, providerRevision: 2, ...outcome, registration: "spawned" }], tickets: [{ ...activeOwner, completionId: `completion-${id}`, rootTaskId: id, target: "model", state: "submitted", deliveryId: delivery.deliveryId, controlGeneration: generation }] } });
    await vi.waitFor(() => expect(handle.asyncTasks!.snapshot().tickets.some((ticket) => ticket.completionId === `completion-${id}`)).toBe(true));
    return { role: "custom" as const, customType: "fixture-completion", content: `RESULT ${id}`, display: true, details: { asyncTasks: delivery }, timestamp: Date.now() };
  }
  async function drainEvents() {
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  }
  return { root, runtime, handle, session, currentHandle: () => handle, currentSession: () => session, currentApi: () => api, supervisor, store, saved, requests, completion, frames, api, send, ready, acknowledgeClose, events, projections, snapshots, transactions, notifications,
    drainEvents, emitRuntime: (event: RuntimeEvent) => eventTarget.applyRuntimeEvent("session-sdk", event) };
}

it("keeps a fresh empty Pickle waiting in durable v2 updates throughout provider negotiation", async () => {
  const f = await fixture({ deferReady: true, captureSaved: true });
  await f.drainEvents();
  const beforeReady = await f.store.loadReadOnly("session-sdk");
  expect(beforeReady).toMatchObject({ status: "waiting_for_input", asyncWorkSummary: { tracking: "reconciling", canReleaseRuntime: false } });
  expect(f.snapshots).toMatchObject([{ status: "waiting_for_input" }]);
  const pendingStates = [...f.snapshots, ...f.projections];
  expect(pendingStates.every((state) => state.status === "waiting_for_input")).toBe(true);
  expect(f.saved.every((state) => state.status === "waiting_for_input")).toBe(true);
  await f.ready();
  const afterReady = await f.store.loadReadOnly("session-sdk");
  expect(afterReady).toMatchObject({ status: "waiting_for_input", asyncWorkSummary: { tracking: "ready", canReleaseRuntime: true } });
  expect(f.saved.some((state) => state.asyncWorkSummary?.tracking === "reconciling" && state.asyncWorkSummary.canReleaseRuntime === false)).toBe(true);
  expect(f.saved.every((state) => state.status === "waiting_for_input")).toBe(true);
  expect([...f.snapshots, ...f.projections].every((state) => state.status === "waiting_for_input")).toBe(true);
  expect(f.transactions.some((mutations) => mutations.some((mutation) => mutation.type === "metaPatch" && mutation.patch.asyncWorkSummary?.tracking === "ready"))).toBe(true);
  expect(f.notifications).toEqual([]);
  expect(f.requests).toEqual([]);
  console.log("FRESH_PERSISTED_V2", JSON.stringify({ saved: f.saved.map((s) => [s.revision, s.status, s.asyncWorkSummary?.tracking, s.asyncWorkSummary?.canReleaseRuntime]), v2: [...f.snapshots, ...f.projections].map((s) => [s.revision, s.status, s.asyncWorkSummary?.tracking, s.asyncWorkSummary?.canReleaseRuntime]) }));
  const from = f.saved.length, v2From = f.projections.length;
  await f.supervisor.setSessionArchived("session-sdk", true, undefined, "empty-archive");
  const archived = await f.store.loadReadOnly("session-sdk");
  expect(archived).toMatchObject({ status: "waiting_for_input", archived: true, asyncControl: { admissionState: "closed" }, asyncWorkSummary: { canReleaseRuntime: true } });
  expect(f.saved.slice(from).some((state) => state.asyncControl?.operations.some((operation) => operation.outcome === "accepted") && state.asyncWorkSummary?.canReleaseRuntime === false)).toBe(true);
  expect(f.saved.slice(from).every((state) => state.status === "waiting_for_input")).toBe(true);
  expect(f.projections.slice(v2From).every((state) => state.status === "waiting_for_input")).toBe(true);
  expect(f.requests).toEqual([]);
  expect(f.notifications).toEqual([]);
  console.log("EMPTY_ARCHIVE_PERSISTED_V2", JSON.stringify({ saved: f.saved.slice(from).map((s) => [s.revision, s.status, s.archived, s.asyncControl?.admissionState, s.asyncWorkSummary?.canReleaseRuntime]), v2: f.projections.slice(v2From).map((s) => [s.revision, s.status, s.archived, s.asyncControl?.admissionState, s.asyncWorkSummary?.canReleaseRuntime]) }));
}, 15_000);

it("preserves a completed Pickle across durable archive accept, closing ACK, and v2 settlement", async () => {
  const f = await fixture({ readyOnDiscovery: true, holdCloseAck: true, captureSaved: true });
  await f.supervisor.followUp("session-sdk", "Finish before archive");
  await f.session.waitForIdle(); await f.drainEvents();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"));
  const before = await f.store.loadReadOnly("session-sdk");
  const from = f.saved.length, v2From = f.projections.length;
  const archive = f.supervisor.setSessionArchived("session-sdk", true, "stopThenArchive", "idle-archive");
  try {
    await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncControlJournal?.some((entry) => entry.result.requestId === "idle-archive:execute" && entry.result.outcome === "accepted")).toBe(true));
    const during = await f.store.loadReadOnly("session-sdk");
    expect(during).toMatchObject({ status: "completed", asyncControl: { admissionState: "closed" }, asyncWorkSummary: { canReleaseRuntime: false } });
    expect(during?.archived).not.toBe(true);
    console.log("ARCHIVE_HELD_PERSISTED_V2", JSON.stringify({ saved: f.saved.slice(from).map((s) => [s.revision, s.status, s.archived, s.asyncControl?.admissionState, s.asyncWorkSummary?.canReleaseRuntime, s.asyncControlJournal?.at(-1)?.result.outcome]), v2: f.projections.slice(v2From).map((s) => [s.revision, s.status, s.archived, s.asyncControl?.admissionState, s.asyncWorkSummary?.canReleaseRuntime]) }));
    expect(f.saved.slice(from).some((state) => state.asyncControl?.operations.some((operation) => operation.outcome === "accepted") && state.asyncWorkSummary?.canReleaseRuntime === false)).toBe(true);
    expect(f.frames.some((frame) => frame.type === "control-request" && frame.action === "closeAdmission")).toBe(true);
    expect(f.saved.slice(from).every((state) => state.status === "completed")).toBe(true);
    expect(f.projections.slice(v2From).every((state) => state.status === "completed")).toBe(true);
  } finally { f.acknowledgeClose(); }
  await archive;
  const after = await f.store.loadReadOnly("session-sdk");
  expect(after).toMatchObject({ status: "completed", archived: true, asyncControl: { admissionState: "closed" }, asyncWorkSummary: { canReleaseRuntime: true } });
  expect(f.saved.slice(from).every((state) => state.status === "completed")).toBe(true);
  expect(f.projections.slice(v2From).every((state) => state.status === "completed")).toBe(true);
  expect(after?.messages).toEqual(before?.messages);
  expect(after?.finalAnswer).toBe(before?.finalAnswer);
  expect(f.notifications).toEqual([]);
  expect(f.requests).toHaveLength(1);
  console.log("ARCHIVE_PERSISTED_V2", JSON.stringify({ saved: f.saved.slice(from).map((s) => [s.revision, s.status, s.archived, s.asyncControl?.admissionState, s.asyncWorkSummary?.canReleaseRuntime, s.asyncControlJournal?.at(-1)?.result.outcome]), v2: f.projections.slice(v2From).map((s) => [s.revision, s.status, s.archived, s.asyncControl?.admissionState, s.asyncWorkSummary?.canReleaseRuntime]), mutations: f.transactions.slice(v2From).map((set) => set.map((m) => m.type)) }));
}, 15_000);

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

it("restores a quiescent released archive with a fresh provider owner and admits a new turn without replaying old work", async () => {
  const f = await fixture({ readyOnDiscovery: true });
  const result = await f.completion("released");
  await f.session.sendCustomMessage(result, { triggerTurn: true });
  await f.session.waitForIdle(); await f.drainEvents();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary?.canReleaseRuntime).toBe(true));
  const before = await f.store.loadReadOnly("session-sdk");
  expect(before?.completionTickets).toMatchObject([{ state: "handled" }]);
  await f.supervisor.setSessionArchived("session-sdk", true, "continue", "release-archive");
  const context = f.supervisor.asyncControls.context("session-sdk");
  const oldCommand = { type: "prepareRuntimeRelease" as const, requestId: "release-request", sessionId: "session-sdk",
    daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: context.runtimeInstanceId!, workRevision: context.workRevision,
    controlGeneration: context.controlGeneration, archiveIntentId: "release-archive", childGeneration: 1 };
  const approval = await f.supervisor.executeAsyncTaskCommand(oldCommand);
  expect(approval.outcome).toBe("settled");
  const releasedDisk = await f.store.loadReadOnly("session-sdk");
  expect(releasedDisk).toMatchObject({ archived: true, asyncControl: { admissionState: "closed", releasePrepared: approval.releaseApproval }, asyncWorkSummary: { canReleaseRuntime: true } });
  await f.handle.dispose?.();

  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  expect(restarted.get("session-sdk")).toMatchObject({ archived: true, asyncControl: { releasePrepared: approval.releaseApproval } });
  expect(restarted.asyncControls.context("session-sdk").runtimeInstanceId).toBeUndefined();
  await expect(restarted.executeAsyncTaskCommand(oldCommand)).rejects.toThrow("owner changed");
  const server = new AgentdServer({ port: 0, token: "released-recovery", supervisor: restarted });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=released-recovery`);
  const wire: EventEnvelope[] = [];
  ws.on("message", (data) => wire.push(JSON.parse(String(data)) as EventEnvelope));
  cleanups.push(async () => { ws.close(); await server.stop(); });
  await once(ws, "open");
  const dispatch = async (command: object, id: string) => {
    ws.send(JSON.stringify({ ...command, id, protocolVersion: PROTOCOL_VERSION }));
    await vi.waitFor(() => expect(wire.some((event) => event.type === "ack" && event.commandId === id || event.type === "error" && event.commandId === id)).toBe(true));
    expect(wire.find((event) => event.type === "error" && event.commandId === id)).toBeUndefined();
  };
  await dispatch({ type: "registerAppCapabilities", capabilities: ["sessionProjectionV2"] }, "register-recovery");
  expect(wire.some((event) => event.type === "sessionProjectionSnapshot" && event.sessionId === "session-sdk")).toBe(true);
  await dispatch({ type: "setSessionArchived", sessionId: "session-sdk", archived: false }, "unarchive-recovery");
  const recovered = restarted.asyncControls.context("session-sdk");
  expect(recovered.runtimeInstanceId).toBeDefined();
  expect(recovered.runtimeInstanceId).not.toBe(context.runtimeInstanceId);
  await vi.waitFor(() => expect(restarted.asyncControls.context("session-sdk").tracking).toBe("ready"));
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncControl?.releasePrepared).toBeUndefined();
  await dispatch({ type: "followUp", sessionId: "session-sdk", text: "Fresh input after release" }, "followup-recovery");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.finalAnswer).toBe("Finite reply"));
  const final = await f.store.loadReadOnly("session-sdk");
  expect(final).toMatchObject({ archived: false, status: "completed", asyncWorkSummary: { tracking: "ready", canReleaseRuntime: true }, completionTickets: [{ state: "handled" }] });
  expect(final?.asyncTasks).toHaveLength(1);
  expect(final?.completionTickets).toHaveLength(1);
  expect(f.requests).toHaveLength(2);
  expect(JSON.stringify(f.requests.at(-1))).toContain("Fresh input after release");
  const newResult = await f.completion("after-release");
  await f.currentSession().sendCustomMessage(newResult, { triggerTurn: true });
  await f.currentSession().waitForIdle();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.at(-1)?.state).toBe("handled"));
  const afterNewResult = await f.store.loadReadOnly("session-sdk");
  expect(afterNewResult).toMatchObject({ status: "completed", asyncWorkSummary: { tracking: "ready", canReleaseRuntime: true } });
  expect(afterNewResult?.asyncTasks).toHaveLength(2);
  expect(afterNewResult?.completionTickets?.map((ticket) => ticket.state)).toEqual(["handled", "handled"]);
  expect(afterNewResult?.asyncTasks?.at(-1)?.runtimeInstanceId).toBe(recovered.runtimeInstanceId);
  expect(f.requests).toHaveLength(3);
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(2);
  await vi.waitFor(() => expect(wire.some((event) => event.type === "sessionProjectionTransaction" && event.sessionId === "session-sdk" && event.revision === afterNewResult?.revision)).toBe(true));
}, 20_000);

it.each(["waiting_for_input", "blocked", "completed", "blocked-completed"] as const)("restores an empty %s Pickle through resume, store and v2 before admitting its first follow-up", async persistedStatus => {
  const f = await fixture({ readyOnDiscovery: true, captureSaved: true });
  await f.drainEvents();
  expect(f.requests).toEqual([]);
  await f.handle.dispose?.();
  const original = (await f.store.loadReadOnly("session-sdk"))!;
  expect(original).toMatchObject({ status: "waiting_for_input", asyncWorkSummary: { canReleaseRuntime: true } });
  if (persistedStatus !== "waiting_for_input") await f.store.save({ ...original,
    status: persistedStatus.startsWith("blocked") ? "blocked" : "completed",
    lastSummary: persistedStatus.startsWith("blocked") ? "Async owner restarted; resource and delivery reconciliation required" : "Earlier answer",
    ...(persistedStatus.includes("completed") ? { finalAnswer: "Earlier answer" } : {}),
  });
  const savedBefore = f.saved.length;
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk",
    forwardPickleCompletionToPrimary: async ({ completionId }) => { f.notifications.push(completionId); } });
  const projections: PickyAgentSession[] = [];
  restarted.on("sessionProjectionTransaction", (_id, _before, after) => projections.push(structuredClone(after)));
  await restarted.load();
  await vi.waitFor(() => expect(restarted.asyncControls.context("session-sdk").tracking).toBe("ready"));
  await restarted.withSessionProjectionBarrier("session-sdk", async () => {});
  const disk = await f.store.loadReadOnly("session-sdk");
  const server = new AgentdServer({ port: 0, token: "empty-reentry", supervisor: restarted });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=empty-reentry`);
  const wire: EventEnvelope[] = [];
  ws.on("message", data => wire.push(JSON.parse(String(data)) as EventEnvelope));
  cleanups.push(async () => { ws.close(); await server.stop(); });
  await once(ws, "open");
  ws.send(JSON.stringify({ type: "registerAppCapabilities", id: "register-empty", protocolVersion: PROTOCOL_VERSION, capabilities: ["sessionProjectionV2"] }));
  await vi.waitFor(() => expect(wire.some(event => event.type === "sessionProjectionSnapshot" && event.sessionId === "session-sdk")).toBe(true));
  const snapshot = wire.find(event => event.type === "sessionProjectionSnapshot" && event.sessionId === "session-sdk");
  const expectedStatus = persistedStatus.includes("completed") ? "completed" : "waiting_for_input";
  expect(projections.at(-1)?.status).toBe(expectedStatus);
  console.log("EMPTY_REENTRY_BEFORE", JSON.stringify({ persistedStatus, disk: [disk?.status, disk?.lastSummary, disk?.asyncWorkSummary], saved: f.saved.slice(savedBefore).map(s => [s.status, s.asyncWorkSummary?.tracking]), v2: [snapshot?.type, projections.at(-1)?.status], notifications: f.notifications.length }));
  expect(f.notifications).toEqual([]);
  await restarted.runtimeControls.setModel("session-sdk", "w3-offline", "finite");
  ws.send(JSON.stringify({ type: "followUp", id: "first-input", protocolVersion: PROTOCOL_VERSION, sessionId: "session-sdk", text: "First input after restart" }));
  await vi.waitFor(() => expect(wire.some(event => event.type === "ack" && event.commandId === "first-input" || event.type === "error" && event.commandId === "first-input")).toBe(true));
  expect(wire.some(event => event.type === "error" && event.commandId === "first-input")).toBe(false);
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.finalAnswer).toBe("Finite reply"));
  expect(JSON.stringify(f.requests.at(-1))).toContain("First input after restart");
  console.log("EMPTY_REENTRY_AFTER", JSON.stringify({ persistedStatus, status: (await f.store.loadReadOnly("session-sdk"))?.status, requests: f.requests.length }));
  expect(disk).toMatchObject({ status: expectedStatus, asyncWorkSummary: { tracking: "ready", canReleaseRuntime: true } });
  expect(disk?.lastSummary).toBe(expectedStatus === "completed" ? "Earlier answer" : "Ready for instructions");
  expect(snapshot).toMatchObject({ type: "sessionProjectionSnapshot", projection: { status: expectedStatus } });
}, 20_000);

it.each(["waiting_for_input", "completed"] as const)("reopens admission for an idle %s Pickle after restart so an extension-injected prompt reaches the model", async persistedStatus => {
  const f = await fixture({ readyOnDiscovery: true });
  await f.drainEvents();
  await f.handle.dispose?.();
  const original = (await f.store.loadReadOnly("session-sdk"))!;
  if (persistedStatus === "completed") await f.store.save({ ...original, status: "completed", lastSummary: "Earlier answer", finalAnswer: "Earlier answer" });
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncControl?.admissionState).toBe("open"), { timeout: 5_000 });
  await restarted.runtimeControls.setModel("session-sdk", "w3-offline", "finite");
  // Pi extensions (e.g. scheduled session delivery) inject prompts without any Picky input command.
  f.currentApi().sendUserMessage("Scheduled delivery after restart");
  await vi.waitFor(() => expect(JSON.stringify(f.requests.at(-1))).toContain("Scheduled delivery after restart"));
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.finalAnswer).toBe("Finite reply"));
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncControl?.admissionState).toBe("open");
}, 20_000);

it("keeps admission closed after restart while async work from the previous owner remains unresolved", async () => {
  const f = await fixture({ readyOnDiscovery: true });
  await f.completion("left-running", { execution: "running", presence: "active" });
  await f.drainEvents();
  await f.handle.dispose?.();
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  await vi.waitFor(() => expect(restarted.asyncControls.context("session-sdk").tracking).toBe("ready"));
  await restarted.withSessionProjectionBarrier("session-sdk", async () => {});
  await restarted.runtimeControls.setModel("session-sdk", "w3-offline", "finite");
  const requestsBefore = f.requests.length;
  f.currentApi().sendUserMessage("Scheduled delivery while work is unknown");
  // The model fence still rejects the injected prompt; the rejection is persisted instead of reaching the model.
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.messages?.at(-1)).toMatchObject({ kind: "agent_error", errorMessage: "Async model admission aborted" }));
  await restarted.withSessionProjectionBarrier("session-sdk", async () => {});
  expect(f.requests).toHaveLength(requestsBefore);
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.asyncControl?.admissionState).toBe("closed");
  expect(disk?.asyncTasks?.find((task) => task.taskId === "left-running")).toMatchObject({ presence: "unknown" });
}, 20_000);

it("keeps an empty resumed Pickle fenced until its new provider snapshot is ready", async () => {
  const options = { readyOnDiscovery: true };
  const f = await fixture(options);
  await f.handle.dispose?.();
  options.readyOnDiscovery = false;
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  expect(restarted.asyncControls.context("session-sdk").tracking).toBe("reconciling");
  expect(await f.store.loadReadOnly("session-sdk")).toMatchObject({ status: "waiting_for_input", asyncControl: { admissionState: "closed" }, asyncWorkSummary: { canReleaseRuntime: false } });
  await expect(restarted.followUp("session-sdk", "Wait for coverage")).rejects.toThrow(/coverage|reconciliation|cleanup/);
  expect(f.requests).toEqual([]);
}, 20_000);

it.each(["failed-control", "unrelated-block"] as const)("does not clear a %s on reentry despite empty tasks", async reason => {
  const f = await fixture({ readyOnDiscovery: true });
  await f.handle.dispose?.();
  const original = (await f.store.loadReadOnly("session-sdk"))!;
  await f.store.save({ ...original, status: "blocked",
    lastSummary: reason === "unrelated-block" ? "Runtime not attached" : "Async owner restarted; resource and delivery reconciliation required",
    asyncControl: reason === "failed-control" ? { ...original.asyncControl!, operations: [{ requestId: "old-stop", operationId: "old-operation", outcome: "blocked_cleanup", controlGeneration: 0 }] } : original.asyncControl });
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  await vi.waitFor(() => expect(restarted.asyncControls.context("session-sdk").tracking).toBe("ready"));
  await restarted.withSessionProjectionBarrier("session-sdk", async () => {});
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.status).toBe("blocked");
  if (reason === "failed-control") {
    expect(disk?.asyncControl?.operations).toMatchObject([{ outcome: "blocked_cleanup" }]);
    expect(disk?.asyncWorkSummary).toMatchObject({ attentionCount: 1, canReleaseRuntime: false });
    expect(f.requests).toEqual([]);
  } else {
    expect(disk?.lastSummary).toBe("Runtime not attached");
    await f.currentHandle().dispose?.();
    const secondRestart = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
    await secondRestart.load();
    await vi.waitFor(() => expect(secondRestart.asyncControls.context("session-sdk").tracking).toBe("ready"));
    await secondRestart.withSessionProjectionBarrier("session-sdk", async () => {});
    expect(await f.store.loadReadOnly("session-sdk")).toMatchObject({ status: "blocked", lastSummary: "Runtime not attached", asyncWorkSummary: { tracking: "ready" } });
    expect(f.requests).toEqual([]);
  }
}, 20_000);

it("refuses resumed input until the fresh provider has negotiated its snapshot", async () => {
  const options = { readyOnDiscovery: true };
  const f = await fixture(options);
  await f.supervisor.setSessionArchived("session-sdk", true, "continue", "coverage-archive");
  const context = f.supervisor.asyncControls.context("session-sdk");
  const result = await f.supervisor.executeAsyncTaskCommand({ type: "prepareRuntimeRelease", requestId: "coverage-release", sessionId: "session-sdk",
    daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: context.runtimeInstanceId!, workRevision: context.workRevision,
    controlGeneration: context.controlGeneration, archiveIntentId: "coverage-archive", childGeneration: 1 });
  expect(result.outcome).toBe("settled");
  await f.handle.dispose?.();
  options.readyOnDiscovery = false;
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  await restarted.setSessionArchived("session-sdk", false);
  expect(restarted.asyncControls.context("session-sdk").tracking).toBe("reconciling");
  await expect(restarted.followUp("session-sdk", "No provider snapshot yet")).rejects.toThrow(/coverage|reconciliation|cleanup/);
  expect(f.requests).toHaveLength(0);
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks ?? []).toHaveLength(0);
}, 20_000);

it("archives a Pickle with incomplete coverage without settling or discarding its result", async () => {
  const f = await fixture({ readyOnDiscovery: true });
  await f.completion("unconfirmed");
  const control = f.handle.asyncTasks!;
  const coverage = control.coverage();
  const spy = vi.spyOn(control, "coverage").mockReturnValue({ ...coverage, tracking: "unsupported", readyProviders: [] });
  try {
    await f.emitRuntime({ type: "async_task_coverage", coverage: control.coverage() });
    await f.supervisor.setSessionArchived("session-sdk", true, "continue", "unconfirmed-archive");
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk).toMatchObject({ archived: true, completionTickets: [{ state: "submitted" }], asyncWorkSummary: { canReleaseRuntime: false } });
    expect(f.frames.filter((frame) => frame.type === "completion-observed")).toEqual([]);
    expect(f.requests).toEqual([]);
  } finally { spy.mockRestore(); }
}, 15_000);

it("keeps an unfinished archived owner fenced after a fresh daemon generation", async () => {
  const f = await fixture({ readyOnDiscovery: true });
  await f.completion("unfinished", { execution: "running", presence: "active" });
  await f.supervisor.setSessionArchived("session-sdk", true, "continue", "unfinished-archive");
  const before = await f.store.loadReadOnly("session-sdk");
  expect(before?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  expect(before?.asyncTasks?.[0]).toMatchObject({ presence: "active", execution: "running" });
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  expect(restarted.get("session-sdk")?.asyncTasks?.[0]?.presence).toBe("unknown");
  expect(restarted.get("session-sdk")?.asyncWorkSummary).toMatchObject({ tracking: "reconciling", canReleaseRuntime: false });
  await restarted.setSessionArchived("session-sdk", false);
  await expect(restarted.followUp("session-sdk", "Must not execute unknown work")).rejects.toThrow(/Async owner unavailable|Async work still has execution|reconciliation|coverage|cleanup/);
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.[0]?.presence).toBe("unknown");
  expect(f.requests).toHaveLength(0);
}, 20_000);

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


it("defers a never-admitted result until concurrent compaction ends", async () => {
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
  const delivery = f.session.sendCustomMessage(message, { triggerTurn: true });
  try {
    await vi.waitFor(() => expect(f.session.isStreaming).toBe(true));
    expect(f.requests).toHaveLength(1);
    expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("submitted");
  } finally { release(); await compact; }
  await delivery;
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tickets[0]?.state).toBe("handled"));
  expect(f.requests).toHaveLength(2);
  expect(JSON.stringify(f.requests.at(-1))).toContain("RESULT compacting");
}, 15_000);

it.each(["held", "failed"] as const)("cancels compaction admission while the close save is %s", async (saveMode) => {
  const f = await fixture();
  await f.handle.followUp({ text: "Seed transcript", imagePaths: [] });
  await f.session.waitForIdle();
  const message = await f.completion(`close-${saveMode}`);
  let enter!: () => void, release!: () => void, releaseSave!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const heldSave = new Promise<void>(resolve => { releaseSave = resolve; });
  f.api.on("session_before_compact", async event => {
    enter(); await held;
    return { compaction: { summary: "Offline summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
  });
  const compact = f.session.compact();
  await entered;
  let delivered = false;
  const delivery = f.session.sendCustomMessage(message, { triggerTurn: true }).finally(() => { delivered = true; });
  const save = f.store.save.bind(f.store);
  let saveEntered = false;
  const saveSpy = vi.spyOn(f.store, "save").mockImplementation(async state => {
    if (state.asyncControl?.admissionState === "closed") {
      saveEntered = true;
      if (saveMode === "failed") throw new Error("Close save unavailable");
      await heldSave;
    }
    return save(state);
  });
  let closing: Promise<unknown> | undefined;
  try {
    await vi.waitFor(() => expect(f.session.isStreaming).toBe(true));
    closing = f.handle.asyncTasks!.closeAdmission().catch(error => error);
    await vi.waitFor(() => expect(saveEntered).toBe(true));
    // Neither compaction nor the held save has been released. Cancellation must
    // settle the SDK delivery now, without dispatching the completion to a model.
    await vi.waitFor(() => expect(delivered).toBe(true));
    expect(f.session.isCompacting).toBe(true);
    expect(f.requests).toHaveLength(1);
    expect(f.frames.filter(frame => frame.type === "completion-observed")).toHaveLength(0);
    if (saveMode === "failed") expect(await closing).toMatchObject({ message: "Close save unavailable" });
  } finally {
    releaseSave();
    await closing;
    saveSpy.mockRestore();
    release(); await compact; await delivery;
  }
  await f.handle.asyncTasks!.reopenAdmission();
  await f.session.waitForIdle();
  expect(f.requests).toHaveLength(1);
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).not.toBe("handled");
}, 15_000);

it("settles a delivered result after the model finishes before a later tool abort, without replay on restart", async () => {
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const f = await fixture({ readyOnDiscovery: true, onTool: async () => { enter(); await held; } });
  const message = await f.completion("consumed-before-abort");
  const delivery = f.session.sendCustomMessage(message, { triggerTurn: true });
  await entered;
  const abort = f.supervisor.abort("session-sdk");
  release();
  await abort;
  await delivery;
  await f.session.waitForIdle(); await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.agentCycle?.outcome).not.toBe("completed");
  expect(disk?.completionTickets?.[0]?.state).toBe("handled");
  expect(f.requests).toHaveLength(1);
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(1);
  const journal = (await readFile(disk!.piSessionFilePath!, "utf8")).split("\n").filter(Boolean).map(line => JSON.parse(line) as { message?: { role?: string; stopReason?: string } });
  expect(journal.some(entry => entry.message?.role === "assistant" && entry.message.stopReason === "toolUse")).toBe(true);
  const restarted = new SessionSupervisor(f.runtime, f.store, { enableAsyncTasksForSession: (id) => id === "session-sdk" });
  await restarted.load();
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled");
  await restarted.followUp("session-sdk", "Continue after confirmed result");
  await vi.waitFor(() => expect(f.requests.filter(request => JSON.stringify(request).includes("Continue after confirmed result"))).toHaveLength(1));
  await f.currentSession().waitForIdle(); await f.drainEvents();
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled");
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toHaveLength(1);
}, 15_000);

it("does not settle a result when the model fails before completing its response", async () => {
  const f = await fixture({ failModel: true });
  const message = await f.completion("unconsumed");
  await f.session.sendCustomMessage(message, { triggerTurn: true });
  await f.session.waitForIdle(); await f.drainEvents();
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("pending");
  expect(f.frames.filter((frame) => frame.type === "completion-observed")).toEqual([]);
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
  const f = await fixture({ readyOnDiscovery: true });
  const previous = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  await f.handle.followUp({ text: "/reload", imagePaths: [] });
  expect(f.handle.asyncTasks!.coverage().runtimeInstanceId).not.toBe(previous);
  const current = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  expect(f.frames.some((frame) => frame.type === "host-state" && frame.runtimeInstanceId === current && frame.supported)).toBe(true);
  expect(f.handle.asyncTasks!.coverage().tracking).toBe("ready");
  await f.supervisor.followUp("session-sdk", "Authorized work after reload");
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
  expect(JSON.stringify(f.requests[0])).toContain("Authorized work after reload");
  await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.agentCycle).toMatchObject({ runtimeInstanceId: current, phase: "settled", outcome: "completed" });
  expect(f.projections.at(-1)?.agentCycle).toEqual(disk?.agentCycle);
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

it.each([
  { recovers: true, settledStatus: "running" },
  { recovers: false, settledStatus: "blocked" },
] as const)("shows a follow-up after a failed response with surviving work as running (recovers=$recovers)", async ({ recovers, settledStatus }) => {
  const options = { failModel: true };
  const f = await fixture(options);
  await f.completion("surviving-resource", { execution: "failed", presence: "active" });
  await f.handle.followUp({ text: "Finite failed response", imagePaths: [] });
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.asyncWorkSummary?.episode?.outcome).toBe("failed"));
  await f.drainEvents();
  const failedCycleId = f.supervisor.get("session-sdk")?.agentCycle?.cycleId;
  expect(f.supervisor.get("session-sdk")).toMatchObject({ status: "blocked", lastSummary: "Agent failed with unfinished work" });

  options.failModel = !recovers;
  await f.supervisor.followUp("session-sdk", "Continue");
  await vi.waitFor(() => expect(f.requests).toHaveLength(2));
  await f.session.waitForIdle();
  await vi.waitFor(() => expect(f.supervisor.get("session-sdk")?.asyncWorkSummary?.episode?.finalizedCycleId).not.toBe(failedCycleId));
  await f.drainEvents();
  // Until the new cycle itself fails, no published projection may fall back to the old failure.
  const nextCycle = f.projections.filter((state) => state.agentCycle && state.agentCycle.cycleId !== failedCycleId && state.agentCycle.outcome !== "failed");
  expect(nextCycle.some((state) => state.agentCycle?.phase === "responding")).toBe(true);
  for (const state of nextCycle) {
    expect(state.status).toBe("running");
    expect(state.lastSummary).not.toBe("Agent failed with unfinished work");
  }
  expect(await f.store.loadReadOnly("session-sdk")).toMatchObject({ status: settledStatus, asyncWorkSummary: { activeRootCount: 1, canReleaseRuntime: false } });
  expect(f.requests).toHaveLength(2);
}, 15_000);

it("does not abort an idle model while reconciling a stopped Pickle before follow-up", async () => {
  const f = await fixture({ readyOnDiscovery: true, captureSaved: true });
  await f.supervisor.followUp("session-sdk", "First turn");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.finalAnswer).toBe("Finite reply"));
  await f.session.waitForIdle(); await f.drainEvents();
  const before = f.saved.length, v2Before = f.projections.length;
  const stopped = await f.supervisor.asyncControls.stop("session-sdk", "stop-before-reopen");
  expect(stopped.outcome).toBe("settled");
  const cancellations = (await f.store.loadReadOnly("session-sdk"))!.messages?.filter(m => m.kind === "system" && m.text === "Cancelled by user").length ?? 0;
  await f.supervisor.followUp("session-sdk", "Second turn");
  await vi.waitFor(() => expect(f.requests).toHaveLength(2));
  await f.session.waitForIdle(); await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk).toMatchObject({ status: "completed", finalAnswer: "Finite reply", asyncControl: { admissionState: "open" } });
  expect(disk?.messages?.filter(m => m.kind === "system" && m.text === "Cancelled by user")).toHaveLength(cancellations);
  expect(f.requests).toHaveLength(2);
  expect(f.saved.slice(before).every(s => s.status !== "cancelled")).toBe(true);
  expect(f.projections.slice(v2Before).every(s => s.status !== "cancelled")).toBe(true);
  console.log("STOP_REOPEN_PERSISTED_V2", JSON.stringify({ saved: f.saved.slice(before).map(s => [s.status, s.asyncControl?.admissionState, s.messages?.filter(m => m.text === "Cancelled by user").length]), v2: f.projections.slice(v2Before).map(s => [s.status, s.asyncControl?.admissionState]) }));
}, 15_000);

it.each(["stop-all", "child-cancel", "timeout"] as const)("%s targets the root and waits for actual child exit after an accepted ACK", async mode => {
  const f = await fixture({ readyOnDiscovery: true, acceptCancel: true, captureSaved: true });
  const owner = f.handle.asyncTasks!.owners!()[0]!;
  const createdAt = new Date().toISOString();
  for (const [id, parentTaskId] of [["root", undefined], ["child", "root"]] as const) {
    const task = { ...owner, taskId: id, rootTaskId: "root", ...(parentTaskId ? { parentTaskId } : {}), kind: "subagent", title: id,
      execution: "queued", presence: "settled", registration: "reserved", providerRevision: 1, controlGeneration: 0, createdAt, updatedAt: createdAt };
    f.send({ type: "task-register", requestId: `grant-${id}`, providerRevision: 1, task });
    await vi.waitFor(() => expect(f.frames.some(frame => frame.type === "task-register-result" && frame.taskId === id && frame.outcome === "accepted")).toBe(true));
    expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary).toMatchObject({ attentionCount: 0, canReleaseRuntime: false });
  }
  expect(f.saved.filter(s => s.asyncTasks?.some(task => task.registration === "approved")).every(s => s.status !== "blocked" && s.asyncWorkSummary?.attentionCount === 0)).toBe(true);
  const grants = f.handle.asyncTasks!.snapshot().tasks;
  expect(grants).toHaveLength(2);
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary).toMatchObject({ activeRootCount: 1, attentionCount: 0, canReleaseRuntime: false });
  expect(f.projections.filter(s => s.asyncTasks?.length === 2).every(s => s.status !== "blocked")).toBe(true);
  f.send({ type: "task-update", providerRevision: 2, detail: { tasks: grants.map(task => ({ ...task, registration: "spawned", execution: "running", presence: "active", providerRevision: 2 })), tickets: [] } });
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tasks.every(task => task.presence === "active")).toBe(true));
  const start = f.saved.length, v2Start = f.projections.length;
  const context = f.supervisor.asyncControls.context("session-sdk");
  const operation = mode === "stop-all" ? f.supervisor.asyncControls.stop("session-sdk", "stop-root-family")
    : f.supervisor.executeAsyncTaskCommand({ type: "cancelAsyncTask", requestId: "cancel-child", sessionId: "session-sdk", taskId: "child", owner,
      daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: context.runtimeInstanceId!, workRevision: context.workRevision, controlGeneration: context.controlGeneration });
  await vi.waitFor(() => expect(f.frames.filter(frame => frame.type === "control-request" && frame.action === "cancel")).toHaveLength(1));
  expect(f.frames.flatMap(frame => frame.type === "control-request" && frame.action === "cancel" ? [frame.taskId] : [])).toEqual(["root"]);
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncControlJournal?.at(-1)?.result.outcome).toBe("accepted");
  expect(f.projections.slice(v2Start).every(s => s.asyncWorkSummary?.canReleaseRuntime === false)).toBe(true);
  if (mode === "timeout") {
    const result = await operation;
    expect(result).toMatchObject({ outcome: "blocked_cleanup", reason: "Async execution cleanup timed out; outcome remains unknown" });
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk).toMatchObject({ status: "blocked", asyncWorkSummary: { canReleaseRuntime: false, attentionCount: 1 } });
    expect(disk?.asyncTasks?.every(task => task.presence === "active")).toBe(true);
    expect(f.projections.at(-1)).toMatchObject({ status: "blocked", asyncWorkSummary: { canReleaseRuntime: false } });
    return;
  }
  const active = f.handle.asyncTasks!.snapshot().tasks;
  f.send({ type: "task-update", providerRevision: 3, detail: { tasks: [{ ...active[0]!, execution: "cancelled", presence: "settled", providerRevision: 3 }, active[1]!], tickets: [] } });
  await vi.waitFor(() => expect(f.handle.asyncTasks!.snapshot().tasks[0]?.presence).toBe("settled"));
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncControlJournal?.at(-1)?.result.outcome).toBe("accepted");
  f.send({ type: "task-update", providerRevision: 4, detail: { tasks: [{ ...f.handle.asyncTasks!.snapshot().tasks[0]!, providerRevision: 4 }, { ...f.handle.asyncTasks!.snapshot().tasks[1]!, execution: "cancelled", presence: "settled", providerRevision: 4 }], tickets: [] } });
  expect((await operation).outcome).toBe("settled");
  await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.asyncTasks?.every(task => task.presence === "settled")).toBe(true);
  expect(disk?.asyncWorkSummary).toMatchObject({ attentionCount: 0, canReleaseRuntime: true });
  expect(f.saved.slice(start).some(s => s.asyncControlJournal?.at(-1)?.result.outcome === "accepted" && s.asyncTasks?.some(task => task.presence === "active"))).toBe(true);
  console.log("ROOT_CANCEL_PERSISTED_V2", JSON.stringify({ saved: f.saved.slice(start).map(s => [s.status, s.asyncControlJournal?.at(-1)?.result.outcome, s.asyncTasks?.map(t => t.presence), s.asyncWorkSummary?.attentionCount]), v2: f.projections.slice(v2Start).map(s => [s.status, s.asyncTasks?.map(t => t.presence), s.asyncWorkSummary?.attentionCount]) }));
}, 15_000);

it("records one explicit stop cancellation and no second bubble when follow-up reopens admission", async () => {
  let entered!: () => void, release!: () => void;
  const running = new Promise<void>(resolve => { entered = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const f = await fixture({ readyOnDiscovery: true, captureSaved: true, onTool: async () => { entered(); await held; } });
  await f.supervisor.followUp("session-sdk", "Run until stopped");
  await running;
  const stop = f.supervisor.asyncControls.stop("session-sdk", "stop-busy-model");
  try {
    await vi.waitFor(() => expect(f.frames.some(frame => frame.type === "control-request" && frame.action === "closeAdmission")).toBe(true));
  } finally { release(); }
  const stopped = await stop;
  expect(stopped.outcome).toBe("settled");
  await f.session.waitForIdle(); await f.drainEvents();
  const before = await f.store.loadReadOnly("session-sdk");
  expect(before?.messages?.filter(m => m.kind === "system" && m.text === "Cancelled by user")).toHaveLength(1);
  const start = f.saved.length, v2Start = f.projections.length;
  await f.supervisor.followUp("session-sdk", "Start a later independent turn");
  await vi.waitFor(() => expect(f.requests).toHaveLength(2));
  await f.session.waitForIdle(); await f.drainEvents();
  const after = await f.store.loadReadOnly("session-sdk");
  expect(after?.messages?.filter(m => m.kind === "system" && m.text === "Cancelled by user")).toHaveLength(1);
  expect(after?.finalAnswer).toBe("Finite reply");
  expect(f.saved.slice(start).every(s => (s.messages?.filter(m => m.kind === "system" && m.text === "Cancelled by user").length ?? 0) === 1)).toBe(true);
  expect(f.projections.slice(v2Start).every(s => (s.messages?.filter(m => m.kind === "system" && m.text === "Cancelled by user").length ?? 0) === 1)).toBe(true);
  console.log("BUSY_STOP_REOPEN_PERSISTED_V2", JSON.stringify({ saved: f.saved.slice(start).map(s => [s.status, s.messages?.filter(m => m.text === "Cancelled by user").length]), v2: f.projections.slice(v2Start).map(s => [s.status, s.messages?.filter(m => m.text === "Cancelled by user").length]) }));
}, 15_000);

it("reattaches a tracked Pickle whose idle owner was detached by terminal sync so archive and follow-up proceed", async () => {
  const f = await fixture({ readyOnDiscovery: true });
  await f.supervisor.followUp("session-sdk", "Finish before terminal use");
  await f.session.waitForIdle(); await f.drainEvents();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"));
  const file = f.supervisor.get("session-sdk")!.piSessionFilePath!;
  const lines = (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line) as { id?: string });
  await appendFile(file, JSON.stringify({ type: "message", id: "external-tui", parentId: lines.at(-1)?.id ?? null, timestamp: new Date().toISOString(),
    message: { role: "assistant", content: [{ type: "text", text: "External terminal reply" }], api: "w3-offline", provider: "w3-offline", model: "finite",
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() } }) + "\n");
  await f.supervisor.syncTerminalSession("session-sdk");
  await vi.waitFor(() => expect(f.supervisor.asyncControls.context("session-sdk")).toMatchObject({ runtimeInstanceId: undefined, tracking: "unsupported" }));

  const server = new AgentdServer({ port: 0, token: "detached-owner", supervisor: f.supervisor });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=detached-owner`);
  const wire: EventEnvelope[] = [];
  ws.on("message", (data) => wire.push(JSON.parse(String(data)) as EventEnvelope));
  cleanups.push(async () => { ws.close(); await server.stop(); });
  await once(ws, "open");
  ws.send(JSON.stringify({ id: "detached-context", protocolVersion: PROTOCOL_VERSION, type: "getAsyncControlContext", sessionId: "session-sdk" }));
  await vi.waitFor(() => expect(wire.some((event) => event.type === "asyncControlContext" && event.requestId === "detached-context")).toBe(true), { timeout: 10_000 });
  const context = wire.find((event) => event.type === "asyncControlContext" && event.requestId === "detached-context");
  expect(context).toMatchObject({ tracking: "ready", runtimeInstanceId: expect.any(String) });

  await f.supervisor.followUp("session-sdk", "Continue after terminal");
  await f.currentSession().waitForIdle(); await f.drainEvents();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"));
  await f.supervisor.setSessionArchived("session-sdk", true, undefined, "after-terminal-archive");
  expect(await f.store.loadReadOnly("session-sdk")).toMatchObject({ archived: true, status: "completed" });
}, 30_000);

it("stops a running tracked Pickle when the app clears its queue right before the stop", async () => {
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const f = await fixture({ readyOnDiscovery: true, onTool: async () => { enter(); await held; } });
  const work = f.supervisor.followUp("session-sdk", "Long running work");
  await entered;
  await f.supervisor.steer("session-sdk", "Queued while the tool runs");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.queuedSteers?.length).toBe(1));
  // The stop button sends clearQueue and abort back to back without waiting for the first ack;
  // the server answers an async-controlled abort through asyncControls.stop with the command ID.
  const cleared = f.supervisor.clearQueue("session-sdk", "all");
  const stopped = f.supervisor.asyncControls.stop("session-sdk", "cmd-stop-button");
  release();
  const [clearOutcome, stopOutcome] = await Promise.allSettled([cleared, stopped]);
  await work.catch(() => undefined);
  await f.session.waitForIdle(); await f.drainEvents();
  expect(clearOutcome.status).toBe("fulfilled");
  expect(stopOutcome.status === "fulfilled" ? stopOutcome.value.outcome : String(stopOutcome.reason)).toBe("settled");
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.status).not.toBe("running");
  expect(disk?.asyncControlJournal?.filter((entry) => entry.result.requestId === "cmd-stop-button").map((entry) => entry.result.outcome)).toEqual(["settled"]);
}, 15_000);
