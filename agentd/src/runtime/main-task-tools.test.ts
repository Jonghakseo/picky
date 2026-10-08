import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { MainTaskService } from "../application/main-task-service.js";
import { createMainTaskTool, createPickleDelegationTool, delegationChoiceLabels } from "./main-task-tools.js";
import { MainTaskEvaluationContext } from "./task/picky-task-runtime.js";
import type { TaskWorker, WorkerEvents, WorkerInput, WorkerOptions } from "./task/types.js";

type ToolResult = { content: Array<{ text: string }>; details: Record<string, unknown>; isError?: boolean };
type Execute = (id: string, params: Record<string, unknown>, signal: AbortSignal | undefined, onUpdate: undefined, ctx: unknown) => Promise<ToolResult>;

const roots: string[] = [];
const services: MainTaskService[] = [];
afterEach(async () => {
  await Promise.all(services.splice(0).map((service) => service.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

class Worker implements TaskWorker {
  inputs: WorkerInput[] = [];
  constructor(readonly options: WorkerOptions, readonly events: WorkerEvents) {}
  async start(input: WorkerInput) { this.inputs.push(input); }
  async update(input: WorkerInput) { this.inputs.push(input); }
  async abort() {}
  async stop() { return true; }
}

type Answer = unknown | ((signal: AbortSignal | undefined) => Promise<unknown>);

function setup(answer: Answer) {
  const root = mkdtempSync(path.join(os.tmpdir(), "main-task-tools-"));
  roots.push(root);
  const workers: Worker[] = [];
  const createPickle = vi.fn(async () => ({ sessionId: "pickle-9" }));
  const service = new MainTaskService({
    directory: root,
    maxConcurrency: 2,
    createWorker: (options, events) => {
      const worker = new Worker(options, events);
      workers.push(worker);
      return worker;
    },
    evaluate: async () => ({ tier: "fast", selection: { provider: "test", model: "fast", thinking: "low" }, evaluator: "test" }),
    createPickle,
    defaultCwd: () => root,
    log: () => {},
  });
  service.attachMainAgent({ currentContext: () => undefined, turnOrigin: () => "user" });
  services.push(service);
  const asked: unknown[] = [];
  const signals: Array<AbortSignal | undefined> = [];
  const ctx = {
    hasUI: true,
    ui: {
      askUserQuestion: async (request: unknown, options?: { signal?: AbortSignal }) => {
        asked.push(request);
        signals.push(options?.signal);
        return typeof answer === "function" ? (answer as (signal: AbortSignal | undefined) => Promise<unknown>)(options?.signal) : answer;
      },
    },
    sessionManager: { getBranch: () => [] },
  };
  const delegation = createPickleDelegationTool(service).execute as unknown as Execute;
  const task = createMainTaskTool(service, new MainTaskEvaluationContext()).execute as unknown as Execute;
  return {
    service, workers, createPickle, asked, signals,
    delegate: (params: Record<string, unknown>) => delegation("call", params, undefined, undefined, ctx),
    task: (params: Record<string, unknown>) => task("call", params, undefined, undefined, ctx),
  };
}

const repo = mkdtempSync(path.join(os.tmpdir(), "main-task-tools-repo-"));
afterAll(() => rmSync(repo, { recursive: true, force: true }));
const ask = { action: "ask", title: "CSV 내보내기", instructions: "Add CSV export to billing", cwd: repo, question: "이 수정은 Pickle로 맡길까요?" };

describe("pickle_delegation", () => {
  it("offers only Hand to Pickle or Don't hand off, and starts nothing when the form is closed", async () => {
    const { service, workers, createPickle, asked, delegate } = setup(undefined);
    const outcome = await delegate(ask);
    // "Task" is an internal term: the choices are fixed product copy, whatever the model writes.
    expect(asked[0]).toMatchObject({
      questions: [{ id: "choice", type: "radio", prompt: "이 수정은 Pickle로 맡길까요?", allowOther: false, options: [{ value: "pickle", label: "Pickle로 맡기기" }, { value: "task", label: "맡기지 않기" }] }],
    });
    expect(outcome.details.state).toBe("pending");
    expect(outcome.content[0].text).toContain("stays pending");
    expect(service.listDecisions()).toHaveLength(1);
    expect(createPickle).not.toHaveBeenCalled();
    expect(workers).toHaveLength(0);
  });

  it("creates the Pickle when the user picks it in the form", async () => {
    const { createPickle, delegate } = setup({ choice: "pickle" });
    const outcome = await delegate(ask);
    expect(outcome.details.state).toBe("pickle");
    expect(outcome.content[0].text).toContain("pickle-9");
    expect(createPickle).toHaveBeenCalledTimes(1);
  });

  it("runs the scope as an approved Task when the user declines the Pickle", async () => {
    const { workers, createPickle, delegate } = setup({ choice: "task" });
    const outcome = await delegate(ask);
    expect(outcome.details.state).toBe("task");
    await vi.waitFor(() => expect(workers).toHaveLength(1));
    expect(workers[0].options).toMatchObject({ cwd: repo, scopeApproved: true });
    expect(createPickle).not.toHaveBeenCalled();
  });
  // The same question is also a block in Picky's conversation and on a paired phone. An answer
  // there must close the open form; otherwise the form stays up and the main turn waits forever.
  it("closes its open question when the user answers it elsewhere, and reports that answer", async () => {
    const answeredOnlyByClosing = (signal: AbortSignal | undefined) =>
      new Promise((resolve) => signal?.addEventListener("abort", () => resolve(undefined), { once: true }));
    const { service, workers, createPickle, signals, delegate } = setup(answeredOnlyByClosing);
    const outcome = delegate(ask);
    await vi.waitFor(() => expect(service.listDecisions()).toHaveLength(1));

    await service.resolveDecision(service.listDecisions()[0].id, "task", "app");
    const result = await outcome;

    expect(signals[0]?.aborted).toBe(true);
    expect(result.details.state).toBe("task");
    expect(result.content[0].text).toContain("the user chose a Task");
    await vi.waitFor(() => expect(workers).toHaveLength(1));
    expect(createPickle).not.toHaveBeenCalled();
  });
});

describe("delegationChoiceLabels", () => {
  it("uses English choices when the question is not Korean", () => {
    expect(delegationChoiceLabels({ title: "CSV export", question: "Hand this fix to a Pickle?" })).toEqual({ question: "Hand this to a Pickle?", pickle: "Hand to Pickle", task: "Don't hand off" });
    expect(delegationChoiceLabels({ title: "CSV 내보내기" }).task).toBe("맡기지 않기");
  });
});

describe("Task tool", () => {
  it("returns a Task ID at once and reports missing input as a tool error", async () => {
    const { workers, task } = setup(undefined);
    const created = await task({ title: "Pricing", task: "Compare three pricing pages", readonly: true });
    expect(created.isError).toBeUndefined();
    expect(created.details.taskId).toMatch(/^task-/);
    await vi.waitFor(() => expect(workers).toHaveLength(1));
    expect(workers[0].options.readonly).toBe(true);
    expect((await task({ action: "revise", taskId: created.details.taskId })).isError).toBe(true);
    expect((await task({})).isError).toBe(true);
  });
});
