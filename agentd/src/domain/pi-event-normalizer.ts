import type { PickyToolActivity, SessionStatus } from "../protocol.js";
import type { RuntimeAssistantRunMetadata, RuntimeEvent, RuntimeSessionStatus, ThinkingLevel } from "../runtime/types.js";
import { sliceUtf16Safe } from "./safe-truncate.js";

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
  | { kind: "status"; status: SessionStatus; summary?: string; finalAnswer?: string; assistantRun?: RuntimeAssistantRunMetadata }
  | { kind: "tool"; tool: PickyToolActivity }
  | { kind: "extensionUi"; request: Record<string, unknown>; waitsForInput: boolean }
  | { kind: "sessionInfo"; name: string }
  | { kind: "turnTextComplete"; text: string; assistantRun?: RuntimeAssistantRunMetadata }
  | { kind: "none" };

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
    if (assistantEvent.type === "error") {
      return { kind: "status", status: "failed", summary: stringValue(assistantEvent.error) ?? "Agent error" };
    }
    return { kind: "none" };
  }

  if (type === "tool_execution_start") {
    const argsPreview = preview(piEvent.args);
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: requiredString(piEvent.toolName, "toolName"),
        status: "running",
        preview: argsPreview,
        argsPreview,
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
    const resultPreview = preview(piEvent.result);
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: requiredString(piEvent.toolName, "toolName"),
        status: piEvent.isError === true ? "failed" : "succeeded",
        preview: resultPreview,
        resultPreview,
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

  if (type === "turn_end") {
    const message = asRecord(piEvent.message);
    const assistantRun = assistantRunMetadata(message, context);
    const stopReason = stringValue(message.stopReason);
    if (stopReason === "error") return { kind: "none" };
    const stopReasonStatus = terminalStatusFromStopReason(stopReason);
    if (stopReasonStatus) return withFinalAnswer(stopReasonStatus, assistantTextFromMessage(message), assistantRun);
    if (!hasAssistantText(message)) return { kind: "none" };
    // Intermediate turn: the LLM emitted both an inline text block and tool calls
    // (or the turn produced text alongside tool results). Surface the text via
    // `turnTextComplete` so the supervisor can flush it as its own quickReply
    // before the tool runs, instead of accumulating it into the next turn's
    // assistant draft and reading both blocks back-to-back through TTS.
    if (hasAssistantToolCalls(message) || hasToolResults(piEvent.toolResults)) {
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
    const stopReasonStatus = terminalStatusFromStopReason(lastMessage ? stringValue(lastMessage.stopReason) : undefined);
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
  if (normalized.kind === "status") {
    return {
      type: "status",
      status: normalized.status as RuntimeSessionStatus,
      ...(normalized.summary ? { summary: normalized.summary } : {}),
      ...(normalized.finalAnswer ? { finalAnswer: normalized.finalAnswer } : {}),
      ...(normalized.assistantRun ? { assistantRun: normalized.assistantRun } : {}),
    };
  }
  if (normalized.kind === "tool") return { type: "tool", toolCallId: normalized.tool.toolCallId, name: normalized.tool.name, status: normalized.tool.status, preview: normalized.tool.preview, argsPreview: normalized.tool.argsPreview, resultPreview: normalized.tool.resultPreview };
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

function completionStatusFromContext(context: PiEventNormalizationContext): NormalizedPiEvent {
  // Require both signals to agree: a runtime-side pending request without a
  // matching host-side pending request is a ghost (see field docs above) and
  // must not flip the turn into waiting_for_input.
  const hasPending = Boolean(context.hasPendingExtensionUiRequest) && context.hostHasPendingExtensionUiRequest !== false;
  if (hasPending) return { kind: "status", status: "waiting_for_input", summary: "Waiting for input" };
  if (context.hasQueuedSteering || context.hasQueuedFollowUp) return { kind: "status", status: "running", summary: "Queued input pending" };
  return { kind: "status", status: "completed", summary: "Completed" };
}

function terminalStatusFromStopReason(stopReason: string | undefined): NormalizedPiEvent | undefined {
  if (stopReason === "aborted") return { kind: "status", status: "cancelled", summary: "Cancelled" };
  if (stopReason === "error") return { kind: "status", status: "failed", summary: "Agent error" };
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
  if (value === "off" || value === "minimal" || value === "low" || value === "medium" || value === "high" || value === "xhigh") return value;
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

/// Reorders object keys so high-signal fields (file path, command) appear at
/// the head of the serialized preview. Without this the 500-char truncation can
/// drop the only field the HUD inline tool row actually surfaces — e.g. an
/// `edit` call carrying a long `edits[].oldText/newText` payload would shift
/// `path` past the cut-off and render as an empty row in the conversation card.
function reorderForPreview(obj: Record<string, unknown>): Record<string, unknown> {
  const priorityKeys = ["path", "file_path", "filePath", "file", "command"];
  const out: Record<string, unknown> = {};
  for (const key of priorityKeys) {
    if (Object.prototype.hasOwnProperty.call(obj, key)) {
      out[key] = obj[key];
    }
  }
  for (const [key, value] of Object.entries(obj)) {
    if (!Object.prototype.hasOwnProperty.call(out, key)) {
      out[key] = value;
    }
  }
  return out;
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
