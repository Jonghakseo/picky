import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickySessionMessage } from "../protocol.js";
import { selectPickleResponseForReport } from "./pickle-response-selector.js";

describe("selectPickleResponseForReport", () => {
  it("prefers session.finalAnswer when present", () => {
    const session = makeSession({
      finalAnswer: "  최종 답변입니다.  ",
      messages: [agentText("m-1", "스트리밍 도중 텍스트")],
    });

    const selection = selectPickleResponseForReport(session);

    expect(selection).toEqual({ markdown: "최종 답변입니다.", messageId: "final-answer", source: "finalAnswer" });
  });

  it("falls back to the most recent non-empty agent_text message when finalAnswer is missing", () => {
    const session = makeSession({
      messages: [
        agentText("m-1", "첫 응답"),
        agentText("m-2", "   "),
        agentText("m-3", "마지막 진행 응답"),
        { id: "m-4", kind: "agent_thinking", createdAt: "2026-05-02T00:00:04.000Z", text: "thinking" },
      ],
    });

    const selection = selectPickleResponseForReport(session);

    expect(selection).toEqual({ markdown: "마지막 진행 응답", messageId: "m-3", source: "agentText" });
  });

  it("ignores non-agent_text messages and whitespace-only agent_text bodies", () => {
    const session = makeSession({
      messages: [
        { id: "u-1", kind: "user_text", createdAt: "2026-05-02T00:00:00.000Z", text: "사용자 질문" },
        { id: "m-1", kind: "agent_text", createdAt: "2026-05-02T00:00:01.000Z", text: "" },
        { id: "m-2", kind: "agent_text", createdAt: "2026-05-02T00:00:02.000Z", text: "   \n  " },
      ],
    });

    expect(selectPickleResponseForReport(session)).toBeUndefined();
  });

  it("returns undefined when neither finalAnswer nor agent_text exists", () => {
    expect(selectPickleResponseForReport(makeSession({}))).toBeUndefined();
  });

  it("treats a whitespace-only finalAnswer as missing and falls through", () => {
    const session = makeSession({
      finalAnswer: "   \n   ",
      messages: [agentText("m-1", "fallback content")],
    });

    expect(selectPickleResponseForReport(session)).toEqual({ markdown: "fallback content", messageId: "m-1", source: "agentText" });
  });
});

function agentText(id: string, text: string): PickySessionMessage {
  return { id, kind: "agent_text", createdAt: "2026-05-02T00:00:00.000Z", text };
}

function makeSession(partial: Partial<PickyAgentSession>): PickyAgentSession {
  return {
    id: "pickle-1",
    title: "테스트 피클",
    status: "running",
    createdAt: "2026-05-02T00:00:00.000Z",
    updatedAt: "2026-05-02T00:00:30.000Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    queuedSteers: [],
    queuedFollowUps: [],
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    ...partial,
  } as PickyAgentSession;
}
