import path from "node:path";
import { describe, expect, it } from "vitest";
import { MainTaskEvaluationContext, taskWorkerEnvironment } from "./picky-task-runtime.js";
import type { TaskRecord } from "./types.js";

describe("taskWorkerEnvironment", () => {
  it("keeps provider credentials but drops the daemon token, Picky pointers, and the internal picky CLI", () => {
    const bin = "/Users/me/Library/Application Support/Picky/bin";
    const env = taskWorkerEnvironment({
      HOME: "/Users/me",
      OPENAI_API_KEY: "sk-test",
      PI_CODING_AGENT_DIR: "/Users/me/.pi/agent",
      PICKY_AGENTD_TOKEN: "secret-token",
      PICKY_APP_SUPPORT_DIR: "/Users/me/Library/Application Support/Picky",
      PATH: [bin, "/opt/homebrew/bin", `${bin}/`, "/usr/bin"].join(path.delimiter),
    }, bin);
    expect(env).toEqual({
      HOME: "/Users/me",
      OPENAI_API_KEY: "sk-test",
      PI_CODING_AGENT_DIR: "/Users/me/.pi/agent",
      PATH: ["/opt/homebrew/bin", "/usr/bin"].join(path.delimiter),
    });
  });
});

describe("MainTaskEvaluationContext", () => {
  const record = (overrides: Partial<TaskRecord> = {}): TaskRecord => ({
    id: "task-1", revision: 2, title: "Resume", cwd: "/tmp", instructions: ["Do it", "Continue"], readonly: false,
    status: "queued", createdAt: "2026-10-08T00:00:00.000Z", updatedAt: "2026-10-08T00:00:00.000Z",
    sessionFile: "/tmp/s.jsonl", contextFile: "/tmp/c.json", ...overrides,
  });
  const signal = new AbortController().signal;

  it("resumes on the model the Task already used while the main model is not ready yet", async () => {
    const selection = { provider: "anthropic", model: "claude-sonnet-5-5", thinking: "medium" as const };
    await expect(new MainTaskEvaluationContext().evaluate(record({ tier: "balanced", selection }), { brief: "", entries: [] }, signal))
      .resolves.toEqual({ tier: "balanced", selection, evaluator: "previous selection" });
  });

  it("fails visibly instead of guessing a model for a new Task before the main model is ready", async () => {
    await expect(new MainTaskEvaluationContext().evaluate(record(), { brief: "", entries: [] }, signal)).rejects.toThrow(/main model is not ready/);
  });

  /** A main context whose evaluator answers `tier` and whose catalog knows every model. */
  function mainContext(tier: string, main = { provider: "openai-codex", id: "gpt-6-sol" }) {
    return {
      model: main,
      modelRegistry: {
        find: (provider: string, id: string) => ({ provider, id }),
        hasConfiguredAuth: () => true,
        streamSimple: () => ({ result: async () => ({ content: [{ type: "text", text: `{"tier":"${tier}"}` }], stopReason: "stop" }) }),
      },
    } as unknown as Parameters<MainTaskEvaluationContext["update"]>[0];
  }

  it("runs a new revision on the model the user chose for its level", async () => {
    const evaluation = new MainTaskEvaluationContext();
    evaluation.update(mainContext("fast"));
    evaluation.setPresetOverrides({ fast: { model: { provider: "anthropic", id: "claude-haiku-5-5" }, thinking: "minimal" } });
    await expect(evaluation.evaluate(record(), { brief: "", entries: [] }, signal)).resolves.toMatchObject({
      tier: "fast",
      selection: { provider: "anthropic", model: "claude-haiku-5-5", thinking: "minimal" },
    });

    // Back on automatic, the same level follows the main model's provider again.
    evaluation.setPresetOverrides({});
    await expect(evaluation.evaluate(record(), { brief: "", entries: [] }, signal)).resolves.toMatchObject({
      selection: { provider: "openai-codex", model: "gpt-6-luna", thinking: "low" },
    });
  });

  it("describes automatic for the current main model, and nothing before the main agent starts", () => {
    const evaluation = new MainTaskEvaluationContext();
    expect(evaluation.automaticPresets()).toBeUndefined();
    evaluation.update(mainContext("balanced", { provider: "anthropic", id: "claude-opus-5-5" }));
    // Settings show what automatic would run, not the user's own choices.
    evaluation.setPresetOverrides({ balanced: { thinking: "max" } });
    expect(evaluation.automaticPresets()).toEqual({
      fast: { provider: "anthropic", model: "claude-haiku-5-5", thinking: "low" },
      balanced: { provider: "anthropic", model: "claude-sonnet-5-5", thinking: "medium" },
      powerful: { provider: "anthropic", model: "claude-opus-5-5", thinking: "high" },
    });
  });
});
