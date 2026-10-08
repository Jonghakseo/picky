import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TaskManager, type CreateTaskInput } from "./manager.js";
import { TaskStore } from "./store.js";
import type { EvaluationResult, TaskReport, TaskWorker, WorkerEvents, WorkerInput, WorkerOptions } from "./types.js";

const roots: string[] = [];
const managers: TaskManager[] = [];
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  vi.useRealTimers();
});
const snapshot = {
  brief: "Keep the public API compatible.",
  entries: [{ ref: "#goal", role: "user", text: "Keep the public API compatible." }],
};
const choice: EvaluationResult = {
  tier: "balanced",
  selection: { provider: "test", model: "balanced", thinking: "medium" },
  evaluator: "test/fast",
};
class FakeWorker implements TaskWorker {
  inputs: WorkerInput[] = [];
  stopped = false;
  aborts = 0;
  exitConfirmed = true;
  constructor(
    readonly options: WorkerOptions,
    readonly events: WorkerEvents,
  ) {}
  async start(input: WorkerInput) {
    this.inputs.push(input);
  }
  async update(input: WorkerInput) {
    this.inputs.push(input);
  }
  async abort() {
    this.aborts++;
    this.events.onActivity("waiting");
  }
  async stop() {
    this.stopped = true;
    return this.exitConfirmed;
  }
  report(revision = this.inputs.at(-1)?.revision ?? 1, status: TaskReport["status"] = "success") {
    const report: TaskReport = {
      taskId: this.options.taskId,
      revision,
      status,
      summary: "Done",
      artifacts: [],
      verification: ["behavior checked"],
      blockers: [],
    };
    this.events.onReport(report);
  }
}
function fixture(
  overrides: {
    maxConcurrency?: number;
    evaluate?: ConstructorParameters<typeof TaskManager>[0]["evaluate"];
    root?: string;
  } = {},
) {
  const root = overrides.root ?? mkdtempSync(path.join(os.tmpdir(), "task-manager-"));
  if (!overrides.root) roots.push(root);
  const workers: FakeWorker[] = [];
  const onTerminal = vi.fn();
  const evaluate = overrides.evaluate ?? vi.fn(async () => choice);
  const manager = new TaskManager({
    store: new TaskStore(root),
    maxConcurrency: overrides.maxConcurrency ?? 4,
    evaluate,
    createWorker: (options, events) => {
      const worker = new FakeWorker(options, events);
      workers.push(worker);
      return worker;
    },
    onTerminal,
  });
  managers.push(manager);
  const create = (instruction: string, extra: Partial<CreateTaskInput> = {}) =>
    manager.create({ title: instruction, instruction, cwd: root, ...extra }, snapshot);
  return { manager, workers, onTerminal, evaluate, root, create };
}
const launched = (workers: FakeWorker[], count: number) =>
  vi.waitFor(() => expect(workers.filter((w) => w.inputs.length)).toHaveLength(count));

describe("Task manager behavior", () => {
  it("returns IDs immediately, queues above the limit, and only final reports free slots", async () => {
    const { workers, onTerminal, create, manager } = fixture();
    const records = Array.from({ length: 5 }, (_, i) => create(`Task ${i}`));
    expect(records.every((r) => r.status === "queued")).toBe(true);
    expect(workers).toHaveLength(0);
    await launched(workers, 4);
    workers[0].events.onActivity("waiting");
    expect(manager.get(records[0].id).status).toBe("waiting");
    expect(manager.get(records[4].id).status).toBe("queued");
    expect(onTerminal).not.toHaveBeenCalled();
    workers[0].report();
    await launched(workers, 5);
    expect(workers[0].stopped).toBe(true);
    expect(manager.get(records[0].id).status).toBe("completed");
    expect(onTerminal).toHaveBeenCalledTimes(1);
    workers[0].report();
    expect(onTerminal).toHaveBeenCalledTimes(1);
  });

  it("runs each Task in its own working folder and tells the worker when the user approved the scope", async () => {
    const { workers, create, root } = fixture();
    create("Rename the files", { cwd: path.join(root, "photos") });
    create("Fix the login bug", { decisionId: "delegation-1" });
    await launched(workers, 2);
    expect(workers[0].options.cwd).toBe(path.join(root, "photos"));
    expect(workers[0].options.scopeApproved).toBe(false);
    expect(workers[1].options.scopeApproved).toBe(true);
    expect(workers[1].inputs[0].prompt).toContain("production-level code work within it is approved");
  });

  it("edits add instructions and reevaluate without terminating the worker, rejecting old reports", async () => {
    const { manager, workers, evaluate, onTerminal, create } = fixture();
    const task = create("Fix login", { readonly: true });
    await launched(workers, 1);
    const pending = manager.edit(task.id, "Email only");
    expect(manager.get(task.id).revision).toBe(2);
    workers[0].report(1);
    expect(onTerminal).not.toHaveBeenCalled();
    await pending;
    await vi.waitFor(() => expect(workers[0].inputs).toHaveLength(2));
    expect(workers).toHaveLength(1);
    expect(workers[0].stopped).toBe(false);
    expect(workers[0].inputs[1].prompt).toContain("Fix login");
    expect(workers[0].inputs[1].prompt).toContain("Email only");
    expect(workers[0].options.readonly).toBe(true);
    expect(evaluate).toHaveBeenCalledTimes(2);
    workers[0].report(1);
    expect(manager.get(task.id).status).toBe("running");
    workers[0].report(2);
    await vi.waitFor(() => expect(onTerminal).toHaveBeenCalledTimes(1));
    expect(manager.get(task.id).report?.revision).toBe(2);
  });

  it("a user stop shuts the worker down, ignores its late report, and frees the slot", async () => {
    const { manager, workers, onTerminal, create } = fixture({ maxConcurrency: 1 });
    const task = create("Run tests");
    const next = create("Next");
    await launched(workers, 1);
    const stopped = await manager.stop(task.id);
    expect(workers[0].stopped).toBe(true);
    expect(stopped).toMatchObject({ status: "cancelled", cleanup: "confirmed" });
    workers[0].report();
    expect(manager.get(task.id).status).toBe("cancelled");
    expect(onTerminal).not.toHaveBeenCalled();
    await launched(workers, 2);
    expect(workers[1].options.taskId).toBe(next.id);
  });

  it("records an unconfirmed worker exit as uncertain cleanup instead of a clean stop", async () => {
    const { manager, workers, create } = fixture();
    const task = create("Long job");
    await launched(workers, 1);
    workers[0].exitConfirmed = false;
    expect(await manager.stop(task.id)).toMatchObject({ status: "cancelled", cleanup: "uncertain" });
  });

  it("stopping a queued Task never launches it", async () => {
    const { manager, workers, create } = fixture({ maxConcurrency: 1 });
    create("Running");
    const queued = create("Queued");
    await launched(workers, 1);
    await manager.stop(queued.id);
    workers[0].report();
    await vi.waitFor(() => expect(workers[0].stopped).toBe(true));
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(workers).toHaveLength(1);
    expect(manager.get(queued.id).status).toBe("cancelled");
  });

  it("a stopped Task resumes in the same child session on an explicit edit", async () => {
    const { manager, workers, create } = fixture();
    const task = create("Organize the folder");
    await launched(workers, 1);
    await manager.stop(task.id);
    await manager.edit(task.id, "Continue where you left off");
    await launched(workers, 2);
    expect(workers[1].options.sessionFile).toBe(task.sessionFile);
    expect(workers[1].inputs[0].revision).toBe(2);
    expect(manager.get(task.id).cleanup).toBeUndefined();
  });

  it("late evaluation results cannot launch an outdated revision", async () => {
    let finish: ((value: EvaluationResult) => void) | undefined;
    const evaluate = vi
      .fn<ConstructorParameters<typeof TaskManager>[0]["evaluate"]>()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      )
      .mockResolvedValue(choice);
    const { manager, workers, create } = fixture({ evaluate });
    const task = create("Original");
    await vi.waitFor(() => expect(evaluate).toHaveBeenCalledTimes(1));
    const edit = manager.edit(task.id, "Revised");
    finish?.(choice);
    await edit;
    await launched(workers, 1);
    expect(workers[0].inputs[0].revision).toBe(2);
    expect(workers[0].inputs[0].prompt).toContain("Revised");
  });

  it("routing failures report to the parent and allow the next queued Task to run", async () => {
    const evaluate = vi.fn().mockRejectedValueOnce(new Error("No evaluator available")).mockResolvedValue(choice);
    const { manager, workers, onTerminal, create } = fixture({ maxConcurrency: 1, evaluate });
    const first = create("Will fail");
    create("Next");
    await launched(workers, 1);
    expect(manager.get(first.id).status).toBe("failed");
    expect(onTerminal).toHaveBeenCalledTimes(1);
    expect(workers[0].inputs[0].prompt).toContain("Next");
  });

  it("recovery shows interruptions once and resumes only when explicitly requested", async () => {
    const first = fixture();
    const task = first.create("Persistent work", { readonly: true });
    await launched(first.workers, 1);
    await first.manager.close();
    const restored = fixture({ root: first.root });
    expect(restored.manager.get(task.id).status).toBe("interrupted");
    expect(restored.manager.takeInterruptions()).toHaveLength(1);
    expect(restored.manager.takeInterruptions()).toHaveLength(0);
    expect(restored.workers).toHaveLength(0);
    await restored.manager.edit(task.id, "Continue");
    await launched(restored.workers, 1);
    expect(restored.workers[0].options.sessionFile).toBe(task.sessionFile);
    expect(restored.workers[0].inputs[0].revision).toBe(2);
  });

  it("an unconfirmed stop from a previous process restores as uncertain, never as running", async () => {
    const first = fixture();
    const task = first.create("Work");
    await launched(first.workers, 1);
    // Simulate a process that died mid-stop: persist the stopping state, then reload.
    const store = new TaskStore(first.root);
    store.save(store.load().map((record) => ({ ...record, status: "stopping" as const })));
    const restored = fixture({ root: first.root });
    expect(restored.manager.get(task.id)).toMatchObject({ status: "cancelled", cleanup: "uncertain" });
  });

  it("shutdown prevents late evaluation from starting a child", async () => {
    let finish: ((value: EvaluationResult) => void) | undefined;
    const evaluate = vi.fn(
      () =>
        new Promise<EvaluationResult>((resolve) => {
          finish = resolve;
        }),
    );
    const { manager, workers, create } = fixture({ evaluate });
    const task = create("Slow evaluation");
    await vi.waitFor(() => expect(evaluate).toHaveBeenCalledTimes(1));
    await manager.close();
    finish?.(choice);
    await Promise.resolve();
    await Promise.resolve();
    expect(workers).toHaveLength(0);
    expect(manager.get(task.id).status).toBe("interrupted");
  });

  it("unexpected worker exit is failure, never a successful final report", async () => {
    const { manager, workers, onTerminal, create } = fixture();
    const task = create("Work");
    await launched(workers, 1);
    workers[0].events.onExit("Worker crashed");
    await vi.waitFor(() => expect(onTerminal).toHaveBeenCalledTimes(1));
    expect(manager.get(task.id).report?.status).toBe("failed");
    expect(manager.get(task.id).report?.summary).toBe("Worker crashed");
  });

  it("delivery is acknowledged once per reported revision", async () => {
    const { manager, workers, onTerminal, create } = fixture();
    const task = create("Work");
    await launched(workers, 1);
    workers[0].report(1, "blocked");
    await vi.waitFor(() => expect(onTerminal).toHaveBeenCalledTimes(1));
    expect(manager.markDelivered(task.id, 1)).toBe(true);
    expect(manager.markDelivered(task.id, 1)).toBe(false);
    await manager.edit(task.id, "Answer: use the staging bucket");
    expect(manager.get(task.id).completionDelivered).toBe(false);
    expect(manager.markDelivered(task.id, 1)).toBe(false);
  });
});
