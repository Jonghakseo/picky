import { randomUUID } from "node:crypto";
import type { ExternalPickleCompletionRequest } from "./pickle-completion-coordinator.js";
import type { DockGroup, PickyAgentSession, PickyContextPacket } from "../protocol.js";

export interface AppPickleHandoffRequest {
  context: PickyContextPacket;
  title: string;
  instructions: string;
  cwd: string;
}

export interface AppPickleHandoffResult {
  sessionId: string;
  title: string;
  cwd?: string;
}

export type AppPickleBridgeRequest =
  | { operation: "listSessions" }
  | { operation: "steer" | "followUp"; sessionId: string; text: string }
  | { operation: "abort"; sessionId: string }
  | { operation: "setArchived"; sessionId: string; archived: boolean }
  | { operation: "delete"; sessionId: string }
  | { operation: "manageGroups"; groupAction: "list" | "create" | "addMembers" | "removeMembers" | "removeGroup" | "archiveGroup"; groupId?: string; name?: string; sessionIds?: string[] }
  | ({
    operation: "notifyMainOfPickleCompletion";
    status?: "completed" | "failed" | "cancelled" | "queued" | "running" | "waiting_for_input" | "blocked";
  } & Omit<ExternalPickleCompletionRequest, "status">);

export interface AppPickleBridgeResult {
  sessions?: PickyAgentSession[];
  groups?: DockGroup[];
  session?: PickyAgentSession;
  delivered?: boolean;
}

export interface PickleCompletionDeliveryTarget {
  deliverMainAgentPickleCompletion(request: ExternalPickleCompletionRequest): Promise<void>;
}

type PendingPickleBridgeRequest<App> = {
  resolve: (result: AppPickleBridgeResult) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  app: App;
};

export interface PickleBridgeRequestCoordinatorDeps<App> {
  firstApp(): App | undefined;
  send(app: App, requestId: string, request: AppPickleBridgeRequest): void;
}

/** Owns app-bridge request lifetimes, including completion delivery round trips. */
export class PickleBridgeRequestCoordinator<App> {
  private readonly pending = new Map<string, PendingPickleBridgeRequest<App>>();

  constructor(private readonly deps: PickleBridgeRequestCoordinatorDeps<App>) {}

  async request(request: AppPickleBridgeRequest, unavailableMessage: string, timeoutMessage: string, timeoutMs = 5_000): Promise<AppPickleBridgeResult> {
    const app = this.deps.firstApp();
    if (!app) throw new Error(unavailableMessage);
    const requestId = `pickle-bridge-${randomUUID()}`;
    return await new Promise<AppPickleBridgeResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(timeoutMessage));
      }, timeoutMs);
      this.pending.set(requestId, { resolve, reject, timer, app });
      this.deps.send(app, requestId, request);
    });
  }

  complete(result: { requestId: string; errorMessage?: string; sessions?: PickyAgentSession[]; groups?: DockGroup[]; session?: PickyAgentSession; delivered?: boolean }): void {
    const pending = this.pending.get(result.requestId);
    if (!pending) throw new Error(`Unknown Pickle bridge request: ${result.requestId}`);
    this.pending.delete(result.requestId);
    clearTimeout(pending.timer);
    if (result.errorMessage) {
      pending.reject(new Error(result.errorMessage));
      return;
    }
    pending.resolve({ sessions: result.sessions, groups: result.groups, session: result.session, delivered: result.delivered });
  }

  rejectForApp(app: App, message: string): void {
    for (const [requestId, pending] of this.pending) {
      if (pending.app !== app) continue;
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
      this.pending.delete(requestId);
    }
  }

  rejectAll(message: string): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
    }
    this.pending.clear();
  }
}

/** Adapts the wire command to the completion coordinator without making the server own admission rules. */
export async function deliverPickleCompletion(
  target: PickleCompletionDeliveryTarget,
  command: ExternalPickleCompletionRequest,
): Promise<void> {
  await target.deliverMainAgentPickleCompletion(command);
}
