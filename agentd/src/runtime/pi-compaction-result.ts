import { numberValue, stringValue } from "./pi-sdk-runtime-helpers.js";
import type { RuntimeCompactionResult } from "./types.js";

/** Pi's `CompactionResult` numbers and summary, or undefined when the payload is missing. */
export function compactionResultFromPiEvent(result: unknown): RuntimeCompactionResult | undefined {
  if (!result || typeof result !== "object") return undefined;
  const record = result as Record<string, unknown>;
  const tokensBefore = numberValue(record.tokensBefore);
  if (tokensBefore === undefined) return undefined;
  const tokensAfter = numberValue(record.estimatedTokensAfter);
  const summary = stringValue(record.summary)?.trim();
  return { tokensBefore, ...(tokensAfter === undefined ? {} : { tokensAfter }), ...(summary ? { summary } : {}) };
}
