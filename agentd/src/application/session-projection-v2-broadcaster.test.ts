import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PickyAgentSessionSchema, type PickyAgentSession, type PickySessionProjectionMutation } from "../protocol.js";
import { MockRuntime } from "../runtime/mock-runtime.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import {
  MAX_BOOTSTRAP_QUEUE_BYTES,
  MAX_BOOTSTRAP_QUEUE_FRAMES,
  SessionProjectionV2Broadcaster,
  type SessionProjectionV2Supervisor,
} from "./session-projection-v2-broadcaster.js";

const epoch = "projection-epoch";

type TestSocket = { id: string };

function session(id: string): PickyAgentSession {
  return PickyAgentSessionSchema.parse({
    id,
    title: id,
    status: "queued",
    cwd: "/tmp/project",
    createdAt: "2026-08-25T00:00:00.000Z",
    updatedAt: "2026-08-25T00:00:00.000Z",
  });
}

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((settle) => { resolve = settle; });
  return { promise, resolve };
}

function supervisorFor(options: {
  sessions: Map<string, PickyAgentSession>;
  list?: () => PickyAgentSession[];
  withBarrier?: SessionProjectionV2Supervisor["withSessionProjectionBarrier"];
}): SessionProjectionV2Supervisor {
  return {
    list: options.list ?? (() => [...options.sessions.values()]),
    get: (sessionId) => options.sessions.get(sessionId),
    projectionEpoch: () => epoch,
    withSessionProjectionBarrier: options.withBarrier ?? (async (sessionId, work) => {
      const current = options.sessions.get(sessionId);
      if (!current) throw new Error(`Unknown session: ${sessionId}`);
      await work({ session: current, epoch });
    }),
    on: () => undefined,
  };
}

describe("SessionProjectionV2Broadcaster", () => {
  it("sends bootstrap snapshots and queued frames before one membership completion, then sends live frames directly", async () => {
    const socket = { id: "v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("initial-session");
    const queued = session("created-during-bootstrap");
    const live = session("created-after-bootstrap");
    const sessions = new Map([[initial.id, initial]]);
    const sent: Array<{ type: string; sessionId?: string; epoch?: string; bootstrapId?: string; sessionIds?: string[] }> = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => { throw new Error("successful bootstrap must not close the socket"); },
    });
    const supervisor = supervisorFor({
      sessions,
      withBarrier: async (_, work) => {
        sessions.set(queued.id, queued);
        snapshotListener?.(queued, epoch);
        await work({ session: initial, epoch });
      },
    });
    supervisor.on = (event, listener) => {
      if (event === "sessionProjectionSnapshot") snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
    };

    broadcaster.bind(supervisor);
    await broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-001");
    sessions.set(live.id, live);
    snapshotListener?.(live, epoch);

    expect(sent.map((payload) => payload.type)).toEqual([
      "sessionProjectionSnapshot",
      "sessionProjectionSnapshot",
      "sessionProjectionBootstrapComplete",
      "sessionProjectionSnapshot",
    ]);
    expect(sent[2]).toMatchObject({
      epoch,
      bootstrapId: "register-v2-001",
      sessionIds: [initial.id, queued.id],
    });
  });

  it("emits a completion with an empty membership and current epoch for an empty bootstrap", async () => {
    const socket = { id: "empty-v2-socket" };
    const sent: Array<{ type: string; epoch?: string; bootstrapId?: string; sessionIds?: string[] }> = [];
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => [socket],
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => { throw new Error("empty bootstrap must not close the socket"); },
    });
    const supervisor = supervisorFor({ sessions: new Map() });

    await broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-empty");

    expect(sent).toEqual([{
      type: "sessionProjectionBootstrapComplete",
      epoch,
      bootstrapId: "register-v2-empty",
      sessionIds: [],
    }]);
  });

  it("excludes archived sessions purged during supervisor load from completion", async () => {
    const directory = await mkdtemp(join(tmpdir(), "picky-projection-bootstrap-purge-"));
    const store = new SessionStore(directory);
    const old = new Date(Date.now() - 8 * 24 * 60 * 60 * 1_000).toISOString();
    await store.save({
      ...session("expired-archived-session"),
      status: "completed",
      archived: true,
      archivedAt: old,
      createdAt: old,
      updatedAt: old,
    });
    const supervisor = new SessionSupervisor(new MockRuntime(), store);
    await supervisor.load();
    const socket = { id: "purged-v2-socket" };
    const sent: Array<{ type: string; sessionIds?: string[] }> = [];
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => [socket],
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => { throw new Error("purged empty bootstrap must not close the socket"); },
    });

    broadcaster.bind(supervisor);
    await broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-purged");

    expect(supervisor.get("expired-archived-session")).toBeUndefined();
    expect(sent).toEqual([expect.objectContaining({
      type: "sessionProjectionBootstrapComplete",
      sessionIds: [],
    })]);
  });

  it("excludes a session deleted between listing and its barrier from completion before sending later live frames", async () => {
    const socket = { id: "deleted-v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("deleted-during-bootstrap");
    const live = session("created-after-bootstrap");
    const sessions = new Map([[initial.id, initial]]);
    const sent: Array<{ type: string; sessionId?: string; sessionIds?: string[] }> = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => { throw new Error("a deleted bootstrap session must not close the socket"); },
    });
    const supervisor = supervisorFor({
      sessions,
      list: () => [initial],
      withBarrier: async (sessionId) => {
        sessions.delete(sessionId);
        throw new Error(`Unknown session: ${sessionId}`);
      },
    });
    supervisor.on = (event, listener) => {
      if (event === "sessionProjectionSnapshot") snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
    };

    broadcaster.bind(supervisor);
    await broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-deleted");
    sessions.set(live.id, live);
    snapshotListener?.(live, epoch);

    expect(sent).toEqual([
      expect.objectContaining({ type: "sessionProjectionBootstrapComplete", sessionIds: [] }),
      expect.objectContaining({ type: "sessionProjectionSnapshot", sessionId: live.id }),
    ]);
  });

  it("emits no completion when a socket disconnects before its barrier completes", async () => {
    const socket = { id: "disconnecting-v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("bootstrap-session");
    const entered = deferred();
    const release = deferred();
    const sent: Array<{ type: string }> = [];
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => {},
    });
    const supervisor = supervisorFor({
      sessions: new Map([[initial.id, initial]]),
      withBarrier: async (_, work) => {
        entered.resolve();
        await release.promise;
        await work({ session: initial, epoch });
      },
    });

    const registration = broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-disconnecting");
    await entered.promise;
    broadcaster.unregister(socket);
    sockets.delete(socket);
    release.resolve();
    await registration;

    expect(sent).toEqual([]);
  });

  it("fails bootstrap when an initial or queued projection has a different epoch", async () => {
    const socket = { id: "epoch-mismatch-v2-socket" };
    const initial = session("epoch-bootstrap-session");
    const queued = session("epoch-queued-session");
    const sent: Array<{ type: string }> = [];
    const closed: TestSocket[] = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => [socket],
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: (candidate) => { closed.push(candidate); },
    });
    const supervisor = supervisorFor({
      sessions: new Map([[initial.id, initial], [queued.id, queued]]),
      list: () => [initial],
      withBarrier: async (_, work) => {
        snapshotListener?.(queued, "other-epoch");
        await work({ session: initial, epoch });
      },
    });
    supervisor.on = (event, listener) => {
      if (event === "sessionProjectionSnapshot") snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
    };

    broadcaster.bind(supervisor);
    await expect(broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-epoch-mismatch")).rejects.toThrow("Session projection epoch changed during bootstrap");

    expect(sent).toEqual([expect.objectContaining({ type: "sessionProjectionSnapshot", sessionId: initial.id })]);
    expect(closed).toEqual([socket]);
  });

  it("fails a partial bootstrap without completion and retains its failed sentinel until unregister", async () => {
    const socket = { id: "failed-bootstrap-v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("failed-bootstrap-session");
    const queuedLive = session("queued-before-failure");
    const sent: Array<{ type: string }> = [];
    const closed: TestSocket[] = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: (candidate) => { closed.push(candidate); },
    });
    const supervisor = supervisorFor({
      sessions: new Map([[initial.id, initial]]),
      withBarrier: async () => {
        snapshotListener?.(queuedLive, epoch);
        throw new Error("projection barrier failed");
      },
    });
    supervisor.on = (event, listener) => {
      if (event === "sessionProjectionSnapshot") snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
    };

    broadcaster.bind(supervisor);
    await expect(broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-failed")).rejects.toThrow("projection barrier failed");
    snapshotListener?.(session("must-not-direct-send"), epoch);

    expect(closed).toEqual([socket]);
    expect(sent).toEqual([]);
  });

  it("closes on either queue limit without completion or a direct-send leak before unregister", async () => {
    const socket = { id: "overflow-v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("overflow-bootstrap-session");
    const entered = deferred();
    const release = deferred();
    const sent: Array<{ type: string }> = [];
    const closed: TestSocket[] = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: (candidate) => { closed.push(candidate); },
    });
    const supervisor = supervisorFor({
      sessions: new Map([[initial.id, initial]]),
      withBarrier: async (_, work) => {
        entered.resolve();
        await release.promise;
        await work({ session: initial, epoch });
      },
    });
    supervisor.on = (event, listener) => {
      if (event === "sessionProjectionSnapshot") snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
    };

    broadcaster.bind(supervisor);
    const registration = broadcaster.register(socket, "negotiating", "v2", supervisor, "register-v2-overflow");
    await entered.promise;
    for (let index = 0; index <= MAX_BOOTSTRAP_QUEUE_FRAMES; index += 1) snapshotListener?.(session(`queued-${index}`), epoch);
    snapshotListener?.(session("must-not-direct-send-after-overflow"), epoch);
    release.resolve();
    await registration;

    expect(closed).toEqual([socket]);
    expect(sent).toEqual([]);

    const byteOverflowSocket = { id: "byte-overflow-v2-socket" };
    const byteOverflowClosed: TestSocket[] = [];
    const byteBroadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => [byteOverflowSocket],
      getDialect: () => "v2",
      send: () => { throw new Error("overflowed queue must not send"); },
      close: (candidate) => { byteOverflowClosed.push(candidate); },
    });
    const byteEntered = deferred();
    const byteRelease = deferred();
    const byteSupervisor = supervisorFor({
      sessions: new Map([[initial.id, initial]]),
      withBarrier: async (_, work) => {
        byteEntered.resolve();
        await byteRelease.promise;
        await work({ session: initial, epoch });
      },
    });
    byteBroadcaster.bind(byteSupervisor);
    const byteRegistration = byteBroadcaster.register(byteOverflowSocket, "negotiating", "v2", byteSupervisor, "register-v2-byte-overflow");
    await byteEntered.promise;
    byteBroadcaster.broadcastTransaction(
      [byteOverflowSocket],
      () => "v2",
      () => { throw new Error("overflowed queue must not send"); },
      initial.id,
      initial,
      { ...initial, revision: 1 },
      [{ type: "logAppend", line: "x".repeat(MAX_BOOTSTRAP_QUEUE_BYTES) }] satisfies PickySessionProjectionMutation[],
      epoch,
    );
    byteRelease.resolve();
    await byteRegistration;

    expect(byteOverflowClosed).toEqual([byteOverflowSocket]);
  });
});
