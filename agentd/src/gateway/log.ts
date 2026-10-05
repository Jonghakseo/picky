/**
 * Gateway lifecycle log. Mirrors `local-log.ts` but tags lines `picky-gateway`
 * so the hub's `gateway.stdout.log` stays readable next to the daemon logs.
 *
 * Scalars only: message text, transcripts and file contents never go here.
 */
export type GatewayLogField = string | number | boolean | null | undefined;

const enabled = process.env.PICKY_GATEWAY_LOG !== "0" && process.env.NODE_ENV !== "test";

export function logGateway(event: string, fields: Record<string, GatewayLogField> = {}): void {
  if (!enabled) return;
  const suffix = Object.entries(fields)
    .filter((entry): entry is [string, Exclude<GatewayLogField, undefined>] => entry[1] !== undefined)
    .map(([key, value]) => `${key}=${typeof value === "string" ? JSON.stringify(value) : String(value)}`)
    .join(" ");
  process.stdout.write(`${new Date().toISOString()} picky-gateway ${event}${suffix ? ` ${suffix}` : ""}\n`);
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
