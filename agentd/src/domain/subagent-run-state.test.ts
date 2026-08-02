import { describe, expect, it } from "vitest";
import { applySubagentRunUpdate, capSubagentRuns, subagentLaunchIntentFromToolArgs, subagentRunActivityUpdateFromDiagnostic, subagentRunUpdateFromCustomMessage, subagentRunUpdateFromDiagnostic } from "./subagent-run-state.js";

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

  it("parses run, batch, and chain launch intents with quoted tasks", () => {
    expect(subagentLaunchIntentFromToolArgs({ command: "subagent run worker --main -- inspect 'the quoted task'" })).toEqual({
      action: "run",
      entries: [{ agent: "worker", task: "inspect 'the quoted task'" }],
    });
    expect(subagentLaunchIntentFromToolArgs(JSON.stringify({ command: 'subagent batch --agent worker --task "Inspect files" --agent reviewer --task "Review \\"quotes\\""' }))).toEqual({
      action: "batch",
      entries: [{ agent: "worker", task: "Inspect files" }, { agent: "reviewer", task: 'Review "quotes"' }],
    });
    expect(subagentLaunchIntentFromToolArgs({ command: "subagent chain --agent scout --task 'Find risks' --agent worker --task implement" })).toEqual({
      action: "chain",
      entries: [{ agent: "scout", task: "Find risks" }, { agent: "worker", task: "implement" }],
    });
    expect(subagentLaunchIntentFromToolArgs({ command: "subagent continue worker -- inspect the current state" })).toEqual({
      action: "run",
      entries: [{ agent: "worker", task: "inspect the current state" }],
    });
    expect(subagentLaunchIntentFromToolArgs({ command: "subagent status" })).toBeUndefined();
  });

  it("maps runner diagnostics without fabricating result previews", () => {
    const spawn = subagentRunUpdateFromDiagnostic({
      schemaVersion: 1,
      recordedAt: "2026-08-02T05:26:36.115Z",
      runId: 3,
      agent: "searcher",
      batchId: "b_1785648388418_hfli",
      pipelineStepIndex: 1,
      event: "spawn",
    });
    expect(spawn).toEqual({
      runId: 3,
      agent: "searcher",
      status: "running",
      startedAt: "2026-08-02T05:26:36.115Z",
      recordedAt: "2026-08-02T05:26:36.115Z",
      batchId: "b_1785648388418_hfli",
      pipelineStepIndex: 1,
    });
    expect(subagentRunUpdateFromDiagnostic({ ...spawn, event: "settled", code: 0 })).toMatchObject({ status: "done" });
    expect(subagentRunUpdateFromDiagnostic({ ...spawn, event: "settled", code: 143 })).toMatchObject({ status: "error" });
    expect(subagentRunUpdateFromDiagnostic({ ...spawn, event: "kill_result" })).toMatchObject({ status: "error", errorClass: "aborted" });
    expect(subagentRunUpdateFromDiagnostic({ recordedAt: "2026-08-02T05:26:36.115Z", event: "session_shutdown" })).toBeUndefined();
  });

  it("upserts by run ID and keeps runs ordered", () => {
    const next = applySubagentRunUpdate([{ runId: 4, agent: "worker", task: "later", status: "running" }], {
      runId: 2, agent: "reviewer", task: "first", status: "running",
    });
    const updated = applySubagentRunUpdate(next, { runId: 4, agent: "worker", task: "later", status: "done", elapsedMs: 10 });

    expect(updated.map((run) => run.runId)).toEqual([2, 4]);
    expect(updated[1]).toMatchObject({ status: "done", elapsedMs: 10 });
  });

  it("parses optional future activity without treating unrelated diagnostics as activity", () => {
    expect(subagentRunActivityUpdateFromDiagnostic({
      schemaVersion: 1,
      recordedAt: "2026-08-02T05:26:36.115Z",
      runId: 3,
      agent: "worker",
      lastToolName: "edit",
      toolCallCount: 12,
      lastLine: "updated presentation",
    })).toEqual({
      runId: 3,
      lastActivity: { toolName: "edit", toolCallCount: 12, lastLine: "updated presentation" },
    });
    expect(subagentRunActivityUpdateFromDiagnostic({ runId: 3, agent: "worker" })).toBeUndefined();
  });

  it("caps retained history at the newest 100 runs", () => {
    const runs = Array.from({ length: 102 }, (_, index) => ({
      runId: index + 1,
      agent: "worker",
      task: `task ${index + 1}`,
      status: "done" as const,
    }));
    expect(capSubagentRuns(runs).map((run) => run.runId)).toEqual(Array.from({ length: 100 }, (_, index) => index + 3));
  });
});
