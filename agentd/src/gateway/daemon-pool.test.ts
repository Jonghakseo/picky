/**
 * Ownership hand-back when a child daemon leaves the topology.
 *
 * Archiving a finished Pickle on the Mac releases its child daemon. The session
 * itself lives on in the shared store, so the phone must keep the room; before
 * this was fixed the gateway dropped the child's projection and never asked the
 * primary for a replacement, and the room vanished from the room list.
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
        socket.send(JSON.stringify({ type: "ack", commandId: message.id }));
        // A real daemon builds the bootstrap after the ack round trip; sending
        // it in the same chunk would reach the link before it counts itself
        // registered, which is a different story than this test's.
        setTimeout(() => {
          for (const sessionId of bootstrap) snapshot(socket, sessionId);
        }, 10);
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

    await until(() => pool.projection(sessionId) !== undefined, "the released session was never re-seeded");
    expect(pool.projection(sessionId)?.title).toBe("from the primary");

    const sessions = new Map(pool.sessionIds().map((id) => [id, pool.projection(id)!]));
    const rooms = buildRoomList({ sessions, main: { busy: false, pendingQuestion: false, unread: false } }).rooms;
    expect(rooms.map((room) => room.id)).toEqual([MAIN_ROOM_ID, sessionId]);

    // The room list is rebuilt from this signal, so losing it would leave the
    // phone on a stale list until the next unrelated change.
    expect(counts.sessionsChanged).toBeGreaterThan(before);
  });
});
