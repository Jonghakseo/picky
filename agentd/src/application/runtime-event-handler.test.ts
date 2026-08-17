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
    expect(harness.recordUserText).toHaveBeenCalledWith("pickle-1", "subagent finished", "pi_extension");
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
});

function inputHarness(initial: Partial<PickyAgentSession> = {}) {
  let current = { ...session(), ...initial };
  const patchSession = vi.fn(async (_sessionId: string, patch: Partial<PickyAgentSession>) => {
    current = { ...current, ...patch };
  });
  const onInputMessage = vi.fn(async () => {});
  const recordUserText = vi.fn(async () => {});
  const materializeTerminalArtifacts = vi.fn(async () => {});
  const notifyPickleCompletion = vi.fn(async () => {});
  const emitArtifactUpdated = vi.fn();
  const handler = new RuntimeEventHandler({
    getSession: () => current,
    patchSession,
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
    messageBuilder: {
      recordExtensionQuestion: async () => {},
      recordExtensionNotification: async () => {},
      cancelExtensionQuestion: async () => {},
      recordError: async () => {},
      recordSystemMessage: async () => {},
      recordUserText,
      appendAssistantDelta: () => {},
      flushAssistantText: async () => {},
      appendThinkingDelta: async () => {},
      flushThinking: async () => {},
      clearAllThinking: async () => {},
      recordActivitySnapshot: async () => {},
    },
  });
  return {
    handler,
    current: () => current,
    setCurrent: (patch: Partial<PickyAgentSession>) => { current = { ...current, ...patch }; },
    patchSession,
    onInputMessage,
    recordUserText,
    materializeTerminalArtifacts,
    notifyPickleCompletion,
    emitArtifactUpdated,
  };
}
