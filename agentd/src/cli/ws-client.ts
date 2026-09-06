import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { PROTOCOL_VERSION, type EventEnvelope } from "../protocol.js";
import type { PickyCliConnection } from "./connection-loader.js";

export class PickyCliTimeoutError extends Error {
  constructor(public readonly commandType: string, public readonly timeoutMs: number) {
    super(`Timed out after ${timeoutMs}ms waiting for daemon response to ${commandType}`);
    this.name = "PickyCliTimeoutError";
  }
}

export class PickyCliServerError extends Error {
  constructor(public readonly code: string, message: string, public readonly commandId?: string) {
    super(message);
    this.name = "PickyCliServerError";
  }
}

export class PickyCliConnectionError extends Error {
  constructor(message: string, cause?: unknown) {
    super(message);
    this.name = "PickyCliConnectionError";
    if (cause instanceof Error) (this as { cause?: unknown }).cause = cause;
  }
}

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_REPLY_TIMEOUT_MS = 120_000;

/**
 * Send a single command to picky-agentd and wait for the matching response event.
 *
 * `matchEvent` returns the event when it is the response we want (and `null` to
 * keep waiting on later events). `errorMessage` lets the caller customise the
 * timeout/error message with command context (e.g. session id).
 */
export async function sendCommand<T extends EventEnvelope>(
  connection: PickyCliConnection,
  command: { type: string; [key: string]: unknown },
  options: {
    matchEvent: (event: EventEnvelope, commandId: string) => T | null;
    timeoutMs?: number;
  },
): Promise<T> {
  const commandId = `cli-${randomUUID()}`;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const url = `${connection.url}?token=${encodeURIComponent(connection.token)}`;
  const ws = new WebSocket(url);

  return await new Promise<T>((resolve, reject) => {
    let settled = false;
    const finish = (action: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws.close(); } catch { /* swallow — already closing */ }
      action();
    };
    const timer = setTimeout(() => {
      finish(() => reject(new PickyCliTimeoutError(command.type, timeoutMs)));
    }, timeoutMs);

    ws.on("error", (error) => {
      finish(() => reject(new PickyCliConnectionError(`Failed to talk to picky-agentd at ${connection.url}: ${(error as Error).message}`, error)));
    });

    ws.on("open", () => {
      try {
        ws.send(JSON.stringify({ id: commandId, protocolVersion: PROTOCOL_VERSION, ...command }));
      } catch (error) {
        finish(() => reject(new PickyCliConnectionError(`Failed to send command: ${(error as Error).message}`, error)));
      }
    });

    ws.on("message", (data) => {
      let event: EventEnvelope;
      try {
        event = JSON.parse(data.toString()) as EventEnvelope;
      } catch {
        return;
      }
      if (event.type === "error" && (event as { commandId?: string }).commandId === commandId) {
        finish(() => reject(new PickyCliServerError(
          (event as { code: string }).code,
          (event as { message: string }).message,
          commandId,
        )));
        return;
      }
      const matched = options.matchEvent(event, commandId);
      if (matched) finish(() => resolve(matched));
    });
  });
}

/**
 * Send a command and stay connected until the daemon's downstream reply lands.
 *
 * Used by `picky submit --wait` and `picky pickle-create --wait` to keep the
 * websocket open past the initial ack so we can capture the assistant turn that
 * arrives as `quickReply` (main agent path) or as a terminal `pickleSessionUpdated`
 * (Pickle path). The ack matcher returns the parsed ack payload; `afterAck` may
 * return a follow-up command (such as `awaitPickleSessionTerminal`) that is sent
 * on the same socket; the reply matcher inspects every later event and returns
 * the assistant text once it recognises the matching context/session id.
 */
export async function sendCommandAndWaitForReply<Ack>(
  connection: PickyCliConnection,
  command: { type: string; [key: string]: unknown },
  options: {
    matchAck: (event: EventEnvelope, commandId: string) => Ack | null;
    afterAck?: (ack: Ack) => { type: string; [key: string]: unknown } | undefined;
    matchReply: (event: EventEnvelope, ack: Ack) => string | null;
    ackTimeoutMs?: number;
    replyTimeoutMs?: number;
  },
): Promise<{ ack: Ack; replyText: string }> {
  const commandId = `cli-${randomUUID()}`;
  const ackTimeoutMs = options.ackTimeoutMs ?? DEFAULT_TIMEOUT_MS;
  const replyTimeoutMs = options.replyTimeoutMs ?? DEFAULT_REPLY_TIMEOUT_MS;
  const url = `${connection.url}?token=${encodeURIComponent(connection.token)}`;
  const ws = new WebSocket(url);

  return await new Promise<{ ack: Ack; replyText: string }>((resolve, reject) => {
    let settled = false;
    let ackPayload: Ack | undefined;
    let followUpCommandId: string | undefined;
    let activeTimer = setTimeout(() => {
      finish(() => reject(new PickyCliTimeoutError(`${command.type} ack`, ackTimeoutMs)));
    }, ackTimeoutMs);

    const finish = (action: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(activeTimer);
      try { ws.close(); } catch { /* swallow */ }
      action();
    };

    ws.on("error", (error) => {
      finish(() => reject(new PickyCliConnectionError(`Failed to talk to picky-agentd at ${connection.url}: ${(error as Error).message}`, error)));
    });

    ws.on("open", () => {
      try {
        ws.send(JSON.stringify({ id: commandId, protocolVersion: PROTOCOL_VERSION, ...command }));
      } catch (error) {
        finish(() => reject(new PickyCliConnectionError(`Failed to send command: ${(error as Error).message}`, error)));
      }
    });

    ws.on("message", (data) => {
      let event: EventEnvelope;
      try { event = JSON.parse(data.toString()) as EventEnvelope; } catch { return; }
      const errorCommandId = event.type === "error" ? (event as { commandId?: string }).commandId : undefined;
      if (errorCommandId !== undefined && (errorCommandId === commandId || errorCommandId === followUpCommandId)) {
        finish(() => reject(new PickyCliServerError(
          (event as { code: string }).code,
          (event as { message: string }).message,
          errorCommandId,
        )));
        return;
      }
      if (ackPayload === undefined) {
        const matched = options.matchAck(event, commandId);
        if (matched !== null) {
          ackPayload = matched;
          clearTimeout(activeTimer);
          activeTimer = setTimeout(() => {
            finish(() => reject(new PickyCliTimeoutError(`${command.type} reply`, replyTimeoutMs)));
          }, replyTimeoutMs);
          const followUp = options.afterAck?.(matched);
          if (followUp) {
            followUpCommandId = `cli-${randomUUID()}`;
            try {
              ws.send(JSON.stringify({ id: followUpCommandId, protocolVersion: PROTOCOL_VERSION, ...followUp }));
            } catch (error) {
              finish(() => reject(new PickyCliConnectionError(`Failed to send ${followUp.type}: ${(error as Error).message}`, error)));
            }
          }
        }
        return;
      }
      const replyText = options.matchReply(event, ackPayload);
      if (replyText !== null) {
        const ack = ackPayload;
        finish(() => resolve({ ack, replyText }));
      }
    });
  });
}
