import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { PickyAgentSessionSchema } from "../protocol.js";
import { aggregateAsyncWork } from "./async-work-aggregate.js";

function finishedResponse() {
  const session = PickyAgentSessionSchema.parse(JSON.parse(readFileSync(new URL("../../../contracts/protocol/session-async-tasks-snapshot.event.json", import.meta.url), "utf8")).projection);
  session.agentCycle = { ...session.agentCycle!, phase: "settled", outcome: "completed" };
  session.asyncWorkSummary = { ...session.asyncWorkSummary!, episode: { id: "first-cycle", settled: false, finalizedCycleId: session.agentCycle.cycleId, outcome: "completed" } };
  session.asyncTasks = session.asyncTasks!.map((task) => ({ ...task, presence: "settled", execution: "failed", registration: "spawned" }));
  session.completionTickets = session.completionTickets!.map((ticket) => ({ ...ticket, state: "handled", cycleId: session.agentCycle!.cycleId }));
  session.asyncControl = { controlGeneration: 1, admissionState: "open", operations: [] };
  return session;
}
const idle = { tracking: "ready" as const, runtimeBusy: false, queuedInput: false };

it("counts one active root for parallel descendants and keeps uncertain execution visible", () => {
  const before = finishedResponse();
  const root = before.asyncTasks![0]!;
  const proposed = { ...before, asyncTasks: [root, { ...root, taskId: "child-a", parentTaskId: root.taskId, presence: "active" as const }, { ...root, taskId: "child-b", parentTaskId: root.taskId, presence: "unknown" as const }] };
  expect(aggregateAsyncWork(before, proposed, idle)).toMatchObject({ status: "blocked", asyncWorkSummary: { activeRootCount: 1, uncertainExecutionCount: 1, canReleaseRuntime: false } });
});

it("shows pending live-owner grants without hiding unconfirmed grants from a lost owner", () => {
  const before = finishedResponse();
  const task = { ...before.asyncTasks![0]!, execution: "queued" as const, presence: "unknown" as const, registration: "approved" as const };
  const proposed = { ...before, asyncTasks: [task] };
  const live = aggregateAsyncWork(before, proposed, { ...idle, runtimeInstanceId: task.runtimeInstanceId });
  expect(live).toMatchObject({ status: "running", asyncWorkSummary: { activeRootCount: 1, uncertainExecutionCount: 0, attentionCount: 0, canReleaseRuntime: false } });
  expect(aggregateAsyncWork(before, proposed, { ...idle, runtimeInstanceId: "replacement-owner" })).toMatchObject({ status: "blocked", asyncWorkSummary: { uncertainExecutionCount: 1, canReleaseRuntime: false } });
  expect(aggregateAsyncWork(before, proposed, { ...idle, runtimeInstanceId: task.runtimeInstanceId, tracking: "reconciling" })).toMatchObject({ status: "blocked", asyncWorkSummary: { uncertainExecutionCount: 1 } });
});

it("keeps execution without resources running but leaves control-only closure at the prior status", () => {
  const before = finishedResponse();
  const queued = { ...before, asyncTasks: before.asyncTasks!.map((task) => ({ ...task, execution: "queued" as const })) };
  expect(aggregateAsyncWork(before, queued, idle)).toMatchObject({ status: "running", asyncWorkSummary: { activeRootCount: 1 } });
  expect(aggregateAsyncWork(before, { ...before, asyncControl: { ...before.asyncControl!, admissionState: "closing" } }, idle)).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: false } });
});

it("lets a handled child failure settle but keeps parent failure with live work blocked", () => {
  const before = finishedResponse();
  expect(aggregateAsyncWork(before, before, idle)).toMatchObject({ status: "completed", asyncWorkSummary: { episode: { settled: true } } });
  const failedParent = { ...before, asyncWorkSummary: { ...before.asyncWorkSummary!, episode: { ...before.asyncWorkSummary!.episode!, outcome: "failed" as const } } };
  expect(aggregateAsyncWork(before, failedParent, { ...idle, queuedInput: true })).toMatchObject({ status: "blocked", lastSummary: "Agent failed with unfinished work" });
  expect(aggregateAsyncWork(before, failedParent, idle)).toMatchObject({ status: "failed", asyncWorkSummary: { canReleaseRuntime: true } });
});

it("lets a newer live response cycle supersede a failed parent with surviving work", () => {
  const finished = finishedResponse();
  const liveRoot = finished.asyncTasks!.map((task) => ({ ...task, presence: "active" as const, execution: "running" as const }));
  const failedEpisode = { ...finished.asyncWorkSummary!.episode!, outcome: "failed" as const };
  const failed = aggregateAsyncWork(finished, { ...finished, asyncTasks: liveRoot, agentCycle: { ...finished.agentCycle!, outcome: "failed" }, asyncWorkSummary: { ...finished.asyncWorkSummary!, episode: failedEpisode } }, idle);
  expect(failed).toMatchObject({ status: "blocked", lastSummary: "Agent failed with unfinished work", asyncWorkSummary: { episode: { settled: false } } });

  const nextCycle = { ...failed.agentCycle!, cycleId: "next-cycle", phase: "responding" as const, outcome: undefined };
  const responding = aggregateAsyncWork(failed, { ...failed, agentCycle: nextCycle }, { ...idle, runtimeBusy: true });
  expect(responding).toMatchObject({ status: "running", asyncWorkSummary: { attentionCount: 0, episode: { id: failedEpisode.id } } });
  expect(responding.lastSummary).toBeUndefined();

  const settledCycle = { ...nextCycle, phase: "settled" as const };
  // The cycle settles before the terminal status finalizes the episode; that gap must not flash the old failure.
  expect(aggregateAsyncWork(responding, { ...responding, agentCycle: { ...settledCycle, outcome: "completed" } }, idle).status).toBe("running");
  const finalizedAs = (outcome: "completed" | "failed") => ({ ...responding, agentCycle: { ...settledCycle, outcome },
    asyncWorkSummary: { ...responding.asyncWorkSummary!, episode: { ...responding.asyncWorkSummary!.episode!, finalizedCycleId: "next-cycle", outcome } } });
  expect(aggregateAsyncWork(responding, finalizedAs("completed"), idle)).toMatchObject({ status: "running", asyncWorkSummary: { attentionCount: 0 } });
  expect(aggregateAsyncWork(responding, finalizedAs("failed"), idle)).toMatchObject({ status: "blocked", lastSummary: "Agent failed with unfinished work" });
});

it("cannot release on reconciling coverage or a pending human result", () => {
  const before = finishedResponse();
  expect(aggregateAsyncWork(before, before, { ...idle, tracking: "reconciling" })).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: false } });
  const pending = { ...before, completionTickets: before.completionTickets!.map((ticket) => ({ ...ticket, target: "human" as const, state: "pending" as const })) };
  expect(aggregateAsyncWork(before, pending, idle)).toMatchObject({ status: "running", asyncWorkSummary: { pendingCompletionCount: 1 } });
});

it.each(["failed", "cancelled"] as const)("keeps a %s episode terminal through control-only closure", (outcome) => {
  const before = finishedResponse();
  const terminal = { ...before, status: outcome, asyncWorkSummary: { ...before.asyncWorkSummary!, episode: { ...before.asyncWorkSummary!.episode!, outcome } } };
  expect(aggregateAsyncWork(terminal, { ...terminal, asyncControl: { ...terminal.asyncControl!, admissionState: "closing" } }, idle)).toMatchObject({ status: outcome, asyncWorkSummary: { canReleaseRuntime: false, attentionCount: 0 } });
});

it("keeps accepted control operations unreleasable without claiming a new turn", () => {
  const before = finishedResponse();
  const accepted = { ...before, asyncControl: { ...before.asyncControl!, operations: [{ requestId: "archive", operationId: "archive-op", outcome: "accepted" as const, controlGeneration: 1 }] } };
  expect(aggregateAsyncWork(before, accepted, idle)).toMatchObject({ status: "completed", asyncWorkSummary: { canReleaseRuntime: false } });
  const empty = { ...before, status: "waiting_for_input" as const, agentCycle: undefined, asyncWorkSummary: { ...before.asyncWorkSummary!, episode: undefined } };
  expect(aggregateAsyncWork(empty, { ...empty, asyncControl: { ...empty.asyncControl!, admissionState: "closing" } }, { ...idle, tracking: "reconciling" })).toMatchObject({ status: "waiting_for_input", asyncWorkSummary: { canReleaseRuntime: false } });
});

it("keeps the settled episode identity across queued preflight until a real new cycle is admitted", () => {
  const session = finishedResponse();
  const settled = aggregateAsyncWork(session, session, idle);
  const queued = aggregateAsyncWork(settled, settled, { ...idle, queuedInput: true });
  expect(queued).toMatchObject({ status: "running", asyncWorkSummary: { canReleaseRuntime: false, episode: { id: "first-cycle", settled: true } } });
  const next = aggregateAsyncWork(queued, { ...queued, agentCycle: { ...queued.agentCycle!, cycleId: "next-cycle", phase: "responding" } }, { ...idle, runtimeBusy: true });
  expect(next.asyncWorkSummary?.episode).toEqual({ id: "next-cycle", settled: false });
});
