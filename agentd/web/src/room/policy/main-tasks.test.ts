/**
 * Where the Picky room shows its Tasks and "hand this to a Pickle?" questions.
 *
 * The rules that matter here are product rules, not layout: a block sits in the
 * turn it started in, right after what Picky said about it; a question the user
 * never answered stays on screen (docs/picky-task-routing-plan.md 3); an
 * answered one stays as a record; a new conversation does not inherit old
 * results. The Mac checks the same cases in PickyTests/PickyMainTaskTests.swift.
 */
import { describe, expect, it } from "vitest";

import type { RemoteMainDelegation, RemoteMainMessage, RemoteMainState, RemoteMainTask } from "../../../../src/remote/protocol";
import { mainTimeline, taskTone, waitingDecision } from "./main-tasks";

const START = Date.parse("2026-10-08T10:00:00.000Z");
const at = (seconds: number): string => new Date(START + seconds * 1000).toISOString();

function task(id: string, createdAt: string, overrides: Partial<RemoteMainTask> = {}): RemoteMainTask {
  return {
    id,
    title: id,
    status: "running",
    readonly: false,
    createdAt,
    updatedAt: createdAt,
    canStop: true,
    canResume: false,
    ...overrides,
  };
}

function decision(id: string, createdAt: string, overrides: Partial<RemoteMainDelegation> = {}): RemoteMainDelegation {
  return {
    id,
    state: "pending",
    title: id,
    instructions: `handle ${id}`,
    createdAt,
    updatedAt: createdAt,
    ...overrides,
  };
}

function message(id: string, role: RemoteMainMessage["role"], createdAt: string): RemoteMainMessage {
  return { id, role, text: id, createdAt };
}

function keys(main: Partial<RemoteMainState>): string[] {
  return mainTimeline({ messages: [], tasks: [], decisions: [], ...main }).map((entry) => entry.key);
}

describe("Tasks and questions in the Picky room", () => {
  it("puts a Task right after the reply that announced it", () => {
    expect(keys({
      messages: [message("request", "user", at(0)), message("announcement", "assistant", at(8)), message("result", "assistant", at(300))],
      tasks: [task("report", at(5), { status: "completed", canStop: false })],
    })).toEqual(["request", "announcement", "task-report", "result"]);
  });

  it("puts a question after what Picky said right before asking", () => {
    expect(keys({
      messages: [
        message("request", "user", at(0)),
        message("announcement", "assistant", at(8)),
        message("explanation", "assistant", at(40)),
        message("after-answer", "assistant", at(60)),
      ],
      tasks: [task("check", at(5), { status: "blocked", canStop: false })],
      decisions: [decision("fix", at(40.1), { state: "pickle", pickle: { state: "created", sessionId: "s1" } })],
    })).toEqual(["request", "announcement", "task-check", "explanation", "decision-fix", "after-answer"]);
  });

  it("closes the turn while Picky has not replied yet", () => {
    const tasks = [task("rename", at(2))];
    expect(keys({ messages: [message("request", "user", at(0))], tasks })).toEqual(["request", "task-rename"]);
    expect(keys({ messages: [message("request", "user", at(0)), message("next", "user", at(10))], tasks }))
      .toEqual(["request", "task-rename", "next"]);
  });

  it("keeps only open work and waiting questions older than the transcript, at the top", () => {
    expect(keys({
      messages: [message("hello", "user", at(100))],
      tasks: [task("old-done", at(10), { status: "completed", canStop: false }), task("old-running", at(20))],
      decisions: [decision("old-question", at(30)), decision("old-answer", at(40), { state: "task", taskId: "t" })],
    })).toEqual(["task-old-running", "decision-old-question", "hello"]);
  });

  it("starts a new conversation without earlier results", () => {
    expect(keys({
      tasks: [task("done", at(10), { status: "completed", canStop: false }), task("running", at(20))],
      decisions: [decision("answered", at(30), { state: "cancelled" })],
    })).toEqual(["task-running"]);
  });

  it("points the pinned bar at the newest question still waiting", () => {
    expect(waitingDecision({
      decisions: [
        decision("older", at(10)),
        decision("newer", at(20)),
        decision("answered", at(30), { state: "task", taskId: "t" }),
      ],
    })?.id).toBe("newer");
    expect(waitingDecision({ decisions: [decision("failed", at(5), { state: "pickle", pickle: { state: "failed" } })] })).toBeUndefined();
  });

  it("separates work still going from work that needs a look", () => {
    expect(taskTone(task("t", at(0), { status: "stopping" }))).toBe("running");
    expect(taskTone(task("t", at(0), { status: "blocked" }))).toBe("attention");
    expect(taskTone(task("t", at(0), { status: "interrupted" }))).toBe("attention");
    expect(taskTone(task("t", at(0), { status: "cancelled" }))).toBe("done");
    expect(taskTone(task("t", at(0), { status: "completed" }))).toBe("done");
  });
});
