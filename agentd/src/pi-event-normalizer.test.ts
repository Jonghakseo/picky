import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { normalizePiEvent } from "./domain/pi-event-normalizer.js";

const contractsRoot = join(process.cwd(), "..", "contracts", "pi-events");

async function fixture(name: string): Promise<unknown> {
  return JSON.parse(await readFile(join(contractsRoot, name), "utf8"));
}

describe("normalizePiEvent", () => {
  it("maps agent lifecycle events to Picky status", async () => {
    expect(normalizePiEvent(await fixture("agent-start.json"))).toMatchObject({ kind: "status", status: "running" });
    expect(normalizePiEvent(await fixture("agent-end.json"))).toMatchObject({ kind: "status", status: "completed" });
    expect(normalizePiEvent(await fixture("agent-end.json"), { hasQueuedFollowUp: true })).toMatchObject({ kind: "status", status: "running" });
    expect(normalizePiEvent({ type: "agent_end", messages: [{ role: "assistant", stopReason: "aborted", content: [] }] })).toMatchObject({ kind: "status", status: "cancelled" });
    expect(normalizePiEvent(await fixture("abort-error.json"))).toMatchObject({ kind: "status", status: "failed" });
  });

  it("maps final turn completion before agent_end so completed cards do not stay working", () => {
    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "end_turn", model: "openai-codex/gpt-5.5", content: [{ type: "text", text: "완료 답변" }] },
      toolResults: [],
    }, { currentThinkingLevel: "high" })).toMatchObject({ kind: "status", status: "completed", finalAnswer: "완료 답변", assistantRun: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" } });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "대기 중" }] },
      toolResults: [],
    }, { hasQueuedSteering: true })).toMatchObject({ kind: "status", status: "running" });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "입력 필요" }] },
      toolResults: [],
    }, { hasPendingExtensionUiRequest: true })).toMatchObject({ kind: "status", status: "waiting_for_input" });
  });

  it("does not mark intermediate tool turns as completed", () => {
    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "tool_use", content: [{ type: "toolCall", name: "bash" }] },
      toolResults: [{ role: "toolResult", content: [] }],
    })).toEqual({ kind: "none" });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "" }] },
      toolResults: [],
    })).toEqual({ kind: "none" });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "검토 중" }, { type: "toolCall", name: "bash" }] },
      toolResults: [],
    })).toEqual({ kind: "none" });
  });

  it("maps turn stop reasons to terminal failure and cancellation", () => {
    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "aborted", content: [{ type: "text", text: "중단됨" }] },
      toolResults: [],
    })).toMatchObject({ kind: "status", status: "cancelled", finalAnswer: "중단됨" });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "error", content: [{ type: "text", text: "오류" }] },
      toolResults: [],
    })).toMatchObject({ kind: "status", status: "failed", finalAnswer: "오류" });
  });

  it("carries only the last assistant message text on agent_end so reports do not include intermediate turns", () => {
    expect(normalizePiEvent({
      type: "agent_end",
      messages: [
        { role: "user", content: [{ type: "text", text: "부탁" }] },
        { role: "assistant", stopReason: "tool_use", content: [{ type: "text", text: "조사 중입니다" }, { type: "toolCall", name: "bash", id: "call-1" }] },
        { role: "toolResult", toolCallId: "call-1", content: [] },
        { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "최종 답변입니다" }] },
      ],
    })).toMatchObject({ kind: "status", status: "completed", finalAnswer: "최종 답변입니다" });
  });

  it("maps message deltas to assistant answer fragments", async () => {
    expect(normalizePiEvent(await fixture("message-text-delta.json"))).toEqual({ kind: "assistantDelta", delta: "Hello" });
  });

  it("maps thinking deltas to current-work thinking previews", async () => {
    expect(normalizePiEvent(await fixture("message-thinking-delta.json"))).toEqual({
      kind: "thinkingDelta",
      delta: "I need to inspect the HUD current work state.",
    });
  });

  it("correlates tool events by toolCallId", async () => {
    expect(normalizePiEvent(await fixture("tool-start.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "running" } });
    expect(normalizePiEvent(await fixture("tool-update.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "running" } });
    expect(normalizePiEvent(await fixture("tool-end-success.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "succeeded" } });
    expect(normalizePiEvent(await fixture("tool-end-error.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-2", status: "failed" } });
  });

  it("marks dialog extension UI as waiting for input", async () => {
    expect(normalizePiEvent(await fixture("extension-ui-request-confirm.json"))).toMatchObject({ kind: "extensionUi", waitsForInput: true });
    expect(normalizePiEvent({ type: "extension_ui_request", id: "ui-form", method: "askUserQuestion", questions: [] })).toMatchObject({ kind: "extensionUi", waitsForInput: true });
  });

  it("leaves queue updates for the runtime adapter to forward", async () => {
    expect(normalizePiEvent(await fixture("queue-update.json"))).toEqual({ kind: "none" });
  });

  it("maps session_info events to a sessionInfo name update and ignores blank names", () => {
    expect(normalizePiEvent({ type: "session_info", id: "abc", name: "型트 소개" })).toEqual({ kind: "sessionInfo", name: "型트 소개" });
    expect(normalizePiEvent({ type: "session_info", id: "abc", name: "  " })).toEqual({ kind: "none" });
    expect(normalizePiEvent({ type: "session_info", id: "abc" })).toEqual({ kind: "none" });
  });
});
