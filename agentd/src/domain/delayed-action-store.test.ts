import { describe, expect, it } from "vitest";
import {
  delayedActionDurationArgument,
  delayedActionStoreDir,
  delayedActionStoreFileName,
  parseDelayedActionStore,
  sameScheduledMessages,
  sanitizeDelayedActionSessionId,
} from "./delayed-action-store.js";

describe("delayed-action store", () => {
  it("resolves the store file the extension writes for a Pi session id", () => {
    // Must stay byte-identical to the extension's sanitizeSessionId, or Picky reads nothing.
    expect(sanitizeDelayedActionSessionId("2026-05-05T00:00:00_abc/def")).toBe("2026-05-05T00-00-00_abc-def");
    expect(sanitizeDelayedActionSessionId("..hidden")).toBe("hidden");
    expect(sanitizeDelayedActionSessionId("...")).toBeUndefined();
    expect(delayedActionStoreFileName("session-1")).toBe("session-1.json");
    expect(delayedActionStoreFileName("...")).toBeUndefined();
    expect(delayedActionStoreDir({ PI_DELAYED_ACTION_DIR: "/tmp/delayed" })).toBe("/tmp/delayed");
    expect(delayedActionStoreDir({})).toMatch(/\.pi\/delayed-action$/);
  });

  it("projects persisted tasks as ISO-timestamped messages sorted by due time", () => {
    const messages = parseDelayedActionStore(JSON.stringify({
      version: 1,
      sessionId: "session-1",
      tasks: [
        { id: "delay-2", prompt: "later", createdAt: 1_000, dueAt: 20_000 },
        { id: "delay-1", prompt: "sooner", createdAt: 1_000, dueAt: 10_000 },
      ],
    }));

    expect(messages).toEqual([
      { id: "delay-1", text: "sooner", dueAt: new Date(10_000).toISOString(), createdAt: new Date(1_000).toISOString() },
      { id: "delay-2", text: "later", dueAt: new Date(20_000).toISOString(), createdAt: new Date(1_000).toISOString() },
    ]);
  });

  it("projects an empty schedule for a half-written or malformed store", () => {
    // The extension writes to a temp file and renames, so a bad read is transient and
    // must not take the session's projection down with it.
    expect(parseDelayedActionStore("{\"version\":1,\"tasks\":[{\"id\"")).toEqual([]);
    expect(parseDelayedActionStore("{}")).toEqual([]);
    expect(parseDelayedActionStore(JSON.stringify({ tasks: [{ id: "delay-1" }] }))).toEqual([]);
  });

  it("compares schedules by content so unchanged files do not republish", () => {
    const message = { id: "delay-1", text: "a", dueAt: "2026-05-05T00:05:00.000Z", createdAt: "2026-05-05T00:00:00.000Z" };
    expect(sameScheduledMessages([message], [{ ...message }])).toBe(true);
    expect(sameScheduledMessages([message], [{ ...message, text: "b" }])).toBe(false);
    expect(sameScheduledMessages([message], [])).toBe(false);
  });

  it("formats sub-minute delays the extension parser accepts", () => {
    expect(delayedActionDurationArgument(300_000)).toBe("300s");
    expect(delayedActionDurationArgument(1)).toBe("1s");
  });
});
