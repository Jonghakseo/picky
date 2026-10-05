/**
 * `/api/*` (docs/remote-pwa-implementation.md 2.2).
 *
 * Shape of every handler: authenticate the cookie, check same-origin for
 * anything that changes state, enforce the body limit, then do the work. The
 * gate order matters, which is why it lives in one place instead of per route.
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";
import { rm } from "node:fs/promises";
import { readFile } from "node:fs/promises";
import type { DeviceRecord } from "./device-store.js";
import type { GatewayCore } from "./core.js";
import { REMOTE_LIMITS } from "../remote/constants.js";
import {
  RemotePairRequestSchema,
  RemotePushSubscriptionSchema,
  type RemoteDictationResponse,
  type RemoteMeResponse,
} from "../remote/protocol.js";
import { PREVIEW_DOCUMENT_CSP, remoteError, sendBytes, sendError, sendJson } from "./http/responses.js";
import { checkSameOrigin, deviceCookie, deviceTokenOf, clearedDeviceCookie, type RequestFacts } from "./http/request-context.js";
import { describeFile, PREVIEW_CONTENT_TYPES, resolveReferencedFile, sniffImageMime, MAX_PREVIEW_IMAGE_BYTES } from "./file-service.js";
import { isAllowedPushEndpoint } from "./push/sender.js";
import { UploadRejected } from "./uploads.js";
import { dataPath, ensureDirectory, randomId, writeFileAtomic } from "./storage.js";
import { errorMessage, logGateway } from "./log.js";
import { z } from "zod";

/** Body of DELETE /api/push/subscription; optional because the browser may have dropped the subscription already. */
const PushEndpointBodySchema = z.object({ endpoint: z.string().url().max(2048) });

function hostOf(endpoint: string): string {
  try {
    return new URL(endpoint).hostname;
  } catch {
    return "invalid";
  }
}

type ApiHandler = (request: IncomingMessage, response: ServerResponse, facts: RequestFacts) => void | Promise<void>;

export class ApiRouter {
  constructor(private readonly core: GatewayCore) {}

  async handle(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    if (this.core.lockout.isBlocked(facts.clientIp)) {
      sendError(response, remoteError("rateLimited", "Too many failed attempts. Try again later."));
      return;
    }
    if (facts.method !== "GET" && facts.method !== "HEAD") {
      const origin = checkSameOrigin(request);
      if (!origin.ok) {
        // 403 like the WebSocket upgrade: the caller may well be authenticated,
        // the request just did not come from this app's own pages.
        sendJson(response, 403, { error: remoteError("unauthorized", "Cross-origin requests are not allowed.") });
        return;
      }
    }

    try {
      await this.route(request, response, facts);
    } catch (error) {
      logGateway("api route failed", { path: facts.path, error: errorMessage(error) });
      if (!response.writableEnded) sendError(response, remoteError("internal", "The gateway could not handle this request."));
    }
  }

  private async route(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const handler = this.handlerFor(facts);
    if (!handler) {
      sendError(response, remoteError("notFound", "Unknown endpoint."));
      return;
    }
    await handler(request, response, facts);
  }

  /** `${METHOD} ${path}` table; the uploads read is the one prefix route. */
  private handlerFor(facts: RequestFacts): ApiHandler | undefined {
    const routes: Record<string, ApiHandler> = {
      "GET /api/me": (request, response, context) => this.me(request, response, context),
      "POST /api/pair": (request, response, context) => this.pair(request, response, context),
      "POST /api/unpair": (request, response, context) => this.unpair(request, response, context),
      "POST /api/uploads": (request, response, context) => this.upload(request, response, context),
      "GET /api/files/meta": (request, response, context) => this.fileMeta(request, response, context),
      "GET /api/files/raw": (request, response, context) => this.fileRaw(request, response, context),
      "POST /api/dictation": (request, response, context) => this.dictation(request, response, context),
      "GET /api/push/key": (request, response, context) => this.pushKey(request, response, context),
      "POST /api/push/subscription": (request, response, context) => this.pushSubscription(request, response, context),
      "DELETE /api/push/subscription": (request, response, context) => this.pushSubscription(request, response, context),
      "POST /api/push/test": (request, response, context) => this.pushTest(request, response, context),
    };
    const exact = routes[`${facts.method} ${facts.path}`];
    if (exact) return exact;
    if (facts.method === "GET" && facts.path.startsWith("/api/uploads/")) {
      return (request, response, context) => this.readUpload(request, response, context);
    }
    return undefined;
  }

  /* --------------------------------------------------------------- */
  /* Auth                                                             */
  /* --------------------------------------------------------------- */

  /** A cookie that matches no device counts as a guess, like a wrong code. */
  private authenticate(request: IncomingMessage, facts: RequestFacts): DeviceRecord | undefined {
    const token = deviceTokenOf(request);
    if (!token) return undefined;
    const device = this.core.devices.findByToken(token);
    if (!device) {
      this.recordFailure(facts.clientIp);
      return undefined;
    }
    return device;
  }

  private requireDevice(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): DeviceRecord | undefined {
    const device = this.authenticate(request, facts);
    if (!device) sendError(response, remoteError("unauthorized", "This phone is not paired with Picky."));
    return device;
  }

  private recordFailure(ip: string): void {
    const blockedUntil = this.core.lockout.recordFailure(ip);
    if (blockedUntil) this.core.audit.record({ action: "lockout", ip, untilMs: blockedUntil });
  }

  /* --------------------------------------------------------------- */
  /* Routes                                                           */
  /* --------------------------------------------------------------- */

  private me(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): void {
    const device = this.authenticate(request, facts);
    // The Mac name often contains the owner's name; only paired devices see it.
    const macName = device ? this.core.hub.hello?.macName : undefined;
    const body: RemoteMeResponse = {
      paired: device !== undefined,
      ...(device ? { device: { id: device.id, name: device.name } } : {}),
      ...(macName ? { macName } : {}),
      insecure: !facts.secure,
    };
    sendJson(response, 200, body);
  }

  private async pair(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const body = await readJsonBody(request);
    const parsed = RemotePairRequestSchema.safeParse(body);
    if (!parsed.success) {
      sendError(response, remoteError("invalid", "Enter the code shown on the Mac."));
      return;
    }
    const check = this.core.pairing.check(parsed.data.code);
    if (!check.ok) {
      this.recordFailure(facts.clientIp);
      this.core.audit.record({ action: "pair.attempt", ip: facts.clientIp, ok: false, reason: check.reason, deviceName: parsed.data.deviceName });
      if (check.reason === "exhausted") this.core.hub.send({ type: "gateway.pairing.ended", reason: "exhausted" });
      sendError(response, remoteError(check.reason === "wrong" ? "invalid" : "rejected", pairingFailureMessage(check.reason)));
      return;
    }

    const { device, token } = await this.core.devices.add(parsed.data.deviceName);
    this.core.lockout.recordSuccess(facts.clientIp);
    this.core.audit.record({ action: "pair.attempt", ip: facts.clientIp, ok: true, deviceName: device.name });
    this.core.audit.record({ action: "pair.success", ip: facts.clientIp, deviceId: device.id, deviceName: device.name });
    this.core.hub.send({ type: "gateway.pairing.ended", reason: "paired", deviceName: device.name });
    this.core.publishDevices();
    sendJson(response, 200, { paired: true, device: { id: device.id, name: device.name } }, {
      "Set-Cookie": deviceCookie(token, facts.secure),
    });
  }

  private async unpair(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    await this.core.revokeDevice(device.id, "device");
    sendJson(response, 200, { paired: false }, { "Set-Cookie": clearedDeviceCookie(facts.secure) });
  }

  private async upload(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    const body = await readRawBody(request, REMOTE_LIMITS.uploadBytes);
    if (!body) {
      sendError(response, remoteError("tooLarge", "That image is too large to send."));
      return;
    }
    try {
      const upload = await this.core.uploads.save(body, headerOf(request, "x-file-name"), headerOf(request, "content-type") ?? "");
      this.core.audit.record({ action: "upload", deviceId: device.id, uploadId: upload.uploadId, bytes: upload.size, mime: upload.mime });
      sendJson(response, 200, upload);
    } catch (error) {
      if (error instanceof UploadRejected) sendError(response, remoteError("unsupported", error.message));
      else throw error;
    }
  }

  private async readUpload(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    const uploadId = facts.path.slice("/api/uploads/".length);
    const stored = await this.core.uploads.read(uploadId);
    if (!stored) {
      sendError(response, remoteError("notFound", "That attachment is no longer available."));
      return;
    }
    sendBytes(response, 200, stored.bytes, sniffImageMime(stored.bytes) ?? "application/octet-stream");
  }

  private async fileMeta(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const resolved = await this.resolveFileRequest(request, response, facts);
    if (!resolved) return;
    sendJson(response, 200, await describeFile(resolved.path));
  }

  private async fileRaw(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const resolved = await this.resolveFileRequest(request, response, facts);
    if (!resolved) return;
    const description = await describeFile(resolved.path);
    if (description.kind === "directory" || description.kind === "binary") {
      sendError(response, remoteError("unsupported", "This file cannot be previewed on the phone."));
      return;
    }
    if (description.size > MAX_PREVIEW_IMAGE_BYTES) {
      sendError(response, remoteError("tooLarge", "This file is too large to preview."));
      return;
    }
    const bytes = await readFile(resolved.path);
    const contentType = description.kind === "image"
      ? sniffImageMime(bytes) ?? "application/octet-stream"
      : PREVIEW_CONTENT_TYPES[description.kind];
    // HTML and SVG render inside a sandboxed iframe; the policy here is what
    // stops a report the agent wrote from calling back into the gateway.
    const headers = description.kind === "html" || description.kind === "svg"
      ? { "Content-Security-Policy": PREVIEW_DOCUMENT_CSP }
      : {};
    sendBytes(response, 200, bytes, contentType, headers);
  }

  private async resolveFileRequest(
    request: IncomingMessage,
    response: ServerResponse,
    facts: RequestFacts,
  ): Promise<{ path: string } | undefined> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return undefined;
    const sessionId = facts.url.searchParams.get("sessionId") ?? "";
    const requestedPath = facts.url.searchParams.get("path") ?? "";
    const session = this.core.fileReferenceSource(sessionId);
    if (!session || !requestedPath) {
      sendError(response, remoteError("notFound", "That file is not part of this conversation."));
      return undefined;
    }
    const result = await resolveReferencedFile(requestedPath, { session });
    this.core.audit.record({
      action: "file.read",
      deviceId: device.id,
      sessionId,
      path: requestedPath,
      ok: result.ok,
      ...(result.ok ? {} : { reason: result.reason }),
    });
    if (!result.ok) {
      sendError(response, remoteError("notFound", "That file is not part of this conversation."));
      return undefined;
    }
    return { path: result.path };
  }

  private async dictation(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    const body = await readRawBody(request, REMOTE_LIMITS.dictationBytes);
    if (!body) {
      sendJson(response, 200, { ok: false, reason: "tooLarge" } satisfies RemoteDictationResponse);
      return;
    }
    const mime = headerOf(request, "content-type") ?? "audio/mp4";
    const temporaryDirectory = dataPath(this.core.config.dataDir, "tmp");
    await ensureDirectory(temporaryDirectory);
    const filePath = join(temporaryDirectory, `${randomId(9)}.${extensionForAudio(mime)}`);
    await writeFileAtomic(filePath, body);

    try {
      // The timeout comes from hubRequestTimeoutMs: dictation gets more room
      // than the Mac's own budget so the phone sees its answer, not `timeout`.
      const data = await this.core.hub.request(device.id, { type: "dictation.transcribe", filePath, mime });
      const text = (data as { text?: unknown } | undefined)?.text;
      this.core.audit.record({ action: "dictation", deviceId: device.id, bytes: body.byteLength, ok: typeof text === "string" });
      sendJson(response, 200, typeof text === "string" && text.trim()
        ? { ok: true, text }
        : { ok: false, reason: "noSpeech" } satisfies RemoteDictationResponse);
    } catch (error) {
      const reason = dictationFailureReason(error);
      this.core.audit.record({ action: "dictation", deviceId: device.id, bytes: body.byteLength, ok: false, reason });
      sendJson(response, 200, { ok: false, reason } satisfies RemoteDictationResponse);
    } finally {
      // The hub deletes the file when it succeeds; this covers every other path.
      await rm(filePath, { force: true }).catch(() => {});
    }
  }

  private pushKey(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): void {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    sendJson(response, 200, { publicKey: this.core.push.publicKey ?? null });
  }

  private async pushSubscription(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    const body = await readJsonBody(request);
    if (facts.method === "DELETE") {
      await this.removePushSubscriptions(device.id, body);
      sendJson(response, 200, { subscribed: false });
      return;
    }
    const parsed = RemotePushSubscriptionSchema.safeParse(body);
    if (!parsed.success) {
      sendError(response, remoteError("invalid", "That push subscription is not valid."));
      return;
    }
    const endpointHost = new URL(parsed.data.endpoint).hostname;
    if (!isAllowedPushEndpoint(parsed.data.endpoint)) {
      sendError(response, remoteError("rejected", "That push service is not supported."));
      return;
    }
    await this.core.devices.addSubscription(device.id, parsed.data);
    this.core.audit.record({ action: "push.subscribe", deviceId: device.id, endpointHost });
    this.core.publishDevices();
    sendJson(response, 200, { subscribed: true });
  }

  /**
   * DELETE takes `{ endpoint }` when the phone still knows its subscription and
   * nothing when it does not (the browser already dropped it); without an
   * endpoint every subscription of this device goes.
   */
  private async removePushSubscriptions(deviceId: string, body: unknown): Promise<void> {
    const endpoint = PushEndpointBodySchema.safeParse(body).data?.endpoint;
    const device = this.core.devices.get(deviceId);
    const endpoints = endpoint ? [endpoint] : (device?.pushSubscriptions.map((subscription) => subscription.endpoint) ?? []);
    for (const target of endpoints) {
      await this.core.devices.removeSubscription(deviceId, target);
      this.core.audit.record({ action: "push.unsubscribe", deviceId, endpointHost: hostOf(target) });
    }
    this.core.publishDevices();
  }

  private async pushTest(request: IncomingMessage, response: ServerResponse, facts: RequestFacts): Promise<void> {
    const device = this.requireDevice(request, response, facts);
    if (!device) return;
    if (!this.core.push.enabled) {
      sendError(response, remoteError("unsupported", "Turn on remote access with a public address first."));
      return;
    }
    const delivered = await this.core.push.notify([device.id], {
      roomId: "main",
      roomTitle: this.core.roomTitle("main"),
      kind: "reply",
      badge: 0,
    });
    sendJson(response, 200, { delivered });
  }
}

function pairingFailureMessage(reason: "noCode" | "expired" | "wrong" | "exhausted"): string {
  switch (reason) {
    case "noCode":
      return "Open \"connect a phone\" on the Mac first.";
    case "expired":
      return "That code expired. Get a new one on the Mac.";
    case "exhausted":
      return "Too many wrong codes. Get a new one on the Mac.";
    case "wrong":
      return "That code does not match.";
  }
}

function dictationFailureReason(error: unknown): "macPermission" | "macService" | "macUnavailable" | "noSpeech" | "failed" {
  const code = (error as { code?: unknown } | undefined)?.code;
  if (code === "macPermission" || code === "macService" || code === "macUnavailable" || code === "noSpeech") return code;
  return "failed";
}

function extensionForAudio(mime: string): string {
  if (mime.includes("mp4") || mime.includes("m4a") || mime.includes("aac")) return "m4a";
  if (mime.includes("webm")) return "webm";
  if (mime.includes("wav")) return "wav";
  if (mime.includes("mpeg") || mime.includes("mp3")) return "mp3";
  if (mime.includes("ogg") || mime.includes("opus")) return "ogg";
  return "bin";
}

function headerOf(request: IncomingMessage, name: string): string | undefined {
  const value = request.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

/** Returns undefined when the body exceeds the limit, so callers answer 413. */
export async function readRawBody(request: IncomingMessage, limitBytes: number): Promise<Buffer | undefined> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = chunk as Buffer;
    total += buffer.byteLength;
    if (total > limitBytes) {
      request.destroy();
      return undefined;
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

export async function readJsonBody(request: IncomingMessage): Promise<unknown> {
  const body = await readRawBody(request, REMOTE_LIMITS.clientMessageBytes);
  if (!body || body.byteLength === 0) return undefined;
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    return undefined;
  }
}
