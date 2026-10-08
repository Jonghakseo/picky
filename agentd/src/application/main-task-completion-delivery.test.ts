import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { PickyContextPacket } from "../protocol.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "../runtime/types.js";
import type { TaskReport, TaskWorker, WorkerEvents, WorkerInput, WorkerOptions } from "../runtime/task/types.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { MainTaskService, type MainAgentTaskHost } from "./main-task-service.js";

const roots: string[] = [];
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

class MainHandle implements RuntimeSessionHandle {
  readonly id = "picky";
  readonly steeringMode = "one-at-a-time" as const;
  readonly followUpMode = "one-at-a-time" as const;
  isStreaming = false;
  followUps: BuiltPrompt[] = [];
  interrupts: BuiltPrompt[] = [];
  private listeners = new Set<(event: RuntimeEvent) => void>();
  async followUp(prompt: BuiltPrompt) { this.followUps.push(prompt); }
  async interrupt(prompt: BuiltPrompt) { this.interrupts.push(prompt); }
  async steer() { return { handledSynchronously: false }; }
  async abort() {}
  clearQueue() { return { steering: [], followUp: [] }; }
  getSteeringMessages() { return []; }
  getFollowUpMessages() { return []; }
  subscribe(listener: (event: RuntimeEvent) => void) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  emit(event: RuntimeEvent) { for (const listener of this.listeners) listener(event); }
}

class MainRuntime implements AgentRuntime {
  handle?: MainHandle;
  async create(): Promise<RuntimeSessionHandle> { return (this.handle = new MainHandle()); }
  async prewarm(): Promise<RuntimeSessionHandle> { return (this.handle = new MainHandle()); }
}

class Worker implements TaskWorker {
  inputs: WorkerInput[] = [];
  constructor(readonly options: WorkerOptions, readonly events: WorkerEvents) {}
  async start(input: WorkerInput) { this.inputs.push(input); }
  async update(input: WorkerInput) { this.inputs.push(input); }
  async abort() {}
  async stop() { return true; }
  report(summary: string) {
    const report: TaskReport = { taskId: this.options.taskId, revision: 1, status: "success", summary, artifacts: [], verification: [], blockers: [] };
    this.events.onReport(report);
  }
}

const context = (id: string, transcript: string, source: PickyContextPacket["source"] = "voice"): PickyContextPacket => ({
  id, source, capturedAt: new Date().toISOString(), transcript, screenshots: [], inkMarks: [], warnings: [],
});

/** Passing the folder of an earlier setup starts Picky again on the same saved Tasks. */
function setup(root = mkdtempSync(path.join(os.tmpdir(), "main-task-delivery-"))) {
  if (!roots.includes(root)) roots.push(root);
  const workers: Worker[] = [];
  const service = new MainTaskService({
    directory: path.join(root, "main-tasks"),
    maxConcurrency: 2,
    createWorker: (options, events) => {
      const worker = new Worker(options, events);
      workers.push(worker);
      return worker;
    },
    evaluate: async () => ({ tier: "fast", selection: { provider: "test", model: "fast", thinking: "low" }, evaluator: "test" }),
    createPickle: async () => ({ sessionId: "pickle-1" }),
    defaultCwd: () => root,
    log: () => {},
  });
  let host: MainAgentTaskHost | undefined;
  const attach = service.attachMainAgent.bind(service);
  service.attachMainAgent = (attached) => {
    host = attached;
    attach(attached);
  };
  const mainRuntime = new MainRuntime();
  const supervisor = new SessionSupervisor(mainRuntime, new SessionStore(path.join(root, "store")), { mainRuntime, mainTasks: service });
  cleanups.push(() => service.close());
  const replies: Array<{ contextId: string; text: string; originSource?: string }> = [];
  supervisor.on("quickReply", (contextId: string, text: string, metadata: { originSource?: string } = {}) => replies.push({ contextId, text, originSource: metadata.originSource }));
  return { root, service, supervisor, mainRuntime, workers, replies, host: () => host! };
}

const resultFollowUps = (handle: MainHandle | undefined) => (handle?.followUps ?? []).filter((prompt) => prompt.text.startsWith("[Picky Task result]"));
const interruptionFollowUps = (handle: MainHandle | undefined) => (handle?.followUps ?? []).filter((prompt) => prompt.text.startsWith("[Picky Task interrupted]"));

describe("main Task result delivery", () => {
  it("waits for the user's turn to finish, then delivers the result once and answers the original request", async () => {
    const { service, supervisor, mainRuntime, workers, replies, host } = setup();
    const request = context("context-voice", "Rename my screenshots");
    await supervisor.route(request);
    const handle = mainRuntime.handle!;
    handle.emit({ type: "status", status: "running", summary: "Running" });
    const task = service.createTask({ title: "Screenshots", instruction: "Rename screenshots by date" });
    await vi.waitFor(() => expect(workers).toHaveLength(1));

    // A different request is in progress when the Task finishes.
    await supervisor.route(context("context-other", "What time is it?", "text"));
    handle.emit({ type: "status", status: "running", summary: "Running" });
    workers[0].report("Renamed 12 files");
    await vi.waitFor(() => expect(service.getTask(task.id).status).toBe("completed"));
    expect(resultFollowUps(handle)).toHaveLength(0);

    handle.emit({ type: "assistant_delta", delta: "It is 3 PM." });
    handle.emit({ type: "status", status: "completed", summary: "Completed" });
    await vi.waitFor(() => expect(resultFollowUps(handle)).toHaveLength(1));
    expect(resultFollowUps(handle)[0].text).toContain("Renamed 12 files");
    expect(host().turnOrigin()).toBe("internal");

    handle.emit({ type: "status", status: "running", summary: "Running" });
    handle.emit({ type: "assistant_delta", delta: "Your screenshots are renamed." });
    handle.emit({ type: "status", status: "completed", summary: "Completed" });
    await vi.waitFor(() => expect(replies.some((reply) => reply.text === "Your screenshots are renamed.")).toBe(true));
    expect(replies.find((reply) => reply.text === "Your screenshots are renamed.")).toMatchObject({ contextId: "context-voice", originSource: "voice" });

    // Nothing is delivered twice, and the next user input is a user turn again.
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(resultFollowUps(handle)).toHaveLength(1);
    expect(service.getTask(task.id).completionDelivered).toBe(true);
    await supervisor.route(context("context-next", "Thanks", "text"));
    expect(host().turnOrigin()).toBe("user");
  });

  it("holds the result while the main agent waits for an answer to its question", async () => {
    const { service, supervisor, mainRuntime, workers } = setup();
    await supervisor.route(context("context-1", "Organize my Downloads"));
    const handle = mainRuntime.handle!;
    handle.emit({ type: "status", status: "running", summary: "Running" });
    service.createTask({ instruction: "Sort Downloads into folders" });
    await vi.waitFor(() => expect(workers).toHaveLength(1));
    handle.emit({
      type: "extension_ui",
      waitsForInput: true,
      request: { id: "question-1", method: "askUserQuestion", title: "Which folders?", sessionId: "picky-main" },
    } as RuntimeEvent);
    await vi.waitFor(() => expect(supervisor.mainPendingExtensionUi()?.id).toBe("question-1"));
    workers[0].report("Sorted 40 files");
    await vi.waitFor(() => expect(service.nextCompletion()).toBeDefined());
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(resultFollowUps(handle)).toHaveLength(0);

    // The user answers; the question's turn continues and ends, and only then the result arrives.
    handle.emit({ type: "extension_ui_cancelled", requestId: "question-1" } as RuntimeEvent);
    await vi.waitFor(() => expect(supervisor.mainPendingExtensionUi()).toBeUndefined());
    expect(resultFollowUps(handle)).toHaveLength(0);
    handle.emit({ type: "assistant_delta", delta: "I'll sort them by type." });
    handle.emit({ type: "status", status: "completed", summary: "Completed" });
    await vi.waitFor(() => expect(resultFollowUps(handle)).toHaveLength(1));
  });

  it("keeps a result that finished before the main agent started until it is ready", async () => {
    const { service, supervisor, mainRuntime, workers } = setup();
    const task = service.createTask({ instruction: "Collect pricing pages" });
    await vi.waitFor(() => expect(workers).toHaveLength(1));
    workers[0].report("Collected three pages");
    await vi.waitFor(() => expect(service.getTask(task.id).status).toBe("completed"));
    expect(mainRuntime.handle).toBeUndefined();
    expect(service.nextCompletion()?.taskId).toBe(task.id);

    await supervisor.prewarmMainAgent("/tmp");
    await vi.waitFor(() => expect(resultFollowUps(mainRuntime.handle)).toHaveLength(1));
    expect(service.getTask(task.id).completionDelivered).toBe(true);
  });

  it("tells the main agent once which Tasks a quit stopped, and restarts none of them", async () => {
    const before = setup();
    await before.supervisor.route(context("context-export", "Send me this month's invoices as a spreadsheet", "text"));
    const task = before.service.createTask({ title: "Export invoices", instruction: "Export this month's invoices to CSV" });
    await vi.waitFor(() => expect(before.workers).toHaveLength(1));
    await before.service.close();

    // Without this notice the main agent would still expect the result it was promised.
    const after = setup(before.root);
    await after.supervisor.prewarmMainAgent("/tmp");
    const handle = after.mainRuntime.handle!;
    await vi.waitFor(() => expect(interruptionFollowUps(handle)).toHaveLength(1));
    const notice = interruptionFollowUps(handle)[0].text;
    expect(notice).toContain("no result will arrive");
    // The user's own request, so Picky can say which work stopped in words they recognize;
    // the ID is there for the resume call only.
    expect(notice).toContain(`"Export invoices". The user asked: "Send me this month's invoices as a spreadsheet".`);
    expect(notice).toContain(`taskId ${task.id}, for Task action resume only`);
    expect(notice).not.toMatch(/revision \d/);
    expect(after.workers).toHaveLength(0);
    expect(after.service.getTask(task.id).status).toBe("interrupted");

    handle.emit({ type: "status", status: "running", summary: "Running" });
    handle.emit({ type: "assistant_delta", delta: "Exporting invoices stopped when Picky quit. Continue it?" });
    handle.emit({ type: "status", status: "completed", summary: "Completed" });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(interruptionFollowUps(handle)).toHaveLength(1);
    await after.service.close();

    const nextStart = setup(before.root);
    await nextStart.supervisor.prewarmMainAgent("/tmp");
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(interruptionFollowUps(nextStart.mainRuntime.handle)).toHaveLength(0);
    expect(nextStart.service.getTask(task.id).status).toBe("interrupted");
  });
});
