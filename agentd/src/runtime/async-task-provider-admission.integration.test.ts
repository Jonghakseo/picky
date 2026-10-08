import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { createServer, type Socket } from "node:net";
import WebSocket from "ws";
import { AgentdServer } from "../server.js";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createAssistantMessageEventStream, type AssistantMessage, type ToolCall } from "@earendil-works/pi-ai";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, VERSION, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { ASYNC_TASK_CONTRACT, type AsyncTaskCommand, type AsyncTaskHostMessage } from "../domain/async-task-contract.js";
import { PROTOCOL_VERSION, type EventEnvelope, type PickyAgentSession, type PickySessionProjectionMutation } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import { validatePickyCliContext } from "./picky-cli-context.js";
import { readCliCallerContext } from "../cli/caller-context.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "./types.js";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); vi.unstubAllEnvs(); });
function userTexts(request: unknown): string[] {
  const context = request as { messages: Array<{ role: string; content: unknown }> };
  return context.messages.filter(message => message.role === "user").map(message =>
    typeof message.content === "string" ? message.content : (message.content as Array<{ type: string; text?: string }>).filter(part => part.type === "text").map(part => part.text).join("\n"));
}
function nativeCancelIds(frames: AsyncTaskHostMessage[]): string[] {
  return frames.flatMap(frame => frame.type === "control-request" && frame.action === "cancel" ? [frame.taskId!] : []);
}
function completionText(request: unknown, taskId: string): string {
  const context = request as { messages: Array<{ role: string; content: unknown }> };
  const texts = context.messages.filter(message => message.role === "user").map(message =>
    typeof message.content === "string" ? message.content : (message.content as Array<{ type: string; text?: string }>).filter(part => part.type === "text").map(part => part.text).join("\n"));
  const matching = texts.filter(text => text.includes(`[bash_async ${taskId}]`));
  expect(matching).toHaveLength(1);
  return matching[0]!;
}

// Keep required async-provider coverage independent of optional, historical
// memory/cron integration suites that use PICKY_TEST_EXTENSION_ROOT.
function providerPackageRoot(): string {
  return process.env.PICKY_TEST_ASYNC_PROVIDER_ROOT ?? process.env.PICKY_TEST_EXTENSION_ROOT
    ?? fileURLToPath(new URL("../../vendor/async-task-providers", import.meta.url));
}

// bash_async (0.2.3+) delivers a completion inside the same agent run when the job finishes
// before the run's final turn. Scenarios that need a completion still pending after the run
// goes idle must finish the job after the offline model's immediate final turn.
const AFTER_IDLE = "sleep 0.3; ";

type ToolInput = { name: string; arguments: ToolCall["arguments"] };
// A function receives the 1-based model request number and returns that request's tool calls.
type ToolPlan = ToolInput | ToolInput[] | ((request: number) => ToolInput[]);
async function fixture(tool: ToolPlan, includeBuiltinTools = false) {
  expect(VERSION).toBe("1.1.0");
  const extensionRoot = providerPackageRoot();
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
    if (process.env.PICKY_TEST_EXTENSION_ARTIFACT === "1") {
      await symlink(join(extensionRoot, "node_modules"), join(root, "packages", name, "node_modules"));
    }
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
appendFileSync(${JSON.stringify(join(root, "child-pids"))}, String(process.pid) + '\\n');
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
    createSessionFromServices: async (options) => { const result = await createAgentSessionFromServices({ ...options, noTools: includeBuiltinTools ? undefined : "builtin" }); session = result.session; return result; },
    resourceLoaderOptions: { additionalExtensionPaths: ["bash-async", "subagent"].map(name => join(root, "packages", name, "index.ts")), noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi) => {
      api = pi;
      pi.events.on(ASYNC_TASK_CONTRACT, (data) => { frames.push(structuredClone(data) as AsyncTaskHostMessage); });
      pi.registerProvider("w0b-offline", { baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "w0b-offline", models: [{ id: "finite", name: "Finite", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }], streamSimple(model, context) {
        requests.push(JSON.parse(JSON.stringify(context)));
        const stream = createAssistantMessageEventStream();
        const calls = typeof tool === "function" ? tool(requests.length) : requests.length === 1 ? (Array.isArray(tool) ? tool : [tool]) : [];
        const toolCall = calls.length > 0;
        const message: AssistantMessage = { role: "assistant", content: toolCall ? calls.map((item, index) => ({ type: "toolCall" as const, id: `actual-provider-call-${index}`, name: item.name, arguments: item.arguments })) : [{ type: "text", text: "W0B acknowledged actual result" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: toolCall ? "toolUse" : "stop", timestamp: Date.now() };
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
    if (supervisor.get("session-sdk")) await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  });
  await vi.waitFor(() => expect(handle.asyncTasks?.coverage().tracking).toBe("ready"));
  expect(session.getAllTools().map(tool => tool.name)).toEqual(expect.arrayContaining(["bash_async", "subagent"]));
  expect(handle.asyncTasks?.coverage().expectedProviders).toEqual(expect.arrayContaining(["bash-async", "subagent"]));
  async function drainEvents() {
    while (pending.size) await Promise.allSettled([...pending]);
    await supervisor.withSessionProjectionBarrier("session-sdk", async () => {});
  }
  return { root, runtime, bus, child: child.promise, childSockets: sockets, handle, session, supervisor, store, requests, frames, api, events, projections, transactions, notifications,
    drainEvents, emitRuntime: (event: RuntimeEvent) => eventTarget.applyRuntimeEvent("session-sdk", event) };
}


it.each(["bash", "bash_async"])("binds real %s execution to the hosted session and invalidates it on disposal", async (toolName) => {
  const previousContext = process.env.PICKY_CLI_CONTEXT;
  const command = 'printf "%s" "$PICKY_CLI_CONTEXT" > caller-context.json; printf "%s" "$PI_SESSION_ID" > caller-pi-id';
  const f = await fixture({ name: toolName, arguments: toolName === "bash" ? { command } : { action: "start", command, timeout: 5 } }, true);
  await f.supervisor.followUp("session-sdk", "Write the calling session identity");
  await vi.waitFor(() => expect(existsSync(join(f.root, "caller-pi-id"))).toBe(true));
  const rawContext = await readFile(join(f.root, "caller-context.json"), "utf8");
  const piId = await readFile(join(f.root, "caller-pi-id"), "utf8");
  const caller = readCliCallerContext({ PICKY_CLI_CONTEXT: rawContext, PI_SESSION_ID: piId });
  expect(caller.sessionId).toBe("session-sdk");
  expect(caller.piSessionId).toBe(f.session.sessionManager.getSessionId());
  expect(() => validatePickyCliContext(caller)).not.toThrow();
  expect(process.env.PICKY_CLI_CONTEXT).toBe(previousContext);
  await f.handle.dispose?.();
  expect(() => validatePickyCliContext(caller)).toThrow();
});

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
  expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "succeeded", presence: "settled", registration: "spawned",
    details: { startedAt: expect.any(String), finishedAt: expect.any(String), elapsedMs: expect.any(Number) } });
  expect(f.projections.some(state => state.asyncTasks?.some(task =>
    typeof task.details?.elapsedMs === "number" && task.details.elapsedMs >= 0))).toBe(true);
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
  expect(after?.asyncTasks?.every(task => typeof task.details?.startedAt === "string"
    && typeof task.details.finishedAt === "string" && typeof task.details.elapsedMs === "number"
    && task.details.elapsedMs >= 0)).toBe(true);
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

it.each(["before", "after"] as const)("does not revive actual provider completion payloads when admission closes and reopens (%s old continuation)", async ordering => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: `${AFTER_IDLE}printf W0B_OLD_GENERATION`, timeout: 5 } });
  const entered = deferred<void>(), release = deferred<void>();
  let contexts = 0;
  f.api.on("context_with_system", async () => {
    if (++contexts === 2 && ordering === "before") { entered.resolve(); await release.promise; }
  });
  const sdkEvents: unknown[] = [];
  const unsubscribe = f.session.subscribe(event => { sdkEvents.push(structuredClone(event)); });
  cleanups.push(async () => { release.resolve(); unsubscribe(); });
  await f.supervisor.followUp("session-sdk", "Run the old generation");
  if (ordering === "before") await entered.promise;
  else await f.session.waitForIdle();
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("pending"), { interval: 5 });
  await f.handle.asyncTasks!.closeAdmission();
  await f.handle.asyncTasks!.control(f.handle.asyncTasks!.snapshot().tasks[0]!, "closeAdmission");
  release.resolve();
  await f.session.waitForIdle();
  const oldRequests = f.requests.length;
  await f.handle.asyncTasks!.reopenAdmission();
  await f.supervisor.followUp("session-sdk", "New authorized generation");
  await f.session.waitForIdle(); await f.drainEvents();
  await vi.waitFor(() => expect(f.requests.some(request => userTexts(request).includes("New authorized generation"))).toBe(true));
  await f.session.waitForIdle(); await f.drainEvents();
  console.log("W5C_RACE_TRACE", JSON.stringify({ ordering, oldRequests, requests: f.requests, sdkEvents, frames: f.frames, disk: await f.store.loadReadOnly("session-sdk"), projection: f.projections.at(-1) }));
  // Closing before the post-tool context reaches the model legitimately removes
  // that old request. Fresh input must still reach the model exactly once.
  const freshRequests = f.requests.filter(request => userTexts(request).includes("New authorized generation"));
  expect(freshRequests).toHaveLength(1);
  expect(f.requests).toHaveLength(oldRequests + 1);
  expect(userTexts(freshRequests[0]).join("\n")).not.toContain("W0B_OLD_GENERATION");
  expect(f.frames.filter(frame => frame.type === "completion-observed")).toEqual([]);
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.completionTickets?.[0]?.state).toBe("suppressed");
  expect(disk?.asyncControl?.controlGeneration).toBe(2);
  expect(f.projections.at(-1)?.completionTickets).toEqual(disk?.completionTickets);
  expect(f.projections.at(-1)?.asyncControl?.controlGeneration).toBe(2);
}, 15000);

it.each([0, 31_000])("automatically consumes an actual result after held compaction without new input (hold %ims)", async holdMs => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: `${AFTER_IDLE}printf W0B_COMPACTION_RESULT; printf spawn >> compact-spawns`, timeout: 5 } });
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
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: `${AFTER_IDLE}printf W0B_STOPPED_RESULT`, timeout: 5 } });
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

it("W5 explicitly reopens actual providers after settled stop and executes a new-generation bash task", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "printf W5_REOPEN_RESULT", timeout: 5 } });
  const stopped = await f.supervisor.asyncControls.stop("session-sdk", "w5-stop-empty");
  expect(stopped.outcome).toBe("settled");
  const closedGeneration = stopped.controlGeneration;
  await f.supervisor.followUp("session-sdk", "Run a fresh authorized task");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled"), { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.asyncTasks?.[0]).toMatchObject({ execution: "succeeded", presence: "settled" });
  expect(disk!.asyncTasks![0]!.controlGeneration).toBeGreaterThan(closedGeneration);
  expect(completionText(f.requests.at(-1), disk!.asyncTasks![0]!.taskId)).toContain("W5_REOPEN_RESULT");
  expect(f.frames.filter((frame) => frame.type === "host-state" && frame.admissionState === "open" && frame.controlGeneration > closedGeneration).map((frame) => frame.providerId)).toEqual(expect.arrayContaining(["bash-async", "subagent"]));
  expect(f.projections.at(-1)?.asyncWorkSummary?.canReleaseRuntime).toBe(true);
}, 15000);

async function verifyPackedFollowUp(f: Awaited<ReturnType<typeof fixture>>, mode: string, projectionStart: number, modelRequestsBeforeStop: number, cancellationCount: number): Promise<void> {
  await f.supervisor.followUp("session-sdk", `Continue after ${mode} stop`);
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.finalAnswer).toBe("W0B acknowledged actual result"), { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const after = await f.store.loadReadOnly("session-sdk");
  expect(after?.messages?.filter(message => message.kind === "system" && message.text === "Cancelled by user")).toHaveLength(cancellationCount);
  expect(after?.asyncWorkSummary).toMatchObject({ attentionCount: 0, canReleaseRuntime: true });
  expect(f.projections.slice(projectionStart).every(projection => projection.asyncWorkSummary?.attentionCount === 0 && projection.status !== "blocked" && (projection.messages?.filter(message => message.kind === "system" && message.text === "Cancelled by user").length ?? 0) === cancellationCount)).toBe(true);
  expect(f.requests).toHaveLength(modelRequestsBeforeStop + 1);
  expect(userTexts(f.requests.at(-1))).toContain(`Continue after ${mode} stop`);
  expect(JSON.stringify(f.requests.at(-1))).not.toMatch(/Subagent execution was aborted|subagent batch .* aborted/);
}

it.each([
  { mode: "single", commands: [{ name: "subagent", arguments: { command: "subagent run finite --isolated -- finite" } }], children: 1, roots: 1 },
  { mode: "batch", commands: [{ name: "subagent", arguments: { command: "subagent batch --isolated --agent finite --task first --agent finite --task second" } }], children: 2, roots: 1 },
  { mode: "parallel", commands: [
    { name: "subagent", arguments: { command: "subagent run finite --isolated -- first" } },
    { name: "subagent", arguments: { command: "subagent run finite --isolated -- second" } },
  ], children: 2, roots: 2 },
])("settles %s native background stop only after its real child exits, then follows up without warning spam", async ({ mode, commands, children, roots }) => {
  const f = await fixture(commands);
  await f.supervisor.followUp("session-sdk", `Start ${mode} native children`);
  await vi.waitFor(async () => {
    expect(f.childSockets).toHaveLength(children);
    expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.filter(task => task.presence === "active" && task.taskId !== task.rootTaskId)).toHaveLength(children);
  }, { timeout: 12000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const before = await f.store.loadReadOnly("session-sdk");
  expect(f.handle.isStreaming).toBe(false);
  expect(before?.asyncWorkSummary).toMatchObject({ activeRootCount: roots, attentionCount: 0, canReleaseRuntime: false });
  const pids = (await readFile(join(f.root, "child-pids"), "utf8")).trim().split("\n").map(Number);
  expect(pids).toHaveLength(children);
  const projectionStart = f.projections.length;
  const frameStart = f.frames.length;
  const modelRequestsBeforeStop = f.requests.length;
  const stop = await f.supervisor.asyncControls.stop("session-sdk", `packed-${mode}-stop`);
  expect(stop.outcome).toBe("settled");
  await f.drainEvents();
  const cancelled = await f.store.loadReadOnly("session-sdk");
  expect(cancelled?.asyncTasks?.filter(task => task.taskId !== task.rootTaskId)).toHaveLength(children);
  expect(cancelled?.asyncTasks?.every(task => task.presence === "settled" && !["queued", "running", "cancelling"].includes(task.execution))).toBe(true);
  expect(cancelled?.asyncWorkSummary).toMatchObject({ attentionCount: 0, canReleaseRuntime: true });
  expect(cancelled?.completionTickets?.every(ticket => ["suppressed", "handled"].includes(ticket.state))).toBe(true);
  const cancelIds = nativeCancelIds(f.frames.slice(frameStart));
  const rootIds = cancelled!.asyncTasks!.filter(task => task.taskId === task.rootTaskId).map(task => task.taskId);
  expect(cancelIds).toHaveLength(roots);
  expect(cancelIds.sort()).toEqual(rootIds.sort());
  for (const pid of pids) expect(() => process.kill(pid, 0)).toThrow(/ESRCH/);
  expect(f.projections.slice(projectionStart).every(projection => projection.asyncWorkSummary?.attentionCount === 0 && projection.status !== "blocked")).toBe(true);
  expect(f.events.filter(event => event.type === "extension_ui" && /warning|aborted/i.test(JSON.stringify(event)))).toEqual([]);
  await verifyPackedFollowUp(f, mode, projectionStart, modelRequestsBeforeStop, cancelled?.messages?.filter(message => message.kind === "system" && message.text === "Cancelled by user").length ?? 0);
  const after = await f.store.loadReadOnly("session-sdk");
  console.log("PACKED_NATIVE_STOP", JSON.stringify({ mode, pids, rootIds, cancelIds, stop: stop.outcome, before: [before?.status, before?.asyncWorkSummary], after: [after?.status, after?.asyncWorkSummary], v2: f.projections.slice(projectionStart).map(projection => [projection.status, projection.asyncWorkSummary?.attentionCount, projection.messages?.filter(message => message.text === "Cancelled by user").length]) }));
}, 25000);

it("explicitly deletes an archived Pickle through v2 after its connected native child exits", async () => {
  const f = await fixture({ name: "subagent", arguments: { command: "subagent run finite --isolated -- finite" } });
  await f.supervisor.followUp("session-sdk", "Start a child for explicit deletion");
  await vi.waitFor(async () => {
    expect(f.childSockets).toHaveLength(1);
    expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.some(task => task.presence === "active")).toBe(true);
    expect(f.handle.isStreaming).toBe(false);
  }, { timeout: 12000 });
  await f.session.waitForIdle(); await f.drainEvents();
  await f.supervisor.setSessionArchived("session-sdk", true, "continue");
  const before = await f.store.loadReadOnly("session-sdk");
  expect(before?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  const pid = Number((await readFile(join(f.root, "child-pids"), "utf8")).trim());
  const server = new AgentdServer({ port: 0, token: "fixture-token", supervisor: f.supervisor });
  const port = await server.start();
  cleanups.push(() => server.stop());
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=fixture-token`);
  const received: EventEnvelope[] = [];
  ws.on("message", data => received.push(JSON.parse(data.toString()) as EventEnvelope));
  cleanups.push(async () => { ws.close(); });
  await once(ws, "open");
  ws.send(JSON.stringify({ id: "v2-delete-register", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["sessionProjectionV2"] }));
  await vi.waitFor(() => expect(received.some(event => event.type === "sessionProjectionBootstrapComplete")).toBe(true));
  expect(received.some(event => event.type === "sessionProjectionSnapshot" && event.sessionId === "session-sdk")).toBe(true);
  const frameStart = f.frames.length;
  ws.send(JSON.stringify({ id: "explicit-delete", protocolVersion: PROTOCOL_VERSION, type: "deleteSession", sessionId: "session-sdk" }));
  await vi.waitFor(() => expect(received.some(event => event.type === "ack" && event.commandId === "explicit-delete")).toBe(true), { timeout: 20000 });
  expect(received.some(event => event.type === "error" && event.commandId === "explicit-delete")).toBe(false);
  expect(nativeCancelIds(f.frames.slice(frameStart))).toHaveLength(1);
  expect(() => process.kill(pid, 0)).toThrow(/ESRCH/);
  expect(f.supervisor.get("session-sdk")).toBeUndefined();
  expect(await f.store.loadReadOnly("session-sdk")).toBeUndefined();
  const reconnect = new WebSocket(`ws://127.0.0.1:${port}?token=fixture-token`);
  const replay: EventEnvelope[] = [];
  reconnect.on("message", data => replay.push(JSON.parse(data.toString()) as EventEnvelope));
  cleanups.push(async () => { reconnect.close(); });
  await once(reconnect, "open");
  reconnect.send(JSON.stringify({ id: "v2-after-delete", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["sessionProjectionV2"] }));
  await vi.waitFor(() => expect(replay.some(event => event.type === "sessionProjectionBootstrapComplete")).toBe(true));
  expect(replay.some(event => event.type === "sessionProjectionSnapshot" && event.sessionId === "session-sdk")).toBe(false);
  console.log("EXPLICIT_DELETE_NATIVE", JSON.stringify({ before: { status: before?.status, archived: before?.archived, tasks: before?.asyncTasks?.length }, pid, cancelIds: nativeCancelIds(f.frames.slice(frameStart)), childExited: true, ack: true, reconnectBootstrap: true, disk: await f.store.loadReadOnly("session-sdk"), replayIds: replay.filter(event => event.type === "sessionProjectionSnapshot").map(event => event.sessionId) }));
}, 30000);

it("cancels one packed native root without stopping the other, then settles the remaining child", async () => {
  const f = await fixture([
    { name: "subagent", arguments: { command: "subagent run finite --isolated -- first" } },
    { name: "subagent", arguments: { command: "subagent run finite --isolated -- second" } },
  ]);
  await f.supervisor.followUp("session-sdk", "Start independent finite children");
  await vi.waitFor(async () => {
    expect(f.childSockets).toHaveLength(2);
    expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.filter(task => task.taskId === task.rootTaskId && task.presence === "active")).toHaveLength(2);
  }, { timeout: 12000 });
  await vi.waitFor(async () => {
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk?.agentCycle?.phase).toBe("settled");
    expect(f.handle.isStreaming).toBe(false);
    expect(f.requests.length).toBeGreaterThanOrEqual(2);
  }, { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const roots = f.handle.asyncTasks!.snapshot().tasks.filter(task => task.taskId === task.rootTaskId);
  const owner = f.handle.asyncTasks!.owners!().find(entry => entry.providerId === "subagent")!;
  const context = f.supervisor.asyncControls.context("session-sdk");
  const frameStart = f.frames.length;
  let cancelled;
  try {
    cancelled = await f.supervisor.executeAsyncTaskCommand({ type: "cancelAsyncTask", requestId: "packed-one-root-cancel", sessionId: "session-sdk", owner, taskId: roots[0]!.taskId,
      daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: context.runtimeInstanceId!, workRevision: context.workRevision, controlGeneration: context.controlGeneration });
  } catch (error) {
    console.log("PACKED_NATIVE_INDIVIDUAL_DIAGNOSTIC", JSON.stringify({ before: context, after: f.supervisor.asyncControls.context("session-sdk"), disk: await f.store.loadReadOnly("session-sdk"), error: String(error) }));
    for (const socket of f.childSockets) socket.end("exit\n");
    await Promise.all(f.childSockets.map(socket => socket.destroyed ? Promise.resolve() : once(socket, "close")));
    throw error;
  }
  expect(cancelled.outcome).toBe("settled");
  await f.drainEvents();
  const afterOne = await f.store.loadReadOnly("session-sdk");
  expect(afterOne?.asyncTasks?.filter(task => task.rootTaskId === roots[0]!.taskId).every(task => task.presence === "settled")).toBe(true);
  expect(afterOne?.asyncTasks?.filter(task => task.rootTaskId === roots[1]!.taskId).some(task => task.presence === "active")).toBe(true);
  expect(afterOne?.asyncWorkSummary).toMatchObject({ activeRootCount: 1, attentionCount: 0, canReleaseRuntime: false });
  expect(nativeCancelIds(f.frames.slice(frameStart))).toEqual([roots[0]!.taskId]);
  const pids = (await readFile(join(f.root, "child-pids"), "utf8")).trim().split("\n").map(Number);
  expect(pids).toHaveLength(2);
  expect(pids.filter(pid => { try { process.kill(pid, 0); return true; } catch { return false; } })).toHaveLength(1);
  // Individual cancellation deliberately retains its model-target result;
  // wait for that separate turn before issuing the next control command.
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled"), { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const stopped = await f.supervisor.asyncControls.stop("session-sdk", "packed-remaining-root-stop");
  expect(stopped.outcome).toBe("settled");
  const lastCancelIds = nativeCancelIds(f.frames.slice(frameStart));
  expect(lastCancelIds).toEqual([roots[0]!.taskId, roots[1]!.taskId]);
  for (const pid of pids) expect(() => process.kill(pid, 0)).toThrow(/ESRCH/);
  const final = await f.store.loadReadOnly("session-sdk");
  expect(final?.asyncWorkSummary).toMatchObject({ attentionCount: 0, canReleaseRuntime: true });
  expect(f.events.filter(event => event.type === "extension_ui" && /warning|aborted/i.test(JSON.stringify(event)))).toEqual([]);
  console.log("PACKED_NATIVE_INDIVIDUAL", JSON.stringify({ pids, rootIds: roots.map(root => root.taskId), cancelIds: lastCancelIds, first: afterOne?.asyncWorkSummary, final: final?.asyncWorkSummary }));
}, 25000);

it("W5 guards direct SDK new, reload and rewind while a real child remains alive after model idle", async () => {
  const f = await fixture({ name: "subagent", arguments: { command: "subagent run finite --isolated -- finite" } });
  await f.supervisor.followUp("session-sdk", "Keep the child until its actual exit");
  const child = await f.child;
  child.write("result\n");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled"), { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const owner = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  await expect(f.handle.newSession!()).rejects.toThrow("Async work");
  await expect(f.handle.rewindToEntry!("unused-entry")).rejects.toThrow("Async work");
  await expect(f.handle.followUp({ text: "/reload", imagePaths: [] })).rejects.toThrow("Async work");
  expect(f.handle.asyncTasks!.coverage().runtimeInstanceId).toBe(owner);
  expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.[0]?.presence).toBe("active");
  const closed = once(child, "close"); child.end("exit\n"); await closed;
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.[0]?.presence).toBe("settled"));
  await f.drainEvents();
  const requestsBeforeReload = f.requests.length;
  await f.handle.followUp({ text: "/reload", imagePaths: [] });
  const reloadOwner = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  expect(reloadOwner).not.toBe(owner);
  await f.supervisor.followUp("session-sdk", "Fresh input after allowed reload");
  await vi.waitFor(() => expect(f.requests.some(request => userTexts(request).includes("Fresh input after allowed reload"))).toBe(true));
  await f.session.waitForIdle(); await f.drainEvents();
  expect(f.requests).toHaveLength(requestsBeforeReload + 1);
  expect(userTexts(f.requests.at(-1))).toEqual(["Keep the child until its actual exit", "Fresh input after allowed reload"]);
  const reloadDisk = await f.store.loadReadOnly("session-sdk");
  expect(reloadDisk?.agentCycle).toMatchObject({ runtimeInstanceId: reloadOwner, phase: "settled", outcome: "completed" });
  expect(f.projections.at(-1)?.agentCycle).toEqual(reloadDisk?.agentCycle);
  console.log("W5C_RELOAD_TRACE", JSON.stringify({ owner, reloadOwner, request: f.requests.at(-1), disk: reloadDisk, projection: f.projections.at(-1) }));
  await expect(f.handle.newSession!()).resolves.toMatchObject({ cancelled: false });
  const freshOwner = f.handle.asyncTasks!.coverage().runtimeInstanceId;
  expect(freshOwner).not.toBe(owner);
  const requestsBeforeFreshInput = f.requests.length;
  await f.supervisor.followUp("session-sdk", "Fresh input after allowed replacement");
  await vi.waitFor(() => expect(f.requests.some(request => userTexts(request).includes("Fresh input after allowed replacement"))).toBe(true));
  await f.session.waitForIdle(); await f.drainEvents();
  expect(f.requests).toHaveLength(requestsBeforeFreshInput + 1);
  expect(userTexts(f.requests.at(-1))).toEqual(["Fresh input after allowed replacement"]);
  const disk = await f.store.loadReadOnly("session-sdk");
  expect(disk?.agentCycle).toMatchObject({ runtimeInstanceId: freshOwner, phase: "settled", outcome: "completed" });
  expect(f.projections.at(-1)?.agentCycle).toEqual(disk?.agentCycle);
  console.log("W5C_REPLACEMENT_TRACE", JSON.stringify({ owner, freshOwner, request: f.requests.at(-1), disk, projection: f.projections.at(-1) }));
}, 20000);


type ProviderFixture = Awaited<ReturnType<typeof fixture>>;
type ProjectionWire = Extract<EventEnvelope, { type: "sessionProjectionSnapshot" | "sessionProjectionTransaction" | "sessionProjectionBootstrapComplete" }>;

async function replayRecorder(f: ProviderFixture, scenario: "bash" | "subagent") {
  const server = new AgentdServer({ port: 0, token: "w7-replay", supervisor: f.supervisor });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=w7-replay`);
  const wire: EventEnvelope[] = [];
  ws.on("message", data => wire.push(JSON.parse(String(data)) as EventEnvelope));
  cleanups.push(async () => { ws.close(); await server.stop(); });
  await once(ws, "open");
  ws.send(JSON.stringify({ id: "w7-register", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["sessionProjectionV2"] }));
  await vi.waitFor(() => expect(wire.some(event => event.type === "sessionProjectionBootstrapComplete")).toBe(true));
  const snapshots = wire.filter(event => event.type === "sessionProjectionSnapshot");
  expect(snapshots.map(event => event.sessionId)).toEqual(["session-sdk"]);
  const checkpoints: Array<{ name: string; through: number; disk: { revision: number; status: string; asyncTasks: PickyAgentSession["asyncTasks"]; completionTickets: PickyAgentSession["completionTickets"]; asyncWorkSummary: PickyAgentSession["asyncWorkSummary"]; agentCycle: PickyAgentSession["agentCycle"] } }> = [];
  async function checkpoint(name: string) {
    await f.drainEvents();
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk).toBeDefined();
    const revision = disk!.revision!;
    await vi.waitFor(() => expect(wire.some(event => event.type === "sessionProjectionTransaction" && event.sessionId === "session-sdk" && event.revision === revision)).toBe(true));
    const frames = wire.filter(event => event.type === "sessionProjectionSnapshot" || event.type === "sessionProjectionTransaction" || event.type === "sessionProjectionBootstrapComplete");
    const through = frames.findIndex(event => event.type === "sessionProjectionTransaction" && event.sessionId === "session-sdk" && event.revision === revision);
    expect(through).toBeGreaterThan(1);
    expect(frames.slice(through + 1).some(event => event.type === "sessionProjectionTransaction" && event.sessionId === "session-sdk")).toBe(false);
    checkpoints.push({ name, through, disk: { revision, status: disk!.status, asyncTasks: disk!.asyncTasks, completionTickets: disk!.completionTickets, asyncWorkSummary: disk!.asyncWorkSummary, agentCycle: disk!.agentCycle } });
  }
  async function finish() {
    const frames = wire.filter((event): event is ProjectionWire => event.type === "sessionProjectionSnapshot" || event.type === "sessionProjectionTransaction" || event.type === "sessionProjectionBootstrapComplete");
    expect(frames.at(-1)).toMatchObject({ type: "sessionProjectionTransaction", revision: checkpoints.at(-1)!.disk.revision });
    const epoch = frames[0]!.epoch;
    expect(frames.every(frame => frame.epoch === epoch)).toBe(true);
    let revision = snapshots[0]!.revision;
    for (const frame of frames) {
      if (frame.type !== "sessionProjectionTransaction") continue;
      expect(frame.baseRevision).toBe(revision);
      expect(frame.revision).toBe(revision + 1);
      revision = frame.revision;
    }
    expect(revision).toBe(checkpoints.at(-1)!.disk.revision);
    expect(checkpoints.map(point => point.through)).toEqual([...checkpoints.map(point => point.through)].sort((a, b) => a - b));
    for (const point of checkpoints) expect(frames[point.through]).toMatchObject({ type: "sessionProjectionTransaction", revision: point.disk.revision });
    expect(checkpoints.at(-1)!.disk).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: true } });
    if (scenario === "bash") expect(checkpoints[1]!.disk).toMatchObject({ status: "running", completionTickets: [{ state: "pending" }], asyncWorkSummary: { canReleaseRuntime: false } });
    else {
      expect(checkpoints[0]!.disk).toMatchObject({ status: "running", asyncWorkSummary: { canReleaseRuntime: false } });
      expect(checkpoints[0]!.disk.asyncTasks?.some(task => task.presence === "active")).toBe(true);
    }
    const providerRoot = providerPackageRoot();
    const hash = async (path: string) => createHash("sha256").update(await readFile(path)).digest("hex");
    const provenance = { scenario, sdkVersion: VERSION, nodeVersion: process.version, protocolVersion: PROTOCOL_VERSION,
      providerEntrySha256: { bash: await hash(join(providerRoot, "packages/bash-async/index.ts")), subagent: await hash(join(providerRoot, "packages/subagent/index.ts")) },
      runtimeSha256: await hash(fileURLToPath(new URL("./pi-sdk-runtime.ts", import.meta.url))),
      sdkEntrySha256: await hash(join(process.cwd(), "node_modules/@earendil-works/pi-coding-agent/dist/index.js")),
      providerPath: process.env.PICKY_TEST_EXTENSION_ARTIFACT === "1"
        ? "extracted npm pack packages/{bash-async,subagent}/index.ts copied into isolated Pi resource loader"
        : "actual checkout packages/{bash-async,subagent}/index.ts copied into isolated Pi resource loader",
      inputPath: "supervisor.followUp -> offline model tool call -> real Pi SDK", sessionId: "session-sdk" };
    const raw = { provenance, frames, checkpoints };
    // Keep all frames and mutations. Replace only volatile string values, with one
    // stable token per distinct identity across the entire envelope.
    const uuids = new Map<string, string>();
    const times = new Map<string, string>();
    const sessionFiles = new Map<string, string>();
    const sessionPath = new RegExp(`${f.root}/home/\\.pi/agent/sessions/[^\\s\"]+\\.jsonl`, "g");
    const alias = (values: Map<string, string>, value: string, create: (index: number) => string) => {
      if (!values.has(value)) values.set(value, create(values.size + 1));
      return values.get(value)!;
    };
    const normalize = (value: unknown): unknown => {
      if (typeof value === "string") return value.replace(sessionPath, match => alias(sessionFiles, match, index => `<fixture-root>/home/.pi/agent/sessions/session-${index}.jsonl`))
        .replaceAll(f.root, "<fixture-root>")
        .replaceAll(f.root.split("/").at(-1)!, "<fixture-name>")
        .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, match => alias(uuids, match, index => `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`))
        .replace(/\b\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z\b/g, match => alias(times, match, index => new Date(Date.UTC(2026, 0, 1) + index).toISOString()));
      if (Array.isArray(value)) return value.map(normalize);
      if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item)]));
      return value;
    };
    const normalized = normalize(raw);
    if (process.env.W7_REPLAY_EXPORT_DIR) {
      await mkdir(process.env.W7_REPLAY_EXPORT_DIR, { recursive: true });
      await writeFile(join(process.env.W7_REPLAY_EXPORT_DIR, `${scenario}.json`), JSON.stringify(normalized, null, 2) + "\n");
    }
    if (process.env.W7_REPLAY_RAW_DIR) {
      await mkdir(process.env.W7_REPLAY_RAW_DIR, { recursive: true });
      await writeFile(join(process.env.W7_REPLAY_RAW_DIR, `${scenario}.json`), JSON.stringify(raw, null, 2) + "\n");
    }
    return { frames, checkpoints };
  }
  return { checkpoint, finish };
}

it("records real bash v2 bootstrap, retained pending completion, and durable settlement", async () => {
  const f = await fixture({ name: "bash_async", arguments: { action: "start", command: "sleep 0.4; printf W7_BASH_RESULT", timeout: 5 } });
  const recorder = await replayRecorder(f, "bash");
  await f.supervisor.followUp("session-sdk", "Run the finite bash job");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.[0]).toMatchObject({ execution: "running", presence: "active" }), { timeout: 7000 });
  await f.session.waitForIdle();
  await recorder.checkpoint("tool-returned-running");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("pending"), { timeout: 7000, interval: 5 });
  await recorder.checkpoint("result-pending");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"), { timeout: 10000 });
  await f.session.waitForIdle();
  await recorder.checkpoint("settled");
  const { checkpoints } = await recorder.finish();
  expect(checkpoints[0]!.disk.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  expect(checkpoints[1]!.disk).toMatchObject({ status: "running", asyncWorkSummary: { canReleaseRuntime: false, pendingCompletionCount: 1 } });
  expect(checkpoints[2]!.disk).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: true } });
  expect(f.frames.filter(frame => frame.type === "task-register")).toHaveLength(1);
  expect(completionText(f.requests.at(-1), checkpoints[2]!.disk.asyncTasks![0]!.taskId)).toContain("W7_BASH_RESULT");
}, 20000);

it("records real subagent v2 result retention through native child exit and ordinary task-only input", async () => {
  const f = await fixture({ name: "subagent", arguments: { command: "subagent run finite --isolated -- finite" } });
  const recorder = await replayRecorder(f, "subagent");
  await f.supervisor.followUp("session-sdk", "Start finite subagent");
  const child = await f.child;
  child.write("result\n");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.completionTickets?.[0]?.state).toBe("handled"), { timeout: 10000 });
  await f.session.waitForIdle();
  await recorder.checkpoint("result-handled-child-alive");
  expect(checkpointsActive(await f.store.loadReadOnly("session-sdk"))).toBe(true);
  const count = f.requests.length;
  await f.supervisor.followUp("session-sdk", "Ordinary input while child is alive");
  await vi.waitFor(() => expect(f.requests.length).toBe(count + 1));
  await f.session.waitForIdle();
  await recorder.checkpoint("task-only-running-input-delivered");
  const closed = once(child, "close"); child.end("exit\n"); await closed;
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"), { timeout: 10000 });
  await recorder.checkpoint("child-exited-settled");
  const { checkpoints } = await recorder.finish();
  expect(userTexts(f.requests.at(-1))).toContain("Ordinary input while child is alive");
  expect(checkpoints[0]!.disk.asyncWorkSummary?.canReleaseRuntime).toBe(false);
  expect(checkpoints[1]!.disk.asyncTasks?.[0]?.presence).toBe("active");
  expect(checkpoints[2]!.disk.asyncTasks?.[0]?.presence).toBe("settled");
  expect(await readFile(join(f.root, "spawns"), "utf8")).toBe("spawn\n");
  expect(f.notifications).toHaveLength(1);
}, 20000);

it("delivers a subagent run started by the turn that a finished batch completion triggered", async () => {
  const f = await fixture(request =>
    request === 1 ? [{ name: "subagent", arguments: { command: 'subagent batch --isolated --agent finite --task "verify" --agent finite --task "review"' } }]
      : request === 3 ? [{ name: "subagent", arguments: { command: "subagent run finite --isolated -- fix it" } }]
        : []);
  const finishChildren = async (count: number) => {
    await vi.waitFor(() => expect(f.childSockets).toHaveLength(count), { timeout: 10000 });
    for (const socket of f.childSockets.slice(count === 2 ? 0 : 2)) { socket.write("result\n"); socket.end("exit\n"); }
  };
  await f.supervisor.followUp("session-sdk", "Review with a batch, then fix with a worker");
  await vi.waitFor(() => expect(f.requests).toHaveLength(2), { timeout: 10000 });
  await f.session.waitForIdle();
  await finishChildren(2);
  // The idle batch completion opens a new turn (request 3) that starts the worker.
  // Its completion must open another turn (request 5) instead of being dropped.
  await vi.waitFor(() => expect(f.requests.length).toBeGreaterThanOrEqual(4), { timeout: 10000 });
  await f.session.waitForIdle();
  await finishChildren(3);
  await vi.waitFor(() => expect(f.requests.length).toBeGreaterThanOrEqual(5), { timeout: 10000 });
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.every(task => task.presence === "settled")).toBe(true), { timeout: 10000 });
  await f.session.waitForIdle(); await f.drainEvents();
  const disk = await f.store.loadReadOnly("session-sdk");
  const roots = disk?.asyncTasks?.filter(task => task.taskId === task.rootTaskId) ?? [];
  expect(roots.map(root => root.title)).toEqual([expect.stringContaining("subagent batch"), expect.stringContaining("subagent run finite")]);
  expect(disk?.completionTickets?.map(ticket => ticket.state)).toEqual(["handled", "handled"]);
  expect(userTexts(f.requests.at(-1)).join("\n")).toContain("[subagent:finite#3] completed");
}, 30000);

function checkpointsActive(disk: PickyAgentSession | undefined): boolean {
  return disk?.asyncTasks?.[0]?.presence === "active" && disk.asyncWorkSummary?.canReleaseRuntime === false;
}

async function verifyQueuedRegistration(mode: "continue" | undefined, f: Awaited<ReturnType<typeof fixture>>, direct: Promise<unknown>, requestId: string): Promise<Socket | undefined> {
  if (mode === undefined) {
    await expect(direct).rejects.toThrow("Async task registration was not approved");
    // The genuine provider request reached the host and the SDK tool completed with a rejection.
    await f.drainEvents();
    expect(f.frames.filter(frame => frame.type === "task-register-result" && frame.outcome === "accepted")).toHaveLength(0);
    expect(existsSync(join(f.root, "spawns"))).toBe(false);
    const disk = await f.store.loadReadOnly("session-sdk");
    expect(disk).toMatchObject({ archived: true, asyncArchiveIntentId: requestId, asyncControl: { admissionState: "closed" } });
    expect(disk?.asyncTasks?.some(task => task.registration === "spawned")).not.toBe(true);
    expect(disk?.asyncWorkSummary?.canReleaseRuntime).toBe(true);
  } else {
    await vi.waitFor(() => expect(existsSync(join(f.root, "spawns"))).toBe(true), { timeout: 7000 });
    const ownedChild = await f.child;
    const active = await f.store.loadReadOnly("session-sdk");
    expect(active).toMatchObject({ archived: true, asyncArchiveIntentId: requestId, asyncControl: { admissionState: "open" } });
    expect(active?.asyncTasks?.some(task => task.registration === "spawned" && task.presence === "active")).toBe(true);
    expect(active?.asyncWorkSummary?.canReleaseRuntime).toBe(false);
    const owner = f.supervisor.asyncControls.context("session-sdk");
    const command: Extract<AsyncTaskCommand, { type: "prepareRuntimeRelease" }> = { type: "prepareRuntimeRelease", requestId: "w5-release", sessionId: "session-sdk", daemonInstanceId: owner.daemonInstanceId, runtimeInstanceId: owner.runtimeInstanceId!, workRevision: owner.workRevision, controlGeneration: owner.controlGeneration, archiveIntentId: requestId, childGeneration: 1 };
    const releaseAttempt = await f.supervisor.executeAsyncTaskCommand(command);
    expect(releaseAttempt.outcome).not.toBe("settled");
    expect(f.supervisor.asyncControls.context("session-sdk").releasePrepared).toBeUndefined();
    const closed = once(ownedChild, "close"); ownedChild.end("exit\n"); await closed;
    await direct;
    await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.asyncTasks?.every(task => task.presence === "settled")).toBe(true), { timeout: 8000 });
    await f.drainEvents();
    expect(await readFile(join(f.root, "spawns"), "utf8")).toContain("spawn");
    return ownedChild;
  }
}

it.each([undefined, "continue"] as const)("commits %s archive before queued actual provider registration resolves", async mode => {
  const f = await fixture({ name: "bash_async", arguments: { action: "list" } });
  await f.supervisor.followUp("session-sdk", "Complete a list-only turn");
  await vi.waitFor(async () => expect((await f.store.loadReadOnly("session-sdk"))?.status).toBe("completed"));
  await f.session.waitForIdle(); await f.drainEvents();
  expect(f.frames.filter(frame => frame.type === "task-register")).toHaveLength(0);

  const server = new AgentdServer({ port: 0, token: "w5-archive-test", supervisor: f.supervisor });
  const port = await server.start();
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=w5-archive-test`);
  const wire: EventEnvelope[] = [];
  ws.on("message", data => wire.push(JSON.parse(String(data)) as EventEnvelope));
  cleanups.push(async () => { ws.close(); await server.stop(); });
  await once(ws, "open");
  ws.send(JSON.stringify({ id: "w5-v2", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["sessionProjectionV2"] }));
  await vi.waitFor(() => expect(wire.some(event => event.type === "sessionProjectionBootstrapComplete")).toBe(true));

  const requestId = `w5-${mode ?? "implicit"}`;
  const entered = deferred<void>(), release = deferred<void>();
  const save = f.store.save.bind(f.store);
  let held = false;
  vi.spyOn(f.store, "save").mockImplementation(async state => {
    if (!held && state.archived === true && state.asyncControlJournal?.some(entry => entry.result.requestId === `${requestId}:execute` && entry.result.outcome === "settled")) {
      held = true; entered.resolve(); await release.promise;
    }
    await save(state);
  });
  let archive: Promise<PickyAgentSession> | undefined;
  let direct: Promise<unknown> | undefined;
  let ownedChild: Socket | undefined;
  const evidence: Record<string, unknown> = { path: "direct public SDK tool invocation, not supervisor input", mode };
  try {
    archive = f.supervisor.setSessionArchived("session-sdk", true, mode, requestId);
    await vi.waitFor(() => expect(held).toBe(true), { timeout: 5000 });
    await entered.promise;
    const duringSave = await f.store.loadReadOnly("session-sdk");
    expect(duringSave?.archived).not.toBe(true);
    expect(duringSave?.asyncControlJournal?.find(entry => entry.result.requestId === `${requestId}:execute`)?.result.outcome).toBe("accepted");
    await expect(f.supervisor.followUp("session-sdk", "Normal input during accepted archive")).rejects.toThrow(/fenced|archived/);
    const definition = f.session.getToolDefinition("subagent");
    expect(definition).toBeDefined();
    direct = definition!.execute("w5-direct-subagent", { command: "subagent run finite --isolated -- finite" }, undefined, undefined, f.session.extensionRunner.createToolContext("w5-direct-subagent", undefined));
    await vi.waitFor(() => expect(f.frames.some(frame => frame.type === "task-register")).toBe(true), { timeout: 5000 });
    expect(f.frames.filter(frame => frame.type === "task-register-result" && frame.outcome === "accepted")).toHaveLength(0);
    expect(existsSync(join(f.root, "spawns"))).toBe(false);
    release.resolve();
    await archive;
    await vi.waitFor(() => expect(f.frames.some(frame => frame.type === "task-register-result")).toBe(true), { timeout: 7000 });
    await expect(f.supervisor.followUp("session-sdk", "Normal input after archive")).rejects.toThrow("archived");

    ownedChild = await verifyQueuedRegistration(mode, f, direct, requestId);
    const final = await f.store.loadReadOnly("session-sdk");
    await vi.waitFor(() => expect(wire.filter(event => event.type === "sessionProjectionTransaction").at(-1)).toMatchObject({ revision: final?.revision }));
    const archiveTransaction = wire.filter(event => event.type === "sessionProjectionTransaction").find(event => event.mutations.some(mutation => mutation.type === "metaPatch" && mutation.patch.archived === true));
    expect(archiveTransaction?.mutations).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: "asyncControlSet", control: expect.objectContaining({ admissionState: mode === undefined ? "closed" : "open", controlGeneration: final?.asyncControl?.controlGeneration }) }),
    ]));
    expect(wire.filter(event => event.type === "sessionProjectionTransaction").at(-1)?.revision).toBe(final?.revision);
    evidence.final = { disk: final, frames: f.frames, wire, coverage: f.handle.asyncTasks?.coverage() };
    if (process.env.W5_SETTLED_SAVE_REPAIR_EVIDENCE) await writeFile(`${process.env.W5_SETTLED_SAVE_REPAIR_EVIDENCE}-${mode ?? "implicit"}.json`, JSON.stringify(evidence, null, 2));
  } finally {
    release.resolve();
    ownedChild?.end("exit\n");
    await Promise.allSettled([archive, direct].filter((promise): promise is Promise<unknown> => promise !== undefined));
  }
}, 25000);
