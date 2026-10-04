/**
 * Reduces a provider error string to what a user can act on: the HTTP status
 * code and the provider's own message.
 *
 * Pi reports provider failures as the raw response, for example
 * `429 {"type":"error","error":{"type":"rate_limit_error","message":"Usage credits are required for fast mode."},"request_id":"req_..."}`.
 * The JSON envelope and request id mean nothing to a user; the code and the
 * message are the only parts that explain why the request keeps failing.
 */
export interface ProviderErrorSummary {
  /** HTTP status code when the error starts with one, e.g. "429". */
  code?: string;
  message: string;
}

const MESSAGE_CHAR_LIMIT = 240;

export function summarizeProviderError(raw: string): ProviderErrorSummary {
  const trimmed = raw.trim();
  const leadingCode = /^(\d{3})(?=\D|$)[\s:-]*([\s\S]*)$/.exec(trimmed);
  const code = leadingCode?.[1];
  const rest = (leadingCode ? leadingCode[2] : trimmed).trim();
  const message = providerMessage(rest) ?? firstLine(rest) ?? firstLine(trimmed) ?? trimmed;
  return { ...(code ? { code } : {}), message: truncate(message) };
}

/** Status for a Pi auto-retry: the attempt plus the summarized cause of the failed request. */
export function autoRetryStatus(attempt: number | undefined, maxAttempts: number | undefined, rawError: string | undefined) {
  if (!attempt || !maxAttempts) return undefined;
  const error = summarizeProviderError(rawError ?? "Unknown error");
  return { attempt, maxAttempts, ...(error.code ? { errorCode: error.code } : {}), errorMessage: error.message };
}

function providerMessage(text: string): string | undefined {
  if (!text.startsWith("{")) return undefined;
  try {
    const parsed = JSON.parse(text) as unknown;
    if (!isRecord(parsed)) return undefined;
    const nested = isRecord(parsed.error) ? parsed.error.message : parsed.error;
    const candidate = typeof nested === "string" ? nested : parsed.message;
    return typeof candidate === "string" ? firstLine(candidate) : undefined;
  } catch {
    return undefined;
  }
}

function firstLine(text: string): string | undefined {
  const line = text.split(/\r?\n/).map((part) => part.trim()).find(Boolean);
  return line || undefined;
}

function truncate(text: string): string {
  return text.length > MESSAGE_CHAR_LIMIT ? `${text.slice(0, MESSAGE_CHAR_LIMIT - 1)}…` : text;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
