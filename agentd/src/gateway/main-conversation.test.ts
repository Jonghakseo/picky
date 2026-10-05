import { describe, expect, it } from "vitest";

import { extractFileReferences } from "./file-references.js";
import { MainConversation } from "./main-conversation.js";

/** What a phone in the Picky room sees: the last `busy` the gateway broadcast. */
function room(): { main: MainConversation; busy: () => boolean | undefined } {
  let busy: boolean | undefined;
  const main = new MainConversation({
    onMessage: () => {},
    onActivity: (_activity, next) => {
      busy = next;
    },
    onQuestion: () => {},
    onStateReplaced: (state) => {
      busy = state.busy;
    },
  });
  return { main, busy: () => busy };
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
