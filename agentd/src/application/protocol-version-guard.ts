export function assertProtocolVersion(input: unknown, expected: string): void {
  if (!input || typeof input !== "object" || Array.isArray(input)) return;
  const protocolVersion = (input as { protocolVersion?: unknown }).protocolVersion;
  if (typeof protocolVersion === "string" && protocolVersion !== expected) {
    throw new Error(`Protocol version mismatch: client=${protocolVersion}, server=${expected}`);
  }
}
