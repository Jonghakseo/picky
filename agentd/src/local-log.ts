type LogField = string | number | boolean | null | undefined;

const enabled = process.env.PICKY_AGENTD_LOG !== "0" && process.env.NODE_ENV !== "test";

export function logAgentd(event: string, fields: Record<string, LogField> = {}): void {
  if (!enabled) return;
  const suffix = Object.entries(fields)
    .filter((entry): entry is [string, Exclude<LogField, undefined>] => entry[1] !== undefined)
    .map(([key, value]) => `${key}=${formatValue(value)}`)
    .join(" ");
  console.log(`${new Date().toISOString()} picky-agentd ${event}${suffix ? ` ${suffix}` : ""}`);
}

function formatValue(value: Exclude<LogField, undefined>): string {
  if (typeof value === "string") return JSON.stringify(value);
  return String(value);
}
