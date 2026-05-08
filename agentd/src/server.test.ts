import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, type EventEnvelope, type PickyAgentSession, type PickyContextPacket } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { AgentdServer, compactSessionsForSnapshot, sanitizeForJson } from "./server.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

let server: AgentdServer;
let port: number;
let supervisor: SessionSupervisor;

beforeEach(async () => {
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-server-test-"));
  supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
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

  it("broadcasts an empty main-message snapshot after resetting the main agent", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-reset-main", protocolVersion: PROTOCOL_VERSION, type: "resetMainAgent" }));
    const snapshot = await nextEvent(ws);
    expect(snapshot.type).toBe("mainMessagesSnapshot");
    if (snapshot.type === "mainMessagesSnapshot") expect(snapshot.messages).toEqual([]);
    ws.close();
  });

  it("passes optional steer context through to the supervisor", async () => {
    const session = await supervisor.create(context("initial"));
    const steer = vi.spyOn(supervisor, "steer");
    const steerContext: PickyContextPacket = {
      ...context("visual steer"),
      id: "context-visual-steer",
      screenshots: [{ id: "shot-1", label: "Main", path: "/tmp/shot.png" }],
    };
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-steer", protocolVersion: PROTOCOL_VERSION, type: "steer", sessionId: session.id, text: "inspect this", context: steerContext }));

    await waitUntil(() => steer.mock.calls.length > 0);

    expect(steer).toHaveBeenCalledWith(session.id, "inspect this", expect.objectContaining({ id: "context-visual-steer", screenshots: [expect.objectContaining({ path: "/tmp/shot.png" })] }));
    ws.close();
  });

  it("clears a session queue through the supervisor", async () => {
    const session = await supervisor.create(context("initial"));
    const clearQueue = vi.spyOn(supervisor, "clearQueue");
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-clear", protocolVersion: PROTOCOL_VERSION, type: "clearQueue", sessionId: session.id, kind: "all" }));

    await waitUntil(() => clearQueue.mock.calls.length > 0);

    expect(clearQueue).toHaveBeenCalledWith(session.id, "all");
    ws.close();
  });

  it("sanitizes unpaired surrogate strings before JSON serialization", () => {
    const sanitized = sanitizeForJson({
      brokenHigh: "tool output: \uD83C",
      brokenLow: "tool output: \uDF3A",
      validPair: "tool output: \uD83C\uDF3A",
      nested: [{ preview: "bash: \uD83C" }],
    });

    expect(sanitized.brokenHigh).toBe("tool output: �");
    expect(sanitized.brokenLow).toBe("tool output: �");
    expect(sanitized.validPair).toBe("tool output: 🌺");
    expect(sanitized.nested[0].preview).toBe("bash: �");
    expect(JSON.stringify(sanitized)).not.toContain("\\ud83c");
    expect(JSON.stringify(sanitized)).not.toContain("\\udf3a");
  });

  it("compacts large session payloads for session snapshots", () => {
    const session = makeSession({
      piSessionFilePath: "/tmp/explicit-picky.jsonl",
      logs: [
        "pi session: /tmp/picky.jsonl",
        "source transcript:\n" + "질문 ".repeat(1_000),
        "steer: keep this visible in the HUD",
        ...Array.from({ length: 80 }, (_, index) => `extension ui: setWidget ${index}`),
        "latest useful log",
      ],
      tools: Array.from({ length: 320 }, (_, index) => ({
        toolCallId: `tool-${index}`,
        name: "bash",
        status: "succeeded" as const,
        preview: "very long tool preview ".repeat(1_000),
      })),
      changedFiles: Array.from({ length: 80 }, (_, index) => ({
        path: `file-${index}.txt`,
        status: "modified",
        summary: "large summary ".repeat(1_000),
      })),
      finalAnswer: "large final answer ".repeat(1_000),
      messages: Array.from({ length: 80 }, (_, index) => ({
        id: `msg-${index}`,
        kind: "agent_text" as const,
        createdAt: "2026-05-03T00:00:00.000Z",
        text: `message ${index} ${"large text ".repeat(1_000)}`,
      })),
    });

    const [compact] = compactSessionsForSnapshot([session]);

    expect(compact.piSessionFilePath).toBe("/tmp/explicit-picky.jsonl");
    expect(compact.logs.length).toBeLessThanOrEqual(16);
    expect(compact.logs).toContain("pi session: /tmp/picky.jsonl");
    expect(compact.logs).toContain("steer: keep this visible in the HUD");
    expect(compact.logs.at(-1)).toBe("latest useful log");
    expect(compact.tools.length).toBeLessThanOrEqual(200);
    expect(compact.tools.length).toBeGreaterThan(12);
    expect(compact.tools.at(-1)?.preview?.length).toBeLessThanOrEqual(241);
    expect(compact.changedFiles.length).toBeLessThanOrEqual(20);
    expect(compact.changedFiles.at(-1)?.summary?.length).toBeLessThanOrEqual(241);
    expect(compact.finalAnswer?.length).toBeLessThanOrEqual(1_501);
    expect(compact.messages?.length).toBeLessThanOrEqual(12);
    expect(compact.messages?.[0]?.id).toBe("msg-68");
    expect(compact.messages?.at(-1)?.text?.length).toBeLessThanOrEqual(701);
    expect(JSON.stringify(compact).length).toBeLessThan(120_000);
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

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function context(text: string): PickyContextPacket {
  return {
    id: `context-${text}`,
    source: "text",
    capturedAt: "2026-05-01T00:00:00.000Z",
    transcript: text,
    cwd: "/tmp/project",
    screenshots: [],
    inkMarks: [],
  warnings: [],
  };
}
