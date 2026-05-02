import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PROTOCOL_VERSION, type EventEnvelope, type PickyAgentSession } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { AgentdServer, compactSessionsForSnapshot } from "./server.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

let server: AgentdServer;
let port: number;

beforeEach(async () => {
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-server-test-"));
  const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
  await supervisor.load();
  server = new AgentdServer({ port: 0, token: "test-token", supervisor });
  port = await server.start();
});

afterEach(async () => {
  await server.stop();
});

describe("AgentdServer", () => {
  it("rejects unauthorized connections", async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    await once(ws, "error");
    expect(ws.readyState).toBe(WebSocket.CLOSED);
  });

  it("sends hello to authorized clients", async () => {
    const { ws, hello } = await connectWithHello();
    expect(hello.type).toBe("hello");
    ws.close();
  });

  it("returns error for malformed JSON and keeps serving commands", async () => {
    const { ws } = await connectWithHello();
    ws.send("not json");
    expect((await nextEvent(ws)).type).toBe("error");
    ws.send(JSON.stringify({ id: "cmd-list", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    const snapshot = await nextEvent(ws);
    expect(snapshot.type).toBe("sessionSnapshot");
    if (snapshot.type === "sessionSnapshot") expect(snapshot.sessions).toEqual([]);
    ws.close();
  });

  it("compacts large session logs for session snapshots", () => {
    const session = makeSession({
      logs: [
        "pi session: /tmp/picky.jsonl",
        "source transcript:\n" + "질문 ".repeat(1_000),
        "steer: keep this visible in the HUD",
        ...Array.from({ length: 80 }, (_, index) => `extension ui: setWidget ${index}`),
        "latest useful log",
      ],
    });

    const [compact] = compactSessionsForSnapshot([session]);

    expect(compact.logs.length).toBeLessThanOrEqual(24);
    expect(compact.logs).toContain("pi session: /tmp/picky.jsonl");
    expect(compact.logs).toContain("steer: keep this visible in the HUD");
    expect(compact.logs.at(-1)).toBe("latest useful log");
    expect(JSON.stringify(compact).length).toBeLessThan(30_000);
  });
});

function makeSession(overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  return {
    id: "session-large",
    title: "Large session",
    status: "completed",
    cwd: "/tmp/project",
    createdAt: "2026-05-03T00:00:00.000Z",
    updatedAt: "2026-05-03T00:00:01.000Z",
    lastSummary: "Done",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    ...overrides,
  };
}

async function connectWithHello(): Promise<{ ws: WebSocket; hello: EventEnvelope }> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=test-token`);
  const helloPromise = nextEvent(ws);
  await once(ws, "open");
  return { ws, hello: await helloPromise };
}

async function nextEvent(ws: WebSocket): Promise<EventEnvelope> {
  const [data] = (await once(ws, "message")) as [Buffer];
  return JSON.parse(data.toString()) as EventEnvelope;
}
