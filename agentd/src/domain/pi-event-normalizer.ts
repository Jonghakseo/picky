import type { PickyToolActivity, SessionStatus } from "../protocol.js";
import type { RuntimeEvent, RuntimeSessionStatus } from "../runtime/types.js";

export interface PiEventNormalizationContext {
  hasQueuedSteering?: boolean;
  hasQueuedFollowUp?: boolean;
  hasPendingExtensionUiRequest?: boolean;
}

export type NormalizedPiEvent =
  | { kind: "log"; line: string }
  | { kind: "assistantDelta"; delta: string }
  | { kind: "thinkingDelta"; delta: string }
  | { kind: "status"; status: SessionStatus; summary?: string }
  | { kind: "tool"; tool: PickyToolActivity }
  | { kind: "extensionUi"; request: Record<string, unknown>; waitsForInput: boolean }
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
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: requiredString(piEvent.toolName, "toolName"),
        status: "running",
        preview: preview(piEvent.args),
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
    return {
      kind: "tool",
      tool: {
        toolCallId: requiredString(piEvent.toolCallId, "toolCallId"),
        name: requiredString(piEvent.toolName, "toolName"),
        status: piEvent.isError === true ? "failed" : "succeeded",
        preview: preview(piEvent.result),
        endedAt: now,
      },
    };
  }

  if (type === "queue_update") {
    const steering = Array.isArray(piEvent.steering) ? piEvent.steering.length : 0;
    const followUp = Array.isArray(piEvent.followUp) ? piEvent.followUp.length : 0;
    return { kind: "log", line: `queue update: steering=${steering} followUp=${followUp}` };
  }

  if (type === "extension_ui_request") {
    const method = requiredString(piEvent.method, "method");
    return { kind: "extensionUi", request: piEvent, waitsForInput: ["select", "confirm", "input", "editor", "askUserQuestion"].includes(method) };
  }

  if (type === "turn_end") {
    const message = asRecord(piEvent.message);
    const stopReasonStatus = terminalStatusFromStopReason(stringValue(message.stopReason));
    if (stopReasonStatus) return stopReasonStatus;
    if (!hasAssistantText(message) || hasAssistantToolCalls(message) || hasToolResults(piEvent.toolResults)) return { kind: "none" };
    return completionStatusFromContext(context);
  }

  if (type === "agent_end") {
    const stopReasonStatus = terminalStatusFromStopReason(lastAssistantStopReason(piEvent.messages));
    if (stopReasonStatus) return stopReasonStatus;
    return completionStatusFromContext(context);
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
  if (normalized.kind === "status") return { type: "status", status: normalized.status as RuntimeSessionStatus, summary: normalized.summary };
  if (normalized.kind === "tool") return { type: "tool", toolCallId: normalized.tool.toolCallId, name: normalized.tool.name, status: normalized.tool.status, preview: normalized.tool.preview };
  if (normalized.kind === "extensionUi") return { type: "extension_ui", request: normalized.request, waitsForInput: normalized.waitsForInput };
  return undefined;
}

function completionStatusFromContext(context: PiEventNormalizationContext): NormalizedPiEvent {
  if (context.hasPendingExtensionUiRequest) return { kind: "status", status: "waiting_for_input", summary: "Waiting for input" };
  if (context.hasQueuedSteering || context.hasQueuedFollowUp) return { kind: "status", status: "running", summary: "Queued input pending" };
  return { kind: "status", status: "completed", summary: "Completed" };
}

function terminalStatusFromStopReason(stopReason: string | undefined): NormalizedPiEvent | undefined {
  if (stopReason === "aborted") return { kind: "status", status: "cancelled", summary: "Cancelled" };
  if (stopReason === "error") return { kind: "status", status: "failed", summary: "Agent error" };
  return undefined;
}

function lastAssistantStopReason(messages: unknown): string | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = asRecord(messages[index]);
    if (message.role === "assistant") return stringValue(message.stopReason);
  }
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
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return text.length > 500 ? `${text.slice(0, 497)}...` : text;
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
