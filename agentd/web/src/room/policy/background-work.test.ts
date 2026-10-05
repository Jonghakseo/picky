/**
 * What the phone's background-work footer says, case by case, against the
 * HUD's PickyBackgroundWorkFooterPresentation. No catalog is installed here,
 * so copy shows up as its catalog key.
 */
import { describe, expect, it } from "vitest";

import type { PickyAgentSession } from "../../../../src/protocol";
import { backgroundWorkModel } from "./background-work";

const owner = { sessionId: "s1", piSessionId: "p1", runtimeInstanceId: "r1", providerId: "bash", providerInstanceId: "i1" };
const NOW = Date.parse("2026-10-05T10:00:00.000Z");

function task(taskId: string, overrides: Record<string, unknown> = {}) {
  return {
    ...owner, taskId, rootTaskId: taskId, kind: "bash", title: `task ${taskId}`,
    execution: "running", presence: "active", registration: "spawned",
    providerRevision: 1, controlGeneration: 0,
    createdAt: "2026-10-05T09:58:00.000Z", updatedAt: "2026-10-05T09:59:00.000Z",
    ...overrides,
  };
}

function session(tasks: unknown[] | undefined, summary: Record<string, unknown> = {}, extra: Record<string, unknown> = {}): PickyAgentSession {
  return {
    status: "running",
    agentCycle: { cycleId: "c1", runtimeInstanceId: "r1", phase: "idle", controlGeneration: 0 },
    asyncWorkSummary: {
      tracking: "ready", activeRootCount: 1, pendingCompletionCount: 0, uncertainExecutionCount: 0,
      attentionCount: 0, workRevision: 1, canReleaseRuntime: false, ...summary,
    },
    ...(tasks ? { asyncTasks: tasks, completionTickets: [] } : {}),
    ...extra,
  } as unknown as PickyAgentSession;
}

describe("background work footer", () => {
  it("names a running command with the time since it actually started", () => {
    const model = backgroundWorkModel(session([task("t1", { title: "pnpm test", details: { startedAt: "2026-10-05T09:59:30.000Z" } })]), NOW);
    expect(model?.status).toEqual({ text: "hud.asyncTasks.execution.running.short", state: "running" });
    expect(model?.groups).toMatchObject([{ title: "pnpm test", state: "running", children: [], timing: { kind: "elapsed" } }]);
    // Created two minutes ago but started thirty seconds ago: queue wait is not run time.
    expect(model?.groups[0]?.timing).toEqual({ kind: "elapsed", since: Date.parse("2026-10-05T09:59:30.000Z") });
  });

  it("lists subagents by agent name, never by the instruction they were given", () => {
    const root = task("g1", { kind: "subagent", title: "group", invocationId: "inv-1", providerId: "subagent" });
    const child = (id: string, runId: number, execution: string) =>
      task(id, { kind: "subagent", rootTaskId: "g1", parentTaskId: "g1", providerId: "subagent", title: "secret delegation prompt", execution, details: { runId } });
    const model = backgroundWorkModel(session(
      [root, child("a", 1, "running"), child("b", 2, "succeeded")],
      {},
      { subagentRuns: [{ runId: 1, agent: "reviewer", task: "x", status: "running", invocationId: "inv-1" }] },
    ), NOW);
    expect(model?.groups[0]?.title).toBe("hud.backgroundWork.subagentGroup");
    expect(model?.groups[0]?.children.map((row) => [row.title, row.state])).toEqual([
      ["reviewer", "running"],
      ["hud.backgroundWork.unnamedAgent", "completed"],
    ]);
  });

  it("still reports work from the counts when the task list was not sent", () => {
    expect(backgroundWorkModel(session(undefined), NOW)).toEqual({
      groups: [],
      status: { text: "hud.asyncTasks.execution.running.short", state: "running" },
      note: "detailUnavailable",
    });
  });

  it("shows nothing once all work is settled and delivered", () => {
    const settled = task("t1", { execution: "succeeded", presence: "settled" });
    expect(backgroundWorkModel(session([settled], { activeRootCount: 0 }), NOW)).toBeNull();
  });

  it("calls out a failed command ahead of the ones still running", () => {
    const model = backgroundWorkModel(session([
      task("t1", { execution: "failed", presence: "active" }),
      task("t2", { createdAt: "2026-10-05T09:57:00.000Z" }),
    ], { attentionCount: 1 }), NOW);
    expect(model?.status).toEqual({ text: "hud.backgroundWork.needsAttention · hud.asyncTasks.execution.running.short", state: "failed" });
  });
});
