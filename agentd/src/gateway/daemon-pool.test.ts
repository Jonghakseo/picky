/**
 * Which daemon a session's frames belong to, while a child joins and after it
 * leaves the topology.
 *
 * Both rules exist because of the same real failure: a Pickle created in the
 * HUD runs in its own child daemon, and the phone either never saw it or saw
 * it disappear. The fakes here reproduce agentd's actual frame order, where a
 * link's bootstrap snapshots arrive before the ack of its registration.
 */
import { afterEach, describe, expect, it } from "vitest";
import { WebSocketServer, type WebSocket } from "ws";
import type { PickyAgentSession } from "../protocol.js";
import { MAIN_ROOM_ID } from "../remote/constants.js";
import { DaemonPool, type DaemonPoolListener } from "./daemon-pool.js";
import { buildRoomList } from "./rooms.js";

interface FakeDaemon {
  url: string;
  close: () => Promise<void>;
}

/**
 * A daemon just real enough for DaemonLink: it says hello, acks the capability
 * registration, bootstraps the sessions it hosts, and answers snapshot
 * requests for any session it knows about.
 */
async function startFakeDaemon(sessions: Map<string, PickyAgentSession>, bootstrap: string[]): Promise<FakeDaemon> {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>((done) => server.once("listening", done));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;

  const snapshot = (socket: WebSocket, sessionId: string, requestId?: string) => {
    const projection = sessions.get(sessionId);
    if (!projection) return;
    socket.send(JSON.stringify({
      type: "sessionProjectionSnapshot",
      ...(requestId ? { requestId } : {}),
      sessionId,
      epoch: `epoch-${port}`,
      revision: 1,
      complete: true,
      omittedFields: [],
      projection,
    }));
  };

  server.on("connection", (socket) => {
    socket.send(JSON.stringify({ type: "hello" }));
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString()) as { id: string; type: string; sessionId?: string; requestId?: string };
      if (message.type === "registerAppCapabilities") {
        // agentd's order, which the gateway has to survive: the broadcaster
        // bootstraps the new subscriber inside the command, so every snapshot
        // is on the wire before the ack that ends it.
        for (const sessionId of bootstrap) snapshot(socket, sessionId);
        socket.send(JSON.stringify({ type: "ack", commandId: message.id }));
        return;
      }
      if (message.type === "getSessionProjectionSnapshot" && message.sessionId) {
        snapshot(socket, message.sessionId, message.requestId);
        socket.send(JSON.stringify({ type: "ack", commandId: message.id }));
        return;
      }
      socket.send(JSON.stringify({ type: "ack", commandId: message.id }));
    });
  });

  return {
    url: `ws://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((done) => {
        for (const socket of server.clients) socket.terminate();
        server.close(() => done());
      }),
  };
}

function session(id: string, title: string): PickyAgentSession {
  return {
    id,
    title,
    status: "completed",
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
  } as unknown as PickyAgentSession;
}

function listener(counts: { sessionsChanged: number }): DaemonPoolListener {
  return {
    onSessionReset: () => {},
    onSessionTransaction: () => {},
    onSessionsChanged: () => {
      counts.sessionsChanged += 1;
    },
    onMainEvent: () => {},
    onPrimaryConnected: () => {},
    onConnectionChange: () => {},
  };
}

async function until(condition: () => boolean, message: string, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await new Promise((done) => setTimeout(done, 20));
  }
  throw new Error(message);
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup();
});

function roomIds(pool: DaemonPool): string[] {
  const sessions = new Map(pool.sessionIds().map((id) => [id, pool.projection(id)!]));
  return buildRoomList({ sessions, main: { busy: false, pendingQuestion: false, unread: false } }).rooms.map((room) => room.id);
}

describe("a child daemon joining the topology", () => {
  it("keeps the bootstrap snapshot it sends before its registration ack", async () => {
    // The Pickle was created in the HUD, inside the child, after the primary
    // started: the primary has no record of it, so the child's own bootstrap is
    // the only projection the gateway will ever get for this room.
    const sessionId = "s-hud-created";
    const primary = await startFakeDaemon(new Map(), []);
    const child = await startFakeDaemon(new Map([[sessionId, session(sessionId, "from the child")]]), [sessionId]);
    const counts = { sessionsChanged: 0 };
    const pool = new DaemonPool(listener(counts));
    cleanups.push(async () => {
      pool.stop();
      await child.close();
      await primary.close();
    });

    pool.setTopology({ token: "t", primaryUrl: primary.url, children: [{ sessionId, url: child.url }] });

    await until(
      () => pool.projection(sessionId)?.title === "from the child",
      `the child's pre-ack bootstrap was dropped (ids=${pool.sessionIds().join(",")})`,
    );
    expect(roomIds(pool)).toEqual([MAIN_ROOM_ID, sessionId]);
  });
});

describe("releasing a child daemon", () => {
  it("re-seeds the child's session from the primary so the room survives", async () => {
    const sessionId = "s-archived";
    const primary = await startFakeDaemon(new Map([[sessionId, session(sessionId, "from the primary")]]), []);
    const child = await startFakeDaemon(new Map([[sessionId, session(sessionId, "from the child")]]), [sessionId]);
    const counts = { sessionsChanged: 0 };
    const pool = new DaemonPool(listener(counts));
    cleanups.push(async () => {
      pool.stop();
      await child.close();
      await primary.close();
    });

    pool.setTopology({ token: "t", primaryUrl: primary.url, children: [{ sessionId, url: child.url }] });
    await until(() => pool.projection(sessionId)?.title === "from the child", `the child never took ownership (ids=${pool.sessionIds().join(",")} title=${pool.projection(sessionId)?.title})`);

    const before = counts.sessionsChanged;
    pool.setTopology({ token: "t", primaryUrl: primary.url, children: [] });

    // The room never blinks out: the handed over state stays until the
    // primary's fresher snapshot replaces it.
    expect(pool.projection(sessionId)?.title).toBe("from the child");
    await until(
      () => pool.projection(sessionId)?.title === "from the primary",
      "the released session was never re-seeded from the primary",
    );

    expect(roomIds(pool)).toEqual([MAIN_ROOM_ID, sessionId]);

    // The room list is rebuilt from this signal, so losing it would leave the
    // phone on a stale list until the next unrelated change.
    expect(counts.sessionsChanged).toBeGreaterThan(before);
  });

  it("keeps the child's last projection when the primary cannot serve the session", async () => {
    // A primary only learns the shared store when it starts, so a session a
    // child created later is unknown to it: the re-seed fails and the handed
    // over state is all the phone has.
    const sessionId = "s-unknown-to-primary";
    const primary = await startFakeDaemon(new Map(), []);
    const child = await startFakeDaemon(new Map([[sessionId, session(sessionId, "from the child")]]), [sessionId]);
    const counts = { sessionsChanged: 0 };
    const pool = new DaemonPool(listener(counts));
    cleanups.push(async () => {
      pool.stop();
      await child.close();
      await primary.close();
    });

    pool.setTopology({ token: "t", primaryUrl: primary.url, children: [{ sessionId, url: child.url }] });
    await until(() => pool.projection(sessionId) !== undefined, "the child never took ownership");

    pool.setTopology({ token: "t", primaryUrl: primary.url, children: [] });
    // Long enough for the failed refresh to come back from the primary.
    await new Promise((done) => setTimeout(done, 300));

    expect(pool.projection(sessionId)?.title).toBe("from the child");
    expect(roomIds(pool)).toEqual([MAIN_ROOM_ID, sessionId]);
  });
});
