import type { PickySubagentToolSummary, PickyTodoState, PickyToolActivity, SessionStatus } from "../protocol.js";
import type { RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeSessionStatus, ThinkingLevel } from "../runtime/types.js";
import { sliceUtf16Safe } from "./safe-truncate.js";
import { subagentLaunchIntentFromToolArgs } from "./subagent-run-state.js";
import { buildToolResultPreview, reorderForPreview } from "./tool-result-preview.js";
import { todoStateFromPiSessionEntry } from "./todo-state.js";

interface PiEventNormalizationContext {
  hasQueuedSteering?: boolean;
  hasQueuedFollowUp?: boolean;
  hasPendingExtensionUiRequest?: boolean;
  // Host's (supervisor's) view of whether a pending extension UI request is
  // currently surfaced to the user. When the runtime adapter's internal
  // `pendingExtensionUiRequestIds` is non-empty but the host has nothing
  // pending (e.g. Pi resume after daemon restart silently revives an
  // unanswered request through `session.bindExtensions`, but the matching
  // `extension_ui` emit happened before the supervisor subscribed), the turn
  // should complete normally instead of parking on a "ghost" waiting_for_input
  // status with no question bubble for the user to answer.
  //
  // Leave undefined when the caller has no host view (tests, mock runtime) to
  // preserve the prior runtime-only behaviour.
  hostHasPendingExtensionUiRequest?: boolean;
  currentModel?: string;
  currentThinkingLevel?: ThinkingLevel;
}

type NormalizedPiEvent =
  | { kind: "log"; line: string }
  | { kind: "assistantDelta"; delta: string }
  | { kind: "thinkingDelta"; delta: string }
  | { kind: "toolCallPreparing" }
  | { kind: "status"; status: SessionStatus; summary?: string; finalAnswer?: string; assistantRun?: RuntimeAssistantRunMetadata }
  | { kind: "tool"; tool: PickyToolActivity }
  | { kind: "todoState"; todoState: PickyTodoState }
  | { kind: "extensionUi"; request: Record<string, unknown>; waitsForInput: boolean }
  | { kind: "sessionInfo"; name: string }
  | { kind: "turnTextComplete"; text: string; assistantRun?: RuntimeAssistantRunMetadata }
  | { kind: "none" };

// eslint-disable-next-line complexity -- This is the exhaustive Pi event adapter; keeping event variants together makes unknown events fail closed.
export function normalizePiEvent(event: unknown, context: PiEventNormalizationContext = {}): NormalizedPiEvent {
  const piEvent = asRecord(event);
  const type = stringValue(piEvent.type);
  const now = new Date().toISOString();

  if (type === "agent_start") return { kind: "status", status: "running", summary: "Agent started" };

  if (type === "message_update") {
    const assistantEvent = asRecord(piEvent.assistantMessageEvent);
    if (assistantEvent.type === "text_delta" && typeof assistantEvent.delta === "string") {
      return { kind: "assistantDelta", delta: assistantEvent.delta };
    }
    if (assistantEvent.type === "thinking_delta" && typeof assistantEvent.delta === "string") {
      return { kind: "thinkingDelta", delta: assistantEvent.delta };
    }
    // The model is streaming a tool call's arguments. A long `write` or `edit`
    // spends most of its step here, before tool_execution_start. Deltas map to
    // the same signal so preparation comes back if an interleaved thinking or
    // text event cleared it in the daemon; the handler reports only transitions.
    if (assistantEvent.type === "toolcall_start" || assistantEvent.type === "toolcall_delta") return { kind: "toolCallPreparing" };
    if (assistantEvent.type === "error") {
      return { kind: "status", status: "failed", summary: stringValue(asRecord(assistantEvent.error).errorMessage) ?? stringValue(assistantEvent.error) ?? "Agent error" };
    }
    return { kind: "none" };
  }

  if (type === "entry_appended") {
    const todoState = todoStateFromPiSessionEntry(piEvent.entry);
    return todoState ? { kind: "todoState", todoState } : { kind: "none" };
  }

  if (type === "tool_execution_start") {
    const toolName = requiredString(piEvent.toolName, "toolName");
    const argsPreview = preview(piEvent.args);
    const subagentSummary = subagentToolSummary(toolName, piEvent.args);
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: toolName,
        status: "running",
        preview: argsPreview,
        argsPreview,
        ...(subagentSummary ? { subagentSummary } : {}),
        startedAt: now,
      },
    };
  }

  if (type === "tool_execution_update") {
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: requiredString(piEvent.toolName, "toolName"),
        status: "running",
        preview: preview(piEvent.partialResult),
        startedAt: now,
      },
    };
  }

  if (type === "tool_execution_end") {
    const result = buildToolResultPreview(piEvent.result);
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: requiredString(piEvent.toolName, "toolName"),
        status: piEvent.isError === true ? "failed" : "succeeded",
        preview: result.text,
        resultPreview: result.text,
        ...(result.jsonText ? { resultJSONPreview: result.jsonText } : {}),
        ...(result.truncated ? { resultPreviewTruncated: true } : {}),
        ...(result.repaired ? { resultPreviewRepaired: true } : {}),
        endedAt: now,
      },
    };
  }

  if (type === "extension_ui_request") {
    const method = requiredString(piEvent.method, "method");
    return { kind: "extensionUi", request: piEvent, waitsForInput: ["select", "confirm", "input", "editor", "askUserQuestion"].includes(method) };
  }

  if (type === "session_info" || type === "session_info_changed") {
    const name = stringValue(piEvent.name)?.trim();
    if (!name) return { kind: "none" };
    return { kind: "sessionInfo", name };
  }

  if (type === "message_end") return toolIntroTextFromMessageEnd(asRecord(piEvent.message), context);

  if (type === "turn_end") {
    const message = asRecord(piEvent.message);
    const assistantRun = assistantRunMetadata(message, context);
    const stopReason = stringValue(message.stopReason);
    if (stopReason === "error") return { kind: "none" };
    const stopReasonStatus = terminalStatusFromStopReason(stopReason);
    if (stopReasonStatus) return withFinalAnswer(stopReasonStatus, assistantTextFromMessage(message), assistantRun);
    if (!hasAssistantText(message)) return { kind: "none" };
    // turn_end arrives only after this turn's tools finished. Text that introduced those tools was
    // already flushed at the assistant message_end; flushing it here again would read it twice.
    if (hasAssistantToolCalls(message)) return { kind: "none" };
    // Text alongside tool results but without tool calls of its own had no message_end flush.
    if (hasToolResults(piEvent.toolResults)) {
      const text = assistantTextFromMessage(message);
      if (!text) return { kind: "none" };
      const event: NormalizedPiEvent = { kind: "turnTextComplete", text };
      return assistantRun && hasAssistantRunMetadata(assistantRun) ? { ...event, assistantRun } : event;
    }
    return withFinalAnswer(completionStatusFromContext(context), assistantTextFromMessage(message), assistantRun);
  }

  if (type === "agent_end") {
    const lastMessage = lastAssistantMessage(piEvent.messages);
    const assistantRun = lastMessage ? assistantRunMetadata(lastMessage, context) : assistantRunMetadata(undefined, context);
    const stopReasonStatus = terminalStatusFromStopReason(lastMessage ? stringValue(lastMessage.stopReason) : undefined, lastMessage ? stringValue(lastMessage.errorMessage) : undefined);
    if (stopReasonStatus) return withFinalAnswer(stopReasonStatus, lastMessage ? assistantTextFromMessage(lastMessage) : undefined, assistantRun);
    return withFinalAnswer(completionStatusFromContext(context), lastMessage ? assistantTextFromMessage(lastMessage) : undefined, assistantRun);
  }

  if (type === "extension_error" || type === "auto_retry_end") {
    if (type === "auto_retry_end" && piEvent.success !== false) return { kind: "none" };
    return { kind: "status", status: "failed", summary: stringValue(piEvent.error) ?? stringValue(piEvent.finalError) ?? "Pi runtime error" };
  }

  return { kind: "none" };
}

export function runtimeEventFromPiEvent(event: unknown, context?: PiEventNormalizationContext): RuntimeEvent | undefined {
  const normalized = normalizePiEvent(event, context);
  if (normalized.kind === "log") return { type: "log", line: normalized.line };
  if (normalized.kind === "assistantDelta") return { type: "assistant_delta", delta: normalized.delta };
  if (normalized.kind === "thinkingDelta") return { type: "thinking_delta", delta: normalized.delta };
  if (normalized.kind === "toolCallPreparing") return { type: "tool_call_preparing" };
  if (normalized.kind === "status") {
    return {
      type: "status",
      status: normalized.status as RuntimeSessionStatus,
      ...(normalized.summary ? { summary: normalized.summary } : {}),
      ...(normalized.finalAnswer ? { finalAnswer: normalized.finalAnswer } : {}),
      ...(normalized.assistantRun ? { assistantRun: normalized.assistantRun } : {}),
    };
  }
  if (normalized.kind === "tool") return runtimeToolEvent(normalized.tool);
  if (normalized.kind === "todoState") return { type: "todo_state", todoState: normalized.todoState };
  if (normalized.kind === "extensionUi") return { type: "extension_ui", request: normalized.request, waitsForInput: normalized.waitsForInput };
  if (normalized.kind === "sessionInfo") return { type: "session_info", name: normalized.name };
  if (normalized.kind === "turnTextComplete") {
    return {
      type: "turn_text_complete",
      text: normalized.text,
      ...(normalized.assistantRun ? { assistantRun: normalized.assistantRun } : {}),
    };
  }
  return undefined;
}

function runtimeToolEvent(tool: PickyToolActivity): RuntimeEvent {
  return {
    type: "tool",
    toolCallId: tool.toolCallId,
    name: tool.name,
    status: tool.status,
    preview: tool.preview,
    argsPreview: tool.argsPreview,
    resultPreview: tool.resultPreview,
    ...(tool.resultJSONPreview ? { resultJSONPreview: tool.resultJSONPreview } : {}),
    ...(tool.resultPreviewTruncated ? { resultPreviewTruncated: true } : {}),
    ...(tool.resultPreviewRepaired ? { resultPreviewRepaired: true } : {}),
    ...(tool.subagentSummary ? { subagentSummary: tool.subagentSummary } : {}),
  };
}

function completionStatusFromContext(context: PiEventNormalizationContext): NormalizedPiEvent {
  // Require both signals to agree: a runtime-side pending request without a
  // matching host-side pending request is a ghost (see field docs above) and
  // must not flip the turn into waiting_for_input.
  const hasPending = Boolean(context.hasPendingExtensionUiRequest) && context.hostHasPendingExtensionUiRequest !== false;
  if (hasPending) return { kind: "status", status: "waiting_for_input", summary: "Waiting for input" };
  if (context.hasQueuedSteering || context.hasQueuedFollowUp) return { kind: "status", status: "running", summary: "Queued input pending" };
  return { kind: "status", status: "completed", summary: "Completed" };
}

/**
 * Text the model wrote before calling tools, surfaced the moment its message ends. Pi's turn_end
 * comes only after those tools finish, which can be minutes for a question the user has to answer;
 * by then Picky has already spoken the streamed sentence, and a late flush is read aloud again.
 * Flushing here also keeps this text out of the next step's draft, so the two are not read
 * back-to-back.
 */
function toolIntroTextFromMessageEnd(message: Record<string, unknown>, context: PiEventNormalizationContext): NormalizedPiEvent {
  if (message.role !== "assistant" || !hasAssistantToolCalls(message)) return { kind: "none" };
  // An aborted or failed message does not lead into tools; turn_end and agent_end report it.
  const stopReason = stringValue(message.stopReason);
  if (stopReason === "error" || terminalStatusFromStopReason(stopReason)) return { kind: "none" };
  const text = assistantTextFromMessage(message);
  if (!text) return { kind: "none" };
  const event: NormalizedPiEvent = { kind: "turnTextComplete", text };
  const assistantRun = assistantRunMetadata(message, context);
  return assistantRun && hasAssistantRunMetadata(assistantRun) ? { ...event, assistantRun } : event;
}

function terminalStatusFromStopReason(stopReason: string | undefined, errorMessage?: string): NormalizedPiEvent | undefined {
  if (stopReason === "aborted") return { kind: "status", status: "cancelled", summary: "Cancelled" };
  if (stopReason === "error") return { kind: "status", status: "failed", summary: errorMessage?.trim() || "Agent error" };
  return undefined;
}

function lastAssistantMessage(messages: unknown): Record<string, unknown> | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = asRecord(messages[index]);
    if (message.role === "assistant") return message;
  }
  return undefined;
}

function assistantTextFromMessage(message: Record<string, unknown>): string | undefined {
  const content = message.content;
  if (!Array.isArray(content)) return undefined;
  const text = content
    .map((item) => {
      const block = asRecord(item);
      return block.type === "text" && typeof block.text === "string" ? block.text : "";
    })
    .join("")
    .trim();
  return text.length > 0 ? text : undefined;
}

function withFinalAnswer(status: NormalizedPiEvent, finalAnswer: string | undefined, assistantRun?: RuntimeAssistantRunMetadata): NormalizedPiEvent {
  if (status.kind !== "status") return status;
  return {
    ...status,
    ...(finalAnswer ? { finalAnswer } : {}),
    ...(assistantRun && hasAssistantRunMetadata(assistantRun) ? { assistantRun } : {}),
  };
}

function assistantRunMetadata(message: Record<string, unknown> | undefined, context: PiEventNormalizationContext): RuntimeAssistantRunMetadata | undefined {
  const model = stringValue(message?.model) ?? context.currentModel;
  const thinkingLevel = parseThinkingLevel(message?.thinkingLevel) ?? context.currentThinkingLevel;
  const metadata: RuntimeAssistantRunMetadata = {
    ...(model ? { model } : {}),
    ...(thinkingLevel ? { thinkingLevel } : {}),
  };
  return hasAssistantRunMetadata(metadata) ? metadata : undefined;
}

function hasAssistantRunMetadata(metadata: RuntimeAssistantRunMetadata): boolean {
  return Boolean(metadata.model || metadata.thinkingLevel);
}

function parseThinkingLevel(value: unknown): ThinkingLevel | undefined {
  if (value === "off" || value === "minimal" || value === "low" || value === "medium" || value === "high" || value === "xhigh" || value === "max") return value;
  return undefined;
}

function hasAssistantText(message: Record<string, unknown>): boolean {
  const content = message.content;
  return Array.isArray(content) && content.some((item) => {
    const block = asRecord(item);
    return block.type === "text" && typeof block.text === "string" && block.text.trim().length > 0;
  });
}

function hasAssistantToolCalls(message: Record<string, unknown>): boolean {
  const content = message.content;
  return Array.isArray(content) && content.some((item) => asRecord(item).type === "toolCall");
}

function hasToolResults(value: unknown): boolean {
  return Array.isArray(value) && value.length > 0;
}

function subagentToolSummary(toolName: string, args: unknown): PickySubagentToolSummary | undefined {
  if (toolName !== "subagent") return undefined;
  const intent = subagentLaunchIntentFromToolArgs(args);
  if (!intent || intent.action === "run") return undefined;
  return {
    action: intent.action,
    agents: intent.entries.map((entry) => entry.agent),
  };
}

function preview(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  let text: string;
  if (typeof value === "string") {
    text = value;
  } else if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    text = JSON.stringify(reorderForPreview(value as Record<string, unknown>));
  } else {
    text = JSON.stringify(value);
  }
  return text.length > 500 ? `${sliceUtf16Safe(text, 497)}...` : text;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`Pi event is missing ${field}`);
  return value;
}
