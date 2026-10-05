import type { IncomingHttpHeaders, IncomingMessage } from "node:http";
import { describe, expect, it } from "vitest";
import {
  checkSameOrigin,
  clearedDeviceCookie,
  clientIpOf,
  deviceCookie,
  deviceTokenOf,
  isLoopbackPeer,
  isSecureRequest,
  parseCookies,
} from "./request-context.js";

function request(headers: IncomingHttpHeaders, remoteAddress = "127.0.0.1"): IncomingMessage {
  return { headers, socket: { remoteAddress }, url: "/api/ws", method: "GET" } as unknown as IncomingMessage;
}

describe("client IP", () => {
  it("prefers CF-Connecting-IP, then the first X-Forwarded-For entry, then the socket", () => {
    expect(clientIpOf(request({ "cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "198.51.100.1" }))).toBe("203.0.113.7");
    expect(clientIpOf(request({ "x-forwarded-for": "198.51.100.1, 10.0.0.1" }))).toBe("198.51.100.1");
    expect(clientIpOf(request({}, "100.64.0.3"))).toBe("100.64.0.3");
  });
});

describe("request scheme", () => {
  it("treats a non-local host as https, because only a tunnel can reach it", () => {
    expect(isSecureRequest(request({ host: "mac.tailnet-1234.ts.net" }))).toBe(true);
    expect(isSecureRequest(request({ host: "127.0.0.1:17640" }))).toBe(false);
    expect(isSecureRequest(request({ host: "localhost:17640" }))).toBe(false);
  });

  it("honours X-Forwarded-Proto in both directions", () => {
    expect(isSecureRequest(request({ host: "127.0.0.1:17640", "x-forwarded-proto": "https" }))).toBe(true);
    expect(isSecureRequest(request({ host: "mac.ts.net", "x-forwarded-proto": "http" }))).toBe(false);
  });
});

describe("device cookie", () => {
  it("adds Secure only on https and always keeps HttpOnly and SameSite=Lax", () => {
    const secure = deviceCookie("token-1", true);
    expect(secure).toContain("HttpOnly");
    expect(secure).toContain("SameSite=Lax");
    expect(secure).toContain("Max-Age=31536000");
    expect(secure).toContain("Secure");
    expect(deviceCookie("token-1", false)).not.toContain("Secure");
    expect(clearedDeviceCookie(false)).toContain("Max-Age=0");
  });

  it("reads the token back out of a cookie header with other cookies present", () => {
    expect(parseCookies("a=1; picky_remote=abc; b=2").picky_remote).toBe("abc");
    expect(deviceTokenOf(request({ cookie: "picky_remote=abc" }))).toBe("abc");
    expect(deviceTokenOf(request({}))).toBeUndefined();
  });
});

describe("same-origin gate", () => {
  it("accepts an Origin whose host matches the request host", () => {
    expect(checkSameOrigin(request({ host: "mac.ts.net", origin: "https://mac.ts.net" }))).toEqual({ ok: true });
    expect(checkSameOrigin(request({ host: "a.ts.net", "x-forwarded-host": "mac.ts.net", origin: "https://mac.ts.net" }))).toEqual({ ok: true });
  });

  it("rejects a foreign origin and a cross-site fetch", () => {
    expect(checkSameOrigin(request({ host: "mac.ts.net", origin: "https://evil.example" }))).toEqual({ ok: false, reason: "origin" });
    expect(checkSameOrigin(request({ host: "mac.ts.net", origin: "https://mac.ts.net", "sec-fetch-site": "cross-site" })))
      .toEqual({ ok: false, reason: "secFetchSite" });
    expect(checkSameOrigin(request({ host: "mac.ts.net", origin: "https://mac.ts.net", "sec-fetch-site": "same-site" })))
      .toEqual({ ok: false, reason: "secFetchSite" });
  });

  it("rejects a request with no Origin at all", () => {
    expect(checkSameOrigin(request({ host: "mac.ts.net" }))).toEqual({ ok: false, reason: "origin" });
    expect(checkSameOrigin(request({ host: "mac.ts.net", "sec-fetch-site": "none" }))).toEqual({ ok: false, reason: "origin" });
  });
});

describe("hub peer", () => {
  it("accepts loopback only and never a forwarded request", () => {
    expect(isLoopbackPeer(request({}, "127.0.0.1"))).toBe(true);
    expect(isLoopbackPeer(request({}, "::ffff:127.0.0.1"))).toBe(true);
    expect(isLoopbackPeer(request({}, "192.168.0.4"))).toBe(false);
    expect(isLoopbackPeer(request({ "x-forwarded-for": "203.0.113.1" }, "127.0.0.1"))).toBe(false);
  });
});
