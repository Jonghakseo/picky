import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import { logAgentd } from "../local-log.js";
import type { parseCommand } from "../protocol.js";

export const APP_SETTINGS_CONTROL_UNAVAILABLE = "Picky app settings control unavailable";
const APP_SETTINGS_CONTROL_TIMEOUT = "Picky app settings control timed out";
// The app waits up to 5s for main-agent setting acknowledgement; leave room
// for that result to return rather than masking a persisted-but-unapplied state.
const SETTINGS_CONTROL_TIMEOUT_MS = 15_000;

/** Carries an app-provided settings error code to the external CLI unchanged. */
export class SettingsControlError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "SettingsControlError";
  }
}

export interface AppPickySettingsRequest {
  action: "list" | "get" | "set";
  key?: string;
  value?: unknown;
  toggle?: boolean;
  displayId?: string;
  caller?: "mainAgent";
}

type CompletePickySettingsRequest = Extract<ReturnType<typeof parseCommand>, { type: "completePickySettingsRequest" }>;
type PickySettingsRequestedEvent = { type: "pickySettingsRequested"; requestId: string } & AppPickySettingsRequest;

interface PickySettingsPending {
  resolve: (result: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  /** Only this recipient app socket may complete the request. */
  app: WebSocket;
}

interface SettingsControlBrokerDependencies {
  firstSettingsControlApp: () => WebSocket | undefined;
  send: (ws: WebSocket, event: PickySettingsRequestedEvent) => void;
}

/** Owns the pending app settings-control round trips and their recipient provenance. */
export class SettingsControlBroker {
  private pendingRequests = new Map<string, PickySettingsPending>();

  constructor(private readonly dependencies: SettingsControlBrokerDependencies) {}

  request(request: AppPickySettingsRequest, timeoutMs = SETTINGS_CONTROL_TIMEOUT_MS): Promise<Record<string, unknown>> {
    const app = this.dependencies.firstSettingsControlApp();
    if (!app) return Promise.reject(this.unavailableError());

    const requestId = `picky-settings-${randomUUID()}`;
    return new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pendingRequests.get(requestId);
        if (!pending) return;
        this.pendingRequests.delete(requestId);
        pending.reject(new SettingsControlError("APP_SETTINGS_CONTROL_TIMEOUT", APP_SETTINGS_CONTROL_TIMEOUT));
      }, timeoutMs);
      this.pendingRequests.set(requestId, { resolve, reject, timer, app });
      this.dependencies.send(app, { type: "pickySettingsRequested", requestId, ...request });
    });
  }

  complete(ws: WebSocket, command: CompletePickySettingsRequest): void {
    const pending = this.pendingRequests.get(command.requestId);
    if (!pending) throw new Error(`Unknown Picky settings request: ${command.requestId}`);
    if (pending.app !== ws) {
      logAgentd("ignored settings completion from non-recipient app socket", { requestId: command.requestId });
      return;
    }
    this.pendingRequests.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorCode || command.errorMessage) {
      pending.reject(new SettingsControlError(command.errorCode ?? "SETTINGS_CONTROL_FAILED", command.errorMessage ?? "Picky settings request failed"));
      return;
    }
    if (command.result === undefined) {
      pending.reject(new SettingsControlError("SETTINGS_CONTROL_INVALID_RESULT", `Missing result for Picky settings request: ${command.requestId}`));
      return;
    }
    // The wire protocol permits any JSON result, while this v1 catalog always returns an object.
    pending.resolve(command.result as Record<string, unknown>);
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

  private unavailableError(): SettingsControlError {
    return new SettingsControlError("APP_SETTINGS_CONTROL_UNAVAILABLE", APP_SETTINGS_CONTROL_UNAVAILABLE);
  }
}
