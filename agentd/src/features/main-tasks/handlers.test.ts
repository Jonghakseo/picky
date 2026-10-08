import { describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION } from "../../protocol-base.js";
import { mainTasksCommandHandlers, type MainTasksPort } from "./handlers.js";

function port(): MainTasksPort & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    snapshot: () => ({ tasks: [], decisions: [] }),
    onChange: () => () => undefined,
    stopTask: vi.fn(async (taskId: string) => { calls.push(`stop:${taskId}`); }),
    resumeTask: vi.fn(async (taskId: string) => { calls.push(`resume:${taskId}`); }),
    resolveDecision: vi.fn(async (decisionId: string, choice: string, actor: string) => { calls.push(`${actor}:${decisionId}:${choice}`); }),
  };
}

const base = { id: "cmd-1", protocolVersion: PROTOCOL_VERSION } as const;

describe("main task commands", () => {
  it("routes the user's stop, resume, and decision answers to the service as user actions", async () => {
    const mainTasks = port();
    const handlers = mainTasksCommandHandlers({ mainTasks });
    await handlers.controlMainTask({ ...base, type: "controlMainTask", taskId: "task-1", action: "stop" });
    await handlers.controlMainTask({ ...base, type: "controlMainTask", taskId: "task-1", action: "resume" });
    await handlers.resolveMainDelegation({ ...base, type: "resolveMainDelegation", decisionId: "delegation-1", choice: "pickle" });
    expect(mainTasks.calls).toEqual(["stop:task-1", "resume:task-1", "app:delegation-1:pickle"]);
  });

  it("fails visibly on a daemon without main Tasks", async () => {
    const handlers = mainTasksCommandHandlers({});
    await expect(handlers.controlMainTask({ ...base, type: "controlMainTask", taskId: "task-1", action: "stop" })).rejects.toThrow(/not available/);
  });
});
