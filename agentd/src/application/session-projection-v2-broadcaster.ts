import { PickyAgentSessionSchema, type PickyAgentSession, type PickyAgentSessionParsed, type PickySessionProjectionMutation } from "../protocol.js";
import { boundedSessionForProjectionSnapshot } from "./app-session-snapshot-policy.js";
import type { SocketDialect } from "./socket-dialect.js";

export type V2ProjectionTransactionPayload = {
  type: "sessionProjectionTransaction";
  sessionId: string;
  epoch: string;
  baseRevision: number;
  revision: number;
  mutations: PickySessionProjectionMutation[];
};

export type V2ProjectionSnapshotPayload = {
  type: "sessionProjectionSnapshot";
  sessionId: string;
  epoch: string;
  revision: number;
  complete: boolean;
  omittedFields: string[];
  projection: PickyAgentSessionParsed;
};

type V2ProjectionPayload = V2ProjectionTransactionPayload | V2ProjectionSnapshotPayload;
type V2BootstrapState = {
  queued: V2ProjectionPayload[];
  snapshotRevisions: Map<string, number>;
};

export interface SessionProjectionV2Supervisor {
  list(): PickyAgentSession[];
  get(sessionId: string): PickyAgentSession | undefined;
  withSessionProjectionBarrier(
    sessionId: string,
    work: (snapshot: { session: PickyAgentSession; epoch: string }) => Promise<void>,
  ): Promise<void>;
  on(event: "sessionProjectionTransaction", listener: (sessionId: string, before: PickyAgentSession, after: PickyAgentSession, mutations: readonly PickySessionProjectionMutation[], epoch: string) => void): unknown;
  on(event: "sessionProjectionSnapshot", listener: (session: PickyAgentSession, epoch: string) => void): unknown;
}

export interface SessionProjectionV2SocketDependencies<Socket extends object> {
  sockets(): Iterable<Socket>;
  getDialect(socket: Socket): SocketDialect;
  send(socket: Socket, payload: V2ProjectionPayload): void;
  close(socket: Socket): void;
}

/**
 * Buffers live v2 frames while a socket receives its revision-bearing index
 * snapshots. A transaction already represented by a snapshot is discarded,
 * so every socket observes all bootstrap snapshots before its first live
 * transaction without losing a concurrent commit.
 */
export class SessionProjectionV2Broadcaster<Socket extends object> {
  private readonly bootstrapStates = new WeakMap<Socket, V2BootstrapState>();

  constructor(private readonly sockets: SessionProjectionV2SocketDependencies<Socket>) {}

  bind(supervisor: SessionProjectionV2Supervisor): void {
    supervisor.on("sessionProjectionTransaction", (sessionId, before, after, mutations, epoch) => {
      this.broadcastTransaction(this.sockets.sockets(), this.sockets.getDialect, this.sockets.send, sessionId, before, after, mutations, epoch);
    });
    supervisor.on("sessionProjectionSnapshot", (session, epoch) => {
      this.broadcastSnapshot(this.sockets.sockets(), this.sockets.getDialect, this.sockets.send, session, epoch);
    });
  }

  async register(socket: Socket, previousDialect: SocketDialect, dialect: SocketDialect, supervisor: SessionProjectionV2Supervisor): Promise<void> {
    if (previousDialect !== "negotiating" || dialect !== "v2") return;
    const state: V2BootstrapState = { queued: [], snapshotRevisions: new Map() };
    this.bootstrapStates.set(socket, state);

    try {
      for (const listed of supervisor.list()) {
        if (!this.isBootstrapping(socket, state)) return;
        try {
          await supervisor.withSessionProjectionBarrier(listed.id, async ({ session, epoch }) => {
            if (!this.isBootstrapping(socket, state)) return;
            const payload = this.snapshot(session, epoch);
            state.snapshotRevisions.set(session.id, payload.revision);
            this.sockets.send(socket, payload);
          });
        } catch (error) {
          // A listed session may be permanently deleted between `list()` and
          // its per-session barrier. It has no bootstrap projection to send.
          if (supervisor.get(listed.id) === undefined) continue;
          throw error;
        }
      }

      if (!this.isBootstrapping(socket, state)) return;
      for (const payload of state.queued) {
        if (payload.type === "sessionProjectionTransaction") {
          const snapshotRevision = state.snapshotRevisions.get(payload.sessionId);
          if (snapshotRevision !== undefined && payload.revision <= snapshotRevision) continue;
        }
        this.sockets.send(socket, payload);
      }
    } catch (error) {
      // A partial index cannot safely become live: force a clean connection
      // and negotiation rather than flushing an incomplete bootstrap queue.
      if (this.isBootstrapping(socket, state)) this.sockets.close(socket);
      throw error;
    } finally {
      if (this.isBootstrapping(socket, state)) this.bootstrapStates.delete(socket);
    }
  }

  /// Called by the transport close path so a stalled registration cannot keep
  /// queueing projections for a disconnected socket.
  unregister(socket: Socket): void {
    this.bootstrapStates.delete(socket);
  }

  broadcastSnapshot(
    sockets: Iterable<Socket>,
    getDialect: (socket: Socket) => SocketDialect,
    send: (socket: Socket, payload: V2ProjectionPayload) => void,
    session: PickyAgentSession,
    epoch: string,
  ): void {
    this.broadcast(sockets, getDialect, send, this.snapshot(session, epoch));
  }

  broadcastTransaction(
    sockets: Iterable<Socket>,
    getDialect: (socket: Socket) => SocketDialect,
    send: (socket: Socket, payload: V2ProjectionPayload) => void,
    sessionId: string,
    before: PickyAgentSession,
    after: PickyAgentSession,
    mutations: readonly PickySessionProjectionMutation[],
    epoch: string,
  ): void {
    this.broadcast(sockets, getDialect, send, {
      type: "sessionProjectionTransaction",
      sessionId,
      epoch,
      baseRevision: before.revision ?? 0,
      revision: after.revision ?? 0,
      mutations: [...mutations],
    });
  }

  private isBootstrapping(socket: Socket, state: V2BootstrapState): boolean {
    return this.bootstrapStates.get(socket) === state;
  }

  private broadcast(
    sockets: Iterable<Socket>,
    getDialect: (socket: Socket) => SocketDialect,
    send: (socket: Socket, payload: V2ProjectionPayload) => void,
    payload: V2ProjectionPayload,
  ): void {
    for (const socket of sockets) {
      if (getDialect(socket) !== "v2") continue;
      const bootstrap = this.bootstrapStates.get(socket);
      if (bootstrap) bootstrap.queued.push(payload);
      else send(socket, payload);
    }
  }

  private snapshot(session: PickyAgentSession, epoch: string): V2ProjectionSnapshotPayload {
    const bounded = boundedSessionForProjectionSnapshot(PickyAgentSessionSchema.parse(session), { epoch });
    if (!bounded.session) throw new Error(`Projection bootstrap snapshot exceeds the app frame budget: ${session.id}`);
    return {
      type: "sessionProjectionSnapshot",
      sessionId: bounded.session.id,
      epoch,
      revision: bounded.session.revision,
      complete: bounded.omittedFields.length === 0,
      omittedFields: bounded.omittedFields,
      projection: bounded.session,
    };
  }
}
