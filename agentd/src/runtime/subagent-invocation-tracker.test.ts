import { describe, expect, it } from "vitest";
import type { AsyncTask } from "../domain/async-task-contract.js";
import { SubagentInvocationTracker } from "./subagent-invocation-tracker.js";

const root: AsyncTask = {
  sessionId: "session", piSessionId: "pi", runtimeInstanceId: "runtime", providerId: "subagent", providerInstanceId: "provider",
  taskId: "root", rootTaskId: "root", invocationId: "call", kind: "subagent", title: "Worker", execution: "succeeded", presence: "unknown",
  registration: "spawned", grantId: "grant", providerRevision: 3, controlGeneration: 0,
  createdAt: "2026-09-25T00:00:00.000Z", updatedAt: "2026-09-25T00:00:00.000Z",
};
const start = { type: "tool_execution_start", toolCallId: "call", toolName: "subagent", args: { command: "subagent run worker -- Inspect" } };
const end = { type: "tool_execution_end", toolCallId: "call", toolName: "subagent", result: { content: [{ type: "text", text: "Accepted" }] } };

describe("subagent invocation ownership", () => {
  it("keeps a tracked invocation open after tool return and result completion until actual root settlement", () => {
    const tracker = new SubagentInvocationTracker();
    expect(tracker.captureLaunchIntent(start)).toMatchObject({ invocationId: "call" });
    expect(tracker.applyTrackedTasks([root])).toEqual([]);
    expect(tracker.closeInvocationIfSettled(end)).toBeUndefined();
    expect(tracker.applyTrackedTasks([{ ...root, presence: "active" }])).toEqual([]);
    expect(tracker.applyTrackedTasks([{ ...root, presence: "settled" }])).toMatchObject([{ invocationId: "call", completed: true }]);
    expect(tracker.applyTrackedTasks([{ ...root, presence: "settled" }])).toEqual([]);
  });
  it("retains the legacy synchronous tool completion contract when no task claims the invocation", () => {
    const tracker = new SubagentInvocationTracker();
    tracker.captureLaunchIntent(start);
    expect(tracker.closeInvocationIfSettled(end)).toMatchObject({ invocationId: "call", completed: true });
  });
});
