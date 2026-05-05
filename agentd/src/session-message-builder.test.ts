import { describe, expect, it } from "vitest";
import type { PickySessionMessage } from "./protocol.js";
import { SessionMessageBuilder } from "./session-message-builder.js";

function makeBuilder() {
  let seq = 0;
  const messages: PickySessionMessage[] = [];
  const events: Array<{ type: "appended"; message: PickySessionMessage; seq: number } | { type: "replaced"; messageId: string; message: PickySessionMessage; seq: number } | { type: "removed"; messageId: string; seq: number }> = [];
  const builder = new SessionMessageBuilder({
    emitAppended: async (_sessionId, message, eventSeq) => { events.push({ type: "appended", message, seq: eventSeq }); },
    emitReplaced: async (_sessionId, messageId, message, eventSeq) => { events.push({ type: "replaced", messageId, message, seq: eventSeq }); },
    emitRemoved: async (_sessionId, messageId, eventSeq) => { events.push({ type: "removed", messageId, seq: eventSeq }); },
    nextSeq: () => ++seq,
    now: () => "2026-05-01T00:00:00.000Z",
    syncSessionMessages: async (_sessionId, nextMessages) => {
      messages.splice(0, messages.length, ...nextMessages);
    },
  });
  return { builder, events, messages };
}

describe("SessionMessageBuilder", () => {
  it("records user text with origin and monotonic sequence", async () => {
    const { builder, events, messages } = makeBuilder();

    await builder.recordUserText("session-1", " hello ", "user");
    await builder.recordUserText("session-1", "from main", "main_agent");

    expect(messages.map((message) => ({ kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { kind: "user_text", text: "hello", originatedBy: "user" },
      { kind: "user_text", text: "from main", originatedBy: "main_agent" },
    ]);
    expect(events.map((event) => event.seq)).toEqual([1, 2]);
  });

  it("seeds pinned sessions with deterministic intro messages", async () => {
    const { builder, messages } = makeBuilder();

    await builder.seedPinnedSession("session-pin", "\n first line \n second", "Final answer", "Pinned title");

    expect(messages.map((message) => ({ id: message.id, kind: message.kind, text: message.text, originatedBy: message.originatedBy }))).toEqual([
      { id: "msg-pin-user-session-pin", kind: "user_text", text: "first line", originatedBy: "pi_extension" },
      { id: "msg-pin-system-session-pin", kind: "system", text: "Pinned from idle Pi session", originatedBy: undefined },
      { id: "msg-pin-agent-session-pin", kind: "agent_text", text: "Final answer", originatedBy: undefined },
    ]);
  });

  it("buffers assistant deltas until a boundary flush", async () => {
    const { builder, events, messages } = makeBuilder();

    builder.appendAssistantDelta("session-1", "Hel");
    builder.appendAssistantDelta("session-1", "lo");
    expect(messages).toEqual([]);

    await builder.flushAssistantText("session-1");

    expect(messages).toMatchObject([{ kind: "agent_text", text: "Hello" }]);
    expect(events).toMatchObject([{ type: "appended", seq: 1 }]);
  });

  it("replaces and removes a stable thinking message per phase", async () => {
    const { builder, events, messages } = makeBuilder();

    await builder.appendThinkingDelta("session-1", "think");
    const thinkingId = messages[0].id;
    await builder.appendThinkingDelta("session-1", " more");
    await builder.flushThinking("session-1");
    await builder.appendThinkingDelta("session-1", "new phase");

    expect(events.map((event) => event.type)).toEqual(["appended", "replaced", "removed", "appended"]);
    expect(events[1]).toMatchObject({ type: "replaced", messageId: thinkingId, message: { text: "think more" } });
    expect(events[2]).toMatchObject({ type: "removed", messageId: thinkingId });
    expect(messages).toMatchObject([{ kind: "agent_thinking", text: "new phase" }]);
    expect(messages[0].id).not.toBe(thinkingId);
  });

  it("records questions, cancellations, errors, system messages, and final reports", async () => {
    const { builder, events, messages } = makeBuilder();

    await builder.recordExtensionQuestion("session-1", { id: "question-1", sessionId: "session-1", method: "input", createdAt: "2026-05-01T00:00:00.000Z", prompt: "Need input" });
    await builder.cancelExtensionQuestion("session-1", "question-1");
    await builder.recordError("session-1", "Boom");
    await builder.recordSystemMessage("session-1", "Cancelled by user");
    await builder.recordFinalReport("session-1", { summary: "Done", body: "Body", status: "success", artifacts: [] });

    expect(messages.map((message) => message.kind)).toEqual(["agent_question", "agent_error", "system", "agent_report"]);
    expect(messages[0].cancelledAt).toBe("2026-05-01T00:00:00.000Z");
    expect(events.map((event) => event.type)).toEqual(["appended", "replaced", "appended", "appended", "appended"]);
  });
});
