import { PickyAgentSessionSchema, type PickyAgentSession, type PickyAgentSessionParsed } from "../protocol.js";
import { boundedSessionForProjectionSnapshot } from "./app-session-snapshot-policy.js";

export type ProjectionRecoveryCommand = { requestId: string; sessionId: string };

type ProjectionSnapshotEvent = {
  type: "sessionProjectionSnapshot";
  requestId: string;
  sessionId: string;
  epoch: string;
  revision: number;
  complete: boolean;
  omittedFields: string[];
  projection: PickyAgentSessionParsed;
};

export interface SessionProjectionRecoveryDependencies {
  withSessionProjectionBarrier(
    sessionId: string,
    work: (snapshot: { session: PickyAgentSession; epoch: string }) => Promise<void>,
  ): Promise<void>;
  send(payload: ProjectionSnapshotEvent): void;
}

/** Builds and unicasts the dormant W6 recovery frame inside the session barrier. */
export async function sendSessionProjectionRecoverySnapshot(
  dependencies: SessionProjectionRecoveryDependencies,
  command: ProjectionRecoveryCommand,
): Promise<void> {
  await dependencies.withSessionProjectionBarrier(command.sessionId, async ({ session, epoch }) => {
    const bounded = boundedSessionForProjectionSnapshot(PickyAgentSessionSchema.parse(session), {
      requestId: command.requestId,
      epoch,
    });
    if (!bounded.session) {
      throw new Error(`Projection recovery snapshot exceeds the app frame budget: ${command.sessionId}`);
    }
    dependencies.send({
      type: "sessionProjectionSnapshot",
      requestId: command.requestId,
      sessionId: bounded.session.id,
      epoch,
      revision: bounded.session.revision,
      complete: bounded.omittedFields.length === 0,
      omittedFields: bounded.omittedFields,
      projection: bounded.session,
    });
  });
}

/** Rejects concurrent recovery commands for the same socket/session pair. */
export class ProjectionRecoveryRequestGate {
  private pendingBySocket = new WeakMap<object, Set<string>>();

  async send(socket: object, dependencies: SessionProjectionRecoveryDependencies, command: ProjectionRecoveryCommand): Promise<void> {
    const pending = this.pendingBySocket.get(socket) ?? new Set<string>();
    if (pending.has(command.sessionId)) throw new Error(`Projection recovery already pending for session: ${command.sessionId}`);
    pending.add(command.sessionId);
    this.pendingBySocket.set(socket, pending);
    try {
      await sendSessionProjectionRecoverySnapshot(dependencies, command);
    } finally {
      pending.delete(command.sessionId);
      if (pending.size === 0) this.pendingBySocket.delete(socket);
    }
  }
}
