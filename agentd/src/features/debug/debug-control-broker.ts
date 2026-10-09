import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { logAgentd } from "../../local-log.js";
import type { parseCommand } from "../../protocol.js";
import type { DebugAppAction } from "./schema.js";

export const DEBUG_APP_CONTROL_UNAVAILABLE = "Picky app debug control unavailable";
const DEBUG_APP_CONTROL_TIMEOUT = "Picky app debug control timed out";
/**
 * The app answers when it has *accepted* the action (text handed to the composer
 * path, push-to-talk key event delivered), not when the resulting turn finishes,
 * so this only has to cover app-side acceptance plus one round trip.
 */
const DEBUG_CONTROL_TIMEOUT_MS = 10_000;

/** Carries an app-provided debug error code to the external CLI unchanged. */
export class DebugControlError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "DebugControlError";
  }
}

export interface AppDebugRequest {
  action: DebugAppAction;
  text?: string;
  /** The `debugApp` command id, carried into the app so its traces share one correlation root. */
  commandId: string;
}

type CompleteDebugApp = Extract<ReturnType<typeof parseCommand>, { type: "completeDebugApp" }>;
type DebugAppRequestedEvent = { type: "debugAppRequested"; requestId: string } & AppDebugRequest;

/** The app's answer plus the request it answered, so the caller can correlate its own traces. */
export interface AppDebugOutcome {
  requestId: string;
  result: Record<string, unknown>;
}

interface DebugControlPending {
  resolve: (outcome: AppDebugOutcome) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  /** Only this recipient app socket may complete the request. */
  app: WebSocket;
}

interface DebugControlBrokerDependencies {
  firstDebugControlApp: () => WebSocket | undefined;
  send: (ws: WebSocket, event: DebugAppRequestedEvent) => void;
}

/**
 * Owns the pending app debug round trips and their recipient provenance.
 *
 * Mirrors `SettingsControlBroker`: the daemon never reaches into the app, it asks
 * the one socket that registered `debugControl` and waits for that same socket to
 * answer. A result from any other socket is ignored rather than trusted.
 */
export class DebugControlBroker {
  private pendingRequests = new Map<string, DebugControlPending>();

  constructor(private readonly dependencies: DebugControlBrokerDependencies) {}

  request(request: AppDebugRequest, timeoutMs = DEBUG_CONTROL_TIMEOUT_MS): Promise<AppDebugOutcome> {
    const app = this.dependencies.firstDebugControlApp();
    if (!app) return Promise.reject(this.unavailableError());

    const requestId = `picky-debug-${randomUUID()}`;
    return new Promise<AppDebugOutcome>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pendingRequests.get(requestId);
        if (!pending) return;
        this.pendingRequests.delete(requestId);
        pending.reject(new DebugControlError("DEBUG_APP_CONTROL_TIMEOUT", DEBUG_APP_CONTROL_TIMEOUT));
      }, timeoutMs);
      this.pendingRequests.set(requestId, { resolve, reject, timer, app });
      this.dependencies.send(app, { type: "debugAppRequested", requestId, ...request });
    });
  }

  complete(ws: WebSocket, command: CompleteDebugApp): void {
    const pending = this.pendingRequests.get(command.requestId);
    if (!pending) throw new DebugControlError("DEBUG_APP_CONTROL_UNKNOWN_REQUEST", `Unknown Picky debug request: ${command.requestId}`);
    if (pending.app !== ws) {
      logAgentd("ignored debug completion from non-recipient app socket", { requestId: command.requestId });
      return;
    }
    this.pendingRequests.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorCode || command.errorMessage) {
      pending.reject(new DebugControlError(command.errorCode ?? "DEBUG_APP_CONTROL_FAILED", command.errorMessage ?? "Picky debug request failed"));
      return;
    }
    if (command.result === undefined) {
      pending.reject(new DebugControlError("DEBUG_APP_CONTROL_INVALID_RESULT", `Missing result for Picky debug request: ${command.requestId}`));
      return;
    }
    pending.resolve({ requestId: command.requestId, result: command.result });
  }

  rejectAll(): void {
    for (const pending of this.pendingRequests.values()) {
      clearTimeout(pending.timer);
      pending.reject(this.unavailableError());
    }
    this.pendingRequests.clear();
  }

  rejectForApp(ws: WebSocket): void {
    for (const [requestId, pending] of this.pendingRequests) {
      if (pending.app !== ws) continue;
      clearTimeout(pending.timer);
      pending.reject(this.unavailableError());
      this.pendingRequests.delete(requestId);
    }
  }

  private unavailableError(): DebugControlError {
    return new DebugControlError("DEBUG_APP_CONTROL_UNAVAILABLE", DEBUG_APP_CONTROL_UNAVAILABLE);
  }
}
