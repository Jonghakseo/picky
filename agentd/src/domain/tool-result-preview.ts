import { jsonrepair } from "jsonrepair";
import { sliceUtf16Safe } from "./safe-truncate.js";

export interface ToolResultPreview {
  text?: string;
  truncated: boolean;
  repaired: boolean;
}

const DEFAULT_MAX_CHARS = 500;

export function buildToolResultPreview(value: unknown, maxChars = DEFAULT_MAX_CHARS): ToolResultPreview {
  if (value === undefined) return { truncated: false, repaired: false };

  const text = serializePreviewValue(value);
  if (text === undefined) return { truncated: false, repaired: false };

  if (!isJSONCandidate(value, text)) {
    return boundedPlainText(text, maxChars);
  }

  const isCompleteJSON = isValidJSON(text);
  if (text.length <= maxChars && isCompleteJSON) {
    return { text, truncated: false, repaired: false };
  }

  // Before structured preview metadata existed, result previews were cut to
  // exactly 500 UTF-16 units by replacing the final three units with `...`.
  // Treat that recognizable wire shape as truncated source so persisted
  // sessions can be projected through the same repair policy on load.
  const legacyTruncated = text.length === maxChars && text.endsWith("...");
  const sourceTruncated = text.length > maxChars || legacyTruncated;
  const repairSource = legacyTruncated ? text.slice(0, -3) : text;
  const repaired = repairWithinBudget(repairSource, maxChars, sourceTruncated);
  if (repaired !== undefined) {
    return {
      text: repaired.text,
      truncated: sourceTruncated || repaired.sourceWasReduced,
      repaired: true,
    };
  }

  return boundedPlainText(text, maxChars);
}

export function isJSONObjectOrArrayText(text: string | undefined): boolean {
  if (!text) return false;
  const trimmed = text.trimStart();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return false;
  try {
    const value = JSON.parse(trimmed) as unknown;
    return value !== null && typeof value === "object";
  } catch {
    return false;
  }
}

function serializePreviewValue(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    return JSON.stringify(reorderForPreview(value as Record<string, unknown>));
  }
  return JSON.stringify(value);
}

function isJSONCandidate(value: unknown, text: string): boolean {
  if (value !== null && typeof value === "object") return true;
  const trimmed = text.trimStart();
  return trimmed.startsWith("{") || trimmed.startsWith("[");
}

function isValidJSON(text: string): boolean {
  try {
    JSON.parse(text);
    return true;
  } catch {
    return false;
  }
}

function repairWithinBudget(
  source: string,
  maxChars: number,
  allowSourceReduction = source.length > maxChars,
): { text: string; sourceWasReduced: boolean } | undefined {
  if (maxChars <= 0) return undefined;

  if (source.length <= maxChars) {
    try {
      const repaired = jsonrepair(source);
      if (repaired.length <= maxChars && isValidJSON(repaired)) {
        return { text: repaired, sourceWasReduced: false };
      }
      if (!allowSourceReduction) return undefined;
    } catch {
      if (!allowSourceReduction) return undefined;
    }
  }

  const initialLength = Math.min(source.length - 1, maxChars);
  for (let length = initialLength; length > 0; length -= 1) {
    const prefix = sliceUtf16Safe(source, length);
    if (!prefix.trim()) continue;
    try {
      const repaired = jsonrepair(prefix);
      if (repaired.length <= maxChars && isValidJSON(repaired)) {
        return { text: repaired, sourceWasReduced: prefix.length < source.length };
      }
    } catch {
      // Retry with a shorter source prefix. A shorter prefix can remove the
      // malformed tail while retaining the visible head of a truncated result.
    }
  }
  return undefined;
}

function boundedPlainText(text: string, maxChars: number): ToolResultPreview {
  if (text.length <= maxChars) return { text, truncated: false, repaired: false };
  if (maxChars <= 0) return { text: "", truncated: true, repaired: false };
  if (maxChars <= 3) return { text: sliceUtf16Safe(text, maxChars), truncated: true, repaired: false };
  return { text: `${sliceUtf16Safe(text, maxChars - 3)}...`, truncated: true, repaired: false };
}

/// Reorders object keys so high-signal fields remain near the start of both
/// argument and result previews when the shared character budget is reached.
export function reorderForPreview(obj: Record<string, unknown>): Record<string, unknown> {
  const priorityKeys = ["path", "file_path", "filePath", "file", "command"];
  const out: Record<string, unknown> = {};
  for (const key of priorityKeys) {
    if (Object.prototype.hasOwnProperty.call(obj, key)) out[key] = obj[key];
  }
  for (const [key, value] of Object.entries(obj)) {
    if (!Object.prototype.hasOwnProperty.call(out, key)) out[key] = value;
  }
  return out;
}
