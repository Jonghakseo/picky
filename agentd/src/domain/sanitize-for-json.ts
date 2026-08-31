/**
 * Replaces lone UTF-16 surrogates so a payload always survives JSON.stringify and the
 * WebSocket frame. Pure string work: no transport or protocol knowledge.
 */
export function sanitizeForJson<T>(value: T): T {
  if (typeof value === "string") return repairLoneSurrogates(value) as T;
  if (Array.isArray(value)) return value.map((item) => sanitizeForJson(item)) as T;
  if (value && typeof value === "object") {
    const sanitized: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value)) sanitized[key] = sanitizeForJson(child);
    return sanitized as T;
  }
  return value;
}

function repairLoneSurrogates(value: string): string {
  let result = "";
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        result += value[index] + value[index + 1];
        index += 1;
      } else {
        result += "\uFFFD";
      }
      continue;
    }
    if (code >= 0xdc00 && code <= 0xdfff) {
      result += "\uFFFD";
      continue;
    }
    result += value[index];
  }
  return result;
}
