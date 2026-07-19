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
});
