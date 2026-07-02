import { describe, expect, it } from "vitest";
import type { PickySessionMessage } from "./protocol.js";
import { SessionMessageBuilder } from "./session-message-builder.js";

function makeBuilder() {
  let seq = 0;
  let now = "2026-05-01T00:00:00.000Z";
  const messages: PickySessionMessage[] = [];
  const events: Array<{ type: "appended"; message: PickySessionMessage; seq: number } | { type: "imported"; messages: readonly PickySessionMessage[]; seq: number } | { type: "replaced"; messageId: string; message: PickySessionMessage; seq: number } | { type: "removed"; messageId: string; seq: number }> = [];
  const builder = new SessionMessageBuilder({
    emitAppended: async (_sessionId, message, eventSeq) => { events.push({ type: "appended", message, seq: eventSeq }); },
    emitImported: async (_sessionId, importedMessages, eventSeq) => { events.push({ type: "imported", messages: importedMessages, seq: eventSeq }); },
    emitReplaced: async (_sessionId, messageId, message, eventSeq) => { events.push({ type: "replaced", messageId, message, seq: eventSeq }); },
    emitRemoved: async (_sessionId, messageId, eventSeq) => { events.push({ type: "removed", messageId, seq: eventSeq }); },
    nextSeq: () => ++seq,
    now: () => now,
    syncSessionMessages: async (_sessionId, nextMessages) => {
      messages.splice(0, messages.length, ...nextMessages);
    },
  });
  return { builder, events, messages, setNow: (value: string) => { now = value; } };
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

    await builder.flushAssistantText("session-1", { model: "openai-codex/gpt-5.5", thinkingLevel: "high" });

    expect(messages).toMatchObject([{ kind: "agent_text", text: "Hello", assistantRun: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" } }]);
    expect(events).toMatchObject([{ type: "appended", seq: 1 }]);
  });

  it("keeps each thinking phase persisted and starts a new bubble per phase", async () => {
    const { builder, events, messages } = makeBuilder();

    await builder.appendThinkingDelta("session-1", "think");
    const firstThinkingId = messages[0].id;
    await builder.appendThinkingDelta("session-1", " more");
    await builder.flushThinking("session-1");
    await builder.appendThinkingDelta("session-1", "new phase");

    expect(events.map((event) => event.type)).toEqual(["appended", "replaced", "appended"]);
    expect(events[1]).toMatchObject({ type: "replaced", messageId: firstThinkingId, message: { text: "think more" } });
    expect(messages).toMatchObject([
      { kind: "agent_thinking", text: "think more" },
      { kind: "agent_thinking", text: "new phase" },
    ]);
    expect(messages[0].id).toBe(firstThinkingId);
    expect(messages[1].id).not.toBe(firstThinkingId);
  });

  it("strips ANSI color sequences from extension notification messages", async () => {
    const { builder, messages } = makeBuilder();

    await builder.recordExtensionNotification("session-1", {
      id: "notify-ansi",
      sessionId: "session-1",
      method: "notify",
      createdAt: "2026-05-01T00:00:00.000Z",
      prompt: "Available subagents\n• \x1B[38;5;81mbrowser\x1B[39m [user]",
      notifyType: "info",
    });

    expect(messages).toMatchObject([{ id: "notify-ansi", kind: "system", text: "Available subagents\n• browser [user]", notifyType: "info" }]);
  });

  it("records activity snapshots as message stream entries", async () => {
    const { builder, events, messages } = makeBuilder();

    await builder.recordActivitySnapshot("session-1", { read: 1, bash: 2, edit: 3, write: 4, thinking: 0, other: 0 });
    await builder.recordActivitySnapshot("session-1", { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 });

    expect(messages).toMatchObject([{ kind: "agent_activity", activitySnapshot: { read: 1, bash: 2, edit: 3, write: 4, thinking: 0, other: 0 } }]);
    expect(events).toMatchObject([{ type: "appended", message: { kind: "agent_activity" }, seq: 1 }]);
  });

  it("keeps appended message timestamps monotonic when the clock moves backward", async () => {
    const { builder, messages, setNow } = makeBuilder();

    setNow("2026-05-01T00:05:00.000Z");
    await builder.recordUserText("session-1", "first", "user");
    setNow("2026-05-01T00:01:00.000Z");
    await builder.recordUserText("session-1", "second", "user");

    expect(messages.map((message) => message.createdAt)).toEqual([
      "2026-05-01T00:05:00.000Z",
      "2026-05-01T00:05:00.000Z",
    ]);
  });

  it("preserves Pi-supplied timestamps when importing terminal session messages", async () => {
    // Regression: a Pi terminal sync that back-fills older turns would previously be clamped to
    // the existing journal max by monotonicCreatedAt, collapsing every imported user_text and
    // agent_activity onto a single instant. That left agentActivityScope with a zero-width range
    // and emptied the per-turn Tool History view even though session.tools was populated.
    const { builder, messages, setNow } = makeBuilder();

    setNow("2026-05-10T10:00:00.000Z");
    await builder.recordUserText("session-1", "existing hud message", "user");

    const imported: PickySessionMessage[] = [
      { id: "msg-pi-user-a", kind: "user_text", createdAt: "2026-05-08T12:00:00.000Z", originatedBy: "pi_extension", text: "pi turn 1 user" },
      { id: "msg-pi-activity-a", kind: "agent_activity", createdAt: "2026-05-08T12:01:30.000Z", activitySnapshot: { read: 1, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 } },
      { id: "msg-pi-user-b", kind: "user_text", createdAt: "2026-05-09T09:00:00.000Z", originatedBy: "pi_extension", text: "pi turn 2 user" },
      { id: "msg-pi-activity-b", kind: "agent_activity", createdAt: "2026-05-09T09:02:15.000Z", activitySnapshot: { read: 0, bash: 3, edit: 0, write: 0, thinking: 0, other: 0 } },
    ];
    await builder.recordTerminalSessionMessages("session-1", imported);

    expect(messages.map((message) => ({ id: message.id, createdAt: message.createdAt }))).toEqual([
      { id: messages[0].id, createdAt: "2026-05-10T10:00:00.000Z" },
      { id: "msg-pi-user-a", createdAt: "2026-05-08T12:00:00.000Z" },
      { id: "msg-pi-activity-a", createdAt: "2026-05-08T12:01:30.000Z" },
      { id: "msg-pi-user-b", createdAt: "2026-05-09T09:00:00.000Z" },
      { id: "msg-pi-activity-b", createdAt: "2026-05-09T09:02:15.000Z" },
    ]);
  });

  it("emits terminal session imports as a single bulk event with one seq", async () => {
    // Regression: per-message appended events made the HUD replay terminal-sync/history-restore
    // imports one bubble at a time ("timelapse" effect). The whole batch must land as one
    // sessionMessagesImported event sharing a single seq.
    const { builder, events, messages } = makeBuilder();

    await builder.recordUserText("session-1", "existing hud message", "user");
    const imported: PickySessionMessage[] = [
      { id: "msg-pi-user-a", kind: "user_text", createdAt: "2026-05-08T12:00:00.000Z", originatedBy: "pi_extension", text: "pi turn 1 user" },
      { id: "msg-pi-agent-a", kind: "agent_text", createdAt: "2026-05-08T12:01:00.000Z", text: "pi turn 1 answer" },
    ];
    await builder.recordTerminalSessionMessages("session-1", imported);

    expect(events).toMatchObject([
      { type: "appended", seq: 1 },
      { type: "imported", seq: 2, messages: [{ id: "msg-pi-user-a" }, { id: "msg-pi-agent-a" }] },
    ]);
    expect(messages.map((message) => message.id)).toEqual([messages[0].id, "msg-pi-user-a", "msg-pi-agent-a"]);

    // Re-importing the same batch is a no-op: no journal growth, no extra event.
    await builder.recordTerminalSessionMessages("session-1", imported);
    expect(events).toHaveLength(2);
    expect(messages).toHaveLength(3);
  });

  it("records questions, cancellations, errors, system messages, and final reports", async () => {
    const { builder, events, messages } = makeBuilder();

    await builder.recordExtensionQuestion("session-1", { id: "question-1", sessionId: "session-1", method: "input", createdAt: "2026-05-01T00:00:00.000Z", prompt: "Need input" });
    await builder.cancelExtensionQuestion("session-1", "question-1");
    await builder.recordError("session-1", "Boom");
    await builder.recordSystemMessage("session-1", "Cancelled by user");

    expect(messages.map((message) => message.kind)).toEqual(["agent_question", "agent_error", "system"]);
    expect(messages[0].cancelledAt).toBe("2026-05-01T00:00:00.000Z");
    expect(events.map((event) => event.type)).toEqual(["appended", "replaced", "appended", "appended"]);
  });
});
