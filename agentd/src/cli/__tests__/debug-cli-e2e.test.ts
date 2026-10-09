import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { writeConnectionInfo } from "../../connection-info-store.js";
import { PROTOCOL_VERSION, type EventEnvelope } from "../../protocol.js";
import { MockRuntime } from "../../runtime/mock-runtime.js";
import { AgentdServer } from "../../server.js";
import { SessionStore } from "../../session-store.js";
import { SessionSupervisor } from "../../session-supervisor.js";
import { DebugClient } from "../debug-client.js";

const execute = promisify(execFile);
const entry = fileURLToPath(new URL("../../debug-cli.ts", import.meta.url));
const loader = fileURLToPath(new URL("../../../node_modules/tsx/dist/loader.mjs", import.meta.url));
let server: AgentdServer;
let support: string;
let port: number;
let app: WebSocket | undefined;

beforeEach(async () => {
  support = await mkdtemp(join(tmpdir(), "picky-debug-e2e-"));
  const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(support));
  await supervisor.load();
  server = new AgentdServer({ port: 0, token: "debug-test-token", supervisor });
  port = await server.start();
  await writeConnectionInfo(support, { protocolVersion: PROTOCOL_VERSION, url: `ws://127.0.0.1:${port}`, token: "debug-test-token", port, pid: process.pid, appSupportDir: support, defaultCwd: support, startedAt: new Date().toISOString() });
});

afterEach(async () => {
  app?.terminate();
  app = undefined;
  await server.stop();
  await rm(support, { recursive: true, force: true });
});

async function run(args: string[]) {
  // Only the isolated connection directory crosses into the CLI process.
  const env = { PATH: process.env.PATH, HOME: support, PICKY_APP_SUPPORT_DIR: support };
  try {
    const result = await execute(process.execPath, ["--import", loader, entry, ...args], { env, timeout: 10000 });
    return { ...result, code: 0 };
  } catch (error) {
    const result = error as { stdout: string; stderr: string; code: number };
    return { stdout: result.stdout, stderr: result.stderr, code: result.code };
  }
}

async function connectApp(handle: (event: EventEnvelope, socket: WebSocket) => void) {
  app = new WebSocket(`ws://127.0.0.1:${port}?token=debug-test-token`);
  const socket = app;
  const registration = new Promise<void>((resolve) => {
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString()) as EventEnvelope;
      if (event.type === "ack" && event.commandId === "register-debug-app") resolve();
      handle(event, socket);
    });
  });
  await once(socket, "open");
  send(socket, { id: "register-debug-app", type: "registerAppCapabilities", capabilities: ["debugControl"], profile: "desktop" });
  await registration;
}

function send(socket: WebSocket, command: Record<string, unknown>) {
  socket.send(JSON.stringify({ id: `app-${randomUUID()}`, protocolVersion: PROTOCOL_VERSION, ...command }));
}

describe("picky-debug CLI against a real isolated daemon", () => {
  it("reads app state and links an explicitly executed text input to redacted trace records", async () => {
    let inputs = 0;
    await connectApp((event, socket) => {
      if (event.type !== "debugAppRequested") return;
      if (event.action === "text") {
        inputs += 1;
        send(socket, { type: "publishDebugTrace", records: [{ source: "app", name: "input.accepted", timestamp: new Date().toISOString(), monotonicMs: 100, inputId: "input-test", contextId: "context-test", commandId: event.commandId, modality: "text", textLength: event.text?.length }] });
      }
      send(socket, { type: "completeDebugApp", requestId: event.requestId, result: { schemaVersion: 1, voiceState: "idle", ...(event.action === "text" ? { inputId: "input-test" } : {}) } });
    });
    const state = await run(["state"]);
    expect(state, state.stderr).toMatchObject({ code: 0 });
    expect(JSON.parse(state.stdout).result).toMatchObject({ schemaVersion: 1, voiceState: "idle" });
    expect(inputs).toBe(0);
    const text = await run(["text", "PRIVATE INPUT DO NOT TRACE", "--execute"]);
    expect(text, text.stderr).toMatchObject({ code: 0 });
    expect(JSON.parse(text.stdout).result.inputId).toBe("input-test");
    expect(inputs).toBe(1);
    const trace = await run(["timeline", "--input", "input-test"]);
    expect(trace, trace.stderr).toMatchObject({ code: 0 });
    const records = JSON.parse(trace.stdout).records;
    expect(records).toContainEqual(expect.objectContaining({ source: "app", inputId: "input-test", contextId: "context-test", commandId: JSON.parse(text.stdout).commandId, sourceElapsedMs: 0 }));
    expect(trace.stdout).not.toContain("PRIVATE INPUT");
    expect(trace.stdout).not.toContain("debug-test-token");
  });

  it("refuses controls without --execute and invalid PTT actions before reaching the app", async () => {
    let requests = 0;
    await connectApp((event) => { if (event.type === "debugAppRequested") requests += 1; });
    for (const args of [["text", "hello"], ["ptt", "press"], ["ptt", "bogus", "--execute"], ["trace", "--limit", "0"]]) {
      const result = await run(args);
      expect(result.code).toBe(64);
    }
    expect(requests).toBe(0);
  });

  it("sends PTT press and release exactly once and reports the app acknowledgement", async () => {
    const actions: string[] = [];
    await connectApp((event, socket) => {
      if (event.type !== "debugAppRequested") return;
      actions.push(event.action);
      send(socket, { type: "completeDebugApp", requestId: event.requestId, result: { schemaVersion: 1, action: event.action } });
    });
    expect((await run(["ptt", "press", "--execute"])).code).toBe(0);
    expect((await run(["ptt", "release", "--execute"])).code).toBe(0);
    expect(actions).toEqual(["pttPress", "pttRelease"]);
  });

  it("fails clearly when the connected app does not offer debugging", async () => {
    const result = await run(["state"]);
    expect(result.code).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toMatch(/debug|app/i);
  });

  it("does not retry a control when the app disconnects before acknowledging it", async () => {
    let deliveries = 0;
    await connectApp((event, socket) => {
      if (event.type === "debugAppRequested") { deliveries += 1; socket.close(); }
    });
    const result = await run(["text", "once only", "--execute"]);
    expect(result.code).toBe(1);
    expect(deliveries).toBe(1);
    expect(result.stdout).toBe("");
  });

  it("continues across trace pages and exposes its capture bound and ring eviction", async () => {
    await connectApp(() => {});
    const socket = app!;
    async function publish(count: number, inputId: string) {
      for (let offset = 0; offset < count; offset += 100) {
        send(socket, { type: "publishDebugTrace", records: Array.from({ length: Math.min(100, count - offset) }, (_, index) => ({ source: "app", name: "input.transition", timestamp: new Date().toISOString(), monotonicMs: offset + index, inputId })) });
      }
      const barrier = new Promise<void>((resolve) => {
        const receive = (data: WebSocket.RawData) => {
          const event = JSON.parse(data.toString());
          if (event.commandId === "published-barrier") { socket.off("message", receive); resolve(); }
        };
        socket.on("message", receive);
      });
      send(socket, { id: "published-barrier", type: "readDebugTrace", limit: 1 });
      await barrier;
    }
    const observer = await DebugClient.connect({ url: `ws://127.0.0.1:${port}`, token: "debug-test-token", port, appSupportDir: support }, 1000);
    let before = 0;
    try {
      while (true) {
        const page = await observer.request({ type: "readDebugTrace", afterSequence: before, limit: 500 }, "debugTrace", 1000);
        before = page.nextSequence;
        if (page.records.length < 500) break;
      }
    } finally { observer.close(); }
    await publish(6, "paged-input");
    const complete = await run(["timeline", "--after", String(before), "--limit", "2", "--input", "paged-input"]);
    expect(complete, complete.stderr).toMatchObject({ code: 0 });
    const history = JSON.parse(complete.stdout);
    expect(history.records).toHaveLength(6);
    expect(new Set(history.records.map((record: { sequence: number }) => record.sequence)).size).toBe(6);
    expect(history.captureLimitReached).toBe(false);
    await publish(2100, "evicted-input");
    const bounded = await run(["timeline", "--limit", "2", "--input", "evicted-input"]);
    expect(bounded, bounded.stderr).toMatchObject({ code: 0 });
    expect(JSON.parse(bounded.stdout)).toMatchObject({ truncated: true, captureLimitReached: true });
    expect(JSON.parse(bounded.stdout).records).toHaveLength(20);
  });

  it("watches metadata pages on a bounded connection without app control requests", async () => {
    let requests = 0;
    await connectApp((event) => { if (event.type === "debugAppRequested") requests += 1; });
    const result = await run(["watch", "--duration", "1", "--interval", "50"]);
    expect(result, result.stderr).toMatchObject({ code: 0 });
    const pages = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
    expect(pages[0]).toMatchObject({ type: "debugTrace", records: expect.any(Array), instanceId: expect.any(String) });
    expect(requests).toBe(0);
  });

  it("rejects non-loopback discovery URLs before transmitting the token", async () => {
    await expect(DebugClient.connect({ url: "ws://example.com", token: "secret", port: 80, appSupportDir: support }, 100)).rejects.toThrow("loopback");
  });
});
