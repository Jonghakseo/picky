import { describe, expect, it } from "vitest";
import { MockRuntimeSession } from "./mock-runtime.js";

describe("MockRuntimeSession queue foundation", () => {
  it("rewinds its in-memory branch and returns editor text", async () => {
    const session = new MockRuntimeSession("mock-rewind-test");
    const first = session.appendMockTurn("A", "a");
    const second = session.appendMockTurn("B", "b");

    expect(session.listRewindTargets().map((target) => ({ entryId: target.entryId, text: target.text }))).toEqual([
      { entryId: first.userEntryId, text: "A" },
      { entryId: second.userEntryId, text: "B" },
    ]);

    await expect(session.rewindToEntry(second.userEntryId)).resolves.toEqual({ editorText: "B", cancelled: false });
    expect(session.getActiveBranchTranscript()).toEqual([
      { role: "user", text: "A" },
      { role: "assistant", text: "a" },
    ]);

    await expect(session.rewindToEntry(first.userEntryId)).resolves.toEqual({ editorText: "A", cancelled: false });
    expect(session.getActiveBranchTranscript()).toEqual([]);
  });

  it("mirrors queue state and drains it via clearQueue", async () => {
    const session = new MockRuntimeSession("mock-test");

    expect(session.steeringMode).toBe("one-at-a-time");
    expect(session.followUpMode).toBe("one-at-a-time");
    expect(session.getSteeringMessages()).toEqual([]);
    expect(session.getFollowUpMessages()).toEqual([]);

    await session.steer({ text: "review logs", imagePaths: [] });
    await session.followUp({ text: "summarize later", imagePaths: [] });

    expect(session.getSteeringMessages()).toEqual(["review logs"]);
    expect(session.getFollowUpMessages()).toEqual(["summarize later"]);
    expect(session.clearQueue()).toEqual({ steering: ["review logs"], followUp: ["summarize later"] });
    expect(session.getSteeringMessages()).toEqual([]);
    expect(session.getFollowUpMessages()).toEqual([]);
  });
});
