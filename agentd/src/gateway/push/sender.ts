/**
 * Delivering one encrypted push to one subscription.
 *
 * The endpoint allowlist is the point of this module: a subscription object
 * comes from the phone, and without the check a paired device could aim the
 * Mac's outbound requests at any host it likes.
 */
import type { RemotePushPayload, RemotePushSubscription } from "../../remote/protocol.js";
import { encryptPushPayload } from "./encryption.js";
import { signVapidToken, vapidAuthorizationHeader, vapidClaims, type VapidKeyPair } from "./vapid.js";

export const ALLOWED_PUSH_HOSTS: readonly string[] = [
  "fcm.googleapis.com",
  "updates.push.services.mozilla.com",
];
export const ALLOWED_PUSH_HOST_SUFFIXES: readonly string[] = [".push.apple.com", ".notify.windows.com"];

export function isAllowedPushEndpoint(endpoint: string): boolean {
  let host: string;
  let protocol: string;
  try {
    const url = new URL(endpoint);
    host = url.hostname.toLowerCase();
    protocol = url.protocol;
  } catch {
    return false;
  }
  if (protocol !== "https:") return false;
  if (ALLOWED_PUSH_HOSTS.includes(host)) return true;
  return ALLOWED_PUSH_HOST_SUFFIXES.some((suffix) => host.endsWith(suffix));
}

export type PushDelivery =
  | { ok: true; status: number }
  | { ok: false; status: number; gone: boolean; reason: string };

export type PushFetch = (url: string, init: { method: string; headers: Record<string, string>; body: Buffer }) => Promise<{ status: number }>;

export interface PushSenderOptions {
  keys: VapidKeyPair;
  /** `hub.config.publicUrl`; without it the gateway does not push at all. */
  subject: string;
  fetchImpl?: PushFetch;
  ttlSeconds?: number;
}

export class PushSender {
  private readonly fetchImpl: PushFetch;

  constructor(private readonly options: PushSenderOptions) {
    this.fetchImpl = options.fetchImpl ?? defaultPushFetch;
  }

  async send(subscription: RemotePushSubscription, payload: RemotePushPayload): Promise<PushDelivery> {
    if (!isAllowedPushEndpoint(subscription.endpoint)) {
      return { ok: false, status: 0, gone: true, reason: "endpointNotAllowed" };
    }

    const encrypted = encryptPushPayload({
      payload: JSON.stringify(payload),
      userAgentPublicKey: Buffer.from(subscription.keys.p256dh, "base64url"),
      authSecret: Buffer.from(subscription.keys.auth, "base64url"),
    });
    const token = signVapidToken(vapidClaims(subscription.endpoint, this.options.subject), this.options.keys.privateJwk);

    const response = await this.fetchImpl(subscription.endpoint, {
      method: "POST",
      headers: {
        Authorization: vapidAuthorizationHeader(token, this.options.keys.publicKey),
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        "Content-Length": String(encrypted.body.byteLength),
        TTL: String(this.options.ttlSeconds ?? 3600),
        Urgency: "high",
      },
      body: encrypted.body,
    });

    if (response.status >= 200 && response.status < 300) return { ok: true, status: response.status };
    // 404/410 mean the browser dropped the subscription; keeping it would retry forever.
    const gone = response.status === 404 || response.status === 410;
    return { ok: false, status: response.status, gone, reason: gone ? "subscriptionGone" : "pushServiceError" };
  }
}

const defaultPushFetch: PushFetch = async (url, init) => {
  const response = await fetch(url, { method: init.method, headers: init.headers, body: new Uint8Array(init.body) });
  return { status: response.status };
};
