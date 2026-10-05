/**
 * The endpoint allowlist and the dead-subscription rule.
 *
 * The subscription object arrives from the phone, so without the allowlist a
 * paired device could aim the Mac's outbound requests at any host; and without
 * the 404/410 rule the gateway would retry a dropped subscription forever.
 */
import { describe, expect, it } from "vitest";
import type { RemotePushSubscription } from "../../remote/protocol.js";
import { generateVapidKeys } from "./vapid.js";
import { isAllowedPushEndpoint, PushSender, type PushFetch } from "./sender.js";

const keys = generateVapidKeys();

function subscription(endpoint = "https://web.push.apple.com/abc"): RemotePushSubscription {
  return {
    endpoint,
    keys: {
      p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
      auth: "BTBZMqHH6r4Tts7J_aSIgg",
    },
  };
}

interface Call {
  url: string;
  headers: Record<string, string>;
  body: Buffer;
}

function recordingFetch(status: number): { fetchImpl: PushFetch; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    fetchImpl: async (url, init) => {
      calls.push({ url, headers: init.headers, body: init.body });
      return { status };
    },
  };
}

function sender(fetchImpl: PushFetch): PushSender {
  return new PushSender({ keys, subject: "https://mac.tail1234.ts.net", fetchImpl });
}

describe("push endpoint allowlist", () => {
  it("accepts the four push services Picky supports", () => {
    expect(isAllowedPushEndpoint("https://fcm.googleapis.com/fcm/send/abc")).toBe(true);
    expect(isAllowedPushEndpoint("https://updates.push.services.mozilla.com/wpush/v2/abc")).toBe(true);
    expect(isAllowedPushEndpoint("https://web.push.apple.com/abc")).toBe(true);
    expect(isAllowedPushEndpoint("https://wns2-par02p.notify.windows.com/w/?token=abc")).toBe(true);
  });

  it("refuses anything else the phone might send", () => {
    expect(isAllowedPushEndpoint("http://web.push.apple.com/abc")).toBe(false);
    expect(isAllowedPushEndpoint("https://evil.example/relay")).toBe(false);
    // The suffix rule must not let a lookalike host through.
    expect(isAllowedPushEndpoint("https://web.push.apple.com.evil.example/abc")).toBe(false);
    expect(isAllowedPushEndpoint("https://fcm.googleapis.com.evil.example/abc")).toBe(false);
    expect(isAllowedPushEndpoint("ws://web.push.apple.com/abc")).toBe(false);
    expect(isAllowedPushEndpoint("not a url")).toBe(false);
  });

  it("is case insensitive about the host, like DNS", () => {
    expect(isAllowedPushEndpoint("https://WEB.PUSH.APPLE.COM/abc")).toBe(true);
  });
});

describe("delivering one push", () => {
  it("never contacts a host outside the allowlist", async () => {
    const { fetchImpl, calls } = recordingFetch(201);
    const result = await sender(fetchImpl).send(subscription("https://evil.example/relay"), payload());
    expect(calls).toHaveLength(0);
    expect(result).toEqual({ ok: false, status: 0, gone: true, reason: "endpointNotAllowed" });
  });

  it("posts an encrypted aes128gcm body with a VAPID authorization", async () => {
    const { fetchImpl, calls } = recordingFetch(201);
    const result = await sender(fetchImpl).send(subscription(), payload());
    expect(result).toEqual({ ok: true, status: 201 });
    expect(calls).toHaveLength(1);
    const [call] = calls;
    expect(call.url).toBe("https://web.push.apple.com/abc");
    expect(call.headers["Content-Encoding"]).toBe("aes128gcm");
    expect(call.headers.Authorization).toMatch(/^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=/);
    expect(call.headers["Content-Length"]).toBe(String(call.body.byteLength));
    expect(call.headers.TTL).toBe("3600");
    // Header is salt(16) + record size(4) + key length(1) + public key(65).
    expect(call.body.byteLength).toBeGreaterThan(86);
    expect(call.body.readUInt32BE(16)).toBe(4096);
    expect(call.body.toString("utf8")).not.toContain("Pickle");
  });

  it("marks a 404 or 410 subscription gone so the caller can drop it", async () => {
    for (const status of [404, 410]) {
      const { fetchImpl } = recordingFetch(status);
      expect(await sender(fetchImpl).send(subscription(), payload())).toEqual({
        ok: false,
        status,
        gone: true,
        reason: "subscriptionGone",
      });
    }
  });

  it("keeps a subscription that failed for another reason", async () => {
    const { fetchImpl } = recordingFetch(500);
    expect(await sender(fetchImpl).send(subscription(), payload())).toEqual({
      ok: false,
      status: 500,
      gone: false,
      reason: "pushServiceError",
    });
  });
});

function payload() {
  return { title: "Pickle", body: "작업을 마쳤어요", roomId: "s1", kind: "completed" as const, badge: 1 };
}
