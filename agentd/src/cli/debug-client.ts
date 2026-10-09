import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { PROTOCOL_VERSION, type EventEnvelope } from "../protocol.js";
import type { PickyCliConnection } from "./connection-loader.js";
import { PickyCliConnectionError, PickyCliServerError, PickyCliTimeoutError } from "./ws-client.js";

interface PendingRequest {
  resolve: (event: EventEnvelope) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  responseType: string;
}

/** One core connection for a debugging session, without claiming desktop ownership. */
export class DebugClient {
  private readonly pending = new Map<string, PendingRequest>();
  private closed = false;

  private constructor(private readonly socket: WebSocket) {
    socket.on("message", (data) => {
      let event: EventEnvelope;
      try { event = JSON.parse(data.toString()) as EventEnvelope; } catch { return; }
      if (!event || typeof event !== "object" || !("commandId" in event) || typeof event.commandId !== "string") return;
      const request = this.pending.get(event.commandId);
      if (!request || (event.type !== "error" && event.type !== request.responseType)) return;
      clearTimeout(request.timer);
      this.pending.delete(event.commandId);
      if (event.type === "error") request.reject(new PickyCliServerError(event.code, event.message, event.commandId));
      else request.resolve(event);
    });
    socket.on("close", () => this.failPending(new PickyCliConnectionError("Picky disconnected. A control already sent may have taken effect; do not retry it automatically.")));
    socket.on("error", () => this.failPending(new PickyCliConnectionError("Picky connection failed. Check that the app is running.")));
  }

  static async connect(connection: PickyCliConnection, timeoutMs: number): Promise<DebugClient> {
    const url = new URL(connection.url);
    if (url.protocol !== "ws:" || !["127.0.0.1", "[::1]", "localhost"].includes(url.hostname) || url.username || url.password) {
      throw new PickyCliConnectionError("picky-debug only connects to a local loopback daemon.");
    }
    url.searchParams.set("token", connection.token);
    const socket = new WebSocket(url);
    const client = new DebugClient(socket);
    await new Promise<void>((resolve, reject) => {
      const finish = (error?: Error) => {
        clearTimeout(timer);
        socket.off("open", opened);
        socket.off("error", failed);
        socket.off("close", disconnected);
        if (error) { client.close(); reject(error); } else resolve();
      };
      const opened = () => finish();
      const failed = () => finish(new PickyCliConnectionError("Could not connect to Picky. Check that the app is running."));
      const disconnected = () => failed();
      const timer = setTimeout(() => finish(new PickyCliTimeoutError("connect", timeoutMs)), timeoutMs);
      socket.once("open", opened);
      socket.once("error", failed);
      socket.once("close", disconnected);
    });
    return client;
  }

  request<Type extends EventEnvelope["type"]>(
    command: { type: string; [key: string]: unknown },
    responseType: Type,
    timeoutMs: number,
  ): Promise<Extract<EventEnvelope, { type: Type }>> {
    if (this.closed || this.socket.readyState !== WebSocket.OPEN) return Promise.reject(new PickyCliConnectionError("Picky connection is closed."));
    const id = `debug-${randomUUID()}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new PickyCliTimeoutError(command.type, timeoutMs));
      }, timeoutMs);
      this.pending.set(id, { resolve: (event) => resolve(event as Extract<EventEnvelope, { type: Type }>), reject, timer, responseType });
      this.socket.send(JSON.stringify({ ...command, id, protocolVersion: PROTOCOL_VERSION }), (error) => {
        if (!error || !this.pending.has(id)) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new PickyCliConnectionError("Picky command delivery failed; its result is unconfirmed."));
      });
    });
  }

  close(): void {
    this.failPending(new PickyCliConnectionError("Debug connection closed."));
    // No command is retried on reconnect. In particular, PTT/text are not idempotent.
    this.socket.terminate();
  }

  private failPending(error: Error): void {
    this.closed = true;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
  }
}
