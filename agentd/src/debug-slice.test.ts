import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PROTOCOL_VERSION, type EventEnvelope, type PickyContextPacket } from "./protocol.js";
import { MockRuntime, type MockRuntimeSession } from "./runtime/mock-runtime.js";
import { AgentdServer } from "./server.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

/**
 * End-to-end through the real WebSocket server: the debug slice only matters if an
 * external client can drive the app, read the trace ring, and be refused when it is
 * not the app. The trace ring is process-wide, so every read here is cursor-relative
 * to a baseline taken in the same test.
 */
let server: AgentdServer;
let port: number;
let supervisor: SessionSupervisor;
const temporaryDirectories: string[] = [];

beforeEach(async () => {
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-debug-test-"));
  temporaryDirectories.push(dir);
  supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir));
  await supervisor.load();
  server = new AgentdServer({ port: 0, token: "test-token", supervisor });
  port = await server.start();
});

afterEach(async () => {
  await server.stop();
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("debug slice", () => {
  it("drives the app through its own socket and returns the app's result to the caller", async () => {
    const app = await connect();
    await registerDebugControl(app, "register-debug-app");
    const cli = await connect();

    cli.send(JSON.stringify({ id: "cmd-debug-text", protocolVersion: PROTOCOL_VERSION, type: "debugApp", action: "text", text: "trace this input" }));
    const requested = await waitForEvent(app, "debugAppRequested");
    expect(requested).toMatchObject({ commandId: "cmd-debug-text", action: "text", text: "trace this input" });
    const requestId = (requested as { requestId: string }).requestId;

    // A socket that never received the request cannot answer for the app.
    cli.send(JSON.stringify({ id: "cmd-debug-forged", protocolVersion: PROTOCOL_VERSION, type: "completeDebugApp", requestId, result: { accepted: false } }));
    await waitForEvent(cli, "ack");
    await expect(eventWithin(cli, "debugAppResult", 100)).resolves.toBeUndefined();

    app.send(JSON.stringify({
      id: "cmd-debug-complete",
      protocolVersion: PROTOCOL_VERSION,
      type: "completeDebugApp",
      requestId,
      result: { schemaVersion: 1, accepted: true, inputId: "app-input-1" },
    }));
    await expect(waitForEvent(cli, "debugAppResult")).resolves.toMatchObject({
      commandId: "cmd-debug-text",
      requestId,
      result: { schemaVersion: 1, accepted: true, inputId: "app-input-1" },
    });

    app.close();
    cli.close();
  });

  it("fails with a bounded error code when no app offers debug control", async () => {
    const cli = await connect();
    cli.send(JSON.stringify({ id: "cmd-debug-unavailable", protocolVersion: PROTOCOL_VERSION, type: "debugApp", action: "snapshot" }));

    await expect(waitForEvent(cli, "error")).resolves.toMatchObject({
      commandId: "cmd-debug-unavailable",
      code: "DEBUG_APP_CONTROL_UNAVAILABLE",
    });
    cli.close();
  });

  it("rejects an app action whose text does not match the action", async () => {
    const cli = await connect();
    cli.send(JSON.stringify({ id: "cmd-debug-missing-text", protocolVersion: PROTOCOL_VERSION, type: "debugApp", action: "text" }));
    await expect(waitForEvent(cli, "error")).resolves.toMatchObject({ commandId: "cmd-debug-missing-text", code: "bad_message" });

    cli.send(JSON.stringify({ id: "cmd-debug-stray-text", protocolVersion: PROTOCOL_VERSION, type: "debugApp", action: "pttPress", text: "nope" }));
    await expect(waitForEvent(cli, "error")).resolves.toMatchObject({ commandId: "cmd-debug-stray-text", code: "bad_message" });
    cli.close();
  });

  it("accepts trace records only from the registered debug-control app", async () => {
    const cli = await connect();
    cli.send(JSON.stringify({
      id: "cmd-publish-forbidden",
      protocolVersion: PROTOCOL_VERSION,
      type: "publishDebugTrace",
      records: [appRecord("app.input.captured")],
    }));
    await expect(waitForEvent(cli, "error")).resolves.toMatchObject({
      commandId: "cmd-publish-forbidden",
      code: "DEBUG_TRACE_PUBLISH_FORBIDDEN",
    });

    cli.send(JSON.stringify({
      id: "cmd-publish-daemon-source",
      protocolVersion: PROTOCOL_VERSION,
      type: "publishDebugTrace",
      records: [{ ...appRecord("app.input.captured"), source: "daemon" }],
    }));
    await expect(waitForEvent(cli, "error")).resolves.toMatchObject({ commandId: "cmd-publish-daemon-source", code: "bad_message" });
    cli.close();
  });

  it("serves published app records in daemon receipt order from the caller's cursor", async () => {
    const app = await connect();
    await registerDebugControl(app, "register-debug-publish");
    const baseline = await readTrace(app, "cmd-trace-baseline");

    app.send(JSON.stringify({
      id: "cmd-publish-records",
      protocolVersion: PROTOCOL_VERSION,
      type: "publishDebugTrace",
      records: [
        appRecord("app.input.captured", { inputId: "input-7", commandId: "cmd-debug-text", modality: "text", textLength: 16 }),
        appRecord("app.context.assembled", { inputId: "input-7", contextId: "context-7" }),
      ],
    }));
    await waitForEvent(app, "ack");

    const page = await readTrace(app, "cmd-trace-after-publish", { afterSequence: baseline.nextSequence });
    expect(page.instanceId).toBe(baseline.instanceId);
    expect(page.truncated).toBe(false);
    expect(page.records.map((record) => record.name)).toEqual(["app.input.captured", "app.context.assembled"]);
    expect(page.records[0]).toMatchObject({ source: "app", inputId: "input-7", commandId: "cmd-debug-text", textLength: 16 });
    expect(page.records[0]!.sequence).toBeLessThan(page.records[1]!.sequence);
    expect(typeof page.records[0]!.receivedAt).toBe("string");

    const empty = await readTrace(app, "cmd-trace-drained", { afterSequence: page.nextSequence });
    expect(empty.records).toEqual([]);
    expect(empty.nextSequence).toBe(page.nextSequence);
    app.close();
  });

  it.each(["followUp", "steer"])("correlates a Pickle %s input with its source context without tracing its text", async (type) => {
    const created = await supervisor.create(context("pickle-seed"));
    const cli = await connect();
    const baseline = await readTrace(cli, "pickle-baseline");
    const inputContext = { ...context("voice-context"), source: "voice-follow-up", transcript: "PRIVATE FOLLOWUP" };
    cli.send(JSON.stringify({ id: "pickle-input-command", protocolVersion: PROTOCOL_VERSION, type, sessionId: created.id, text: "PRIVATE FOLLOWUP", context: inputContext }));
    await waitForMatchingEvent(cli, (event) => event.type === "ack" && event.commandId === "pickle-input-command");
    const trace = await readTrace(cli, "pickle-after", { afterSequence: baseline.nextSequence });
    expect(trace.records).toContainEqual(expect.objectContaining({ name: "pickle.input.received", contextId: "voice-context", sessionId: created.id, commandId: "pickle-input-command", event: type, modality: "audio" }));
    if (type === "followUp") expect(trace.records).toContainEqual(expect.objectContaining({ name: "pickle.followUp.requested", contextId: "voice-context", sessionId: created.id }));
    expect(JSON.stringify(trace)).not.toContain("PRIVATE FOLLOWUP");
    cli.close();
  });

  it("records which live turn a new input supersedes without attributing replacement to the new turn", async () => {
    const runtime = await useMainRuntime();
    const cli = await connect();
    const baseline = await readTrace(cli, "replace-baseline");
    for (const id of ["old-input", "new-input"]) {
      cli.send(JSON.stringify({ id, protocolVersion: PROTOCOL_VERSION, type: "routeTask", context: context(id) }));
      await waitForMatchingEvent(cli, (event) => event.type === "ack" && event.commandId === id);
      if (id === "old-input") runtime.handle!.emit({ type: "status", status: "running" });
    }
    const trace = await readTrace(cli, "replace-trace", { afterSequence: baseline.nextSequence });
    const started = trace.records.find((record) => record.name === "main.turn.started" && record.contextId === "new-input");
    expect(started).toBeDefined();
    expect(trace.records).toContainEqual(expect.objectContaining({ name: "main.turn.superseded", contextId: "old-input", target: started!.inputId, outcome: "contextReplaced" }));
    runtime.handle!.emit({ type: "status", status: "completed" });
    await waitForEvent(cli, "mainTurnSettled");
    cli.close();
  });

  it("distinguishes resumed compaction-buffered input from its first acceptance", async () => {
    const runtime = await useMainRuntime();
    const cli = await connect();
    cli.send(JSON.stringify({ id: "warm-input", protocolVersion: PROTOCOL_VERSION, type: "routeTask", context: context("warm-input") }));
    await waitForMatchingEvent(cli, (event) => event.type === "ack" && event.commandId === "warm-input");
    runtime.handle!.isCompacting = true;
    const baseline = await readTrace(cli, "buffer-baseline");
    cli.send(JSON.stringify({ id: "buffered-input", protocolVersion: PROTOCOL_VERSION, type: "routeTask", context: { ...context("buffered-input"), transcript: "after compaction" } }));
    await waitForMatchingEvent(cli, (event) => event.type === "ack" && event.commandId === "buffered-input");
    runtime.handle!.isCompacting = false;
    runtime.handle!.emit({ type: "status", status: "completed" });
    await waitForMatchingEvent(cli, (event) => event.type === "mainMessageAppended" && event.message.text === "after compaction");
    const trace = await readTrace(cli, "buffer-trace", { afterSequence: baseline.nextSequence });
    const names = trace.records.filter((record) => record.contextId === "buffered-input").map((record) => record.name);
    expect(names).toEqual(["main.input.accepted", "main.input.buffered", "main.input.resumed", "main.turn.started", "main.prompt.delivered"]);
    runtime.handle!.emit({ type: "status", status: "completed" });
    await waitForMatchingEvent(cli, (event) => event.type === "mainTurnSettled" && event.contextId === "buffered-input");
    cli.close();
  });

  it.each(["terminal", "step"])("traces a real main-agent %s reply and terminal state under one context id", async (replyPath) => {
    const mainRuntime = await useMainRuntime();

    const cli = await connect();
    const baseline = await readTrace(cli, "cmd-main-baseline");

    cli.send(JSON.stringify({ id: "cmd-main-route", protocolVersion: PROTOCOL_VERSION, type: "routeTask", context: context("context-main-trace") }));
    await waitForMatchingEvent(cli, (event) => event.type === "ack" && event.commandId === "cmd-main-route");
    expect(mainRuntime.handle).toBeDefined();
    mainRuntime.handle!.emit({ type: "assistant_delta", delta: "Done." });
    if (replyPath === "step") {
      mainRuntime.handle!.emit({ type: "turn_text_complete", text: "Done." });
      await waitForEvent(cli, "quickReply");
    }
    mainRuntime.handle!.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitForEvent(cli, replyPath === "step" ? "mainTurnSettled" : "quickReply");

    const page = await readTrace(cli, "cmd-main-trace", { afterSequence: baseline.nextSequence, limit: 500 });
    const mine = page.records.filter((record) => record.contextId === "context-main-trace");
    expect(mine.map((record) => record.name)).toEqual([
      "main.input.accepted",
      "main.turn.started",
      "main.prompt.delivered",
      "main.response.firstDelta",
      ...(replyPath === "step" ? ["main.reply.emitted", "main.turn.settled"] : ["main.turn.settled", "main.reply.emitted"]),
    ]);
    expect(mine[0]).toMatchObject({ source: "daemon", modality: "text", textLength: "route this".length });
    // The turn's runtime input id links delivery, first token, and reply to the same turn.
    const turnInputIds = new Set(mine.slice(1).map((record) => record.inputId));
    expect(turnInputIds.size).toBe(1);
    expect([...turnInputIds][0]).toBeTruthy();
    expect(mine.find((record) => record.name === "main.reply.emitted")).toMatchObject({ textLength: "Done.".length, outcome: "emitted" });
    expect(mine.find((record) => record.name === "main.turn.settled")).toMatchObject({ state: "idle", outcome: "completed" });
    cli.close();
  });
});

async function useMainRuntime(): Promise<TrackingMainRuntime> {
  await server.stop();
  const dir = await mkdtemp(join(tmpdir(), "picky-agentd-debug-main-"));
  temporaryDirectories.push(dir);
  const mainRuntime = new TrackingMainRuntime();
  supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir), { mainRuntime });
  await supervisor.load();
  server = new AgentdServer({ port: 0, token: "test-token", supervisor });
  port = await server.start();
  return mainRuntime;
}

class TrackingMainRuntime extends MockRuntime {
  handle?: MockRuntimeSession;

  override async create(...args: Parameters<MockRuntime["create"]>): Promise<MockRuntimeSession> {
    const handle = await super.create(...args) as MockRuntimeSession;
    this.handle = handle;
    return handle;
  }
}

interface TracePage {
  instanceId: string;
  oldestSequence: number;
  nextSequence: number;
  truncated: boolean;
  records: { name: string; sequence: number; receivedAt: string; source: string; contextId?: string; inputId?: string }[];
}

async function readTrace(ws: WebSocket, id: string, query: { afterSequence?: number; limit?: number } = {}): Promise<TracePage> {
  ws.send(JSON.stringify({ id, protocolVersion: PROTOCOL_VERSION, type: "readDebugTrace", ...query }));
  const event = await waitForMatchingEvent(ws, (candidate) => candidate.type === "debugTrace" && (candidate as { commandId?: string }).commandId === id);
  return event as unknown as TracePage;
}

function appRecord(name: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source: "app",
    name,
    timestamp: "2026-10-09T05:00:00.000Z",
    monotonicMs: 42.5,
    ...overrides,
  };
}

function context(id: string): PickyContextPacket {
  return {
    id,
    source: "text",
    capturedAt: "2026-10-09T05:00:00.000Z",
    transcript: "route this",
    cwd: "/tmp/project",
    screenshots: [],
    inkMarks: [],
    warnings: [],
  };
}

async function connect(): Promise<WebSocket> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}?token=test-token`);
  trackEvents(ws);
  await once(ws, "open");
  return ws;
}

async function registerDebugControl(ws: WebSocket, id: string): Promise<void> {
  ws.send(JSON.stringify({ id, protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["debugControl"] }));
  await waitForMatchingEvent(ws, (event) => event.type === "ack" && (event as { commandId?: string }).commandId === id);
}

const eventBuffers = new WeakMap<WebSocket, EventEnvelope[]>();

function trackEvents(ws: WebSocket): EventEnvelope[] {
  const existing = eventBuffers.get(ws);
  if (existing) return existing;
  const buffer: EventEnvelope[] = [];
  eventBuffers.set(ws, buffer);
  ws.on("message", (data) => buffer.push(JSON.parse(data.toString()) as EventEnvelope));
  return buffer;
}

async function waitForEvent(ws: WebSocket, type: EventEnvelope["type"], timeoutMs = 2_000): Promise<EventEnvelope> {
  return waitForMatchingEvent(ws, (event) => event.type === type, timeoutMs);
}

async function waitForMatchingEvent(ws: WebSocket, predicate: (event: EventEnvelope) => boolean, timeoutMs = 2_000): Promise<EventEnvelope> {
  const buffer = trackEvents(ws);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const index = buffer.findIndex((event) => predicate(event));
    if (index >= 0) return buffer.splice(index, 1)[0]!;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Timed out waiting for event; buffered=${buffer.map((event) => event.type).join(",")}`);
}

async function eventWithin(ws: WebSocket, type: EventEnvelope["type"], timeoutMs: number): Promise<EventEnvelope | undefined> {
  try {
    return await waitForEvent(ws, type, timeoutMs);
  } catch {
    return undefined;
  }
}
