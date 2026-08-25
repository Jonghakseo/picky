import { describe, expect, it } from "vitest";
import { PickyAgentSessionSchema, type PickyAgentSession } from "../protocol.js";
import {
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

describe("SessionProjectionV2Broadcaster", () => {
  it("skips a session deleted during bootstrap and delivers subsequent live projections", async () => {
    const socket = { id: "v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("deleted-during-bootstrap");
    const live = session("created-after-bootstrap");
    const sessions = new Map([[initial.id, initial]]);
    const sent: Array<{ type: string; sessionId: string }> = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => { throw new Error("a deleted bootstrap session must not close the socket"); },
    });
    const supervisor: SessionProjectionV2Supervisor = {
      list: () => [initial],
      get: (sessionId) => sessions.get(sessionId),
      withSessionProjectionBarrier: async (sessionId, work) => {
        sessions.delete(sessionId);
        throw new Error(`Unknown session: ${sessionId}`);
      },
      on: (event, listener) => {
        if (event === "sessionProjectionSnapshot") {
          snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
        }
      },
    };

    broadcaster.bind(supervisor);
    await broadcaster.register(socket, "negotiating", "v2", supervisor);

    sessions.set(live.id, live);
    snapshotListener?.(live, epoch);

    expect(sent).toEqual([expect.objectContaining({ type: "sessionProjectionSnapshot", sessionId: live.id })]);
  });

  it("cleans bootstrap state when a socket disconnects before its barrier completes", async () => {
    const socket = { id: "disconnecting-v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("bootstrap-session");
    const queuedLive = session("queued-live-session");
    const entered = deferred();
    const release = deferred();
    const sent: Array<{ type: string; sessionId: string }> = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: () => {},
    });
    const supervisor: SessionProjectionV2Supervisor = {
      list: () => [initial],
      get: (sessionId) => sessionId === initial.id ? initial : undefined,
      withSessionProjectionBarrier: async (_, work) => {
        entered.resolve();
        await release.promise;
        await work({ session: initial, epoch });
      },
      on: (event, listener) => {
        if (event === "sessionProjectionSnapshot") {
          snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
        }
      },
    };

    broadcaster.bind(supervisor);
    const registration = broadcaster.register(socket, "negotiating", "v2", supervisor);
    await entered.promise;
    snapshotListener?.(queuedLive, epoch);
    broadcaster.unregister(socket);
    sockets.delete(socket);
    release.resolve();
    await registration;

    expect(sent).toEqual([]);
  });

  it("closes and clears bootstrap state without flushing partial projections when the index cannot be completed", async () => {
    const socket = { id: "failed-bootstrap-v2-socket" };
    const sockets = new Set<TestSocket>([socket]);
    const initial = session("failed-bootstrap-session");
    const queuedLive = session("queued-before-failure");
    const sent: Array<{ type: string; sessionId: string }> = [];
    const closed: TestSocket[] = [];
    let snapshotListener: ((projection: PickyAgentSession, projectionEpoch: string) => void) | undefined;
    const broadcaster = new SessionProjectionV2Broadcaster<TestSocket>({
      sockets: () => sockets,
      getDialect: () => "v2",
      send: (_, payload) => { sent.push(payload); },
      close: (candidate) => { closed.push(candidate); sockets.delete(candidate); },
    });
    const supervisor: SessionProjectionV2Supervisor = {
      list: () => [initial],
      get: (sessionId) => sessionId === initial.id ? initial : undefined,
      withSessionProjectionBarrier: async () => {
        snapshotListener?.(queuedLive, epoch);
        throw new Error("projection barrier failed");
      },
      on: (event, listener) => {
        if (event === "sessionProjectionSnapshot") {
          snapshotListener = listener as (projection: PickyAgentSession, projectionEpoch: string) => void;
        }
      },
    };

    broadcaster.bind(supervisor);
    await expect(broadcaster.register(socket, "negotiating", "v2", supervisor)).rejects.toThrow("projection barrier failed");

    expect(closed).toEqual([socket]);
    expect(sent).toEqual([]);
  });
});
