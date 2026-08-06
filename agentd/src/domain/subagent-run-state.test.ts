import { describe, expect, it } from "vitest";
import { applySubagentRunUpdate, capSubagentRuns, retainSubagentRunResultText, subagentGroupRunUpdatesFromCustomMessage, subagentLaunchIntentFromToolArgs, subagentRunActivityUpdateFromDiagnostic, subagentRunUpdateFromCustomMessage, subagentRunUpdateFromDiagnostic, subagentRunUpdatesFromToolResult } from "./subagent-run-state.js";

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
      resultText: "Final result",
    }));
  });

  it("keeps the complete single-run response while previewing its trailing paragraph", () => {
    const update = subagentRunUpdateFromCustomMessage("subagent-tool", {
      runId: 12,
      agent: "worker",
      task: "Inspect the implementation",
      status: "done",
    }, "[subagent:worker#12] completed\nPrompt: Inspect\n\nFirst paragraph\n\nFinal paragraph");

    expect(update).toMatchObject({
      resultText: "First paragraph\n\nFinal paragraph",
      resultPreview: "Final paragraph",
    });
  });

  it("parses batch sections only at known headers preceded by a blank line", () => {
    const updates = subagentGroupRunUpdatesFromCustomMessage("subagent-tool", {
      batchId: "batch-a",
      runIds: [12, 13],
      status: "done",
      runSummaries: [
        { runId: 12, agent: "reviewer", status: "done", elapsedMs: 120, model: "model-a" },
        { runId: 13, agent: "challenger", status: "error", elapsedMs: 240, errorClass: "timeout" },
      ],
    }, [
      "[subagent-batch#batch-a] completed",
      "Runs: #12 done, #13 error",
      "",
      "#12 reviewer",
      "- First response line",
      "#99 unrelated header",
      "#13 challenger",
      "still part of reviewer output",
      "",
      "#13 challenger",
      "- Challenger response",
    ].join("\n"));

    expect(updates).toEqual([
      expect.objectContaining({
        runId: 12,
        agent: "reviewer",
        status: "done",
        batchId: "batch-a",
        elapsedMs: 120,
        model: "model-a",
        resultText: "First response line\n#99 unrelated header\n#13 challenger\nstill part of reviewer output",
      }),
      expect.objectContaining({
        runId: 13,
        agent: "challenger",
        status: "error",
        errorClass: "timeout",
        resultText: "Challenger response",
      }),
    ]);
  });

  it("parses chain sections and removes a multiline known task", () => {
    const updates = subagentGroupRunUpdatesFromCustomMessage("subagent-command", {
      pipelineId: "pipeline-a",
      stepRunIds: [12],
      status: "done",
      runSummaries: [{ runId: 12, agent: "worker", status: "done", stepIndex: 0 }],
    }, [
      "[subagent-chain#pipeline-a] completed",
      "",
      "Step 1 · #12 worker · done",
      "Task: Inspect the implementation",
      "across multiple files",
      "Full response with details.",
    ].join("\n"), new Map([[12, "Inspect the implementation\nacross multiple files"]]));

    expect(updates).toEqual([expect.objectContaining({
      runId: 12,
      pipelineId: "pipeline-a",
      pipelineStepIndex: 0,
      resultText: "Full response with details.",
    })]);
  });

  it("extracts sync single-run responses after an idle warning and maps escalation to error", () => {
    const knownRuns = [{ runId: 12, agent: "worker", task: "Inspect", status: "running" as const }];
    const completed = subagentRunUpdatesFromToolResult({ content: [{ type: "text", text: [
      "Idle warning", "", "[subagent:worker#12] completed", "Prompt: Inspect", "", "Complete response",
    ].join("\n") }] }, knownRuns);
    const escalated = subagentRunUpdatesFromToolResult("Idle warning\n\n[subagent:worker#12] escalated\nPrompt: Inspect\n\nEscalation response", knownRuns);

    expect(completed).toEqual([expect.objectContaining({ runId: 12, agent: "worker", status: "done", resultText: "Complete response" })]);
    expect(escalated).toEqual([expect.objectContaining({ runId: 12, agent: "worker", status: "error", resultText: "Escalation response" })]);
  });

  it("extracts sync batch and chain responses only for matching diagnostic runs", () => {
    const batchRuns = [
      { runId: 12, agent: "worker", task: "Inspect", status: "done" as const, batchId: "batch-a" },
      { runId: 13, agent: "reviewer", task: "Review", status: "error" as const, batchId: "batch-a" },
    ];
    const chainRuns = [
      { runId: 14, agent: "worker", task: "Inspect\nmultiple files", status: "done" as const, pipelineId: "chain-a", pipelineStepIndex: 0 },
      { runId: 15, agent: "reviewer", task: "Review", status: "error" as const, pipelineId: "chain-a", pipelineStepIndex: 1 },
    ];

    expect(subagentRunUpdatesFromToolResult([
      "Idle warning", "", "[subagent-batch#batch-a] completed", "Runs: #12 done, #13 error", "", "#12 worker", "- Worker response", "", "#13 reviewer", "- Reviewer response",
    ].join("\n"), batchRuns)).toEqual([
      expect.objectContaining({ runId: 12, status: "done", resultText: "Worker response" }),
      expect.objectContaining({ runId: 13, status: "error", resultText: "Reviewer response" }),
    ]);
    expect(subagentRunUpdatesFromToolResult([
      "[subagent-chain#chain-a] error", "", "Step 1 · #14 worker · done", "Task: Inspect", "multiple files", "Worker response", "", "Step 2 · #15 reviewer · error", "Task: Review", "Reviewer response",
    ].join("\n"), chainRuns)).toEqual([
      expect.objectContaining({ runId: 14, status: "done", resultText: "Worker response" }),
      expect.objectContaining({ runId: 15, status: "error", resultText: "Reviewer response" }),
    ]);
  });

  it("does not match chain sections for summaries without a usable step index", () => {
    const updates = subagentGroupRunUpdatesFromCustomMessage("subagent-tool", {
      pipelineId: "pipeline-a",
      stepRunIds: [12],
      status: "done",
      runSummaries: [{ runId: 12, agent: "worker", status: "done" }],
    }, "[subagent-chain#pipeline-a] completed\n\n\n- unrelated output");

    expect(updates).toEqual([]);
  });

  it("skips group runs whose exact known header is absent", () => {
    const updates = subagentGroupRunUpdatesFromCustomMessage("subagent-tool", {
      batchId: "batch-a",
      runIds: [12, 13],
      status: "done",
      runSummaries: [
        { runId: 12, agent: "worker", status: "done" },
        { runId: 13, agent: "reviewer", status: "done" },
      ],
    }, "[subagent-batch#batch-a] completed\n\n#12 worker\n- Present response");

    expect(updates.map((update) => update.runId)).toEqual([12]);
  });

  it("rejects unrelated or incomplete custom messages",  () => {
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

  it("upserts by invocation and run ID while keeping duplicate run IDs ordered", () => {
    const next = applySubagentRunUpdate([{ runId: 4, agent: "worker", task: "later", status: "running", invocationId: "first" }], {
      runId: 2, agent: "reviewer", task: "first", status: "running", invocationId: "first",
    });
    const updated = applySubagentRunUpdate(next, { runId: 4, agent: "worker", task: "later", status: "done", elapsedMs: 10, invocationId: "first" });
    const reused = applySubagentRunUpdate(updated, {
      runId: 4,
      agent: "worker",
      task: "new invocation",
      status: "running",
      invocationId: "second",
    });

    expect(reused.map((run) => [run.invocationId, run.runId])).toEqual([["first", 2], ["first", 4], ["second", 4]]);
    expect(reused[1]).toMatchObject({ status: "done", elapsedMs: 10, task: "later" });
    expect(reused[2]).toMatchObject({ status: "running", task: "new invocation" });
  });

  it("updates the most recent reused run ID when an update has no invocation ID", () => {
    const runs = applySubagentRunUpdate([
      { runId: 4, agent: "worker", task: "old task", status: "done" as const, invocationId: "first" },
      { runId: 4, agent: "worker", task: "new task", status: "running" as const, invocationId: "second" },
    ], { runId: 4, agent: "worker", task: "new task", status: "done", elapsedMs: 25 });

    expect(runs).toEqual([
      expect.objectContaining({ invocationId: "first", status: "done", task: "old task" }),
      expect.objectContaining({ invocationId: "second", status: "done", elapsedMs: 25, task: "new task" }),
    ]);
  });

  it("replaces terminal run state for an unscoped fresh spawn", () => {
    const updated = applySubagentRunUpdate([{
      runId: 4,
      agent: "worker",
      task: "old task",
      status: "done",
      elapsedMs: 10,
      resultPreview: "old result",
      errorClass: "timeout",
      lastActivity: { toolName: "bash" },
      displayTask: "Old task",
    }], {
      runId: 4,
      agent: "worker",
      task: "new task",
      status: "running",
    });

    expect(updated).toEqual([{ runId: 4, agent: "worker", task: "new task", status: "running" }]);
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
      contextTokens: 84_000,
      contextWindow: 200_000,
      contextPercent: 42,
    })).toEqual({
      runId: 3,
      lastActivity: {
        toolName: "edit",
        toolCallCount: 12,
        lastLine: "updated presentation",
        contextUsage: { tokens: 84_000, contextWindow: 200_000, percent: 42 },
      },
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

  it("caps result text at 32000 UTF-16 code units and retains it for only 30 recent runs", () => {
    const oversized = subagentRunUpdateFromCustomMessage("subagent-tool", {
      runId: 12,
      agent: "worker",
      task: "Inspect",
      status: "done",
    }, `[subagent:worker#12] completed\n\n${"x".repeat(32_001)}`);
    expect(oversized?.resultText).toHaveLength(32_000);

    const runs = Array.from({ length: 31 }, (_, index) => ({
      runId: index + 1,
      agent: "worker",
      task: `task ${index + 1}`,
      status: "done" as const,
      startedAt: new Date(Date.UTC(2026, 0, 1, 0, 0, 31 - index)).toISOString(),
      elapsedMs: 100,
      resultText: `response ${index + 1}`,
    }));
    const retained = retainSubagentRunResultText(runs);
    expect(retained[0]?.resultText).toBe("response 1");
    expect(retained[1]?.resultText).toBe("response 2");
    expect(retained[30]).not.toHaveProperty("resultText");
  });
});
