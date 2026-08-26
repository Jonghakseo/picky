import { PickyAgentSessionSchema, type PickyAgentSession, type PickyAgentSessionParsed, type PickySessionProjectionMutation } from "../protocol.js";
import { APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT, boundedSessionForProjectionSnapshot, eventPayloadByteLength } from "./app-session-snapshot-policy.js";
import type { SocketDialect } from "./socket-dialect.js";

export const MAX_BOOTSTRAP_QUEUE_FRAMES = 1_024;
export const MAX_BOOTSTRAP_QUEUE_BYTES = APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT;

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

export type V2ProjectionBootstrapCompletePayload = {
  type: "sessionProjectionBootstrapComplete";
  epoch: string;
  bootstrapId: string;
  sessionIds: string[];
};

type V2ProjectionPayload = V2ProjectionTransactionPayload | V2ProjectionSnapshotPayload;
type V2BootstrapState = {
  phase: "active" | "failed";
  bootstrapId: string;
  epoch: string;
  observedSessionIDs: Set<string>;
  queued: V2ProjectionPayload[];
  queuedBytes: number;
  snapshotRevisions: Map<string, number>;
};

export interface SessionProjectionV2Supervisor {
  list(): PickyAgentSession[];
  get(sessionId: string): PickyAgentSession | undefined;
  projectionEpoch(): string;
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
  send(socket: Socket, payload: V2ProjectionPayload | V2ProjectionBootstrapCompletePayload): void;
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

  async register(socket: Socket, previousDialect: SocketDialect, dialect: SocketDialect, supervisor: SessionProjectionV2Supervisor, bootstrapId: string): Promise<void> {
    if (previousDialect !== "negotiating" || dialect !== "v2") return;
    const state: V2BootstrapState = {
      phase: "active",
      bootstrapId,
      epoch: supervisor.projectionEpoch(),
      observedSessionIDs: new Set(),
      queued: [],
      queuedBytes: 0,
      snapshotRevisions: new Map(),
    };
    this.bootstrapStates.set(socket, state);

    try {
      for (const listed of supervisor.list()) {
        if (!this.isActive(socket, state)) return;
        let receivedBarrierSnapshot = false;
        try {
          await supervisor.withSessionProjectionBarrier(listed.id, async ({ session, epoch }) => {
            receivedBarrierSnapshot = true;
            if (!this.isActive(socket, state)) return;
            this.assertEpoch(state, epoch);
            const payload = this.snapshot(session, epoch);
            state.snapshotRevisions.set(session.id, payload.revision);
            state.observedSessionIDs.add(session.id);
            this.sockets.send(socket, payload);
          });
        } catch (error) {
          // A listed session may be permanently deleted before its per-session
          // barrier begins. Any error after a barrier snapshot has started,
          // including an epoch mismatch, fails the entire bootstrap.
          if (!receivedBarrierSnapshot && supervisor.get(listed.id) === undefined) continue;
          throw error;
        }
      }

      if (!this.isActive(socket, state)) return;
      for (const payload of state.queued) {
        if (!this.isActive(socket, state)) return;
        this.assertEpoch(state, payload.epoch);
        if (payload.type === "sessionProjectionTransaction") {
          const snapshotRevision = state.snapshotRevisions.get(payload.sessionId);
          if (snapshotRevision !== undefined && payload.revision <= snapshotRevision) continue;
        } else {
          state.observedSessionIDs.add(payload.sessionId);
        }
        this.sockets.send(socket, payload);
      }

      if (!this.isActive(socket, state)) return;
      if (supervisor.projectionEpoch() !== state.epoch) {
        throw new Error("Session projection epoch changed during bootstrap");
      }
      const sessionIds = [...state.observedSessionIDs].filter((sessionId) => supervisor.get(sessionId) !== undefined);
      this.sockets.send(socket, {
        type: "sessionProjectionBootstrapComplete",
        epoch: state.epoch,
        bootstrapId: state.bootstrapId,
        sessionIds,
      });
      this.bootstrapStates.delete(socket);
    } catch (error) {
      // A partial index cannot safely become live: force a clean connection
      // and negotiation rather than flushing an incomplete bootstrap queue.
      this.failBootstrap(socket, state);
      throw error;
    }
  }

  /** Called by the transport close path so a stalled registration cannot keep queueing projections for a disconnected socket. */
  unregister(socket: Socket): void {
    this.bootstrapStates.delete(socket);
  }

  broadcastSnapshot(
    sockets: Iterable<Socket>,
    getDialect: (socket: Socket) => SocketDialect,
    send: (socket: Socket, payload: V2ProjectionPayload | V2ProjectionBootstrapCompletePayload) => void,
    session: PickyAgentSession,
    epoch: string,
  ): void {
    this.broadcast(sockets, getDialect, send, this.snapshot(session, epoch));
  }

  broadcastTransaction(
    sockets: Iterable<Socket>,
    getDialect: (socket: Socket) => SocketDialect,
    send: (socket: Socket, payload: V2ProjectionPayload | V2ProjectionBootstrapCompletePayload) => void,
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

  private isActive(socket: Socket, state: V2BootstrapState): boolean {
    return this.bootstrapStates.get(socket) === state && state.phase === "active";
  }

  private assertEpoch(state: V2BootstrapState, epoch: string): void {
    if (epoch !== state.epoch) throw new Error("Session projection epoch changed during bootstrap");
  }

  private failBootstrap(socket: Socket, state: V2BootstrapState): void {
    if (this.bootstrapStates.get(socket) !== state || state.phase === "failed") return;
    state.phase = "failed";
    state.queued = [];
    state.queuedBytes = 0;
    this.sockets.close(socket);
  }

  private broadcast(
    sockets: Iterable<Socket>,
    getDialect: (socket: Socket) => SocketDialect,
    send: (socket: Socket, payload: V2ProjectionPayload | V2ProjectionBootstrapCompletePayload) => void,
    payload: V2ProjectionPayload,
  ): void {
    for (const socket of sockets) {
      if (getDialect(socket) !== "v2") continue;
      const bootstrap = this.bootstrapStates.get(socket);
      if (bootstrap?.phase === "failed") continue;
      if (bootstrap) {
        const payloadBytes = eventPayloadByteLength(payload);
        if (bootstrap.queued.length >= MAX_BOOTSTRAP_QUEUE_FRAMES || bootstrap.queuedBytes + payloadBytes > MAX_BOOTSTRAP_QUEUE_BYTES) {
          this.failBootstrap(socket, bootstrap);
          continue;
        }
        bootstrap.queued.push(payload);
        bootstrap.queuedBytes += payloadBytes;
      } else {
        send(socket, payload);
      }
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
