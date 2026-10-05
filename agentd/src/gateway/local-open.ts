/**
 * "Open in browser" from the Mac: one-time loopback sign-in links.
 *
 * The Mac asks over the hub socket (which only Picky.app can open), gets a URL
 * with a single-use token, and hands it to the default browser. The gateway
 * accepts the token only from a loopback peer with no tunnel in front, so the
 * link is useless from a phone even if it leaks. A browser that is already
 * paired keeps its device; a new one is added as this Mac's browser.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";

export const LOCAL_OPEN_TTL_MS = 60_000;
const MAX_PENDING = 8;

export class LocalOpenTokens {
  private readonly pending = new Map<string, number>();

  constructor(private readonly now: () => number = Date.now) {}

  issue(): string {
    this.prune();
    // A burst of clicks keeps only the newest few links alive.
    while (this.pending.size >= MAX_PENDING) this.pending.delete(this.pending.keys().next().value as string);
    const token = randomBytes(24).toString("base64url");
    this.pending.set(token, this.now() + LOCAL_OPEN_TTL_MS);
    return token;
  }

  /** True once per issued token, within its lifetime. */
  consume(candidate: string): boolean {
    this.prune();
    for (const [token] of this.pending) {
      const a = Buffer.from(token);
      const b = Buffer.from(candidate);
      if (a.length === b.length && timingSafeEqual(a, b)) {
        this.pending.delete(token);
        return true;
      }
    }
    return false;
  }

  private prune(): void {
    const now = this.now();
    for (const [token, expiresAt] of this.pending) if (expiresAt <= now) this.pending.delete(token);
  }
}

/** A short, recognisable device name from the user agent: "Chrome", "Safari", ... */
export function browserNameOf(userAgent: string | undefined): string {
  const ua = userAgent ?? "";
  if (/Edg\//.test(ua)) return "Edge";
  if (/Firefox\//.test(ua)) return "Firefox";
  if (/(Chrome|CriOS)\//.test(ua)) return "Chrome";
  if (/Safari\//.test(ua)) return "Safari";
  return "Browser";
}
