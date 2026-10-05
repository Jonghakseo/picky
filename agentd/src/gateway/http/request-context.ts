/**
 * What the gateway is allowed to believe about an incoming request
 * (docs/remote-pwa-implementation.md 2.3 and 2.4).
 *
 * The gateway binds loopback only, so anything whose host is not localhost
 * arrived through Tailscale Serve or a tunnel, which terminate TLS. That is why
 * a non-local host counts as https even without `X-Forwarded-Proto`.
 */
import type { IncomingHttpHeaders, IncomingMessage } from "node:http";

export const DEVICE_COOKIE_NAME = "picky_remote";
export const DEVICE_COOKIE_MAX_AGE_SECONDS = 31_536_000;

export interface RequestFacts {
  method: string;
  /** Path without the query string. */
  path: string;
  url: URL;
  host: string;
  secure: boolean;
  clientIp: string;
  headers: IncomingHttpHeaders;
}

function headerValue(headers: IncomingHttpHeaders, name: string): string | undefined {
  const value = headers[name];
  if (Array.isArray(value)) return value[0];
  return value;
}

/**
 * `CF-Connecting-IP` first, then the right-most `X-Forwarded-For` entry, then
 * the socket. The gateway listens on loopback only, so the one hop in front of
 * it is the local tunnel: Cloudflare overwrites `CF-Connecting-IP` at its edge,
 * and Tailscale Serve appends the address it saw to `X-Forwarded-For`. Earlier
 * entries come from the client and can be forged, so they must not key the
 * lockout.
 */
export function clientIpOf(request: IncomingMessage): string {
  const cloudflare = headerValue(request.headers, "cf-connecting-ip")?.trim();
  if (cloudflare) return cloudflare;
  const forwarded = headerValue(request.headers, "x-forwarded-for");
  const last = forwarded?.split(",").map((entry) => entry.trim()).filter(Boolean).at(-1);
  if (last) return last;
  return request.socket.remoteAddress ?? "unknown";
}

export function requestHostOf(request: IncomingMessage): string {
  return (headerValue(request.headers, "x-forwarded-host") ?? headerValue(request.headers, "host") ?? "").trim();
}

export function isLocalHost(host: string): boolean {
  const hostname = host.replace(/^\[/, "").split("]")[0].split(":")[0].toLowerCase();
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1" || hostname === "";
}

export function isSecureRequest(request: IncomingMessage): boolean {
  const proto = headerValue(request.headers, "x-forwarded-proto")?.split(",")[0]?.trim().toLowerCase();
  if (proto === "https") return true;
  if (proto === "http") return false;
  return !isLocalHost(requestHostOf(request));
}

export function requestFacts(request: IncomingMessage): RequestFacts {
  const host = requestHostOf(request);
  const url = new URL(request.url ?? "/", `http://${host || "127.0.0.1"}`);
  return {
    method: (request.method ?? "GET").toUpperCase(),
    path: url.pathname,
    url,
    host,
    secure: isSecureRequest(request),
    clientIp: clientIpOf(request),
    headers: request.headers,
  };
}

export type OriginCheck = { ok: true } | { ok: false; reason: "origin" | "secFetchSite" };

/**
 * Same-origin gate for the WebSocket upgrade and every state-changing `/api`
 * call. A browser cannot forge either header, so this is the CSRF boundary.
 */
export function checkSameOrigin(request: IncomingMessage): OriginCheck {
  const site = headerValue(request.headers, "sec-fetch-site")?.trim().toLowerCase();
  if (site && site !== "same-origin" && site !== "none") return { ok: false, reason: "secFetchSite" };

  const origin = headerValue(request.headers, "origin")?.trim();
  if (!origin) return { ok: false, reason: "origin" };
  let originHost: string;
  try {
    originHost = new URL(origin).host;
  } catch {
    return { ok: false, reason: "origin" };
  }
  return originHost === requestHostOf(request) ? { ok: true } : { ok: false, reason: "origin" };
}

export function parseCookies(header: string | undefined): Record<string, string> {
  const cookies: Record<string, string> = {};
  for (const part of (header ?? "").split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (!name) continue;
    cookies[name] = decodeURIComponent(part.slice(separator + 1).trim());
  }
  return cookies;
}

export function deviceTokenOf(request: IncomingMessage): string | undefined {
  return parseCookies(headerValue(request.headers, "cookie"))[DEVICE_COOKIE_NAME];
}

export function deviceCookie(token: string, secure: boolean): string {
  const attributes = [
    `${DEVICE_COOKIE_NAME}=${token}`,
    "HttpOnly",
    "SameSite=Lax",
    "Path=/",
    `Max-Age=${DEVICE_COOKIE_MAX_AGE_SECONDS}`,
  ];
  if (secure) attributes.push("Secure");
  return attributes.join("; ");
}

export function clearedDeviceCookie(secure: boolean): string {
  const attributes = [`${DEVICE_COOKIE_NAME}=`, "HttpOnly", "SameSite=Lax", "Path=/", "Max-Age=0"];
  if (secure) attributes.push("Secure");
  return attributes.join("; ");
}

/** The hub socket is loopback-only; a tunnel always sets a forwarding header. */
export function isLoopbackPeer(request: IncomingMessage): boolean {
  if (headerValue(request.headers, "x-forwarded-for") || headerValue(request.headers, "cf-connecting-ip")) return false;
  const address = request.socket.remoteAddress ?? "";
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}
