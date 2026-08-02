import { describe, expect, it } from "vitest";
import { applySubagentRunUpdate, pruneSettledSubagentRuns, subagentRunUpdateFromCustomMessage } from "./subagent-run-state.js";

describe("subagent run state", () => {
  it("maps extension lifecycle details and extracts the trailing result preview", () => {
    const update = subagentRunUpdateFromCustomMessage("subagent-tool", {
      runId: 12,
      agent: "worker",
      task: "Inspect the implementation",
      displayTask: "Inspect implementation",
      status: "done",
      startedAt: 1_700_000_000_000,
      elapsedMs: 4_100,
      batchId: "batch-a",
    }, "[subagent:worker#12] done\n\nFinal result");

    expect(update).toEqual(expect.objectContaining({
      runId: 12,
      status: "done",
      startedAt: "2023-11-14T22:13:20.000Z",
      resultPreview: "Final result",
    }));
  });

  it("rejects unrelated or incomplete custom messages", () => {
    expect(subagentRunUpdateFromCustomMessage("other", { runId: 1, agent: "worker", task: "task", status: "started" })).toBeUndefined();
    expect(subagentRunUpdateFromCustomMessage("subagent-command", { runId: 1, status: "started" })).toBeUndefined();
  });

  it("upserts by run ID and keeps runs ordered", () => {
    const next = applySubagentRunUpdate([{ runId: 4, agent: "worker", task: "later", status: "running" }], {
      runId: 2, agent: "reviewer", task: "first", status: "running",
    });
    const updated = applySubagentRunUpdate(next, { runId: 4, agent: "worker", task: "later", status: "done", elapsedMs: 10 });

    expect(updated.map((run) => run.runId)).toEqual([2, 4]);
    expect(updated[1]).toMatchObject({ status: "done", elapsedMs: 10 });
  });

  it("clears settled runs only when no background run remains", () => {
    expect(pruneSettledSubagentRuns([{ runId: 1, agent: "worker", task: "task", status: "done" }])).toEqual([]);
    const active = [{ runId: 1, agent: "worker", task: "task", status: "running" }, { runId: 2, agent: "worker", task: "task", status: "done" }] as const;
    expect(pruneSettledSubagentRuns(active)).toEqual(active);
  });
});
