import type { PickyExtensionUiRequest } from "../protocol.js";

export function mapExtensionUiRequest(rawRequest: Record<string, unknown>): PickyExtensionUiRequest {
  return rawRequest as PickyExtensionUiRequest;
}

export function extensionUiLogLine(request: PickyExtensionUiRequest): string {
  return `extension ui: ${request.method}${request.title ? ` ${request.title}` : ""}`;
}

export function extensionUiWaitingSummary(request: PickyExtensionUiRequest): string {
  return request.prompt ?? request.title ?? "Waiting for input";
}

/**
 * Build a human-readable summary of the user's answer to an extension UI request.
 * Returns `undefined` for cancellations or when the answer carries no displayable
 * content. Picky uses the result to refresh the Pickle card REQUEST line and
 * to write a `extension ui answer:` log entry that survives snapshot rebuilds.
 */
export function summarizeExtensionUiAnswer(request: PickyExtensionUiRequest, rawValue: unknown): string | undefined {
  if (isCancelled(rawValue)) return undefined;
  switch (request.method) {
    case "confirm":
      return isAllowed(rawValue) ? "Allowed" : undefined;
    case "select": {
      const text = trimString(unwrapValue(rawValue));
      return text || undefined;
    }
    case "input":
    case "editor": {
      const text = trimString(unwrapValue(rawValue));
      return text || undefined;
    }
    case "askUserQuestion": {
      const inner = unwrapValue(rawValue);
      if (!isPlainObject(inner)) return undefined;
      return summarizeAskUserQuestion(request.questions ?? [], inner);
    }
    default:
      return undefined;
  }
}

function summarizeAskUserQuestion(questions: PickyExtensionUiRequest["questions"], answers: Record<string, unknown>): string | undefined {
  if (!questions || questions.length === 0) return undefined;
  const parts: string[] = [];
  questions.forEach((question, index) => {
    const key = questionKey(question, index);
    if (!(key in answers)) return;
    const formatted = formatQuestionAnswer(answers[key], question.options ?? []);
    if (!formatted) return;
    if (questions.length === 1) {
      parts.push(formatted);
      return;
    }
    const label = ((question.prompt ?? question.label ?? key) ?? "").trim();
    parts.push(label ? `${label}: ${formatted}` : formatted);
  });
  if (questions.length === 1 && parts.length === 1) return parts[0];
  const combined = parts.join(" \u00b7 ");
  return combined ? combined : undefined;
}

function formatQuestionAnswer(value: unknown, options: NonNullable<NonNullable<PickyExtensionUiRequest["questions"]>[number]["options"]>): string | undefined {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return undefined;
    return options.find((option) => option.value === trimmed)?.label ?? trimmed;
  }
  if (Array.isArray(value)) {
    const labels: string[] = [];
    for (const item of value) {
      if (typeof item !== "string") continue;
      const trimmed = item.trim();
      if (!trimmed) continue;
      labels.push(options.find((option) => option.value === trimmed)?.label ?? trimmed);
    }
    return labels.length ? labels.join(", ") : undefined;
  }
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number" && Number.isFinite(value)) return Number.isInteger(value) ? String(value) : String(value);
  return undefined;
}

function questionKey(question: NonNullable<PickyExtensionUiRequest["questions"]>[number], index: number): string {
  const trimmed = (question.id ?? "").trim();
  return trimmed || `q${index + 1}`;
}

function unwrapValue(rawValue: unknown): unknown {
  if (isPlainObject(rawValue) && "value" in rawValue) return rawValue.value;
  return rawValue;
}

function isCancelled(value: unknown): boolean {
  return isPlainObject(value) && value.cancelled === true;
}

function isAllowed(value: unknown): boolean {
  if (value === true) return true;
  if (isPlainObject(value)) {
    if (value.confirmed === true) return true;
    if (value.value === true) return true;
  }
  return false;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function trimString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}
