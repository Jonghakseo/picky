/**
 * A Pickle that lives in its own child daemon, from the phone's side.
 *
 * This is the topology Picky.app actually runs (docs/per-pickle-daemon-topology.md):
 * every Pickle gets its own agentd, and the gateway has to attribute each
 * daemon's projection frames correctly while that child joins and after it is
 * released. Two bugs only appeared here: a child's bootstrap snapshot arrives
 * before the ack of its registration, and a released child's session is not in
 * the primary's memory, so nothing can re-seed it.
 *
 * Everything is throwaway: mock-runtime daemons on free ports with their own
 * temp support directory, a gateway on an ephemeral port. It never touches the
 * user's Picky (17631 / 17640) or `~/Library/Application Support/Picky`.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { REMOTE_PROTOCOL_VERSION } from "../remote/constants.js";
import { parseGatewayConfig } from "./config.js";
import { GatewayServer } from "./server.js";
import { StandInHub } from "./dev/stand-in-hub.js";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const hubToken = randomBytes(24).toString("base64url");
const daemonToken = randomBytes(24).toString("base64url");

let daemon: ChildProcess;
let gateway: GatewayServer;
let hub: StandInHub;
let daemonSupportDir: string;
let gatewaySupportDir: string;
let port = 0;
let origin = "";
let cookie = "";

beforeAll(async () => {
  const daemonPort = await freePort();
  daemonSupportDir = await mkdtemp(join(tmpdir(), "picky-child-e2e-agentd-"));
  gatewaySupportDir = await mkdtemp(join(tmpdir(), "picky-child-e2e-gateway-"));

  daemon = spawn("node", ["--import", "tsx", join(packageRoot, "src", "index.ts")], {
    cwd: packageRoot,
    env: {
      ...process.env,
      PICKY_AGENTD_RUNTIME: "mock",
      PICKY_AGENTD_PORT: String(daemonPort),
      PICKY_AGENTD_TOKEN: daemonToken,
      PICKY_APP_SUPPORT_DIR: daemonSupportDir,
      PICKY_DEFAULT_CWD: daemonSupportDir,
      PICKY_AGENTD_PARENT_PID: String(process.pid),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  await waitForDaemonReady(daemon);

  gateway = new GatewayServer({
    config: parseGatewayConfig({
      env: {
        PICKY_GATEWAY_PORT: "0",
        PICKY_GATEWAY_HUB_TOKEN: hubToken,
        PICKY_APP_SUPPORT_DIR: gatewaySupportDir,
        PICKY_GATEWAY_WEB_ROOT: join(gatewaySupportDir, "web"),
      },
      entryDir: join(packageRoot, "dist", "gateway"),
    }),
  });
  port = await gateway.start();
  origin = `http://127.0.0.1:${port}`;

  hub = new StandInHub({
    gatewayUrl: `ws://127.0.0.1:${port}`,
    hubToken,
    daemonUrl: `ws://127.0.0.1:${daemonPort}`,
    daemonToken,
    cwd: daemonSupportDir,
    packageRoot,
    daemonSupportDir,
    print: () => {},
  });
  hub.start();
  await until(() => gateway.core.hub.connected, "the stand-in hub did not connect");

  hub.startPairing();
  await until(() => gateway.core.pairing.current() !== undefined, "no pairing code was issued");
  const response = await fetch(`${origin}/api/pair`, {
    method: "POST",
    headers: { "content-type": "application/json", Origin: origin },
    body: JSON.stringify({ code: gateway.core.pairing.current()?.display ?? "", deviceName: "Child E2E iPhone" }),
  });
  cookie = (response.headers.get("set-cookie") ?? "").split(";")[0];
}, 180_000);

afterAll(async () => {
  hub?.stop();
  await gateway?.stop();
  daemon?.kill("SIGKILL");
  await rm(daemonSupportDir, { recursive: true, force: true }).catch(() => {});
  await rm(gatewaySupportDir, { recursive: true, force: true }).catch(() => {});
});

describe("a Pickle created from the phone into its own child daemon", () => {
  it("starts, answers, and keeps its room after the child is released", async () => {
    const client = await openSocket();
    try {
      await client.waitFor((message) => message.type === "welcome");
      client.send({ type: "hello", protocolVersion: REMOTE_PROTOCOL_VERSION, visible: true, locale: "ko-KR" });
      await client.waitFor((message) => message.type === "rooms");

      // 1. Create it with a first prompt. The gateway only answers `ok` once it
      //    holds the child's projection, which is the bug-1 contract: the
      //    child's bootstrap lands before its registration ack.
      const probe = `child daemon 테스트 ${randomBytes(4).toString("hex")}`;
      const createId = `cmd-${randomBytes(6).toString("hex")}`;
      client.send({
        type: "command",
        commandId: createId,
        command: { type: "pickle.create", cwd: daemonSupportDir, text: probe },
      });
      const created = await client.waitFor(
        (message) => message.type === "command.result" && message.commandId === createId,
        60_000,
      );
      expect(created.error ?? null).toBeNull();
      expect(created.ok).toBe(true);
      const sessionId = (created.data as { sessionId?: string } | undefined)?.sessionId ?? "";
      expect(sessionId).not.toBe("");

      // 2. Opening the room shows the prompt that created the Pickle. The mock
      //    runtime keeps a manual Pickle's first follow-up queued instead of
      //    starting a turn, so it counts wherever the daemon put it.
      client.send({ type: "room.open", roomId: sessionId });
      const snapshot = await client.waitFor((message) => message.type === "session.snapshot" && message.sessionId === sessionId);
      expect((snapshot.projection as { id?: string } | undefined)?.id).toBe(sessionId);
      expect(JSON.stringify(snapshot.projection)).toContain(probe);

      // 3. Live frames flow from the child too, not just its bootstrap: a
      //    second message comes back as a transaction on the open room.
      const second = `child daemon 후속 ${randomBytes(4).toString("hex")}`;
      const sendId = `cmd-${randomBytes(6).toString("hex")}`;
      client.send({
        type: "command",
        commandId: sendId,
        command: { type: "session.send", sessionId, text: second, kind: "followUp" },
      });
      const sent = await client.waitFor(
        (message) => message.type === "command.result" && message.commandId === sendId,
        30_000,
      );
      expect(sent.ok).toBe(true);
      await client.waitFor(
        (message) => message.type === "session.transaction" && message.sessionId === sessionId
          && JSON.stringify(message).includes(second),
        30_000,
      );

      // 4. Archiving releases the child daemon, exactly like the Mac does. The
      //    primary never learned this session, so only the handed over
      //    projection can keep the room alive (bug 2).
      const archiveId = `cmd-${randomBytes(6).toString("hex")}`;
      client.send({
        type: "command",
        commandId: archiveId,
        command: { type: "session.archive", sessionId, archived: true },
      });
      const archived = await client.waitFor(
        (message) => message.type === "command.result" && message.commandId === archiveId,
        30_000,
      );
      expect(archived.ok).toBe(true);
      await client.waitFor(
        (message) => message.type === "rooms"
          && (message.rooms as Array<{ id: string; archived?: boolean }>).some((room) => room.id === sessionId && room.archived === true),
        30_000,
      );

      // The room is still there, still openable, still holding the
      // conversation. A second phone makes the first reply after `room.open`
      // unambiguous, instead of counting snapshots on the busy socket.
      expect(gateway.core.rooms().rooms.map((room) => room.id)).toContain(sessionId);
      const reopened = await openSocket();
      try {
        await reopened.waitFor((message) => message.type === "welcome");
        reopened.send({ type: "hello", protocolVersion: REMOTE_PROTOCOL_VERSION, visible: true, locale: "ko-KR" });
        const rooms = await reopened.waitFor((message) => message.type === "rooms");
        expect((rooms.rooms as Array<{ id: string }>).map((room) => room.id)).toContain(sessionId);

        reopened.send({ type: "room.open", roomId: sessionId });
        const afterRelease = await reopened.waitFor(
          (message) => (message.type === "session.snapshot" || message.type === "session.unavailable")
            && message.sessionId === sessionId,
          30_000,
        );
        expect(afterRelease.type).toBe("session.snapshot");
        expect(JSON.stringify(afterRelease.projection)).toContain(probe);
        expect(JSON.stringify(afterRelease.projection)).toContain(second);
      } finally {
        reopened.close();
      }
    } finally {
      client.close();
    }
  }, 180_000);
});

/* ------------------------------------------------------------------ */

type Message = Record<string, unknown> & { type: string };

interface TestClient {
  send: (message: Record<string, unknown>) => void;
  waitFor: (predicate: (message: Message) => boolean, timeoutMs?: number, skip?: number) => Promise<Message>;
  close: () => void;
}

async function openSocket(): Promise<TestClient> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/api/ws`, {
    headers: { Origin: origin, Host: `127.0.0.1:${port}`, Cookie: cookie },
  });
  const received: Message[] = [];
  socket.on("message", (data) => received.push(JSON.parse(data.toString()) as Message));
  await new Promise<void>((resolveOpen, rejectOpen) => {
    socket.once("open", () => resolveOpen());
    socket.once("unexpected-response", (_request, response) => rejectOpen(new Error(`upgrade refused: ${response.statusCode}`)));
    socket.once("error", (error) => rejectOpen(error));
  });

  return {
    send: (message) => socket.send(JSON.stringify(message)),
    waitFor: async (predicate, timeoutMs = 15_000, skip = 0) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const matches = received.filter(predicate);
        if (matches.length > skip) return matches[skip];
        await delay(50);
      }
      throw new Error(`no matching message within ${timeoutMs} ms (saw ${received.map((item) => item.type).join(", ")})`);
    },
    close: () => socket.close(),
  };
}

function delay(ms: number): Promise<void> {
  return new Promise((done) => setTimeout(done, ms));
}

async function until(condition: () => boolean, message: string, timeoutMs = 30_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await delay(50);
  }
  throw new Error(message);
}

async function freePort(): Promise<number> {
  return new Promise((resolvePort, rejectPort) => {
    const probe = createServer();
    probe.once("error", rejectPort);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      const found = typeof address === "object" && address ? address.port : 0;
      probe.close(() => resolvePort(found));
    });
  });
}

async function waitForDaemonReady(child: ChildProcess): Promise<void> {
  await new Promise<void>((resolveReady, rejectReady) => {
    const timer = setTimeout(() => rejectReady(new Error("the mock daemon did not start in time")), 90_000);
    child.stdout?.on("data", (chunk: Buffer) => {
      if (!chunk.toString().includes("picky-agentd listening on")) return;
      clearTimeout(timer);
      resolveReady();
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      rejectReady(new Error(`the mock daemon exited with code ${String(code)}`));
    });
  });
}
