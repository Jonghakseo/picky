/**
 * One WebSocket to one agentd (docs/remote-pwa-implementation.md 2.5).
 *
 * The gateway registers as a `core` client with `sessionProjectionV2`, so the
 * daemon bootstraps it with snapshots and then streams transactions, exactly
 * like the Mac app. Frames are not re-validated with the protocol zod schemas:
 * the peer is our own daemon on loopback behind a bearer token, and parsing a
 * full session snapshot twice per frame is the one cost this path cannot pay.
 */
import WebSocket from "ws";
import { PROTOCOL_VERSION } from "../protocol-base.js";
import type { PickyAgentSession, PickySessionProjectionMutation } from "../protocol.js";
import { errorMessage, logGateway } from "./log.js";
import { randomId } from "./storage.js";

export const DAEMON_COMMAND_TIMEOUT_MS = 10_000;
const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 10_000;

export type DaemonSnapshotFrame = {
  type: "sessionProjectionSnapshot";
  requestId?: string;
  sessionId: string;
  epoch: string;
  revision: number;
  complete: boolean;
  omittedFields: string[];
  projection: PickyAgentSession;
};

export type DaemonTransactionFrame = {
  type: "sessionProjectionTransaction";
  sessionId: string;
  epoch: string;
  baseRevision: number;
  revision: number;
  mutations: PickySessionProjectionMutation[];
};

export interface DaemonEvent {
  type: string;
  [key: string]: unknown;
}

export interface DaemonLinkHandlers {
  onSnapshot: (frame: DaemonSnapshotFrame) => void;
  onTransaction: (frame: DaemonTransactionFrame) => void;
  onEvent: (event: DaemonEvent) => void;
  onConnectionChange: (connected: boolean) => void;
}

export interface DaemonCommand {
  type: string;
  [key: string]: unknown;
}

/**
 * Some daemon commands correlate their reply through a `requestId` that must
 * equal the command id (`getSessionProjectionSnapshot`) or is simply a second
 * copy of it (`getSessionDiff`), so a builder gets the generated id.
 */
export type DaemonCommandInput = DaemonCommand | ((commandId: string) => DaemonCommand);

interface PendingCommand {
  resolve: (event: DaemonEvent | undefined) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  /** When set, the command resolves on this event rather than on `ack`. */
  match?: (event: DaemonEvent) => boolean;
  matched?: DaemonEvent;
}

export class DaemonLink {
  private socket?: WebSocket;
  private reconnectTimer?: NodeJS.Timeout;
  private reconnectDelayMs = RECONNECT_MIN_MS;
  private stopped = false;
  private registered = false;
  private readonly pending = new Map<string, PendingCommand>();

  constructor(
    readonly url: string,
    private token: string,
    private readonly handlers: DaemonLinkHandlers,
    private readonly label: string,
  ) {}

  get connected(): boolean {
    return this.registered && this.socket?.readyState === WebSocket.OPEN;
  }

  /**
   * The socket is up and the capability registration is sent or in flight.
   *
   * agentd streams a new subscriber's bootstrap snapshots while it handles
   * `registerAppCapabilities`, so the first frames of a link always arrive
   * before its ack. Ownership decisions must use this, not `connected`, or they
   * credit those frames to the wrong daemon.
   */
  get attached(): boolean {
    return this.socket?.readyState === WebSocket.OPEN;
  }

  start(): void {
    this.stopped = false;
    this.connect();
  }

  /** A new `hub.daemons` can rotate the shared token without changing the url. */
  updateToken(token: string): void {
    if (this.token === token) return;
    this.token = token;
    this.reconnect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.failPending(new Error("daemon link stopped"));
    const socket = this.socket;
    this.socket = undefined;
    this.registered = false;
    socket?.removeAllListeners();
    socket?.close();
  }

  /** Resolves on the daemon's `ack`, rejects on its `error` for this command. */
  async send(command: DaemonCommandInput, timeoutMs = DAEMON_COMMAND_TIMEOUT_MS): Promise<void> {
    await this.dispatch(command, undefined, timeoutMs);
  }

  /** Resolves with the correlated reply event (runtime options, diff, snapshot). */
  async request(
    command: DaemonCommandInput,
    match: (event: DaemonEvent) => boolean,
    timeoutMs = DAEMON_COMMAND_TIMEOUT_MS,
  ): Promise<DaemonEvent> {
    const event = await this.dispatch(command, match, timeoutMs);
    if (!event) throw new Error("daemon returned no reply");
    return event;
  }

  private dispatch(
    input: DaemonCommandInput,
    match: ((event: DaemonEvent) => boolean) | undefined,
    timeoutMs: number,
  ): Promise<DaemonEvent | undefined> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error(`daemon ${this.label} is not connected`));
    }
    const id = randomId(9);
    const command = typeof input === "function" ? input(id) : input;
    return new Promise<DaemonEvent | undefined>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`daemon ${this.label} timed out on ${command.type}`));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer, ...(match ? { match } : {}) });
      socket.send(JSON.stringify({ id, protocolVersion: PROTOCOL_VERSION, ...command }));
    });
  }

  private connect(): void {
    if (this.stopped) return;
    const socket = new WebSocket(this.url, { headers: { Authorization: `Bearer ${this.token}` } });
    this.socket = socket;
    this.registered = false;

    socket.on("open", () => logGateway("daemon socket open", { daemon: this.label }));
    socket.on("message", (data) => this.handleMessage(socket, data.toString()));
    socket.on("error", (error) => logGateway("daemon socket error", { daemon: this.label, error: errorMessage(error) }));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      const wasConnected = this.registered;
      this.registered = false;
      this.socket = undefined;
      this.failPending(new Error(`daemon ${this.label} disconnected`));
      if (wasConnected) this.handlers.onConnectionChange(false);
      this.scheduleReconnect();
    });
  }

  private reconnect(): void {
    this.socket?.removeAllListeners();
    this.socket?.close();
    this.socket = undefined;
    this.registered = false;
    this.failPending(new Error(`daemon ${this.label} reconnecting`));
    this.connect();
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    const delay = this.reconnectDelayMs;
    this.reconnectDelayMs = Math.min(delay * 2, RECONNECT_MAX_MS);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
    this.reconnectTimer.unref?.();
  }

  private handleMessage(socket: WebSocket, raw: string): void {
    let event: DaemonEvent;
    try {
      event = JSON.parse(raw) as DaemonEvent;
    } catch {
      return;
    }
    if (typeof event?.type !== "string") return;

    if (event.type === "hello") {
      void this.register(socket);
      return;
    }
    if (event.type === "ack" || event.type === "error") {
      this.settle(event);
      return;
    }
    this.resolveMatching(event);

    // Frames from our own daemon are trusted without re-validation (see the file header).
    if (event.type === "sessionProjectionSnapshot") {
      this.handlers.onSnapshot(event as DaemonSnapshotFrame);
      return;
    }
    if (event.type === "sessionProjectionTransaction") {
      this.handlers.onTransaction(event as DaemonTransactionFrame);
      return;
    }
    this.handlers.onEvent(event);
  }

  private async register(socket: WebSocket): Promise<void> {
    try {
      await this.send({ type: "registerAppCapabilities", capabilities: ["sessionProjectionV2"], profile: "core" });
      if (this.socket !== socket) return;
      this.registered = true;
      this.reconnectDelayMs = RECONNECT_MIN_MS;
      logGateway("daemon registered", { daemon: this.label });
      this.handlers.onConnectionChange(true);
    } catch (error) {
      logGateway("daemon registration failed", { daemon: this.label, error: errorMessage(error) });
      socket.close();
    }
  }

  private resolveMatching(event: DaemonEvent): void {
    for (const [id, pending] of this.pending) {
      if (!pending.match || pending.matched || !pending.match(event)) continue;
      pending.matched = event;
      // The daemon sends the reply event before the ack; `settle` finishes it so
      // a command that silently produced no reply still fails instead of hanging.
      this.pending.set(id, pending);
      return;
    }
  }

  private settle(event: DaemonEvent): void {
    const commandId = typeof event.commandId === "string" ? event.commandId : undefined;
    if (!commandId) return;
    const pending = this.pending.get(commandId);
    if (!pending) return;
    this.pending.delete(commandId);
    clearTimeout(pending.timer);
    if (event.type === "error") {
      pending.reject(new Error(typeof event.message === "string" ? event.message : "daemon command failed"));
      return;
    }
    pending.resolve(pending.matched);
  }

  private failPending(error: Error): void {
    for (const [id, pending] of this.pending) {
      this.pending.delete(id);
      clearTimeout(pending.timer);
      pending.reject(error);
    }
  }
}
