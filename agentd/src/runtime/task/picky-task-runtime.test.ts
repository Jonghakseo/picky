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
});
