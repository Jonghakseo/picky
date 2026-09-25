import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { once } from "node:events";
import { createServer, type Socket } from "node:net";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAssistantMessageEventStream, type AssistantMessage, type ToolCall } from "@earendil-works/pi-ai";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, VERSION, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, type AsyncTaskHostMessage } from "../domain/async-task-contract.js";
import { type PickyAgentSession, type PickySessionProjectionMutation } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "./types.js";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); vi.unstubAllEnvs(); });
function completionText(request: unknown, taskId: string): string {
  const context = request as { messages: Array<{ role: string; content: unknown }> };
  const texts = context.messages.filter(message => message.role === "user").map(message =>
    typeof message.content === "string" ? message.content : (message.content as Array<{ type: string; text?: string }>).filter(part => part.type === "text").map(part => part.text).join("\n"));
  const matching = texts.filter(text => text.includes(`[bash_async ${taskId}]`));
  expect(matching).toHaveLength(1);
  return matching[0]!;
}

type ToolInput = { name: string; arguments: ToolCall["arguments"] };
async function fixture(tool: ToolInput | ToolInput[]) {
  expect(VERSION).toBe("0.87.1");
  const extensionRoot = process.env.PICKY_TEST_EXTENSION_ROOT;
  if (!extensionRoot) throw new Error("PICKY_TEST_EXTENSION_ROOT must name the frozen provider checkout");
  const root = await mkdtemp(join(tmpdir(), "picky-w0b-provider-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "home/.pi/agent"); await mkdir(agentDir, { recursive: true });
  vi.stubEnv("HOME", join(root, "home")); vi.stubEnv("PI_CODING_AGENT_DIR", agentDir); vi.stubEnv("PI_OFFLINE", "1");
  let bus!: { emit(channel: string, data: unknown): void };
  let api!: ExtensionAPI;
  let session!: AgentSession;
  let handle!: RuntimeSessionHandle;

  const requests: unknown[] = [];
  const frames: AsyncTaskHostMessage[] = [];
  for (const name of ["bash-async", "subagent"]) {
    await cp(join(extensionRoot, "packages", name), join(root, "packages", name), { recursive: true, filter: path => !path.includes("/node_modules") });
  }
  await symlink(join(process.cwd(), "node_modules"), join(root, "node_modules"));
  await writeFile(join(root, "package.json"), JSON.stringify({ type: "module" }));
  vi.stubEnv("PICKY_APP_SUPPORT_DIR", join(root, "store")); vi.stubEnv("PICKY_AGENTD_PORT", "19873");
  const child = deferred<Socket>();
  const sockets: Socket[] = [];
  const server = createServer(socket => { sockets.push(socket); socket.once("data", () => child.resolve(socket)); });
  server.listen(join(root, "child.sock")); await once(server, "listening");
  cleanups.push(async () => {
    for (const socket of sockets) { if (!socket.destroyed) socket.end("exit\n"); }
    await new Promise<void>(resolve => server.close(() => resolve()));
  });
  await mkdir(join(root, "bin"));
  await writeFile(join(root, "bin/pi"), `#!${process.execPath}
import net from 'node:net';
import { appendFileSync } from 'node:fs';
appendFileSync(${JSON.stringify(join(root, "spawns"))}, 'spawn\\n');
process.on('SIGTERM', () => {});
const socket = net.connect(${JSON.stringify(join(root, "child.sock"))});
socket.on('connect', () => socket.write('ready\\n'));
socket.on('data', data => {
 if (data.toString().includes('result')) console.log(JSON.stringify({type:'message_end',message:{role:'assistant',content:[{type:'text',text:'W0B_FINITE_CHILD_RESULT'}],stopReason:'stop',usage:{input:0,output:0,cacheRead:0,cacheWrite:0,cost:{total:0}}}}));
 if (data.toString().includes('exit')) process.exit(0);
});
socket.on('end', () => process.exit(0));
setTimeout(() => process.exit(70), 15000);
`, { mode: 0o755 });
  vi.stubEnv("PATH", `${join(root, "bin")}:/usr/bin:/bin:/usr/sbin:/sbin`);
  await mkdir(join(agentDir, "agents"));
  await writeFile(join(agentDir, "agents/finite.md"), "---\nname: finite\ndescription: Offline fixture\ntools: []\n---\nFinite local process only.\n");
  const runtime = new PiSdkRuntime({ agentDir, modelPattern: "w0b-offline/finite",
    createServices: (options) => { bus = options.resourceLoaderOptions!.eventBus!; return createAgentSessionServices({ ...options, settingsManager: SettingsManager.inMemory({ packages: [], retry: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 100 } }) }); },
    createSessionFromServices: async (options) => { const result = await createAgentSessionFromServices({ ...options, noTools: "builtin" }); session = result.session; return result; },
    resourceLoaderOptions: { additionalExtensionPaths: ["bash-async", "subagent"].map(name => join(root, "packages", name, "index.ts")), noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi) => {
      api = pi;
      pi.events.on(ASYNC_TASK_CONTRACT, (data) => { frames.push(structuredClone(data) as AsyncTaskHostMessage); });
      pi.registerProvider("w0b-offline", { baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "w0b-offline", models: [{ id: "finite", name: "Finite", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }], streamSimple(model, context) {
        requests.push(JSON.parse(JSON.stringify(context)));
        const stream = createAssistantMessageEventStream();
        const toolCall = requests.length === 1;
        const message: AssistantMessage = { role: "assistant", content: toolCall ? (Array.isArray(tool) ? tool : [tool]).map((item, index) => ({ type: "toolCall" as const, id: `actual-provider-call-${index}`, name: item.name, arguments: item.arguments })) : [{ type: "text", text: "W0B acknowledged actual result" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: toolCall ? "toolUse" : "stop", timestamp: Date.now() };
        stream.push({ type: "start", partial: message });
        stream.push({ type: "done", reason: toolCall ? "toolUse" : "stop", message });
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
  await supervisor.createEmptyPickleSession({ id: "ctx", source: "text", capturedAt: new Date().toISOString(), cwd: root, screenshots: [], inkMarks: [], warnings: [] }, true);
  cleanups.push(async () => {
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  });
  await vi.waitFor(() => expect(handle.asyncTasks?.coverage().tracking).toBe("ready"));
  expect(session.getAllTools().map(tool => tool.name)).toEqual(expect.arrayContaining(["bash_async", "subagent"]));
  expect(handle.asyncTasks?.coverage().expectedProviders).toEqual(expect.arrayContaining(["bash-async", "subagent"]));
  async function drainEvents() {
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  }
  return { root, runtime, bus, child: child.promise, handle, session, supervisor, store, requests, frames, api, events, projections, transactions, notifications,
    drainEvents, emitRuntime: (event: RuntimeEvent) => eventTarget.applyRuntimeEvent("session-sdk", event) };
}


it("holds actual bash admission until the approval is durable and consumes its real result", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W0B_REAL_RESULT; printf spawn >> actual-spawns", timeout: 5 } });
  const entered = deferred<void>(), release = deferred<void>();
  const save = f.store.save.bind(f.store);
  let held = false;
  vi.spyOn(f.store, "save").mockImplementation(async state => {
    if (!held && state.asyncTasks?.some(task => task.registration === "approved")) {
      held = true; entered.resolve(); await release.promise;
    }
    await save(state);
  });
  const run = f.supervisor.followUp("session-sdk", "Run the finite tool");
  try {
    await entered.promise;
    expect(existsSync(join(f.root, "actual-spawns"))).toBe(false);
    expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks ?? []).toEqual([]);
    expect(f.frames.some(frame => frame.type === "task-register-result")).toBe(false);
    expect(f.frames.some(frame => frame.type === "task-update" && JSON.stringify(frame).includes('"running"'))).toBe(false);
  } finally { release.resolve(); }
  await run;
  try { await vi.waitFor(async () => {
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk?.completionTickets?.length).toBe(1);
    expect(disk?.completionTickets?.[0]?.state).toBe("handled");
    expect(disk?.status).toBe("completed");
  }, { timeout: 10000 }); } finally { console.log("W0B_ADMISSION_TRACE", JSON.stringify({ disk: await f.store.loadReadOnly("session-sdk"), frames: f.frames, events: f.events, requests: f.requests })); }
  await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "succeeded", presence: "settled", registration: "spawned" });
  const completionId = disk!.completionTickets![0]!.completionId;
  expect(f.session.messages).toContainEqual(expect.objectContaining({ role: "custom", customType: "bash-async-completion", details: expect.objectContaining({ asyncTasks: expect.objectContaining({ completionIds: [completionId] }) }) }));
  expect(await readFile(disk!.piSessionFilePath!, "utf8")).toContain(completionId);
  expect(f.projections.some(state => state.completionTickets?.[0]?.state === "processing")).toBe(true);
  expect(JSON.stringify(f.requests.at(-1))).not.toContain(completionId);
  expect(completionText(f.requests.at(-1), disk!.asyncTasks![0]!.taskId)).toContain("\nW0B_REAL_RESULT\n");
  expect(disk?.finalAnswer).toBe("W0B acknowledged actual result");
  expect(await readFile(join(f.root, "actual-spawns"), "utf8")).toBe("spawn");
  expect(f.frames.filter(frame => frame.type === "completion-observed")).toHaveLength(1);
  expect(f.notifications).toHaveLength(1);
  console.log("W0B_DURABLE_TRACE", JSON.stringify({ disk, projections: f.projections, transactions: f.transactions, frames: f.frames }));
}, 20000);

it("records actual subagent validation rejection before any runner starts", async () => {
  const f = await fixture({ name: "subagent", arguments: { command: "subagent run w0b-nonexistent --isolated -- finite" } });
  await f.supervisor.followUp("session-sdk", "Reject the unknown agent");
  await vi.waitFor(() => expect(f.requests.length).toBeGreaterThanOrEqual(2));
  await f.session.waitForIdle(); await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  console.log("W0B_REJECTION_TRACE", JSON.stringify({ disk, frames: f.frames, transactions: f.transactions }));
  expect(existsSync(join(f.root, "spawns"))).toBe(false);
  expect(disk?.asyncTasks).toHaveLength(1);
  expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "failed", presence: "settled", registration: "starting" });
  expect(disk?.asyncWorkSummary).toMatchObject({ activeRootCount: 0, canReleaseRuntime: true });
  expect(disk?.status).toBe("completed");
}, 20000);

it("retains a real subagent result until its original child exits, then settles atomically", async () => {
  const f = await fixture({ name: "subagent", arguments: { command: "subagent run finite --isolated -- finite" } });
  await f.supervisor.followUp("session-sdk", "Run the finite child");
  const child = await f.child;
  child.write("result\n");
  await vi.waitFor(async () => {
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk?.completionTickets?.[0]?.state).toBe("handled");
    expect(disk?.asyncWorkSummary?.activeRootCount).toBe(1);
  }, { timeout: 10000 });
  await f.drainEvents();
  const before = await f.store.loadReadOnly("session-sdk");
  expect(before?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  expect(f.notifications).toEqual([]);
  const requests = f.requests.length;
  const transactionStart = f.transactions.length;
  const closed = once(child, "close"); child.end("exit\n"); await closed;
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"));
  await f.drainEvents();
  const after = await f.store.loadReadOnly("session-sdk");
  expect(after?.asyncTasks?.every(task => task.presence === "settled")).toBe(true);
  expect(after?.messages?.filter(message => message.kind === "agent_text")).toEqual(before?.messages?.filter(message => message.kind === "agent_text"));
  expect(f.requests).toHaveLength(requests);
  expect(f.notifications).toHaveLength(1);
  expect(await readFile(join(f.root, "spawns"), "utf8")).toBe("spawn\n");
  expect(JSON.stringify(f.requests.at(-1))).toContain("W0B_FINITE_CHILD_RESULT");
  expect(f.transactions.slice(transactionStart).some(mutations => mutations.some(mutation => mutation.type === "asyncTaskDetailSet") && mutations.some(mutation => mutation.type === "metaPatch" && mutation.patch.status === "completed"))).toBe(true);
  console.log("W0B_LATE_EXIT_TRACE", JSON.stringify({ before, after, transactions: f.transactions }));
}, 20000);

it("recovers a lost real registration reply by querying the same task without duplicate execution", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W0B_QUERY_RESULT; printf spawn >> query-spawns", timeout: 5 } });
  const emit = f.bus.emit.bind(f.bus);
  let lost: AsyncTaskHostMessage | undefined;
  vi.spyOn(f.bus, "emit").mockImplementation((channel, data) => {
    const frame = data as AsyncTaskHostMessage;
    if (channel === ASYNC_TASK_CONTRACT && frame.type === "task-register-result" && frame.outcome === "accepted" && !lost) { lost = structuredClone(frame); return; }
    emit(channel, data);
  });
  await f.supervisor.followUp("session-sdk", "Run after reply loss");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled"), { timeout: 10000 });
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.asyncTasks).toHaveLength(1);
  expect(f.frames.filter(frame => frame.type === "registration-query")).toHaveLength(1);
  expect(f.frames.find(frame => frame.type === "registration-query")).toMatchObject({ taskId: disk?.asyncTasks?.[0]?.taskId });
  expect(f.frames.filter(frame => frame.type === "task-register")).toHaveLength(1);
  expect(lost).toMatchObject({ taskId: disk?.asyncTasks?.[0]?.taskId, grantId: disk?.asyncTasks?.[0]?.grantId });
  expect(await readFile(join(f.root, "query-spawns"), "utf8")).toBe("spawn");
}, 15000);

it("abandons an actual bash registration when abort wins during its durable approval", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "touch must-not-spawn", timeout: 5 } });
  const entered = deferred<void>(), release = deferred<void>();
  const save = f.store.save.bind(f.store); let held = false;
  vi.spyOn(f.store, "save").mockImplementation(async state => {
    if (!held && state.asyncTasks?.some(task => task.registration === "approved")) { held = true; entered.resolve(); await release.promise; }
    await save(state);
  });
  await f.supervisor.followUp("session-sdk", "Abort before spawn");
  await entered.promise;
  const abort = f.handle.abort();
  release.resolve(); await abort;
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.[0]?.registration).toBe("abandoned"), { timeout: 10000 });
  expect(existsSync(join(f.root, "must-not-spawn"))).toBe(false);
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.[0]).toMatchObject({ execution: "cancelled", presence: "settled" });
}, 15000);

it("retries a failed real-result settlement save without replaying model or execution", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W0B_SAVE_RESULT", timeout: 5 } });
  const save = f.store.save.bind(f.store);
  let failed = false;
  const fault = vi.spyOn(f.store, "save").mockImplementation(async state => {
    if (state.completionTickets?.some(ticket => ticket.state === "handled")) { failed = true; throw new Error("W0B injected settlement disk failure"); }
    await save(state);
  });
  await f.supervisor.followUp("session-sdk", "Run and retain the result");
  await vi.waitFor(() => expect(failed).toBe(true), { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const before = await f.store.loadReadOnly("session-sdk");
  expect(before?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  expect(before?.completionTickets?.[0]?.state).toBe("processing");
  expect(f.notifications).toEqual([]);
  const requests = f.requests.length;
  fault.mockRestore();
  await f.supervisor.retryAsyncWorkPersistence("session-sdk");
  console.log("W0B_RETRY_DIAGNOSTIC", JSON.stringify({ disk: await f.store.loadReadOnly("session-sdk"), events: f.events, frames: f.frames }));
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"));
  await f.drainEvents();
  const after = await f.store.loadReadOnly("session-sdk");
  expect(after?.completionTickets?.[0]?.state).toBe("handled");
  expect(f.requests).toHaveLength(requests);
  expect(f.frames.filter(frame => frame.type === "task-register")).toHaveLength(1);
  expect(f.notifications).toHaveLength(1);
  await f.supervisor.retryAsyncWorkPersistence("session-sdk");
  expect((await f.store.loadReadOnly("session-sdk"))?.messages).toEqual(after?.messages);
  expect(f.notifications).toHaveLength(1);
  console.log("W0B_SAVE_RETRY_TRACE", JSON.stringify({ before, after, requests }));
}, 15000);

it("keeps the real 500ms zero-execution gap retained and merges two completion IDs", async () => {
  const f = await fixture(["A", "B"].map(value => ({ name: "bash_async", arguments: { action: "start", command: `printf W0B_BATCH_${value}`, timeout: 5 } })));
  await f.supervisor.followUp("session-sdk", "Run both independent finite jobs");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.filter(ticket => ticket.state === "handled")).toHaveLength(2), { timeout: 10000 });
  await f.drainEvents();
  const gap = f.projections.find(state => state.asyncTasks?.length === 2 && state.asyncTasks.every(task => task.execution === "succeeded" && task.presence === "settled") && state.completionTickets?.every(ticket => ticket.state === "pending"));
  expect(gap).toMatchObject({ status: "running", asyncWorkSummary: { activeRootCount: 0, pendingCompletionCount: 2, canReleaseRuntime: false } });
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(new Set(disk?.completionTickets?.map(ticket => ticket.deliveryId)).size).toBe(1);
  expect(f.frames.filter(frame => frame.type === "completion-observed")).toHaveLength(1);
  expect(f.frames.find(frame => frame.type === "completion-observed")).toMatchObject({ completionIds: expect.arrayContaining(disk!.completionTickets!.map(ticket => ticket.completionId)) });
  expect(JSON.stringify(f.requests.at(-1))).toContain("W0B_BATCH_A");
  expect(JSON.stringify(f.requests.at(-1))).toContain("W0B_BATCH_B");
  expect(f.notifications).toHaveLength(1);
  expect(f.projections.filter(state => state.status === "completed").every(state => state.completionTickets?.length === 2 && state.completionTickets.every(ticket => ticket.state === "handled"))).toBe(true);
  console.log("W0B_BATCH_TRACE", JSON.stringify({ gap, disk }));
}, 15000);

it("does not revive actual provider completion payloads when admission closes and reopens", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W0B_OLD_GENERATION", timeout: 5 } });
  await f.supervisor.followUp("session-sdk", "Run the old generation");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("pending"), { interval: 5 });
  await f.handle.asyncTasks!.closeAdmission();
  await f.handle.asyncTasks!.control(f.handle.asyncTasks!.snapshot().tasks[0]!, "closeAdmission");
  await f.handle.asyncTasks!.reopenAdmission();
  await f.supervisor.followUp("session-sdk", "New authorized generation");
  await vi.waitFor(() => expect(f.requests.length).toBeGreaterThanOrEqual(3));
  await f.session.waitForIdle(); await f.drainEvents();
  expect(JSON.stringify(f.requests.at(-1))).not.toContain("bash-async-completion");
  expect(f.frames.filter(frame => frame.type === "completion-observed")).toEqual([]);
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.completionTickets?.[0]?.state).toBe("suppressed");
  expect(disk?.asyncControl?.controlGeneration).toBe(2);
}, 15000);

it.each([0, 31_000])("automatically consumes an actual result after held compaction without new input (hold %ims)", async holdMs => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W0B_COMPACTION_RESULT; printf spawn >> compact-spawns", timeout: 5 } });
  const entered = deferred<void>(), release = deferred<void>();
  f.api.on("session_before_compact", async event => {
    entered.resolve(); await release.promise;
    return { compaction: { summary: "Offline held compaction", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
  });
  await f.supervisor.followUp("session-sdk", "Start before compaction");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("pending"), { interval: 5 });
  await f.session.waitForIdle();
  const compact = f.session.compact();
  await entered.promise;
  try {
    await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("submitted"), { timeout: 5000 });
    expect(f.frames.filter(frame => frame.type === "completion-observed")).toEqual([]);
    expect((await f.store.loadReadOnly("session-sdk"))?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
    const started = performance.now();
    // Real elapsed time crosses the former production deadline while SDK, IO and
    // provider batching continue on their normal clocks. This does not signal readiness.
    if (holdMs) await new Promise(resolve => setTimeout(resolve, holdMs));
    console.log("W0B_COMPACTION_DURATION", JSON.stringify({ holdMs, elapsedMs: performance.now() - started }));
  } finally { release.resolve(); await compact; }
  await f.session.waitForIdle();
  console.log("W0B_COMPACTION_HELD_TRACE", JSON.stringify({ disk: await f.store.loadReadOnly("session-sdk"), requests: f.requests.length }));
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled"), { timeout: 5000 });
  await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(completionText(f.requests.at(-1), disk!.asyncTasks![0]!.taskId)).toContain("\nW0B_COMPACTION_RESULT\n");
  expect(JSON.stringify(f.requests.at(-1))).not.toContain(disk!.completionTickets![0]!.completionId);
  expect(f.requests).toHaveLength(3);
  expect(disk).toMatchObject({ status: "completed", finalAnswer: "W0B acknowledged actual result", asyncWorkSummary: { canReleaseRuntime: true } });
  expect(f.projections.at(-1)?.completionTickets?.[0]?.state).toBe("handled");
  expect(f.frames.filter(frame => frame.type === "completion-observed")).toHaveLength(1);
  expect(f.notifications).toHaveLength(1);
  expect(await readFile(join(f.root, "compact-spawns"), "utf8")).toBe("spawn");
  expect(f.frames.filter(frame => frame.type === "task-register")).toHaveLength(1);
  console.log("W0B_COMPACTION_AUTO_TRACE", JSON.stringify({ disk, request: f.requests.at(-1), frames: f.frames, projection: f.projections.at(-1) }));
}, 45000);

it.each(["abort", "close-reopen"])("prevents a later model call when %s wins during held compaction", async action => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W0B_STOPPED_RESULT", timeout: 5 } });
  const entered = deferred<void>(), release = deferred<void>();
  f.api.on("session_before_compact", async event => {
    entered.resolve(); await release.promise;
    return { compaction: { summary: "Offline held compaction", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } };
  });
  await f.supervisor.followUp("session-sdk", "Start before stop");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("pending"), { interval: 5 });
  await f.session.waitForIdle();
  const compact = f.session.compact().catch(error => error as Error);
  let stop: Promise<void> | undefined;
  await entered.promise;
  try {
    await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("submitted"));
    expect(f.requests).toHaveLength(2);
    if (action === "abort") stop = f.handle.abort();
    else {
      await f.handle.asyncTasks!.closeAdmission();
      await f.handle.asyncTasks!.control(f.handle.asyncTasks!.snapshot().tasks[0]!, "closeAdmission");
      await f.handle.asyncTasks!.reopenAdmission();
    }
  } finally { release.resolve(); await compact; await stop; }
  await f.session.waitForIdle(); await f.drainEvents();
  expect(f.requests).toHaveLength(2);
  expect(f.frames.filter(frame => frame.type === "completion-observed")).toHaveLength(0);
  expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).not.toBe("handled");
  if (action === "close-reopen") {
    await f.supervisor.followUp("session-sdk", "New authorized generation");
    await vi.waitFor(() => expect(f.requests).toHaveLength(3));
    await f.session.waitForIdle(); await f.drainEvents();
    const last = f.requests.at(-1) as { messages: Array<{ role: string; content: unknown }> };
    expect(JSON.stringify(last.messages.filter(message => message.role === "user"))).not.toContain("W0B_STOPPED_RESULT");
    // A submitted delivery may already have entered a model elsewhere. Closing
    // admission preserves its evidence; only never-submitted tickets are suppressed.
    expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("submitted");
  }
  console.log("W0B_COMPACTION_STOP_TRACE", JSON.stringify({ action, disk: await f.store.loadReadOnly("session-sdk"), requests: f.requests }));
}, 15000);

it("keeps a durably approved unknown registration non-releasable after owner loss and reload", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "touch must-not-spawn", timeout: 5 } });
  const emit = f.bus.emit.bind(f.bus);
  let partitioned = false;
  vi.spyOn(f.bus, "emit").mockImplementation((channel, data) => {
    const frame = data as AsyncTaskHostMessage;
    if (channel === ASYNC_TASK_CONTRACT && frame.type === "task-register-result" && frame.outcome === "accepted") { partitioned = true; return; }
    if (partitioned && channel === ASYNC_TASK_CONTRACT) return;
    emit(channel, data);
  });
  await f.supervisor.followUp("session-sdk", "Lose the owner before permission arrives");
  await vi.waitFor(() => expect(partitioned).toBe(true));
  await f.handle.abort();
  await f.handle.dispose?.();
  await f.drainEvents();
  expect(existsSync(join(f.root, "must-not-spawn"))).toBe(false);
  const persisted = await f.store.loadReadOnly("session-sdk");
  expect(persisted?.asyncTasks?.[0]).toMatchObject({ registration: "approved", presence: "unknown" });
  expect(persisted?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  const restarted = new SessionSupervisor(f.runtime, new SessionStore(join(f.root, "store")), { enableAsyncTasksForSession: () => true });
  await restarted.load();
  expect(restarted.get("session-sdk")?.asyncTasks).toEqual(persisted?.asyncTasks);
  expect(restarted.get("session-sdk")?.asyncWorkSummary).toMatchObject({ canReleaseRuntime: false, uncertainExecutionCount: 1 });
  console.log("W0B_OWNER_LOSS_TRACE", JSON.stringify({ persisted, reloaded: restarted.get("session-sdk") }));
}, 15000);
