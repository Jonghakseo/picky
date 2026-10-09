import { describe, expect, it, vi } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { RuntimeEventHandler } from "./runtime-event-handler.js";


function session(): PickyAgentSession {
  return {
    id: "pickle-1",
    title: "Pickle",
    status: "running",
    createdAt: "2026-07-19T00:00:00.000Z",
    updatedAt: "2026-07-19T00:00:00.000Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
  };
}

describe("RuntimeEventHandler", () => {
  it("logs each runtime event type dropped after a terminal status once until the next status", async () => {
    const logAgentd = vi.fn();
    const harness = inputHarness({ status: "cancelled" }, logAgentd);
    const dropped = () => logAgentd.mock.calls
      .filter(([event]) => event === "runtime event dropped after terminal")
      .map(([, fields]) => (fields as { eventType: string }).eventType);

    for (const delta of ["late ", "assistant ", "text"]) await harness.handler.handle("pickle-1", { type: "assistant_delta", delta });
    await harness.handler.handle("pickle-1", { type: "tool", toolCallId: "late-tool", name: "bash", status: "running" });
    expect(dropped()).toEqual(["assistant_delta", "tool"]);

    await harness.handler.handle("pickle-1", { type: "status", status: "completed", summary: "late completion" });
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "after status" });
    expect(dropped()).toEqual(["assistant_delta", "tool", "status:completed", "assistant_delta"]);
  });

  it("commits the first runtime completion after terminal tail pre-completed the session", async () => {
    let current = session();
    let assistantDraft = "";
    const flushAssistantText = vi.fn(async () => {
      if (!assistantDraft) return;
      current = {
        ...current,
        messages: [
          ...(current.messages ?? []),
          {
            id: "agent-1",
            kind: "agent_text",
            createdAt: "2026-07-19T00:00:01.000Z",
            text: assistantDraft,
          },
        ],
      };
      assistantDraft = "";
    });
    const notifyPickleCompletion = vi.fn(async () => {});
    const finishAssistantRun = vi.fn();
    const handler = new RuntimeEventHandler({
      getSession: () => current,
      patchSession: async (_sessionId, patch) => { current = { ...current, ...patch }; },
      applyAutoTitle: async (_sessionId, name) => { current = { ...current, title: name }; },
      emitToolActivityUpdated: () => {},
      updateTodoState: async () => {},
      appendLog: async () => {},
      materializeTerminalArtifacts: async () => {},
      applyQueueUpdate: async () => {},
      incrementActivity: async () => {},
      commitTurnActivity: async () => {},
      notifyPickleCompletion,
      isPickleSession: () => true,
      emitExtensionUiRequest: () => {},
      finishAssistantRun,
      messageBuilder: {
        recordExtensionQuestion: async () => {},
        recordExtensionNotification: async () => {},
        cancelExtensionQuestion: async () => {},
        recordError: async () => {},
        recordSystemMessage: async () => {},
        recordExtensionText: async () => {},
        recordUserText: async () => {},
        appendAssistantDelta: (_sessionId, delta) => { assistantDraft += delta; },
        flushAssistantText,
        appendThinkingDelta: async () => {},
        flushThinking: async () => {},
        clearAllThinking: async () => {},
        recordActivitySnapshot: async () => {},
      },
    });
    handler.resetAssistantDraft(current.id);

    await handler.handle(current.id, { type: "assistant_delta", delta: "clean Pickle answer" });
    current = { ...current, status: "completed" };
    const completion = {
      type: "status" as const,
      status: "completed" as const,
      summary: "Completed",
      finalAnswer: "clean Pickle answer",
    };
    await handler.handle(current.id, completion);
    await handler.handle(current.id, completion);

    expect(flushAssistantText).toHaveBeenCalledTimes(1);
    expect(current.messages?.at(-1)?.text).toBe("clean Pickle answer");
    expect(current.finalAnswer).toBe("clean Pickle answer");
    expect(notifyPickleCompletion).toHaveBeenCalledTimes(1);
    expect(finishAssistantRun).toHaveBeenCalledTimes(2);
  });

  it("journals an idle custom extension message without reviving a completed Pickle", async () => {
    const harness = inputHarness({
      status: "completed",
      finalAnswer: "Completed answer",
      lastSummary: "Completed answer",
      pinned: true,
    });

    await harness.handler.handle("pickle-1", {
      type: "input_message",
      role: "custom",
      text: "subagent finished",
      originatedBy: "pi_extension",
      customType: "subagent",
      turnActive: false,
    });

    expect(harness.current()).toMatchObject({
      status: "completed",
      finalAnswer: "Completed answer",
      lastSummary: "Completed answer",
      pinned: true,
    });
    expect(harness.recordExtensionText).toHaveBeenCalledWith("pickle-1", "subagent finished", "subagent");
    expect(harness.recordUserText).not.toHaveBeenCalled();
    expect(harness.onInputMessage).not.toHaveBeenCalled();
    expect(harness.patchSession).not.toHaveBeenCalled();
  });

  it("ignores a hidden idle custom extension message without changing a completed Pickle", async () => {
    const harness = inputHarness({
      status: "completed",
      finalAnswer: "Completed answer",
      lastSummary: "Completed answer",
      pinned: true,
    });

    await harness.handler.handle("pickle-1", {
      type: "input_message",
      role: "custom",
      text: "hidden subagent status",
      originatedBy: "pi_extension",
      customType: "subagent",
      display: false,
      turnActive: false,
    });

    expect(harness.current()).toMatchObject({
      status: "completed",
      finalAnswer: "Completed answer",
      lastSummary: "Completed answer",
      pinned: true,
    });
    expect(harness.recordUserText).not.toHaveBeenCalled();
    expect(harness.onInputMessage).not.toHaveBeenCalled();
    expect(harness.patchSession).not.toHaveBeenCalled();
  });

  it("revives a completed Pickle for a hidden custom message observed during an active Pi turn without journaling it", async () => {
    const harness = inputHarness({ status: "completed", finalAnswer: "Previous answer" });

    // The preceding Pi agent_start is ignored because the Pickle was completed. The adapter's
    // authoritative isStreaming snapshot on this custom event must still revive the session.
    await harness.handler.handle("pickle-1", {
      type: "input_message",
      role: "custom",
      text: "subagent result starts next turn",
      originatedBy: "pi_extension",
      customType: "subagent",
      display: false,
      turnActive: true,
    });

    expect(harness.current()).toMatchObject({
      status: "running",
      lastSummary: "Pi extension message started",
    });
    expect(harness.current().finalAnswer).toBeUndefined();
    expect(harness.onInputMessage).toHaveBeenCalledTimes(1);
    expect(harness.recordUserText).not.toHaveBeenCalled();
  });

  it("processes terminal completion after an extension turn resets the previous terminal dedupe", async () => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", {
      type: "status",
      status: "completed",
      summary: "First completed turn",
      finalAnswer: "First answer",
    });
    await harness.handler.handle("pickle-1", {
      type: "input_message",
      role: "custom",
      text: "subagent starts another turn",
      originatedBy: "pi_extension",
      customType: "subagent",
      turnActive: true,
    });

    // The terminal tail can win the race and patch the second turn as completed before the
    // runtime status arrives. The status event must still commit completion side effects.
    harness.setCurrent({ status: "completed" });
    await harness.handler.handle("pickle-1", {
      type: "status",
      status: "completed",
      summary: "Second completed turn",
      finalAnswer: "Second answer",
    });

    expect(harness.current()).toMatchObject({ status: "completed", finalAnswer: "Second answer" });
    expect(harness.materializeTerminalArtifacts).toHaveBeenCalledTimes(2);
    expect(harness.notifyPickleCompletion).toHaveBeenCalledTimes(2);
  });

  it("preserves subagent summary metadata when a tool settles", async () => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", {
      type: "tool",
      toolCallId: "subagent-batch",
      name: "subagent",
      status: "running",
      argsPreview: "truncated original args...",
      subagentSummary: {
        action: "batch",
        agents: ["verifier", "reviewer", "challenger"],
      },
    });
    await harness.handler.handle("pickle-1", {
      type: "tool",
      toolCallId: "subagent-batch",
      name: "subagent",
      status: "succeeded",
      resultPreview: "done",
    });

    expect(harness.current().tools).toEqual([
      expect.objectContaining({
        argsPreview: "truncated original args...",
        subagentSummary: {
          action: "batch",
          agents: ["verifier", "reviewer", "challenger"],
        },
      }),
    ]);
  });

  it("preserves terminal JSON preview metadata across later sparse updates", async () => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", {
      type: "tool",
      toolCallId: "json-result",
      name: "mcp__example__search",
      status: "succeeded",
      resultPreview: '{"items":[...',
      resultJSONPreview: '{"items":[]}',
      resultPreviewTruncated: true,
      resultPreviewRepaired: true,
    });
    await harness.handler.handle("pickle-1", {
      type: "tool",
      toolCallId: "json-result",
      name: "mcp__example__search",
      status: "succeeded",
      preview: "completed",
    });

    expect(harness.current().tools).toEqual([
      expect.objectContaining({
        resultPreview: '{"items":[...',
        resultJSONPreview: '{"items":[]}',
        resultPreviewTruncated: true,
        resultPreviewRepaired: true,
      }),
    ]);
  });

  it("captures file artifacts only from write successes and re-arms same-path updates", async () => {
    const harness = inputHarness({ cwd: "/workspace" });
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-08-15T10:00:00.000Z"));
      await harness.handler.handle("pickle-1", {
        type: "tool",
        toolCallId: "write-report",
        name: "write",
        status: "succeeded",
        filePath: "/workspace/reports/write.csv",
        fileExistedBefore: false,
      });
      await harness.handler.handle("pickle-1", {
        type: "tool",
        toolCallId: "write-report-again",
        name: "write",
        status: "succeeded",
        filePath: "/workspace/reports/write.csv",
        fileExistedBefore: true,
      });
      vi.setSystemTime(new Date("2026-08-15T09:59:59.000Z"));
      await harness.handler.handle("pickle-1", {
        type: "tool",
        toolCallId: "write-report-after-clock-rollback",
        name: "write",
        status: "succeeded",
        filePath: "/workspace/reports/write.csv",
        fileExistedBefore: true,
      });
      await harness.handler.handle("pickle-1", {
        type: "status",
        status: "completed",
        finalAnswer: "An existing local PDF is at `/workspace/reports/done.pdf`.",
      });

      expect(harness.current().artifacts).toEqual([
        expect.objectContaining({ kind: "file", path: "/workspace/reports/write.csv", updatedAt: "2026-08-15T10:00:00.002Z" }),
      ]);
      expect(harness.emitArtifactUpdated).toHaveBeenCalledTimes(3);
    } finally {
      vi.useRealTimers();
    }
  });

  it("lists files changed by successful write and edit calls without explicit Changed file lines", async () => {
    const harness = inputHarness({ cwd: "/workspace" });
    const tool = (toolCallId: string, name: string, status: "succeeded" | "failed", filePath: string, fileExistedBefore: boolean) =>
      harness.handler.handle("pickle-1", { type: "tool", toolCallId, name, status, filePath, fileExistedBefore });

    await tool("create", "write", "succeeded", "/workspace/src/new.ts", false);
    await tool("edit-created", "edit", "succeeded", "/workspace/src/new.ts", true);
    await tool("edit-existing", "edit", "succeeded", "/workspace/src/app.ts", true);
    await tool("edit-failed", "edit", "failed", "/workspace/src/broken.ts", true);
    await tool("edit-outside", "edit", "succeeded", "/etc/hosts", true);
    await harness.handler.handle("pickle-1", {
      type: "status",
      status: "completed",
      finalAnswer: "Done.\nChanged file: M src/app.ts - wire the new module",
    });

    expect(harness.current().changedFiles).toEqual([
      { path: "src/new.ts", status: "A" },
      { path: "src/app.ts", status: "M", summary: "wire the new module" },
      { path: "/etc/hosts", status: "M" },
    ]);
  });

  it("leaves legacy write success events without structured paths artifact-free", async () => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", {
      type: "tool",
      toolCallId: "legacy-write",
      name: "write",
      status: "succeeded",
      argsPreview: '{"path":"reports/legacy.md"}',
    });

    expect(harness.current().artifacts).toEqual([]);
    expect(harness.emitArtifactUpdated).not.toHaveBeenCalled();
  });

  it("continues to start a turn for an extension user message", async () => {
    const harness = inputHarness({ status: "completed", finalAnswer: "Previous answer" });

    await harness.handler.handle("pickle-1", {
      type: "input_message",
      role: "user",
      text: "extension follow-up",
      originatedBy: "pi_extension",
    });

    expect(harness.current()).toMatchObject({
      status: "running",
      lastSummary: "Pi extension follow-up started",
    });
    expect(harness.current().finalAnswer).toBeUndefined();
    expect(harness.onInputMessage).toHaveBeenCalledTimes(1);
  });

  it("reports reply writing once per segment without persisting anything", async () => {
    const harness = inputHarness();
    harness.handler.resetAssistantDraft("pickle-1");
    harness.patchSession.mockClear();
    harness.setLiveOutput.mockClear();
    const live = () => harness.setLiveOutput.mock.calls.map(([, signal, active]) => [signal, active]);
    const reported = () => live().map(([, active]) => active);

    // One notification for the whole streamed segment, not one per delta, and
    // streaming must not write to the session store at all.
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "Writing " });
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "a reply" });
    expect(reported()).toEqual([true]);
    expect(harness.patchSession).not.toHaveBeenCalled();

    // A tool call ends the segment; the next segment reports again.
    await harness.handler.handle("pickle-1", { type: "tool", toolCallId: "tool-1", name: "bash", status: "running" });
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "more" });
    expect(reported()).toEqual([true, false, true]);

    // Reasoning output is not reply text.
    await harness.handler.handle("pickle-1", { type: "thinking_delta", delta: "deciding" });
    expect(reported()).toEqual([true, false, true, false]);

    // A terminal status leaves it cleared.
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "final" });
    await harness.handler.handle("pickle-1", { type: "status", status: "completed", summary: "Done" });
    expect(reported()).toEqual([true, false, true, false, true, false]);
    // Pure reply streaming never reports tool-call preparation.
    expect(live().every(([signal]) => signal === "replyWriting")).toBe(true);
  });

  it("reports tool-call preparation until the tool runs, exclusive with reply writing", async () => {
    const harness = inputHarness();
    harness.handler.resetAssistantDraft("pickle-1");
    harness.patchSession.mockClear();
    harness.setLiveOutput.mockClear();
    const live = () => harness.setLiveOutput.mock.calls.map(([, signal, active]) => [signal, active]);

    // A short preamble, then the model streams a long tool call's arguments:
    // writing hands over to preparing, and a second start in the same step is not re-reported.
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "Writing the file." });
    await harness.handler.handle("pickle-1", { type: "tool_call_preparing" });
    await harness.handler.handle("pickle-1", { type: "tool_call_preparing" });
    expect(live()).toEqual([["replyWriting", true], ["replyWriting", false], ["toolCallPreparing", true]]);
    expect(harness.patchSession).not.toHaveBeenCalled();

    // Reply text after the arguments clears preparation before writing is raised.
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "and then" });
    expect(live().slice(-2)).toEqual([["toolCallPreparing", false], ["replyWriting", true]]);
    await harness.handler.handle("pickle-1", { type: "tool_call_preparing" });
    expect(live().slice(-2)).toEqual([["replyWriting", false], ["toolCallPreparing", true]]);

    // The tool starting ends preparation.
    await harness.handler.handle("pickle-1", { type: "tool", toolCallId: "tool-1", name: "write", status: "running" });
    expect(live().at(-1)).toEqual(["toolCallPreparing", false]);

    // A terminal status clears a preparation that never reached its tool.
    await harness.handler.handle("pickle-1", { type: "tool_call_preparing" });
    await harness.handler.handle("pickle-1", { type: "status", status: "cancelled", summary: "Stopped" });
    expect(live().slice(-2)).toEqual([["toolCallPreparing", true], ["toolCallPreparing", false]]);
  });

  it("returns an isolated runtime terminal snapshot without flushing drafts", async () => {
    const harness = inputHarness();
    harness.handler.resetAssistantDraft("pickle-1");
    await harness.handler.handle("pickle-1", { type: "assistant_delta", delta: "draft answer" });
    await harness.handler.handle("pickle-1", { type: "thinking_delta", delta: "draft thinking" });

    const snapshot = harness.handler.terminalSnapshot("pickle-1");
    expect(snapshot).toMatchObject({
      assistantDraft: "draft answer",
      thinkingDraft: "draft thinking",
      thinkingActive: true,
      pendingThinkingDelta: "draft thinking",
    });

    // Snapshot mutation must not write back to the handler's transient maps.
    (snapshot.seenToolCallIds as string[]).push("external-tool");
    expect(harness.handler.terminalSnapshot("pickle-1").seenToolCallIds).toEqual([]);
    expect(harness.messageBuilder.flushAssistantText).not.toHaveBeenCalled();
    expect(harness.messageBuilder.flushThinking).not.toHaveBeenCalled();
  });
});

// Picky owns these journal sentences, so the app has to be able to render them in the user's
// language. The daemon keeps writing the English wording for CLI readers and older clients, and
// tags the entry with a semantic code; text the agent or the shell produced stays verbatim.
describe("RuntimeEventHandler presentation codes", () => {
  it("tags a cancelled turn and keeps its English fallback text", async () => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", { type: "status", status: "cancelled", summary: "Cancelled" });

    expect(harness.messageBuilder.recordSystemMessage).toHaveBeenCalledWith(
      "pickle-1",
      "Cancelled by user",
      { presentation: { code: "sessionCancelledByUser" } },
    );
  });

  it("tags only the no-detail agent failure, leaving a runtime summary untagged", async () => {
    const withoutSummary = inputHarness();
    const withSummary = inputHarness();

    await withoutSummary.handler.handle("pickle-1", { type: "status", status: "failed" });
    await withSummary.handler.handle("pickle-1", { type: "status", status: "failed", summary: "Model refused the request" });

    expect(withoutSummary.messageBuilder.recordError).toHaveBeenCalledWith(
      "pickle-1",
      "Agent failed",
      { presentation: { code: "agentFailedWithoutDetail" } },
    );
    expect(withSummary.messageBuilder.recordError).toHaveBeenCalledWith("pickle-1", "Model refused the request", {});
  });

  it.each([
    ["threshold", "Session compacted", "sessionCompacted"],
    ["overflow", "Session compacted after context overflow", "sessionCompactedAfterOverflow"],
  ])("tags a %s compaction", async (reason, text, code) => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", {
      type: "status",
      status: "running",
      summary: "Session compacted; continuing…",
      compactionCompleted: true,
      compactionReason: reason as "threshold" | "overflow",
      compaction: { tokensBefore: 128_000, tokensAfter: 21_000 },
    });

    expect(harness.messageBuilder.recordSystemMessage).toHaveBeenCalledWith("pickle-1", text, {
      compaction: { tokensBefore: 128_000, tokensAfter: 21_000 },
      presentation: { code },
    });
  });

  it("carries the compaction failure detail and context usage as typed parameters", async () => {
    const harness = inputHarness({ contextUsage: { tokens: 190_000, contextWindow: 200_000, percent: 95 } });

    await harness.handler.handle("pickle-1", {
      type: "status",
      status: "running",
      summary: "Auto-compaction failed: summarization request timed out",
      compactionFailed: true,
    });

    expect(harness.messageBuilder.recordSystemMessage).toHaveBeenCalledWith(
      "pickle-1",
      expect.stringContaining("summarization request timed out"),
      { presentation: { code: "sessionCompactionFailed", params: { detail: "summarization request timed out", contextTokens: 190_000, contextWindowTokens: 200_000 } } },
    );
  });

  it("omits usage parameters when the session has no context snapshot", async () => {
    const harness = inputHarness();

    await harness.handler.handle("pickle-1", { type: "status", status: "running", compactionFailed: true });

    expect(harness.messageBuilder.recordSystemMessage).toHaveBeenCalledWith(
      "pickle-1",
      expect.stringContaining("Summarization failed."),
      { presentation: { code: "sessionCompactionFailed", params: { detail: "Summarization failed." } } },
    );
  });
});

function inputHarness(initial: Partial<PickyAgentSession> = {}, log?: (event: string, fields?: Record<string, unknown>) => void) {
  let current = { ...session(), ...initial };
  const patchSession = vi.fn(async (_sessionId: string, patch: Partial<PickyAgentSession>) => {
    current = { ...current, ...patch };
  });
  const onInputMessage = vi.fn(async () => {});
  const setLiveOutput = vi.fn();
  const recordExtensionText = vi.fn(async () => {});
  const recordUserText = vi.fn(async () => {});
  const materializeTerminalArtifacts = vi.fn(async () => {});
  const notifyPickleCompletion = vi.fn(async () => {});
  const emitArtifactUpdated = vi.fn();
  const messageBuilder = {
    recordExtensionQuestion: async () => {},
    recordExtensionNotification: async () => {},
    cancelExtensionQuestion: async () => {},
    recordError: vi.fn(async () => {}),
    recordSystemMessage: vi.fn(async () => {}),
    recordExtensionText,
    recordUserText,
    appendAssistantDelta: () => {},
    flushAssistantText: vi.fn(async () => {}),
    appendThinkingDelta: async () => {},
    flushThinking: vi.fn(async () => {}),
    clearAllThinking: async () => {},
    recordActivitySnapshot: async () => {},
  };
  const handler = new RuntimeEventHandler({
    log,
    getSession: () => current,
    patchSession,
    applyAutoTitle: async (sessionId: string, name: string) => { await patchSession(sessionId, { title: name }); },
    emitToolActivityUpdated: () => {},
    emitArtifactUpdated,
    updateTodoState: async () => {},
    appendLog: async () => {},
    materializeTerminalArtifacts,
    applyQueueUpdate: async () => {},
    incrementActivity: async () => {},
    commitTurnActivity: async () => {},
    notifyPickleCompletion,
    isPickleSession: () => true,
    emitExtensionUiRequest: () => {},
    onInputMessage,
    setLiveOutput,
    messageBuilder,
  });
  return {
    handler,
    current: () => current,
    setCurrent: (patch: Partial<PickyAgentSession>) => { current = { ...current, ...patch }; },
    patchSession,
    onInputMessage,
    setLiveOutput,
    recordExtensionText,
    recordUserText,
    materializeTerminalArtifacts,
    notifyPickleCompletion,
    emitArtifactUpdated,
    messageBuilder,
  };
}
