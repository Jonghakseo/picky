import { describe, expect, it } from "vitest";
import { MockRuntime, MockRuntimeSession } from "./mock-runtime.js";

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

  it("supports exact runtime picker selections and reports effective options", async () => {
    const session = new MockRuntimeSession("mock-runtime-picker");

    await expect(session.listRuntimeOptions()).resolves.toMatchObject({
      models: [
        { provider: "mock", modelId: "gpt-5.5", pattern: "mock/gpt-5.5" },
        { provider: "mock", modelId: "opus-4-7", pattern: "mock/opus-4-7" },
      ],
      thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
      currentModel: { provider: "mock", modelId: "gpt-5.5" },
    });

    await expect(session.setExactModel("mock", "opus-4-7")).resolves.toEqual({
      model: "mock/opus-4-7",
      thinkingLevel: "medium",
    });
    session.setThinkingLevel("max");
    expect(session.getAssistantRunMetadata()).toEqual({ model: "mock/opus-4-7", thinkingLevel: "max" });
    await expect(session.setExactModel("other", "opus-4-7")).rejects.toThrow("Model is not available in this session");
  });

  it("reflects a global exact scope in existing sessions and cycles into it", async () => {
    const runtime = new MockRuntime();
    const handle = await runtime.prewarm!();
    const initial = await handle.listRuntimeOptions!();

    await runtime.setGlobalModelScope!({
      mode: "exact",
      patterns: ["mock/opus-4-7"],
      expectedRevision: initial.globalScope!.revision!,
    });

    await expect(handle.listRuntimeOptions!()).resolves.toMatchObject({
      models: [{ pattern: "mock/opus-4-7" }],
      globalScope: { mode: "exact", patterns: ["mock/opus-4-7"] },
    });
    await expect(handle.cycleModel!("forward")).resolves.toEqual({
      model: "mock/opus-4-7",
      thinkingLevel: "medium",
    });
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
