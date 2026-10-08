/**
 * What the Picky room's Tasks section shows, case by case.
 *
 * The rules that matter here are product rules, not layout: a decision the
 * user never answered must stay on screen (docs/picky-task-routing-plan.md 3),
 * a failed Pickle creation must stay retryable (section 7), and running work
 * must never be pushed below finished work.
 */
import { describe, expect, it } from "vitest";

import type { RemoteMainDelegation, RemoteMainState, RemoteMainTask } from "../../../../src/remote/protocol";
import { mainTasksModel, taskTone } from "./main-tasks";

function task(id: string, overrides: Partial<RemoteMainTask> = {}): RemoteMainTask {
  return {
    id,
    title: id,
    status: "running",
    readonly: false,
    createdAt: "2026-10-08T10:00:00.000Z",
    updatedAt: "2026-10-08T10:00:00.000Z",
    canStop: true,
    canResume: false,
    ...overrides,
  };
}

function decision(id: string, overrides: Partial<RemoteMainDelegation> = {}): RemoteMainDelegation {
  return {
    id,
    state: "pending",
    title: id,
    instructions: `handle ${id}`,
    createdAt: "2026-10-08T11:00:00.000Z",
    updatedAt: "2026-10-08T11:00:00.000Z",
    ...overrides,
  };
}

function main(overrides: Partial<RemoteMainState> = {}): RemoteMainState {
  return { messages: [], busy: false, tasks: [], decisions: [], ...overrides };
}

describe("the Tasks section", () => {
  it("stays out of the room until the main agent actually runs something", () => {
    expect(mainTasksModel(undefined)).toBeNull();
    expect(mainTasksModel(main())).toBeNull();
    // Decisions the user already answered are history, not a control.
    expect(mainTasksModel(main({ decisions: [decision("d1", { state: "task", taskId: "t1" })] }))).toBeNull();
  });

  it("keeps an unanswered decision on screen and offers a retry after a failed Pickle creation", () => {
    const model = mainTasksModel(main({
      decisions: [
        decision("answered", { state: "pickle", pickle: { state: "created", sessionId: "s1" } }),
        decision("failed", { state: "pickle", pickle: { state: "failed", error: "cwd is gone" } }),
        decision("pending"),
      ],
    }));
    expect(model?.decisions.map((item) => item.id)).toEqual(["failed", "pending"]);
  });

  it("names running work first, then the newest finished Task", () => {
    const model = mainTasksModel(main({
      tasks: [
        task("old", { status: "completed", canStop: false, updatedAt: "2026-10-08T09:00:00.000Z" }),
        task("recent", { status: "failed", canStop: false, canResume: true, updatedAt: "2026-10-08T12:00:00.000Z" }),
        task("live"),
      ],
    }));
    expect(model?.tasks.map((item) => item.id)).toEqual(["live", "recent", "old"]);
    expect(model?.summary).toEqual({ key: "remote.room.tasks.summary.running", count: 1 });
  });

  it("summarizes what the user can do once nothing is running", () => {
    const resumable = mainTasksModel(main({
      tasks: [
        task("blocked", { status: "blocked", canStop: false, canResume: true }),
        task("done", { status: "completed", canStop: false }),
      ],
    }));
    expect(resumable?.summary).toEqual({ key: "remote.room.tasks.summary.resumable", count: 1 });

    const finished = mainTasksModel(main({ tasks: [task("done", { status: "completed", canStop: false })] }));
    expect(finished?.summary).toEqual({ key: "remote.room.tasks.summary.finished", count: 1 });
  });

  it("separates work still going from work that needs a look", () => {
    expect(taskTone(task("t", { status: "stopping" }))).toBe("running");
    expect(taskTone(task("t", { status: "blocked" }))).toBe("attention");
    expect(taskTone(task("t", { status: "interrupted" }))).toBe("attention");
    expect(taskTone(task("t", { status: "cancelled" }))).toBe("done");
    expect(taskTone(task("t", { status: "completed" }))).toBe("done");
  });
});
