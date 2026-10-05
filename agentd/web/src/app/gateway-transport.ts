/**
 * The real transport: one WebSocket to `/api/ws` plus the REST routes in
 * docs/remote-pwa-implementation.md 2.2. Everything is same origin, so the
 * device cookie rides along and no token is kept in JavaScript.
 */
import { REMOTE_PROTOCOL_VERSION } from "../../../src/remote/constants";
import type {
  RemoteClientMessage,
  RemoteDictationResponse,
  RemoteFileMetaResponse,
  RemoteMeResponse,
  RemotePushSubscription,
  RemoteServerMessage,
  RemoteUploadResponse,
} from "../../../src/remote/protocol";
import type { PairOutcome, Transport, TransportHandlers } from "./transport";
import { TransportError } from "./transport";

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 15_000;
const PING_INTERVAL_MS = 25_000;

/** Device revoked by the Mac: the gateway closes with this code and the cookie is dead. */
export const CLOSE_REVOKED = 4401;

export interface GatewayTransportOptions {
  locale: string;
  isVisible(): boolean;
  onRevoked(): void;
}

export class GatewayTransport implements Transport {
  private socket?: WebSocket;
  private handlers?: TransportHandlers;
  private reconnectDelay = RECONNECT_MIN_MS;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private pingTimer?: ReturnType<typeof setInterval>;
  private stopped = false;

  constructor(private readonly options: GatewayTransportOptions) {}

  start(handlers: TransportHandlers): void {
    this.handlers = handlers;
    this.stopped = false;
    this.open();
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.reconnectTimer);
    clearInterval(this.pingTimer);
    this.socket?.close();
    this.socket = undefined;
  }

  send(message: RemoteClientMessage): void {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify(message));
  }

  private open(): void {
    if (this.stopped) return;
    this.handlers?.status("connecting");
    const url = new URL("/api/ws", location.href);
    url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(url);
    this.socket = socket;

    socket.addEventListener("open", () => {
      this.reconnectDelay = RECONNECT_MIN_MS;
      this.send({
        type: "hello",
        protocolVersion: REMOTE_PROTOCOL_VERSION,
        locale: this.options.locale,
        visible: this.options.isVisible(),
      });
      this.handlers?.status("open");
      clearInterval(this.pingTimer);
      this.pingTimer = setInterval(() => this.send({ type: "ping", t: Date.now() }), PING_INTERVAL_MS);
    });

    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      let parsed: RemoteServerMessage;
      try {
        parsed = JSON.parse(event.data) as RemoteServerMessage;
      } catch {
        return;
      }
      this.handlers?.message(parsed);
    });

    socket.addEventListener("close", (event) => {
      clearInterval(this.pingTimer);
      if (this.socket === socket) this.socket = undefined;
      if (this.stopped) return;
      this.handlers?.status("offline");
      if (event.code === CLOSE_REVOKED) {
        this.stopped = true;
        this.options.onRevoked();
        return;
      }
      this.scheduleReconnect();
    });
  }

  private scheduleReconnect(): void {
    clearTimeout(this.reconnectTimer);
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(delay * 2, RECONNECT_MAX_MS);
    this.reconnectTimer = setTimeout(() => this.open(), delay);
  }

  /** Called when the app comes back to the foreground: don't make the user wait out the backoff. */
  reconnectNow(): void {
    if (this.stopped || this.socket) return;
    clearTimeout(this.reconnectTimer);
    this.reconnectDelay = RECONNECT_MIN_MS;
    this.open();
  }

  /* ---- REST ---------------------------------------------------------- */

  async me(): Promise<RemoteMeResponse> {
    return await requestJson<RemoteMeResponse>("/api/me", { method: "GET" });
  }

  async pair(code: string, deviceName: string): Promise<PairOutcome> {
    const response = await fetch("/api/pair", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code, deviceName }),
    });
    if (response.ok) return { ok: true };
    if (response.status === 429) return { ok: false, reason: "locked" };
    if (response.status === 503) return { ok: false, reason: "macOffline" };
    if (response.status === 401 || response.status === 403 || response.status === 404 || response.status === 400) {
      const reason = await readPairReason(response);
      return { ok: false, reason };
    }
    return { ok: false, reason: "failed" };
  }

  async unpair(): Promise<void> {
    await requestJson<unknown>("/api/unpair", { method: "POST" });
  }

  async upload(file: Blob, name: string): Promise<RemoteUploadResponse> {
    return await requestJson<RemoteUploadResponse>("/api/uploads", {
      method: "POST",
      headers: { "content-type": file.type || "application/octet-stream", "x-file-name": encodeURIComponent(name) },
      body: file,
    });
  }

  uploadUrl(uploadId: string): string {
    return `/api/uploads/${encodeURIComponent(uploadId)}`;
  }

  async dictate(audio: Blob): Promise<RemoteDictationResponse> {
    const response = await fetch("/api/dictation", {
      method: "POST",
      headers: { "content-type": audio.type || "audio/webm" },
      body: audio,
    });
    if (response.status === 413) return { ok: false, reason: "tooLarge" };
    if (!response.ok) return { ok: false, reason: "failed" };
    return (await response.json()) as RemoteDictationResponse;
  }

  async fileMeta(roomId: string, path: string): Promise<RemoteFileMetaResponse> {
    const query = new URLSearchParams({ sessionId: roomId, path });
    return await requestJson<RemoteFileMetaResponse>(`/api/files/meta?${query.toString()}`, { method: "GET" });
  }

  fileUrl(roomId: string, path: string): string {
    const query = new URLSearchParams({ sessionId: roomId, path });
    return `/api/files/raw?${query.toString()}`;
  }

  async pushSubscribe(subscription: RemotePushSubscription): Promise<void> {
    await requestJson<unknown>("/api/push/subscription", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(subscription),
    });
  }

  async pushUnsubscribe(): Promise<void> {
    await requestJson<unknown>("/api/push/subscription", { method: "DELETE" });
  }

  async pushTest(): Promise<void> {
    await requestJson<unknown>("/api/push/test", { method: "POST" });
  }
}

async function readPairReason(response: Response): Promise<"invalid" | "expired" | "macOffline" | "failed"> {
  try {
    const body = (await response.json()) as { error?: { code?: string; message?: string } };
    const code = body.error?.code ?? "";
    if (code === "macOffline") return "macOffline";
    if (code === "expired" || code === "notFound") return "expired";
    return "invalid";
  } catch {
    return "invalid";
  }
}

async function requestJson<Value>(path: string, init: RequestInit): Promise<Value> {
  const response = await fetch(path, { ...init, credentials: "same-origin" });
  if (!response.ok) throw new TransportError(`${init.method ?? "GET"} ${path} failed`, response.status);
  if (response.status === 204) return undefined as Value;
  return (await response.json()) as Value;
}
