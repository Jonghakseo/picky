/**
 * The `/hub` socket: one Picky.app at a time (docs/remote-pwa-implementation.md 2).
 *
 * The hub owns the daemon list, the HUD overlay state, pairing, and the actions
 * that only the app can run. Everything a phone asks the Mac to do travels
 * through `gateway.request` and comes back as `hub.response`.
 */
import type { WebSocket } from "ws";
import {
  HubToGatewayMessageSchema,
  type GatewayToHubMessage,
  type HubRequest,
  type HubToGatewayMessage,
} from "../remote/hub-protocol.js";
import { errorMessage, logGateway } from "./log.js";
import { randomId } from "./storage.js";

export const HUB_REQUEST_TIMEOUT_MS = 20_000;

export type HubOverlay = Extract<HubToGatewayMessage, { type: "hub.overlay" }>;
export type HubConfig = Extract<HubToGatewayMessage, { type: "hub.config" }>;
export type HubHello = Extract<HubToGatewayMessage, { type: "hub.hello" }>;
export type HubDaemons = Extract<HubToGatewayMessage, { type: "hub.daemons" }>;

export class HubRequestError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

export interface HubLinkListener {
  onHello: (hello: HubHello) => void;
  onDaemons: (daemons: HubDaemons) => void;
  onOverlay: (overlay: HubOverlay) => void;
  onConfig: (config: HubConfig) => void;
  onPairingStart: () => void;
  onPairingCancel: () => void;
  onRevoke: (deviceId: string) => void;
  onRename: (deviceId: string, name: string) => void;
  onConnectionChange: (connected: boolean) => void;
}

interface PendingHubRequest {
  resolve: (data: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class HubLink {
  private socket?: WebSocket;
  private readonly pending = new Map<string, PendingHubRequest>();
  hello?: HubHello;
  config?: HubConfig;
  overlay?: HubOverlay;

  constructor(private readonly listener: HubLinkListener) {}

  get connected(): boolean {
    return this.socket !== undefined;
  }

  /** One hub at a time: a reconnecting app replaces the previous socket. */
  attach(socket: WebSocket): void {
    this.socket?.close(4409, "replaced by a newer hub connection");
    this.socket = socket;
    socket.on("message", (data) => this.handleMessage(data.toString()));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.hello = undefined;
      this.failPending(new HubRequestError("macOffline", "Picky on the Mac disconnected."));
      logGateway("hub disconnected");
      this.listener.onConnectionChange(false);
    });
    socket.on("error", (error) => logGateway("hub socket error", { error: errorMessage(error) }));
    this.listener.onConnectionChange(true);
  }

  send(message: GatewayToHubMessage): void {
    this.socket?.send(JSON.stringify(message));
  }

  async request(deviceId: string, request: HubRequest, timeoutMs = HUB_REQUEST_TIMEOUT_MS): Promise<unknown> {
    if (!this.socket) throw new HubRequestError("macOffline", "Picky on the Mac is not connected.");
    const requestId = `req_${randomId(8)}`;
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new HubRequestError("timeout", "The Mac did not answer in time."));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(requestId, { resolve, reject, timer });
      this.send({ type: "gateway.request", requestId, deviceId, request });
    });
  }

  private handleMessage(raw: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      logGateway("hub message rejected", { reason: "invalid json" });
      return;
    }
    const result = HubToGatewayMessageSchema.safeParse(parsed);
    if (!result.success) {
      logGateway("hub message rejected", { reason: "schema", type: typeof parsed === "object" && parsed && "type" in parsed ? String((parsed as { type: unknown }).type) : "unknown" });
      return;
    }
    this.dispatch(result.data);
  }

  private dispatch(message: HubToGatewayMessage): void {
    switch (message.type) {
      case "hub.hello":
        this.hello = message;
        this.listener.onHello(message);
        return;
      case "hub.daemons":
        this.listener.onDaemons(message);
        return;
      case "hub.overlay":
        this.overlay = message;
        this.listener.onOverlay(message);
        return;
      case "hub.config":
        this.config = message;
        this.listener.onConfig(message);
        return;
      case "hub.pairing.start":
        this.listener.onPairingStart();
        return;
      case "hub.pairing.cancel":
        this.listener.onPairingCancel();
        return;
      case "hub.devices.revoke":
        this.listener.onRevoke(message.deviceId);
        return;
      case "hub.devices.rename":
        this.listener.onRename(message.deviceId, message.name);
        return;
      case "hub.response":
        this.settle(message);
        return;
    }
  }

  private settle(message: Extract<HubToGatewayMessage, { type: "hub.response" }>): void {
    const pending = this.pending.get(message.requestId);
    if (!pending) return;
    this.pending.delete(message.requestId);
    clearTimeout(pending.timer);
    if (message.ok) pending.resolve(message.data);
    else pending.reject(new HubRequestError(message.error.code, message.error.message));
  }

  private failPending(error: Error): void {
    for (const [requestId, pending] of this.pending) {
      this.pending.delete(requestId);
      clearTimeout(pending.timer);
      pending.reject(error);
    }
  }
}
