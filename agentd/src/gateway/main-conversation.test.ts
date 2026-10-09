import { describe, expect, it } from "vitest";

import { REMOTE_LIMITS } from "../remote/constants.js";
import type { MainDelegationDecision, MainTask } from "../features/main-tasks/schema.js";
import { extractFileReferences } from "./file-references.js";
import { MainConversation } from "./main-conversation.js";
import type { RemoteMainTasksView } from "./main-tasks.js";

/** What a phone in the Picky room sees: the last `busy` the gateway broadcast. */
function room(): { main: MainConversation; busy: () => boolean | undefined; tasks: () => RemoteMainTasksView | undefined } {
  let busy: boolean | undefined;
  let tasks: RemoteMainTasksView | undefined;
  const main = new MainConversation({
    onMessage: () => {},
    onActivity: (_activity, next) => {
      busy = next;
    },
    onQuestion: () => {},
    onStateReplaced: (state) => {
      busy = state.busy;
    },
    onTasks: (view) => {
      tasks = view;
    },
  });
  return { main, busy: () => busy, tasks: () => tasks };
}

function task(id: string, overrides: Partial<MainTask> = {}): MainTask {
  return {
    id,
    revision: 1,
    title: id,
    status: "running",
    cwd: "/work",
    readonly: false,
    instructions: [`do ${id}`],
    createdAt: "2026-10-08T10:00:00.000Z",
    updatedAt: "2026-10-08T10:00:00.000Z",
    canStop: true,
    canResume: false,
    ...overrides,
  };
}

function decision(id: string, overrides: Partial<MainDelegationDecision> = {}): MainDelegationDecision {
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

const reply = { role: "assistant", text: "안농!", createdAt: "2026-10-05T09:30:01.000Z" };

describe("the Picky room's running state", () => {
  it("ends when a main turn answers, which agentd reports as quickReply rather than mainTurnSettled", () => {
    // Order seen from agentd for a phone message that gets an answer.
    const { main, busy } = room();
    main.markTurnStarted();
    main.handleEvent({ type: "mainActivityUpdated", activity: { kind: "thinking" } });
    main.handleEvent({ type: "mainMessageAppended", message: reply });
    main.handleEvent({ type: "mainActivityUpdated" });
    expect(busy()).toBe(true);

    main.handleEvent({ type: "quickReply", contextId: "ctx-1", text: "안농!", replyKind: "main", originSource: "text" });
    expect(busy()).toBe(false);
  });

  it("ends on a router reply and on a delivered Pickle completion, which are main turns too", () => {
    for (const event of [
      { type: "quickReply", contextId: "ctx-2", text: "바로 답", replyKind: "router" },
      { type: "quickReply", contextId: "session-1", text: "끝났어", replyKind: "pickleCompletion", sessionId: "session-1" },
    ]) {
      const { main, busy } = room();
      main.markTurnStarted();
      main.handleEvent(event);
      expect(busy()).toBe(false);
    }
  });

  it("stays running when a Pickle speaks for itself while the main turn is still going", () => {
    const { main, busy } = room();
    main.markTurnStarted();
    main.handleEvent({ type: "quickReply", contextId: "ctx-pickle", text: "이거 봐", replyKind: "main", sessionId: "session-9" });
    expect(busy()).toBe(true);
  });

  it("still ends on mainTurnSettled, and after an abort or a failed submit", () => {
    const settled = room();
    settled.main.markTurnStarted();
    settled.main.handleEvent({ type: "mainTurnSettled", contextId: "ctx-3" });
    expect(settled.busy()).toBe(false);

    const aborted = room();
    aborted.main.markTurnStarted();
    aborted.main.handleEvent({ type: "mainActivityUpdated", activity: { kind: "tool", toolName: "bash", status: "running" } });
    aborted.main.markTurnSettled();
    expect(aborted.busy()).toBe(false);
  });
});

describe("the Picky room's Tasks", () => {
  it("replaces the whole set on every snapshot and counts only Tasks that still occupy a worker", () => {
    const { main, tasks } = room();
    main.handleEvent({
      type: "mainTasksUpdated",
      tasks: [
        task("running"),
        task("waiting", { status: "waiting" }),
        task("stopping", { status: "stopping", canStop: false }),
        task("done", { status: "completed", canStop: false }),
      ],
      decisions: [],
    });
    expect(main.activeTaskCount).toBe(3);
    expect(tasks()?.tasks.map((item) => item.id)).toEqual(["running", "waiting", "stopping", "done"]);
    expect(main.state().tasks.map((item) => item.id)).toEqual(["running", "waiting", "stopping", "done"]);

    main.handleEvent({ type: "mainTasksUpdated", tasks: [task("running", { status: "cancelled", canStop: false, canResume: true })], decisions: [] });
    expect(main.activeTaskCount).toBe(0);
    expect(main.state().tasks).toHaveLength(1);
    expect(main.state().tasks[0]?.canResume).toBe(true);
  });

  it("keeps a pending decision visible and carries the failed Pickle error so the phone can offer a retry", () => {
    const { main } = room();
    main.handleEvent({
      type: "mainTasksUpdated",
      tasks: [],
      decisions: [
        decision("d-failed", { state: "pickle", pickle: { state: "failed", error: "cwd is gone" } }),
        decision("d-pending", { question: "피클에 맡길까요?" }),
      ],
    });
    expect(main.hasPendingDecision).toBe(true);
    const [failed, pending] = main.state().decisions;
    expect(failed?.pickle).toEqual({ state: "failed", error: "cwd is gone" });
    expect(pending?.question).toBe("피클에 맡길까요?");

    main.handleEvent({ type: "mainTasksUpdated", tasks: [], decisions: [decision("d-pending", { state: "task", taskId: "t1" })] });
    expect(main.hasPendingDecision).toBe(false);
  });

  it("bounds what it sends without dropping work the user can still act on", () => {
    const { main } = room();
    const finished = Array.from({ length: REMOTE_LIMITS.mainTasks + 20 }, (_, index) =>
      task(`old-${index}`, { status: "completed", canStop: false, updatedAt: `2026-10-0${1 + (index % 8)}T00:00:00.000Z` }));
    main.handleEvent({ type: "mainTasksUpdated", tasks: [...finished, task("live")], decisions: [] });

    const sent = main.state().tasks;
    expect(sent).toHaveLength(REMOTE_LIMITS.mainTasks);
    expect(sent.some((item) => item.id === "live")).toBe(true);
    // The count on the room list comes from the full snapshot, not the trimmed list.
    expect(main.activeTaskCount).toBe(1);
  });

  it("clips long result text instead of forwarding a whole report", () => {
    const { main } = room();
    main.handleEvent({
      type: "mainTasksUpdated",
      tasks: [task("t1", {
        status: "blocked",
        canStop: false,
        canResume: true,
        report: {
          status: "blocked",
          summary: "x".repeat(REMOTE_LIMITS.mainTaskTextChars + 500),
          artifacts: [],
          verification: [],
          blockers: Array.from({ length: REMOTE_LIMITS.mainTaskListItems + 5 }, (_, index) => `blocker ${index}`),
        },
      })],
      decisions: [],
    });
    const report = main.state().tasks[0]?.report;
    expect(report?.summary).toHaveLength(REMOTE_LIMITS.mainTaskTextChars);
    expect(report?.blockers).toHaveLength(REMOTE_LIMITS.mainTaskListItems);
  });

  it("tells the phone how demanding each Task was judged, once it is known", () => {
    const { main } = room();
    main.handleEvent({ type: "mainTasksUpdated", tasks: [task("judged", { tier: "powerful" }), task("judging", { status: "evaluating" })], decisions: [] });
    expect(main.state().tasks.map((entry) => entry.tier)).toEqual(["powerful", undefined]);
  });
});

describe("images the main agent read", () => {
  const readImage = (toolCallId: string, imagePath: string) => ({
    type: "mainActivityUpdated",
    activity: { kind: "tool", toolCallId, toolName: "read", status: "succeeded", imagePath, imageMimeType: "image/jpeg" },
  });

  it("show up in the Picky room after the text before them, once each, and survive a transcript reload", () => {
    const { main } = room();
    main.handleEvent({ type: "mainMessagesSnapshot", messages: [{ role: "user", text: "이거 봐줘", createdAt: "2000-01-01T00:00:00.000Z" }] });
    main.handleEvent(readImage("call-1", "/uploads/7973.jpg"));
    main.handleEvent(readImage("call-1", "/uploads/7973.jpg"));
    main.handleEvent({ type: "mainMessageAppended", message: { role: "assistant", text: "고양이네요", createdAt: "2999-01-01T00:00:00.000Z" } });

    const rows = () => main.state().messages.map((message) => message.image?.path ?? message.text);
    expect(rows()).toEqual(["이거 봐줘", "/uploads/7973.jpg", "고양이네요"]);

    // The primary daemon re-sends its text-only transcript on reconnect.
    main.handleEvent({
      type: "mainMessagesSnapshot",
      messages: [
        { role: "user", text: "이거 봐줘", createdAt: "2000-01-01T00:00:00.000Z" },
        { role: "assistant", text: "고양이네요", createdAt: "2999-01-01T00:00:00.000Z" },
      ],
    });
    expect(rows()).toEqual(["이거 봐줘", "/uploads/7973.jpg", "고양이네요"]);
    expect(main.lastAssistantText()).toBe("고양이네요");
  });

  it("ignore a read that is still running, failed, or returned text", () => {
    const { main } = room();
    main.handleEvent({ type: "mainActivityUpdated", activity: { kind: "tool", toolCallId: "a", toolName: "read", status: "running" } });
    main.handleEvent({ type: "mainActivityUpdated", activity: { kind: "tool", toolCallId: "b", toolName: "read", status: "failed" } });
    main.handleEvent({ type: "mainActivityUpdated", activity: { kind: "tool", toolCallId: "c", toolName: "read", status: "succeeded" } });
    expect(main.state().messages).toEqual([]);
  });

  it("are files the Picky room may open, like its own reply links", () => {
    const { main } = room();
    main.handleEvent(readImage("call-1", "/uploads/7973.jpg"));
    main.handleEvent({ type: "mainMessageAppended", message: { role: "assistant", text: "[보고서](/tmp/report.md)", createdAt: "2999-01-01T00:00:00.000Z" } });
    expect(extractFileReferences(main.fileReferences()).sort()).toEqual(["/tmp/report.md", "/uploads/7973.jpg"]);
  });
});
