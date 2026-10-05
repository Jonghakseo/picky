/**
 * Wire contract between the remote hub inside Picky.app (Swift) and the
 * gateway (Node). Transport: WebSocket `ws://127.0.0.1:<port>/hub` with
 * `Authorization: Bearer <PICKY_GATEWAY_HUB_TOKEN>`.
 *
 * Every message is one JSON object with a `type`. The gateway validates hub
 * messages with these schemas; the Swift side mirrors them as Codable types.
 * Example messages for both directions live in `contracts/remote/hub/` and are
 * checked by tests on both sides.
 *
 * Architecture and rules: docs/remote-pwa-implementation.md.
 */
import { z } from "zod";

export const HUB_PROTOCOL_VERSION = 1;

const IdSchema = z.string().min(1).max(200);
const PathSchema = z.string().min(1).max(4096);
const LoopbackWsUrlSchema = z.string().regex(/^ws:\/\/127\.0\.0\.1:\d{2,5}\/?$/, "daemon url must be ws://127.0.0.1:<port>");

export const HubDictationAvailabilitySchema = z.discriminatedUnion("available", [
  z.object({ available: z.literal(true) }),
  z.object({ available: z.literal(false), reason: z.enum(["macPermission", "macService", "macUnavailable"]) }),
]);

/* ------------------------------------------------------------------ */
/* Hub -> gateway                                                      */
/* ------------------------------------------------------------------ */

/** Reply to `gateway.request`. Two shapes share one `type`, so it sits outside the discriminated union. */
export const HubResponseSchema = z.union([
  z.object({ type: z.literal("hub.response"), requestId: IdSchema, ok: z.literal(true), data: z.unknown().optional() }),
  z.object({
    type: z.literal("hub.response"),
    requestId: IdSchema,
    ok: z.literal(false),
    error: z.object({ code: z.string().min(1).max(60), message: z.string().max(2000) }),
  }),
]);

const HubEventSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("hub.hello"),
    protocolVersion: z.number().int(),
    appVersion: z.string().max(100),
    macName: z.string().max(200),
  }),
  /**
   * Every daemon the app currently runs. All daemons share one bearer token.
   * A child daemon hosts exactly one Pickle session (`sessionId`); frames for
   * that session are taken from the child, everything else from the primary.
   */
  z.object({
    type: z.literal("hub.daemons"),
    token: z.string().min(1).max(512),
    primary: z.object({ url: LoopbackWsUrlSchema }).optional(),
    children: z.array(z.object({ sessionId: IdSchema, url: LoopbackWsUrlSchema })).max(500),
  }),
  /** App-owned room state the projection does not carry. Sent on change, throttled by the hub. */
  z.object({
    type: z.literal("hub.overlay"),
    /** Sessions shown in the HUD dock, in no particular order. */
    activeSessionIds: z.array(IdSchema).max(2000),
    /** Sessions in the HUD archive. */
    archivedSessionIds: z.array(IdSchema).max(5000),
    unreadSessionIds: z.array(IdSchema).max(2000),
    groups: z.array(z.object({ id: IdSchema, name: z.string().max(200), color: z.string().max(40), memberIds: z.array(IdSchema).max(2000) })).max(200),
    folders: z.object({ pinned: z.array(PathSchema).max(100), recent: z.array(PathSchema).max(100) }),
  }),
  z.object({
    type: z.literal("hub.config"),
    /** https origin the phone uses (Tailscale Serve or Cloudflare), without a trailing slash. */
    publicUrl: z.string().url().max(500).optional(),
    dictation: HubDictationAvailabilitySchema,
  }),
  /** The user opened "connect a phone" on the Mac. The gateway answers with `gateway.pairing`. */
  z.object({ type: z.literal("hub.pairing.start") }),
  z.object({ type: z.literal("hub.pairing.cancel") }),
  /**
   * "Open in browser" on the Mac. The gateway answers with `gateway.localOpen`:
   * a one-time loopback URL that signs this Mac's default browser in.
   */
  z.object({ type: z.literal("hub.localOpen.start") }),
  z.object({ type: z.literal("hub.devices.revoke"), deviceId: IdSchema }),
  z.object({ type: z.literal("hub.devices.rename"), deviceId: IdSchema, name: z.string().min(1).max(60) }),
]);

export const HubToGatewayMessageSchema = z.union([HubEventSchema, HubResponseSchema]);
export type HubToGatewayMessage = z.infer<typeof HubToGatewayMessageSchema>;

/* ------------------------------------------------------------------ */
/* Gateway -> hub                                                      */
/* ------------------------------------------------------------------ */

/** App-owned actions the gateway asks the hub to run on behalf of a paired device. */
export const HubRequestSchema = z.discriminatedUnion("type", [
  /** Create an empty Pickle in its own child daemon, like the HUD folder picker. Reply data: `{ sessionId }`. */
  z.object({ type: z.literal("pickle.create"), cwd: PathSchema }),
  /**
   * Send to the main agent without screen capture. The app registers the
   * context as remote-owned first so the Mac shows no cursor bubble and does
   * not speak the reply. `text` already contains attachment paths.
   */
  z.object({ type: z.literal("main.send"), text: z.string().min(1).max(100_000) }),
  z.object({ type: z.literal("main.abort") }),
  z.object({ type: z.literal("main.answer"), requestId: IdSchema, value: z.unknown() }),
  /** Clear unread like opening the conversation card (`markSessionRead`). */
  z.object({ type: z.literal("session.markRead"), sessionId: IdSchema }),
  z.object({ type: z.literal("session.archive"), sessionId: IdSchema, archived: z.boolean() }),
  /**
   * Transcribe a recording with the Mac's current speech recognition service.
   * The hub deletes the file when done. Reply data: `{ text }`; error codes:
   * `macPermission`, `macService`, `macUnavailable`, `noSpeech`, `failed`.
   */
  z.object({ type: z.literal("dictation.transcribe"), filePath: PathSchema, mime: z.string().max(100) }),
]);
export type HubRequest = z.infer<typeof HubRequestSchema>;

export interface HubDevice {
  id: string;
  name: string;
  createdAt: string;
  lastSeenAt?: string;
  online: boolean;
  pushEnabled: boolean;
  /** Paired from a browser on this Mac (loopback, no tunnel in between). */
  local?: boolean;
}

export type GatewayToHubMessage =
  | { type: "gateway.hello"; protocolVersion: number; version: string; port: number }
  | { type: "gateway.pairing"; code: string; expiresAt: string; url?: string }
  | { type: "gateway.pairing.ended"; reason: "paired" | "expired" | "cancelled" | "exhausted"; deviceName?: string }
  | { type: "gateway.devices"; devices: HubDevice[] }
  /** One-time `http://127.0.0.1:<port>/api/local-open?token=...`, valid for a minute. */
  | { type: "gateway.localOpen"; url: string }
  | { type: "gateway.request"; requestId: string; deviceId: string; request: HubRequest };
