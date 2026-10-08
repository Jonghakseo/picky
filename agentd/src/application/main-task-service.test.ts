import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { MainTaskService, type MainTaskServiceDependencies, type MainTurnOrigin } from "./main-task-service.js";
import type { PickyContextPacket } from "../protocol.js";
import type { EvaluationResult, TaskReport, TaskWorker, WorkerEvents, WorkerInput, WorkerOptions } from "../runtime/task/types.js";

const roots: string[] = [];
const services: MainTaskService[] = [];
afterEach(async () => {
  await Promise.all(services.splice(0).map((service) => service.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

const choice: EvaluationResult = { tier: "fast", selection: { provider: "test", model: "fast", thinking: "low" }, evaluator: "test" };

class FakeWorker implements TaskWorker {
  inputs: WorkerInput[] = [];
  stopped = false;
  constructor(readonly options: WorkerOptions, readonly events: WorkerEvents) {}
  async start(input: WorkerInput) { this.inputs.push(input); }
  async update(input: WorkerInput) { this.inputs.push(input); }
  async abort() {}
  async stop() { this.stopped = true; return true; }
  report(partial: Partial<TaskReport> = {}) {
    this.events.onReport({
      taskId: this.options.taskId, revision: this.inputs.at(-1)?.revision ?? 1, status: "success",
      summary: "Renamed 12 files", artifacts: ["~/Desktop"], verification: ["Listed the folder"], blockers: [], ...partial,
    });
  }
}

const voiceContext: PickyContextPacket = {
  id: "context-voice-1", source: "voice", capturedAt: "2026-10-08T10:00:00.000Z", transcript: "Rename my desktop screenshots by date",
  activeApp: { name: "Finder" }, screenshots: [{ id: "s1", label: "Main display", path: "/tmp/picky/s1.png" }], inkMarks: [], warnings: [],
};

const folders = mkdtempSync(path.join(os.tmpdir(), "main-task-folders-"));
afterAll(() => rmSync(folders, { recursive: true, force: true }));
const desktop = path.join(folders, "Desktop");
const defaultFolder = path.join(folders, "default");
const product = path.join(folders, "product");
for (const folder of [desktop, defaultFolder, product]) mkdirSync(folder, { recursive: true });

function fixture(options: { root?: string; createPickle?: MainTaskServiceDependencies["createPickle"]; turnOrigin?: () => MainTurnOrigin } = {}) {
  const root = options.root ?? mkdtempSync(path.join(os.tmpdir(), "main-task-service-"));
  if (!options.root) roots.push(root);
  const workers: FakeWorker[] = [];
  const createPickle = vi.fn(options.createPickle ?? (async () => ({ sessionId: "pickle-1" })));
  const service = new MainTaskService({
    directory: root,
    maxConcurrency: 4,
    createWorker: (workerOptions, events) => {
      const worker = new FakeWorker(workerOptions, events);
      workers.push(worker);
      return worker;
    },
    evaluate: async () => choice,
    createPickle,
    defaultCwd: () => defaultFolder,
    log: () => {},
  });
  service.attachMainAgent({ currentContext: () => voiceContext, turnOrigin: options.turnOrigin ?? (() => "user") });
  services.push(service);
  const completions = vi.fn();
  service.onCompletionAvailable(completions);
  return { service, workers, createPickle, root, completions };
}

const launched = (workers: FakeWorker[], count: number) =>
  vi.waitFor(() => expect(workers.filter((worker) => worker.inputs.length)).toHaveLength(count));

describe("main Tasks", () => {
  it("runs in the requested folder with the original request and delivers its result once", async () => {
    const { service, workers, completions } = fixture();
    const task = service.createTask({ title: "Screenshots", instruction: "Rename screenshots by date", cwd: desktop });
    await launched(workers, 1);
    expect(workers[0].options.cwd).toBe(desktop);
    expect(workers[0].inputs[0].prompt).toContain("original user request: Rename my desktop screenshots by date");
    expect(workers[0].inputs[0].prompt).toContain("/tmp/picky/s1.png");
    expect(service.getTask(task.id).origin).toMatchObject({ contextId: "context-voice-1", source: "voice" });

    workers[0].report();
    await vi.waitFor(() => expect(completions).toHaveBeenCalledTimes(1));
    const completion = service.nextCompletion();
    expect(completion).toMatchObject({ taskId: task.id, revision: 1, origin: { contextId: "context-voice-1" } });
    expect(completion?.prompt).toContain("Renamed 12 files");
    expect(completion?.prompt).toContain("Listed the folder");
    service.markCompletionDelivered({ taskId: task.id, revision: 1 });
    expect(service.nextCompletion()).toBeUndefined();
  });

  it("starts in the injected default folder when the request names none", async () => {
    const { service, workers } = fixture();
    service.createTask({ instruction: "Summarize the three newest PDFs in Downloads" });
    await launched(workers, 1);
    expect(workers[0].options.cwd).toBe(defaultFolder);
  });

  it("rejects a working folder that does not exist instead of starting a worker there", async () => {
    const { service, workers } = fixture();
    expect(() => service.createTask({ instruction: "Tidy up", cwd: path.join(folders, "missing") })).toThrow(/does not exist/);
    expect(() => service.createTask({ instruction: "Tidy up", cwd: "relative/path" })).toThrow(/absolute path/);
    expect(service.listTasks()).toHaveLength(0);
    expect(workers).toHaveLength(0);
  });

  it("shows the app what can be stopped or resumed", async () => {
    const { service, workers } = fixture();
    const task = service.createTask({ instruction: "Collect pricing pages" });
    await launched(workers, 1);
    expect(service.snapshot().tasks[0]).toMatchObject({ id: task.id, canStop: true, canResume: false });
    await service.stopTask(task.id);
    expect(service.snapshot().tasks[0]).toMatchObject({ id: task.id, status: "cancelled", cleanup: "confirmed", canStop: false, canResume: true });
    await service.resumeTask(task.id);
    await launched(workers, 2);
    expect(workers[1].options.sessionFile).toBe(workers[0].options.sessionFile);
  });
});

describe("Pickle delegation decisions", () => {
  const ask = { title: "CSV export", instructions: "Add CSV export to billing, with tests", cwd: product, question: "Hand this to a Pickle?" };

  it("starts nothing while pending, and keeps pending across a restart", async () => {
    const first = fixture();
    const decision = first.service.createDecision(ask);
    expect(decision.state).toBe("pending");
    expect(first.workers).toHaveLength(0);
    expect(first.createPickle).not.toHaveBeenCalled();
    await first.service.close();

    const restored = fixture({ root: first.root });
    expect(restored.service.getDecision(decision.id).state).toBe("pending");
    expect(restored.service.snapshot().decisions[0]).toMatchObject({ id: decision.id, state: "pending", question: "Hand this to a Pickle?" });
  });

  it("a declined Pickle runs the same scope as an approved Task, exactly once", async () => {
    const { service, workers } = fixture();
    const decision = service.createDecision(ask);
    const [first, second] = await Promise.all([
      service.resolveDecision(decision.id, "task", "form"),
      service.resolveDecision(decision.id, "task", "app"),
    ]);
    expect(first.taskId).toBeDefined();
    expect(second.taskId).toBe(first.taskId);
    await launched(workers, 1);
    expect(workers).toHaveLength(1);
    expect(workers[0].options).toMatchObject({ cwd: product, scopeApproved: true });
    expect(workers[0].inputs[0].prompt).toContain("Add CSV export to billing");
    await expect(service.resolveDecision(decision.id, "pickle", "app")).rejects.toThrow(/running as a Task/);
  });

  it("an approved Pickle is created once from the stored request, and a failure can be retried", async () => {
    let attempts = 0;
    const { service, createPickle } = fixture({
      createPickle: async () => {
        attempts += 1;
        if (attempts === 1) throw new Error("Picky app handoff unavailable");
        return { sessionId: "pickle-7" };
      },
    });
    const decision = service.createDecision(ask);
    const failed = await service.resolveDecision(decision.id, "pickle", "form");
    expect(failed.pickle).toMatchObject({ state: "failed", error: "Picky app handoff unavailable" });
    expect(service.snapshot().decisions[0]).toMatchObject({ id: decision.id, state: "pickle", pickle: { state: "failed" } });

    const created = await service.resolveDecision(decision.id, "pickle", "app");
    const repeated = await service.resolveDecision(decision.id, "pickle", "app");
    expect(created.pickle).toEqual({ state: "created", sessionId: "pickle-7" });
    expect(repeated.pickle?.sessionId).toBe("pickle-7");
    expect(createPickle).toHaveBeenCalledTimes(2);
    expect(createPickle.mock.calls[1][0]).toMatchObject({ title: "CSV export", cwd: product, context: { id: "context-voice-1" } });
  });

  it("only a user-started turn lets the model answer for the user", async () => {
    let origin: MainTurnOrigin = "internal";
    const { service, workers } = fixture({ turnOrigin: () => origin });
    const decision = service.createDecision(ask);
    await expect(service.resolveDecision(decision.id, "task", "model")).rejects.toThrow(/Only the user can answer/);
    expect(service.getDecision(decision.id).state).toBe("pending");
    origin = "user";
    expect((await service.resolveDecision(decision.id, "task", "model")).state).toBe("task");
    await launched(workers, 1);
  });

  it("a Pickle creation cut off by a restart is reported, never silently retried", async () => {
    let release: (() => void) | undefined;
    const first = fixture({ createPickle: () => new Promise((resolve) => { release = () => resolve({ sessionId: "late" }); }) });
    const decision = first.service.createDecision(ask);
    void first.service.resolveDecision(decision.id, "pickle", "form");
    await vi.waitFor(() => expect(first.service.getDecision(decision.id).pickle?.state).toBe("creating"));
    const restored = fixture({ root: first.root });
    expect(restored.service.getDecision(decision.id).pickle).toMatchObject({ state: "failed" });
    expect(restored.createPickle).not.toHaveBeenCalled();
    release?.();
  });
});

describe("Task to Pickle handoff", () => {
  async function escalatedTask() {
    const harness = fixture();
    const task = harness.service.createTask({ title: "Login retry", instruction: "Find why login retries twice", cwd: product });
    await launched(harness.workers, 1);
    harness.workers[0].report({
      status: "blocked", summary: "The retry comes from the auth client.", artifacts: ["src/auth/client.ts"],
      verification: ["Reproduced with the unit tests"], blockers: ["Fix needs a product code change"], escalation: "production_code",
    });
    await vi.waitFor(() => expect(harness.service.getTask(task.id).status).toBe("blocked"));
    expect(harness.service.nextCompletion()?.prompt).toContain(`fromTaskId ${task.id}`);
    return { ...harness, task };
  }

  it("asking twice about the same Task returns the open question instead of a second decision", async () => {
    const { service, task } = await escalatedTask();
    const first = service.createDecision({ title: "Fix login retry", instructions: "Fix the double retry", fromTaskId: task.id });
    const second = service.createDecision({ title: "Fix login retry again", instructions: "Fix it", fromTaskId: task.id });
    expect(second.id).toBe(first.id);
    expect(service.listDecisions()).toHaveLength(1);
  });

  it("offers the question's answers instead of a resume while the user decides", async () => {
    const { service, task } = await escalatedTask();
    const taskView = () => service.snapshot().tasks.find((entry) => entry.id === task.id);
    expect(taskView()).toMatchObject({ status: "blocked", canResume: true });
    const decision = service.createDecision({ title: "Fix login retry", instructions: "Fix the double retry", fromTaskId: task.id });
    expect(taskView()).toMatchObject({ status: "blocked", canResume: false });
    await service.resolveDecision(decision.id, "cancel", "app");
    expect(taskView()).toMatchObject({ status: "blocked", canResume: true });
  });

  it("hands the Task's findings to a new Pickle and closes the Task's own path", async () => {
    const { service, createPickle, task } = await escalatedTask();
    service.markCompletionDelivered({ taskId: task.id, revision: 1 });
    const decision = service.createDecision({ title: "Fix login retry", instructions: "Fix the double retry", fromTaskId: task.id });
    const resolved = await service.resolveDecision(decision.id, "pickle", "form");
    expect(resolved.pickle).toEqual({ state: "created", sessionId: "pickle-1" });
    const instructions = createPickle.mock.calls[0][0].instructions;
    expect(instructions).toContain(`continues Picky Task ${task.id}`);
    expect(instructions).toContain("src/auth/client.ts");
    expect(instructions).toContain("Reproduced with the unit tests");
    expect(instructions).toContain("Fix needs a product code change");
    expect(createPickle.mock.calls[0][0].cwd).toBe(product);
    expect(service.getTask(task.id).handoff).toEqual({ decisionId: decision.id, pickleSessionId: "pickle-1" });
    expect(() => service.createDecision({ title: "Again", instructions: "Again", fromTaskId: task.id })).toThrow(/already handed to Pickle/);
    expect(service.snapshot().tasks.find((entry) => entry.id === task.id)).toMatchObject({ status: "blocked", canResume: false });
    await expect(service.resumeTask(task.id)).rejects.toThrow(/handed to Pickle/);
  });

  it("choosing Task continues the same worker session with the scope approved", async () => {
    const { service, workers, task } = await escalatedTask();
    const decision = service.createDecision({ title: "Fix login retry", instructions: "Fix the double retry", fromTaskId: task.id });
    const resolved = await service.resolveDecision(decision.id, "task", "form");
    expect(resolved).toMatchObject({ state: "task", taskId: task.id });
    await launched(workers, 2);
    expect(workers[1].options).toMatchObject({ sessionFile: workers[0].options.sessionFile, scopeApproved: true });
    expect(workers[1].inputs[0].revision).toBe(2);
    expect(workers[1].inputs[0].prompt).toContain("Production-level code work within this scope is approved");
  });
});
