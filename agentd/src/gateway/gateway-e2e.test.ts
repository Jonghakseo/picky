/**
 * The whole path a phone takes, over real sockets: pair, open the WebSocket,
 * open a room, send a message into a mock-runtime agentd, and get revoked.
 *
 * Everything is throwaway: a mock daemon on a free port with its own temp
 * support directory, a gateway on an ephemeral port with its own data
 * directory, and the stand-in hub. It never touches the user's Picky (17631 /
 * 17640) or `~/Library/Application Support/Picky`.
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
let seededSessionId = "";

/** Shared across the ordered steps below: pairing hands the cookie to the socket. */
let cookie = "";

beforeAll(async () => {
  const daemonPort = await freePort();
  daemonSupportDir = await mkdtemp(join(tmpdir(), "picky-e2e-agentd-"));
  gatewaySupportDir = await mkdtemp(join(tmpdir(), "picky-e2e-gateway-"));

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

  await hub.seed(["원격 E2E 테스트용 Pickle이에요"]);
  await until(() => gateway.core.rooms().rooms.some((room) => room.kind === "pickle"), "no Pickle reached the room list");
  seededSessionId = gateway.core.rooms().rooms.find((room) => room.kind === "pickle")?.id ?? "";
}, 120_000);

afterAll(async () => {
  hub?.stop();
  await gateway?.stop();
  daemon?.kill("SIGKILL");
  await rm(daemonSupportDir, { recursive: true, force: true }).catch(() => {});
  await rm(gatewaySupportDir, { recursive: true, force: true }).catch(() => {});
});

describe("a phone from pairing to revocation", () => {
  it("seeded a Pickle through the hub and the mock daemon", () => {
    expect(seededSessionId).not.toBe("");
    expect(gateway.core.session(seededSessionId)?.id).toBe(seededSessionId);
  });

  it("refuses a cross-origin pairing request before it even looks at the code", async () => {
    const response = await fetch(`${origin}/api/pair`, {
      method: "POST",
      headers: { "content-type": "application/json", Origin: "http://evil.example" },
      body: JSON.stringify({ code: "AAAA-AAAA", deviceName: "Attacker" }),
    });
    expect(response.status).toBe(403);
    expect(response.headers.get("set-cookie")).toBeNull();
  });

  it("refuses a wrong code and hands out no cookie", async () => {
    hub.startPairing();
    await until(() => gateway.core.pairing.current() !== undefined, "no pairing code was issued");
    const response = await pair("ZZZZ-ZZZZ");
    expect(response.status).toBe(400);
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(gateway.core.pairing.isActive()).toBe(true);
  });

  it("keeps the Mac name from unpaired visitors", async () => {
    const me = await (await fetch(`${origin}/api/me`)).json() as { paired: boolean; macName?: string };
    expect(me.paired).toBe(false);
    expect(me.macName).toBeUndefined();
  });

  it("pairs with the code the Mac is showing and sets the device cookie", async () => {
    const code = gateway.core.pairing.current()?.display ?? "";
    const response = await pair(code);
    const body = await response.json() as { paired: boolean; device: { id: string; name: string } };
    expect(response.status).toBe(200);
    expect(body.paired).toBe(true);

    const setCookie = response.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("picky_remote=");
    expect(setCookie).toContain("HttpOnly");
    expect(setCookie).toContain("SameSite=Lax");
    // Loopback http: no `Secure`, or the cookie would never be stored.
    expect(setCookie).not.toContain("Secure");
    cookie = setCookie.split(";")[0];

    // One code pairs one device.
    expect(gateway.core.pairing.isActive()).toBe(false);
    const me = await (await fetch(`${origin}/api/me`, { headers: { cookie } })).json() as { paired: boolean; macName?: string };
    expect(me.paired).toBe(true);
    expect(me.macName).toBeTruthy();
  });

  it("drops every push subscription of the device when DELETE carries no endpoint", async () => {
    const headers = { cookie, origin, "content-type": "application/json" };
    const subscription = (endpoint: string) => JSON.stringify({ endpoint, keys: { p256dh: "BPub", auth: "secret" } });
    for (const endpoint of ["https://fcm.googleapis.com/fcm/send/a", "https://web.push.apple.com/b"]) {
      expect((await fetch(`${origin}/api/push/subscription`, { method: "POST", headers, body: subscription(endpoint) })).status).toBe(200);
    }
    const deviceId = gateway.core.devices.list()[0]?.id ?? "";
    expect(gateway.core.devices.get(deviceId)?.pushSubscriptions).toHaveLength(2);

    const removed = await fetch(`${origin}/api/push/subscription`, { method: "DELETE", headers: { cookie, origin } });
    expect(removed.status).toBe(200);
    expect(gateway.core.devices.get(deviceId)?.pushSubscriptions).toHaveLength(0);
  });

  it("signs this Mac's browser in once from the hub's one-time link, and never through a tunnel", async () => {
    const url = await hub.openLocalBrowser();
    expect(url).toMatch(new RegExp(`^http://127\\.0\\.0\\.1:${port}/api/local-open\\?token=`));

    // A request that came through Tailscale Serve or cloudflared carries a forwarding header.
    const tunnelled = await fetch(url, { redirect: "manual", headers: { "x-forwarded-for": "100.64.0.9" } });
    expect(tunnelled.status).toBe(403);

    const opened = await fetch(url, { redirect: "manual" });
    expect(opened.status).toBe(303);
    expect(opened.headers.get("location")).toBe("/");
    const browserCookie = opened.headers.get("set-cookie")?.split(";")[0] ?? "";
    expect(browserCookie).not.toBe("");
    const me = await (await fetch(`${origin}/api/me`, { headers: { cookie: browserCookie } })).json() as { paired: boolean };
    expect(me.paired).toBe(true);
    await until(() => hub.devices.some((device) => device.local === true), "the Mac never listed the browser as this Mac's");

    // The link is spent: opening it again signs nothing in.
    const reused = await fetch(url, { redirect: "manual" });
    expect(reused.status).toBe(303);
    expect(reused.headers.get("set-cookie")).toBeNull();

    // An already-signed-in browser keeps its device instead of adding another.
    const before = gateway.core.devices.list().length;
    const again = await fetch(await hub.openLocalBrowser(), { redirect: "manual", headers: { cookie: browserCookie } });
    expect(again.status).toBe(303);
    expect(again.headers.get("set-cookie")).toBeNull();
    expect(gateway.core.devices.list().length).toBe(before);
  });

  it("refuses a WebSocket upgrade from another origin, and one with no cookie", async () => {
    await expect(openSocket({ cookie, origin: "http://evil.example" })).rejects.toThrow(/403/);
    await expect(openSocket({ origin })).rejects.toThrow(/401/);
  });

  it("keeps the hub socket to a loopback peer with the right token", async () => {
    await expect(openHubSocket({ Authorization: "Bearer wrong-token" })).rejects.toThrow(/401/);
    await expect(openHubSocket({})).rejects.toThrow(/401/);
    // A forwarding header means the request came through a tunnel, not from
    // Picky.app on this Mac.
    await expect(openHubSocket({ Authorization: `Bearer ${hubToken}`, "X-Forwarded-For": "203.0.113.9" }))
      .rejects.toThrow(/401/);
  });

  it("carries a conversation: hello, room.open, send, transaction, dedupe, revoke", async () => {
    const client = await openSocket({ cookie, origin });
    try {
      const welcome = await client.waitFor((message) => message.type === "welcome");
      expect(welcome.protocolVersion).toBe(REMOTE_PROTOCOL_VERSION);

      client.send({ type: "hello", protocolVersion: REMOTE_PROTOCOL_VERSION, visible: true, locale: "ko-KR" });
      const rooms = await client.waitFor((message) => message.type === "rooms");
      expect((rooms.rooms as Array<{ id: string }>).map((room) => room.id)).toContain(seededSessionId);
      // The hub marks a new Pickle unread; reading it on the phone must clear the mark on the Mac.
      expect((rooms.rooms as Array<{ id: string; unread: boolean }>).find((room) => room.id === seededSessionId)?.unread).toBe(true);

      client.send({ type: "room.open", roomId: seededSessionId });
      const snapshot = await client.waitFor((message) => message.type === "session.snapshot");
      expect(snapshot.sessionId).toBe(seededSessionId);
      expect((snapshot.projection as { id?: string } | undefined)?.id).toBe(seededSessionId);
      await client.waitFor(
        (message) => message.type === "rooms"
          && (message.rooms as Array<{ id: string; unread: boolean }>).some((room) => room.id === seededSessionId && !room.unread),
        10_000,
      );

      // The composer's slash autocomplete reads the Pickle's own command list from its daemon.
      client.send({ type: "query", queryId: "q-slash", query: { type: "session.slashCommands", sessionId: seededSessionId } });
      const slash = await client.waitFor((message) => message.type === "query.result" && message.queryId === "q-slash");
      expect(slash.ok).toBe(true);
      expect((slash.data as { commands: Array<{ name: string }> }).commands.map((command) => command.name)).toContain("skill:mock-skill");

      const probe = `E2E 후속 메시지 ${randomBytes(4).toString("hex")}`;
      const commandId = `cmd-${randomBytes(6).toString("hex")}`;
      client.send({
        type: "command",
        commandId,
        command: { type: "session.send", sessionId: seededSessionId, text: probe, kind: "followUp" },
      });
      const result = await client.waitFor((message) => message.type === "command.result" && message.commandId === commandId);
      expect(result.ok).toBe(true);

      // The message really reached the daemon: it comes back as a transaction
      // on the open room, not just as an ack.
      await client.waitFor(
        (message) => message.type === "session.transaction" && message.sessionId === seededSessionId
          && JSON.stringify(message).includes(probe),
        20_000,
      );

      // A retry after a dropped socket replays the first answer instead of
      // sending the message twice.
      client.send({
        type: "command",
        commandId,
        command: { type: "session.send", sessionId: seededSessionId, text: probe, kind: "followUp" },
      });
      const retry = await client.waitFor(
        (message) => message.type === "command.result" && message.commandId === commandId,
        10_000,
        1,
      );
      expect(retry.ok).toBe(true);
      await delay(1500);

      // Ask the daemon for a fresh projection and count what actually landed in
      // the conversation: the retry must not have sent the message twice.
      client.send({ type: "room.resync", roomId: seededSessionId });
      const resynced = await client.waitFor((message) => message.type === "session.snapshot", 20_000, 1);
      expect(userTextCount(resynced.projection, probe)).toBe(1);

      const deviceId = (welcome.device as { id: string }).id;
      const closed = client.closed();
      await gateway.core.revokeDevice(deviceId, "hub");
      expect(await closed).toBe(4401);

      // The cookie dies with the device.
      const me = await (await fetch(`${origin}/api/me`, { headers: { cookie } })).json() as { paired: boolean };
      expect(me.paired).toBe(false);
    } finally {
      client.close();
    }
  }, 60_000);
});

/* ------------------------------------------------------------------ */

type Message = Record<string, unknown> & { type: string };

interface TestClient {
  send: (message: Record<string, unknown>) => void;
  waitFor: (predicate: (message: Message) => boolean, timeoutMs?: number, skip?: number) => Promise<Message>;
  closed: () => Promise<number>;
  close: () => void;
}

async function openSocket(options: { cookie?: string; origin: string }): Promise<TestClient> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/api/ws`, {
    headers: {
      Origin: options.origin,
      Host: `127.0.0.1:${port}`,
      ...(options.cookie ? { Cookie: options.cookie } : {}),
    },
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
    waitFor: async (predicate, timeoutMs = 10_000, skip = 0) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const matches = received.filter(predicate);
        if (matches.length > skip) return matches[skip];
        await delay(50);
      }
      throw new Error(`no matching message within ${timeoutMs} ms (saw ${received.map((item) => item.type).join(", ")})`);
    },
    closed: () => new Promise<number>((resolveClose) => socket.once("close", (code) => resolveClose(code))),
    close: () => socket.close(),
  };
}

async function openHubSocket(headers: Record<string, string>): Promise<void> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/hub`, { headers });
  try {
    await new Promise<void>((resolveOpen, rejectOpen) => {
      socket.once("open", () => resolveOpen());
      socket.once("unexpected-response", (_request, response) => rejectOpen(new Error(`upgrade refused: ${response.statusCode}`)));
      socket.once("error", (error) => rejectOpen(error));
    });
  } finally {
    socket.close();
  }
}

function pair(code: string): Promise<Response> {
  return fetch(`${origin}/api/pair`, {
    method: "POST",
    headers: { "content-type": "application/json", Origin: origin },
    body: JSON.stringify({ code, deviceName: "E2E iPhone" }),
  });
}

/**
 * How many times the user's text exists in the conversation. A follow-up sent
 * while the Pickle is mid-turn waits in the queue instead of becoming a
 * message, so both places count.
 */
function userTextCount(projection: unknown, text: string): number {
  const session = projection as {
    messages?: Array<{ kind?: string; text?: string }>;
    queuedFollowUps?: Array<{ text?: string }>;
    queuedSteers?: Array<{ text?: string }>;
  } | undefined;
  const messages = (session?.messages ?? []).filter((item) => item.kind === "user_text" && item.text?.includes(text));
  const queued = [...(session?.queuedFollowUps ?? []), ...(session?.queuedSteers ?? [])]
    .filter((item) => item.text?.includes(text));
  return messages.length + queued.length;
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
