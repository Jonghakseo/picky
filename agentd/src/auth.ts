import type { IncomingMessage } from "node:http";

export function isAuthorized(request: IncomingMessage, expectedToken: string): boolean {
  if (!expectedToken) return false;
  const header = request.headers.authorization;
  if (header === `Bearer ${expectedToken}`) return true;
  const url = new URL(request.url ?? "/", "ws://127.0.0.1");
  return url.searchParams.get("token") === expectedToken;
}
