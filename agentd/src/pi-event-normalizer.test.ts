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
  });

  // When a turn mixes assistant text + tool calls, the text block is the LLM's
  // intro for that step ("잠시 도구 호출하고 이어서 말씀드릴게요."). Picky must speak
  // it through TTS as soon as the turn ends, separately from the next turn's text,
  // so a dedicated `turnTextComplete` kind is emitted rather than dropping the
  // text on the floor as `none`.
  it("emits turnTextComplete for an intermediate turn that mixed text and tool calls", () => {
    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "end_turn", model: "openai-codex/gpt-5.5", content: [{ type: "text", text: "검토 중" }, { type: "toolCall", name: "bash" }] },
      toolResults: [],
    }, { currentThinkingLevel: "high" })).toMatchObject({ kind: "turnTextComplete", text: "검토 중", assistantRun: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" } });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "tool_use", content: [{ type: "text", text: "확인해볼게요." }, { type: "toolCall", name: "read" }] },
      toolResults: [{ role: "toolResult", content: [] }],
    })).toMatchObject({ kind: "turnTextComplete", text: "확인해볼게요." });
  });

  it("maps turn stop reasons to cancellation but waits for agent_end before final failure", () => {
    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "aborted", content: [{ type: "text", text: "중단됨" }] },
      toolResults: [],
    })).toMatchObject({ kind: "status", status: "cancelled", finalAnswer: "중단됨" });

    expect(normalizePiEvent({
      type: "turn_end",
      message: { role: "assistant", stopReason: "error", content: [{ type: "text", text: "오류" }] },
      toolResults: [],
    })).toEqual({ kind: "none" });

    expect(normalizePiEvent({
      type: "agent_end",
      messages: [{ role: "assistant", stopReason: "error", content: [{ type: "text", text: "오류" }] }],
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

  it("keeps file path at the head of argsPreview even when bulky fields would push it past the truncation limit", () => {
    const longText = "X".repeat(600);
    const event = {
      type: "tool_execution_start",
      toolCallId: "call-edit",
      toolName: "edit",
      args: { edits: [{ oldText: longText, newText: longText }], path: "src/foo.swift" },
    };
    const result = normalizePiEvent(event);
    expect(result.kind).toBe("tool");
    if (result.kind !== "tool") return;
    expect(result.tool.argsPreview?.startsWith('{"path":"src/foo.swift"')).toBe(true);
  });

  it("hoists command field to the head of argsPreview for bash-like tools", () => {
    const event = {
      type: "tool_execution_start",
      toolCallId: "call-bash",
      toolName: "bash",
      args: { title: "build", command: "xcodebuild -scheme Picky" },
    };
    const result = normalizePiEvent(event);
    expect(result.kind).toBe("tool");
    if (result.kind !== "tool") return;
    expect(result.tool.argsPreview?.startsWith('{"command":"xcodebuild')).toBe(true);
  });

  it("correlates tool events by toolCallId", async () => {
    const start = normalizePiEvent(await fixture("tool-start.json"));
    expect(start).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "running" } });
    if (start.kind === "tool") {
      expect(start.tool.argsPreview).toBeTypeOf("string");
      expect(start.tool.resultPreview).toBeUndefined();
    }
    expect(normalizePiEvent(await fixture("tool-update.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "running" } });
    const end = normalizePiEvent(await fixture("tool-end-success.json"));
    expect(end).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "succeeded" } });
    if (end.kind === "tool") {
      expect(end.tool.resultPreview).toBeTypeOf("string");
      expect(end.tool.argsPreview).toBeUndefined();
    }
    expect(normalizePiEvent(await fixture("tool-end-error.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-2", status: "failed" } });
  });

  it("marks dialog extension UI as waiting for input", async () => {
    expect(normalizePiEvent(await fixture("extension-ui-request-confirm.json"))).toMatchObject({ kind: "extensionUi", waitsForInput: true });
    expect(normalizePiEvent({ type: "extension_ui_request", id: "ui-form", method: "askUserQuestion", questions: [] })).toMatchObject({ kind: "extensionUi", waitsForInput: true });
  });

  it("leaves queue updates for the runtime adapter to forward", async () => {
    expect(normalizePiEvent(await fixture("queue-update.json"))).toEqual({ kind: "none" });
  });

  it("maps session_info / session_info_changed events to a sessionInfo name update and ignores blank names", () => {
    expect(normalizePiEvent({ type: "session_info_changed", name: "원래 이름" })).toEqual({ kind: "sessionInfo", name: "원래 이름" });
    expect(normalizePiEvent({ type: "session_info", id: "abc", name: "세션 파일 이름" })).toEqual({ kind: "sessionInfo", name: "세션 파일 이름" });
    expect(normalizePiEvent({ type: "session_info_changed", name: "  " })).toEqual({ kind: "none" });
    expect(normalizePiEvent({ type: "session_info_changed" })).toEqual({ kind: "none" });
  });
});
