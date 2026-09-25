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

it("keeps execution without resources and host control obligations nonterminal", () => {
  const before = finishedResponse();
  const queued = { ...before, asyncTasks: before.asyncTasks!.map((task) => ({ ...task, execution: "queued" as const })) };
  expect(aggregateAsyncWork(before, queued, idle)).toMatchObject({ status: "running", asyncWorkSummary: { activeRootCount: 1 } });
  expect(aggregateAsyncWork(before, { ...before, asyncControl: { ...before.asyncControl!, admissionState: "closing" } }, idle)).toMatchObject({ status: "running", asyncWorkSummary: { canReleaseRuntime: false } });
});

it("lets a handled child failure settle but keeps parent failure with live work blocked", () => {
  const before = finishedResponse();
  expect(aggregateAsyncWork(before, before, idle)).toMatchObject({ status: "completed", asyncWorkSummary: { episode: { settled: true } } });
  const failedParent = { ...before, asyncWorkSummary: { ...before.asyncWorkSummary!, episode: { ...before.asyncWorkSummary!.episode!, outcome: "failed" as const } } };
  expect(aggregateAsyncWork(before, failedParent, { ...idle, queuedInput: true })).toMatchObject({ status: "blocked", lastSummary: "Agent failed with unfinished work" });
  expect(aggregateAsyncWork(before, failedParent, idle)).toMatchObject({ status: "failed", asyncWorkSummary: { canReleaseRuntime: true } });
});

it("cannot release on reconciling coverage or a pending human result", () => {
  const before = finishedResponse();
  expect(aggregateAsyncWork(before, before, { ...idle, tracking: "reconciling" })).toMatchObject({ status: "running", asyncWorkSummary: { canReleaseRuntime: false } });
  const pending = { ...before, completionTickets: before.completionTickets!.map((ticket) => ({ ...ticket, target: "human" as const, state: "pending" as const })) };
  expect(aggregateAsyncWork(before, pending, idle)).toMatchObject({ status: "running", asyncWorkSummary: { pendingCompletionCount: 1 } });
});

it("keeps the settled episode identity across queued preflight until a real new cycle is admitted", () => {
  const session = finishedResponse();
  const settled = aggregateAsyncWork(session, session, idle);
  const queued = aggregateAsyncWork(settled, settled, { ...idle, queuedInput: true });
  expect(queued).toMatchObject({ status: "running", asyncWorkSummary: { canReleaseRuntime: false, episode: { id: "first-cycle", settled: true } } });
  const next = aggregateAsyncWork(queued, { ...queued, agentCycle: { ...queued.agentCycle!, cycleId: "next-cycle", phase: "responding" } }, { ...idle, runtimeBusy: true });
  expect(next.asyncWorkSummary?.episode).toEqual({ id: "next-cycle", settled: false });
});
