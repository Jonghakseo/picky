import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import WebSocket from "ws";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, PickyAgentSessionSchema, parseCommand, type EventEnvelope, type PickyAgentSession, type PickyContextPacket, type PickyExtensionUiRequest } from "./protocol.js";
import { MockRuntime, type MockRuntimeSession } from "./runtime/mock-runtime.js";
import { AgentdServer, commandLogFields, compactSessionsForSnapshot, createDefaultPackageManager, sanitizeForJson } from "./server.js";
import { boundedSessionForAppHydration } from "./application/app-session-snapshot-policy.js";
import { EdgeTTSService, type EdgeTTSClient } from "./edge-tts-service.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import type { PiOAuthHandling } from "./application/pi-oauth-service.js";

let server: AgentdServer;
let port: number;
let supervisor: SessionSupervisor;

class TrackingMainRuntime extends MockRuntime {
  handle?: MockRuntimeSession;

  override async create(...args: Parameters<MockRuntime["create"]>): Promise<MockRuntimeSession> {
    const handle = await super.create(...args) as MockRuntimeSession;
    this.handle = handle;
    return handle;
  }
}

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

  it("keeps negotiating sockets free of legacy session projection broadcasts", async () => {
    const { ws } = await connectWithHello();
    trackEvents(ws);

    await supervisor.create(context("negotiating projection"));
    ws.send(JSON.stringify({ id: "cmd-negotiating-control", protocolVersion: PROTOCOL_VERSION, type: "listMainMessages" }));
    await waitForEvent(ws, "ack");

    expect(eventBuffers.get(ws)?.filter((event) => event.type === "sessionUpdated" || event.type === "sessionMetaUpdated")).toEqual([]);
    ws.close();
  });

  it("locks no-capability CLI projection commands to v1", async () => {
    const session = await supervisor.create(context("legacy cli projection"));
    const { ws } = await connectWithHello();
    trackEvents(ws);

    ws.send(JSON.stringify({ id: "cmd-legacy-cli-list", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await expect(waitForEvent(ws, "sessionSnapshot")).resolves.toMatchObject({ sessions: [{ id: session.id }] });
    await waitForEvent(ws, "ack");

    await (supervisor as unknown as {
      patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
    }).patch(session.id, { status: "completed" });
    await expect(waitForEvent(ws, "sessionMetaUpdated")).resolves.toMatchObject({ session: { id: session.id, status: "completed" } });
    ws.close();
  });

  it("locks older app capabilities to v1 and preserves the bounded bootstrap path", async () => {
    const session = await supervisor.create(context("legacy app projection"));
    const { ws } = await connectWithHello();
    trackEvents(ws);

    ws.send(JSON.stringify({
      id: "cmd-register-legacy-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(ws, "ack");
    ws.send(JSON.stringify({ id: "cmd-legacy-app-list", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await expect(waitForEvent(ws, "sessionSnapshot")).resolves.toMatchObject({ sessions: [{ id: session.id, messages: [] }] });
    await expect(waitForEvent(ws, "sessionUpdated")).resolves.toMatchObject({ session: { id: session.id } });
    await waitForEvent(ws, "ack");
    ws.close();
  });

  it("keeps v2 sockets free of legacy projections and rejects a dialect change", async () => {
    const session = await supervisor.create(context("v2 projection filtering"));
    const { ws } = await connectWithHello();
    trackEvents(ws);

    ws.send(JSON.stringify({
      id: "cmd-register-v2-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["sessionProjectionV2"],
    }));
    await waitForEvent(ws, "ack");
    ws.send(JSON.stringify({ id: "cmd-v2-direct-session", protocolVersion: PROTOCOL_VERSION, type: "getSession", sessionId: session.id }));
    await waitForEvent(ws, "ack");
    ws.send(JSON.stringify({
      id: "cmd-reregister-v1-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await expect(waitForEvent(ws, "error")).resolves.toMatchObject({
      commandId: "cmd-reregister-v1-app",
      message: "Socket dialect is locked to v2; cannot change to v1",
    });

    await (supervisor as unknown as {
      patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
    }).patch(session.id, { status: "completed" });
    ws.send(JSON.stringify({ id: "cmd-v2-control", protocolVersion: PROTOCOL_VERSION, type: "listMainMessages" }));
    await waitForEvent(ws, "ack");

    expect(eventBuffers.get(ws)?.filter((event) => event.type === "sessionUpdated" || event.type === "sessionMetaUpdated" || event.type === "sessionSnapshot")).toEqual([]);
    ws.close();
  });

  it("rejects recovery snapshots before a socket locks v2", async () => {
    const session = await supervisor.create(context("v1 recovery rejected"));
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-v1-list", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitForEvent(ws, "sessionSnapshot");
    await waitForEvent(ws, "ack");

    ws.send(JSON.stringify({
      id: "cmd-v1-projection-recovery",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionProjectionSnapshot",
      requestId: "recovery-v1",
      sessionId: session.id,
    }));
    await expect(waitForEvent(ws, "error")).resolves.toMatchObject({
      commandId: "cmd-v1-projection-recovery",
      message: "Session projection recovery requires v2 socket dialect",
    });
    ws.close();
  });

  it("broadcasts bounded patch metadata while full snapshots retain journal hydration", async () => {
    const { ws } = await connectWithHello();
    // An unregistered CLI locks v1 on its first legacy projection command.
    ws.send(JSON.stringify({ id: "cmd-lock-thin-meta-v1", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitForEvent(ws, "sessionSnapshot");
    await waitForEvent(ws, "ack");
    const session = await supervisor.create(context("thin metadata update"));
    const message = {
      id: "message-hydration",
      kind: "agent_text" as const,
      createdAt: "2026-08-23T00:00:00.000Z",
      text: "Retain this in the reconnect snapshot",
    };
    const largeLog = "x".repeat(1_000_000);
    const accumulatedTools = Array.from({ length: 200 }, (_, index) => ({
      toolCallId: `tool-${index}`,
      name: "bash",
      status: "succeeded" as const,
      preview: "p".repeat(400),
    }));
    await (supervisor as unknown as {
      upsert(session: PickyAgentSession, options: { emitSession: boolean }): Promise<void>;
    }).upsert({ ...session, messages: [message], logs: [largeLog], tools: accumulatedTools }, { emitSession: false });

    const metaUpdate = nextEvent(ws);
    await (supervisor as unknown as {
      patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
    }).patch(session.id, { status: "completed", lastSummary: "Done" });

    await expect(metaUpdate).resolves.toMatchObject({
      type: "sessionMetaUpdated",
      session: { id: session.id, status: "completed", lastSummary: "Done" },
    });
    const event = await metaUpdate;
    if (event.type === "sessionMetaUpdated") {
      expect(event.session).not.toHaveProperty("messages");
      expect(event.session).not.toHaveProperty("logs");
      expect(event.session).not.toHaveProperty("tools");
      expect(Buffer.byteLength(JSON.stringify(event))).toBeLessThan(2_000);
    }

    ws.send(JSON.stringify({ id: "cmd-list-thin-meta", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    const snapshot = await waitForEvent(ws, "sessionSnapshot");
    expect(snapshot).toMatchObject({
      sessions: [{ id: session.id, messages: [message] }],
    });
    if (snapshot.type === "sessionSnapshot") {
      const hydratedSession = snapshot.sessions.find((candidate) => candidate.id === session.id);
      expect(hydratedSession?.logs).toEqual([`${"x".repeat(600)}…`]);
      expect(hydratedSession?.tools).toHaveLength(accumulatedTools.length);
    }
    ws.close();
  });

  it("hydrates registered app sessions without exceeding the WebSocket frame budget", async () => {
    const sessions = makeLargeSessionSnapshotFixtures();
    vi.spyOn(supervisor, "list").mockReturnValue(sessions);

    const { ws } = await connectWithHello();
    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({
      id: "cmd-register-large-snapshot-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    ws.send(JSON.stringify({ id: "cmd-list-large-app-snapshot", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitUntil(() => rawFrames.some((frame) => {
      const event = JSON.parse(frame) as EventEnvelope;
      return event.type === "ack" && event.commandId === "cmd-list-large-app-snapshot";
    }));
    ws.off("message", captureFrame);

    const events = rawFrames.map((frame) => JSON.parse(frame) as EventEnvelope);
    const snapshot = events.find((event) => event.type === "sessionSnapshot");
    const hydrationEvents = events.filter((event) => event.type === "sessionUpdated");
    expect(snapshot).toMatchObject({
      type: "sessionSnapshot",
      sessions: sessions.map((session) => ({ id: session.id, messages: [], messageJournalAvailable: false })),
    });
    expect(hydrationEvents).toHaveLength(sessions.length);
    expect(hydrationEvents).toEqual(expect.arrayContaining(sessions.map((session) => expect.objectContaining({
      type: "sessionUpdated",
      session: expect.objectContaining({ id: session.id, messages: session.messages }),
    }))));
    expect(events.findIndex((event) => event.type === "sessionSnapshot")).toBeLessThan(events.findIndex((event) => event.type === "sessionUpdated"));
    expect(Math.max(...rawFrames.map((frame) => Buffer.byteLength(frame, "utf8")))).toBeLessThan(8 * 1024 * 1024);
    ws.close();
  });

  it("records a deterministic 94-session registered-app bootstrap budget", async () => {
    const sessions = makeNormalSessionBootstrapFixtures();
    vi.spyOn(supervisor, "list").mockReturnValue(sessions);

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-register-bootstrap-budget-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(ws, "ack");

    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({ id: "cmd-list-bootstrap-budget", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitUntil(() => rawFrames.some((frame) => {
      const event = JSON.parse(frame) as EventEnvelope;
      return event.type === "ack" && event.commandId === "cmd-list-bootstrap-budget";
    }));
    ws.off("message", captureFrame);

    const replayFrames = rawFrames
      .map((frame) => ({ frame, event: JSON.parse(frame) as EventEnvelope }))
      .filter(({ event }) => event.type === "sessionSnapshot" || event.type === "sessionUpdated");
    const budget = {
      frameCount: replayFrames.length,
      maxSingleFrameBytes: Math.max(...replayFrames.map(({ frame }) => Buffer.byteLength(frame, "utf8"))),
      totalEncodedBytes: replayFrames.reduce((total, { frame }) => total + Buffer.byteLength(frame, "utf8"), 0),
    };

    expect(replayFrames.map(({ event }) => event.type)).toEqual(["sessionSnapshot", ...Array(94).fill("sessionUpdated")]);
    expect(budget).toEqual({
      frameCount: 95,
      maxSingleFrameBytes: 48_455,
      totalEncodedBytes: 120_043,
    });
    // Exact fixture bytes ratchet projection changes; keep this independent transport cap.
    expect(budget.maxSingleFrameBytes).toBeLessThan(8 * 1024 * 1024);
    expect(sessions.map((session) => boundedSessionForAppHydration(PickyAgentSessionSchema.parse(session)).omittedFields)).toEqual(Array.from({ length: 94 }, () => []));
    ws.close();
  });

  it("reuses the bounded bootstrap route after registered-app reconnect", async () => {
    const sessions = makeNormalSessionBootstrapFixtures();
    vi.spyOn(supervisor, "list").mockReturnValue(sessions);

    const first = await connectWithHello();
    first.ws.send(JSON.stringify({
      id: "cmd-register-bootstrap-reconnect-first-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(first.ws, "ack");
    first.ws.close();
    await once(first.ws, "close");

    const replacement = await connectWithHello();
    replacement.ws.send(JSON.stringify({
      id: "cmd-register-bootstrap-reconnect-replacement-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(replacement.ws, "ack");

    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    replacement.ws.on("message", captureFrame);
    replacement.ws.send(JSON.stringify({ id: "cmd-list-bootstrap-reconnect", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitUntil(() => rawFrames.some((frame) => {
      const event = JSON.parse(frame) as EventEnvelope;
      return event.type === "ack" && event.commandId === "cmd-list-bootstrap-reconnect";
    }));
    replacement.ws.off("message", captureFrame);

    const replayFrames = rawFrames
      .map((frame) => ({ frame, event: JSON.parse(frame) as EventEnvelope }))
      .filter(({ event }) => event.type === "sessionSnapshot" || event.type === "sessionUpdated");
    const budget = {
      frameCount: replayFrames.length,
      maxSingleFrameBytes: Math.max(...replayFrames.map(({ frame }) => Buffer.byteLength(frame, "utf8"))),
      totalEncodedBytes: replayFrames.reduce((total, { frame }) => total + Buffer.byteLength(frame, "utf8"), 0),
    };

    expect(replayFrames.map(({ event }) => event.type)).toEqual(["sessionSnapshot", ...Array(94).fill("sessionUpdated")]);
    expect(budget).toEqual({ frameCount: 95, maxSingleFrameBytes: 48_455, totalEncodedBytes: 120_043 });
    expect(budget.maxSingleFrameBytes).toBeLessThan(8 * 1024 * 1024);
    expect(sessions.map((session) => boundedSessionForAppHydration(PickyAgentSessionSchema.parse(session)).omittedFields)).toEqual(Array.from({ length: 94 }, () => []));
    replacement.ws.close();
  });

  it("reuses the bounded bootstrap route after deletion for registered app clients", async () => {
    const sessions = makeNormalSessionBootstrapFixtures();
    vi.spyOn(supervisor, "list").mockReturnValue(sessions);
    vi.spyOn(supervisor, "deleteSession").mockResolvedValue();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-register-delete-bootstrap-budget-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(ws, "ack");

    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({
      id: "cmd-delete-bootstrap-budget",
      protocolVersion: PROTOCOL_VERSION,
      type: "deleteSession",
      sessionId: "deleted-session",
    }));
    await waitUntil(() => rawFrames.some((frame) => {
      const event = JSON.parse(frame) as EventEnvelope;
      return event.type === "ack" && event.commandId === "cmd-delete-bootstrap-budget";
    }));
    ws.off("message", captureFrame);

    const replayEvents = rawFrames
      .map((frame) => JSON.parse(frame) as EventEnvelope)
      .filter((event) => event.type === "sessionSnapshot" || event.type === "sessionUpdated");
    expect(replayEvents.map((event) => event.type)).toEqual(["sessionSnapshot", ...Array(94).fill("sessionUpdated")]);
    ws.close();
  });

  it("keeps the aggregate legacy snapshot for unregistered clients", async () => {
    const sessions = makeNormalSessionBootstrapFixtures();
    vi.spyOn(supervisor, "list").mockReturnValue(sessions);

    const { ws } = await connectWithHello();
    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({ id: "cmd-list-bootstrap-budget-legacy", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitUntil(() => rawFrames.some((frame) => {
      const event = JSON.parse(frame) as EventEnvelope;
      return event.type === "ack" && event.commandId === "cmd-list-bootstrap-budget-legacy";
    }));
    ws.off("message", captureFrame);

    const events = rawFrames.map((frame) => JSON.parse(frame) as EventEnvelope);
    const snapshots = events.filter((event) => event.type === "sessionSnapshot");
    expect(snapshots).toHaveLength(1);
    expect(events.filter((event) => event.type === "sessionUpdated")).toHaveLength(0);
    expect(snapshots[0]).toMatchObject({ type: "sessionSnapshot", sessions: sessions.map((session) => ({ id: session.id })) });
    ws.close();
  });

  it("degrades a single oversized session hydration instead of exceeding the app frame budget", async () => {
    const oversizedSession: PickyAgentSession = {
      id: "oversized-single-session",
      title: "Oversized single session",
      status: "completed",
      createdAt: "2026-08-23T00:00:00.000Z",
      updatedAt: "2026-08-23T00:00:01.000Z",
      logs: [],
      tools: [],
      artifacts: [],
      changedFiles: [],
      messages: [{
        id: "oversized-single-message",
        kind: "agent_text",
        createdAt: "2026-08-23T00:00:01.000Z",
        text: "m".repeat(9 * 1024 * 1024),
      }],
    };
    vi.spyOn(supervisor, "list").mockReturnValue([oversizedSession]);

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-register-oversized-session-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(ws, "ack");

    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({ id: "cmd-list-oversized-session", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitForEvent(ws, "ack");
    ws.off("message", captureFrame);

    const hydration = rawFrames
      .map((frame) => JSON.parse(frame) as EventEnvelope)
      .find((event) => event.type === "sessionUpdated");
    expect(hydration).toMatchObject({
      type: "sessionUpdated",
      session: { id: oversizedSession.id, messages: [], messageJournalAvailable: false },
    });
    expect(Math.max(...rawFrames.map((frame) => Buffer.byteLength(frame, "utf8")))).toBeLessThan(8 * 1024 * 1024);
    ws.close();
  });

  it("bounds registered app session snapshots broadcast after deletion", async () => {
    const sessions = makeLargeSessionSnapshotFixtures();
    vi.spyOn(supervisor, "list").mockReturnValue(sessions);
    vi.spyOn(supervisor, "deleteSession").mockResolvedValue();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-register-delete-snapshot-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(ws, "ack");

    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({
      id: "cmd-delete-large-snapshot-session",
      protocolVersion: PROTOCOL_VERSION,
      type: "deleteSession",
      sessionId: "deleted-session",
    }));
    await waitForEvent(ws, "ack");
    ws.off("message", captureFrame);

    const events = rawFrames.map((frame) => JSON.parse(frame) as EventEnvelope);
    expect(events.filter((event) => event.type === "sessionSnapshot")).toHaveLength(1);
    expect(events.filter((event) => event.type === "sessionUpdated")).toHaveLength(sessions.length);
    expect(Math.max(...rawFrames.map((frame) => Buffer.byteLength(frame, "utf8")))).toBeLessThan(8 * 1024 * 1024);
    ws.close();
  });

  it("returns a bounded error instead of an empty authoritative snapshot when metadata cannot fit", async () => {
    const oversizedMetadataSession = makeSession({
      id: "s".repeat(9 * 1024 * 1024),
      title: "Oversized metadata session",
    });
    vi.spyOn(supervisor, "list").mockReturnValue([oversizedMetadataSession]);

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-register-oversized-metadata-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleBridge"],
    }));
    await waitForEvent(ws, "ack");

    const rawFrames: string[] = [];
    const captureFrame = (data: WebSocket.RawData) => rawFrames.push(data.toString());
    ws.on("message", captureFrame);
    ws.send(JSON.stringify({ id: "cmd-list-oversized-metadata", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitForEvent(ws, "ack");
    ws.off("message", captureFrame);

    const events = rawFrames.map((frame) => JSON.parse(frame) as EventEnvelope);
    expect(events).toContainEqual(expect.objectContaining({
      type: "error",
      code: "session_snapshot_too_large",
    }));
    expect(events.some((event) => event.type === "sessionSnapshot")).toBe(false);
    expect(events.some((event) => event.type === "sessionUpdated")).toBe(false);
    expect(Math.max(...rawFrames.map((frame) => Buffer.byteLength(frame, "utf8")))).toBeLessThan(8 * 1024 * 1024);
    ws.close();
  });

  it("returns a bounded projection recovery snapshot only to its requesting socket", async () => {
    const requester = await connectWithHello();
    await registerV2(requester.ws, "cmd-register-recovery-requester");
    const observer = await connectWithHello();
    const session = await supervisor.create(context("projection recovery"));
    const oversizedSession = {
      ...session,
      messages: [{
        id: "oversized-projection-message",
        kind: "agent_text" as const,
        createdAt: "2026-08-24T00:00:00.000Z",
        text: "m".repeat(9 * 1024 * 1024),
      }],
    };
    await (supervisor as unknown as {
      upsert(session: PickyAgentSession, options: { emitSession: boolean }): Promise<void>;
    }).upsert(oversizedSession, { emitSession: false });

    const observerFrames: string[] = [];
    observer.ws.on("message", (data) => observerFrames.push(data.toString()));
    requester.ws.send(JSON.stringify({
      id: "cmd-projection-recovery",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionProjectionSnapshot",
      requestId: "recovery-001",
      sessionId: session.id,
    }));

    const recovery = await waitForEvent(requester.ws, "sessionProjectionSnapshot");
    await waitForEvent(requester.ws, "ack");
    expect(recovery).toMatchObject({
      requestId: "recovery-001",
      sessionId: session.id,
      complete: false,
      omittedFields: ["subagentRuns", "tools", "messages"],
      projection: { id: session.id, messages: [], messageJournalAvailable: false },
    });
    if (recovery.type === "sessionProjectionSnapshot") {
      expect(recovery.revision).toBeGreaterThanOrEqual(1);
      expect(recovery.projection.revision).toBe(recovery.revision);
    }
    expect(Buffer.byteLength(JSON.stringify(recovery), "utf8")).toBeLessThan(8 * 1024 * 1024);
    expect(observerFrames.map((frame) => JSON.parse(frame) as EventEnvelope).filter((event) => event.type === "sessionProjectionSnapshot")).toEqual([]);
    requester.ws.close();
    observer.ws.close();
  });

  it("rejects recovery for a missing projection session", async () => {
    const { ws } = await connectWithHello();
    await registerV2(ws, "cmd-register-missing-recovery");
    ws.send(JSON.stringify({
      id: "cmd-missing-projection-recovery",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionProjectionSnapshot",
      requestId: "recovery-missing",
      sessionId: "missing-session",
    }));

    await expect(waitForEvent(ws, "error")).resolves.toMatchObject({
      commandId: "cmd-missing-projection-recovery",
      message: "Unknown session: missing-session",
    });
    ws.close();
  });

  it("runs recovery snapshot publication through the supervisor projection barrier", async () => {
    const { ws } = await connectWithHello();
    await registerV2(ws, "cmd-register-projection-barrier");
    const session = await supervisor.create(context("projection barrier"));
    const barrier = vi.spyOn(supervisor, "withSessionProjectionBarrier");

    ws.send(JSON.stringify({
      id: "cmd-projection-barrier",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionProjectionSnapshot",
      requestId: "recovery-barrier",
      sessionId: session.id,
    }));

    await waitForEvent(ws, "sessionProjectionSnapshot");
    expect(barrier).toHaveBeenCalledWith(session.id, expect.any(Function));
    ws.close();
  });

  it("rejects a duplicate recovery request for the same socket and session while the first is in flight", async () => {
    const { ws } = await connectWithHello();
    await registerV2(ws, "cmd-register-duplicate-recovery");
    trackEvents(ws);
    const session = await supervisor.create(context("duplicate projection recovery"));
    let entered!: () => void;
    const enteredBarrier = new Promise<void>((resolve) => { entered = resolve; });
    let release!: () => void;
    const releaseBarrier = new Promise<void>((resolve) => { release = resolve; });
    vi.spyOn(supervisor, "withSessionProjectionBarrier").mockImplementationOnce(async (_, work) => {
      entered();
      await releaseBarrier;
      await work({ session: supervisor.get(session.id)!, epoch: "test-epoch" });
    });

    ws.send(JSON.stringify({
      id: "cmd-projection-first",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionProjectionSnapshot",
      requestId: "recovery-first",
      sessionId: session.id,
    }));
    await enteredBarrier;
    ws.send(JSON.stringify({
      id: "cmd-projection-duplicate",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionProjectionSnapshot",
      requestId: "recovery-duplicate",
      sessionId: session.id,
    }));

    await expect(waitForEvent(ws, "error")).resolves.toMatchObject({
      commandId: "cmd-projection-duplicate",
      message: `Projection recovery already pending for session: ${session.id}`,
    });
    release();
    await expect(waitForEvent(ws, "sessionProjectionSnapshot")).resolves.toMatchObject({ requestId: "recovery-first" });
    ws.close();
  });

  it("returns session diff responses only to the requesting client", async () => {
    const requester = await connectWithHello();
    const observer = await connectWithHello();
    vi.spyOn(supervisor, "getSessionDiff").mockResolvedValue({
      isGitRepo: true,
      files: [{ path: "source.ts", status: "modified", additions: 2, deletions: 1, diff: "@@ -1 +1 @@", truncated: false }],
      filesTruncated: false,
    });

    requester.ws.send(JSON.stringify({
      id: "cmd-session-diff",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionDiff",
      sessionId: "session-diff",
      view: "unstaged",
      requestId: "request-session-diff",
    }));

    await expect(nextEvent(requester.ws)).resolves.toMatchObject({
      type: "sessionDiffResult",
      sessionId: "session-diff",
      view: "unstaged",
      requestId: "request-session-diff",
      isGitRepo: true,
      files: [{ path: "source.ts", additions: 2, deletions: 1 }],
    });
    await expect(nextEventWithin(observer.ws, 50)).resolves.toBeUndefined();
    requester.ws.close();
    observer.ws.close();
  });

  it("routes autocomplete capabilities, query, and apply responses only to the requesting client", async () => {
    const requester = await connectWithHello();
    const observer = await connectWithHello();
    const capabilities = vi.spyOn(supervisor, "getAutocompleteCapabilities")
      .mockResolvedValue({ generation: 7, triggerCharacters: [">"] });
    const query = vi.spyOn(supervisor, "queryAutocomplete")
      .mockResolvedValue({ generation: 7, prefix: ">w", items: [{ value: ">worker", label: "Worker" }] });
    const apply = vi.spyOn(supervisor, "applyAutocomplete")
      .mockResolvedValue({ generation: 7, lines: [">worker "], cursorLine: 0, cursorCol: 8 });

    requester.ws.send(JSON.stringify({
      id: "cmd-autocomplete-capabilities",
      protocolVersion: PROTOCOL_VERSION,
      type: "getAutocompleteCapabilities",
      sessionId: "session-autocomplete",
    }));
    await expect(waitForEvent(requester.ws, "autocompleteCapabilitiesSnapshot")).resolves.toMatchObject({
      type: "autocompleteCapabilitiesSnapshot",
      requestId: "cmd-autocomplete-capabilities",
      generation: 7,
      triggerCharacters: [">"],
    });

    requester.ws.send(JSON.stringify({
      id: "cmd-autocomplete-query",
      protocolVersion: PROTOCOL_VERSION,
      type: "autocompleteQuery",
      sessionId: "session-autocomplete",
      generation: 7,
      lines: [">w"],
      cursorLine: 0,
      cursorCol: 2,
      draftRevision: 3,
      draftFingerprint: "draft-3",
    }));
    await expect(waitForEvent(requester.ws, "autocompleteSuggestionsSnapshot")).resolves.toMatchObject({
      type: "autocompleteSuggestionsSnapshot",
      requestId: "cmd-autocomplete-query",
      draftRevision: 3,
      draftFingerprint: "draft-3",
      prefix: ">w",
      items: [{ value: ">worker", label: "Worker" }],
    });

    requester.ws.send(JSON.stringify({
      id: "cmd-autocomplete-apply",
      protocolVersion: PROTOCOL_VERSION,
      type: "autocompleteApply",
      sessionId: "session-autocomplete",
      generation: 7,
      lines: [">w"],
      cursorLine: 0,
      cursorCol: 2,
      draftRevision: 3,
      draftFingerprint: "draft-3",
      item: { value: ">worker", label: "Worker" },
      prefix: ">w",
    }));
    await expect(waitForEvent(requester.ws, "autocompleteCompletionApplied")).resolves.toMatchObject({
      type: "autocompleteCompletionApplied",
      requestId: "cmd-autocomplete-apply",
      lines: [">worker "],
      cursorLine: 0,
      cursorCol: 8,
    });

    expect(capabilities).toHaveBeenCalledWith("session-autocomplete");
    expect(query).toHaveBeenCalledWith("session-autocomplete", expect.objectContaining({ generation: 7, cursorCol: 2 }));
    expect(apply).toHaveBeenCalledWith("session-autocomplete", expect.objectContaining({ prefix: ">w" }));
    await expect(nextEventWithin(observer.ws, 50)).resolves.toBeUndefined();
    requester.ws.close();
    observer.ws.close();
  });

  it("keeps OAuth interactions owned by the requesting websocket and reloads active runtimes", async () => {
    await server.stop();
    const piOAuth: PiOAuthHandling = {
      status: vi.fn(async () => ({ configured: false })),
      login: vi.fn(async (request) => {
        request.onPrompt("prompt-1", {
          type: "select",
          message: "Choose login method",
          options: [{ id: "browser", label: "Browser" }],
        });
        request.onNotify({ type: "auth_url", url: "https://example.com/oauth" });
        return { configured: true, source: "stored" };
      }),
      answerPrompt: vi.fn(),
      cancel: vi.fn(() => true),
      cancelOwnedBy: vi.fn(() => 1),
    };
    const reloadAuthentication = vi.spyOn(supervisor, "reloadPiAuthentication").mockResolvedValue(2);
    server = new AgentdServer({ port: 0, token: "test-token", supervisor, piOAuth });
    port = await server.start();

    const requester = await connectWithHello();
    const observer = await connectWithHello();
    const oauthEvents: EventEnvelope[] = [];
    requester.ws.on("message", (data) => oauthEvents.push(JSON.parse(data.toString()) as EventEnvelope));
    requester.ws.send(JSON.stringify({
      id: "cmd-oauth-login",
      protocolVersion: PROTOCOL_VERSION,
      type: "signInPiOAuth",
      providerId: "anthropic",
    }));

    await waitUntil(() => oauthEvents.filter((event) => "requestId" in event && event.requestId === "cmd-oauth-login").length === 3);
    expect(oauthEvents.find((event) => event.type === "piOAuthPromptRequested")).toMatchObject({
      type: "piOAuthPromptRequested",
      requestId: "cmd-oauth-login",
      promptId: "prompt-1",
      promptType: "select",
      options: [{ id: "browser", label: "Browser" }],
    });
    expect(oauthEvents.find((event) => event.type === "piOAuthUrlRequested")).toMatchObject({
      type: "piOAuthUrlRequested",
      requestId: "cmd-oauth-login",
      url: "https://example.com/oauth",
    });
    expect(oauthEvents.find((event) => event.type === "piOAuthStatus")).toMatchObject({
      type: "piOAuthStatus",
      requestId: "cmd-oauth-login",
      providerId: "anthropic",
      configured: true,
      source: "stored",
    });
    await expect(nextEventWithin(observer.ws, 50)).resolves.toBeUndefined();

    requester.ws.send(JSON.stringify({
      id: "cmd-oauth-answer",
      protocolVersion: PROTOCOL_VERSION,
      type: "answerPiOAuthPrompt",
      requestId: "cmd-oauth-login",
      promptId: "prompt-1",
      value: "browser",
    }));
    await waitUntil(() => vi.mocked(piOAuth.answerPrompt).mock.calls.length === 1);
    expect(piOAuth.answerPrompt).toHaveBeenCalledWith(expect.objectContaining({
      requestId: "cmd-oauth-login",
      promptId: "prompt-1",
      value: "browser",
    }));

    requester.ws.send(JSON.stringify({
      id: "cmd-auth-reload",
      protocolVersion: PROTOCOL_VERSION,
      type: "reloadPiAuthentication",
    }));
    await expect(nextEvent(requester.ws)).resolves.toMatchObject({
      type: "piAuthenticationReloaded",
      requestId: "cmd-auth-reload",
      reloadedHandleCount: 2,
    });
    expect(reloadAuthentication).toHaveBeenCalledOnce();

    requester.ws.close();
    await once(requester.ws, "close");
    await waitUntil(() => vi.mocked(piOAuth.cancelOwnedBy).mock.calls.length === 1);
    expect(piOAuth.cancelOwnedBy).toHaveBeenCalledOnce();
    observer.ws.close();
  });

  it("unicasts an ack after a successfully handled command", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-abort-main", protocolVersion: PROTOCOL_VERSION, type: "abortMainAgent" }));
    const ack = await waitForEvent(ws, "ack");
    expect(ack).toMatchObject({ type: "ack", commandId: "cmd-abort-main" });
    ws.close();
  });

  it("acks after the handler's own events so command responses arrive first", async () => {
    const { ws } = await connectWithHello();
    const types: string[] = [];
    ws.on("message", (data) => types.push((JSON.parse(data.toString()) as EventEnvelope).type));
    ws.send(JSON.stringify({ id: "cmd-list", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitUntil(() => types.includes("ack"));
    expect(types.indexOf("sessionSnapshot")).toBeGreaterThanOrEqual(0);
    expect(types.indexOf("sessionSnapshot")).toBeLessThan(types.indexOf("ack"));
    ws.close();
  });

  it("emits error without ack when a command is rejected", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-bad", protocolVersion: PROTOCOL_VERSION, type: "submit" }));
    const rejection = await nextEvent(ws);
    expect(rejection.type).toBe("error");
    expect(await nextEventWithin(ws, 150)).toBeUndefined();
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

  it("broadcasts an empty Picky message snapshot after resetting Picky", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-reset-main", protocolVersion: PROTOCOL_VERSION, type: "resetMainAgent" }));
    const snapshot = await nextEvent(ws);
    expect(snapshot.type).toBe("mainMessagesSnapshot");
    if (snapshot.type === "mainMessagesSnapshot") expect(snapshot.messages).toEqual([]);
    ws.close();
  });

  it("resends a pending main extension UI request to a newly connected client", async () => {
    const pendingRequest = {
      id: "main-ui-pending",
      sessionId: "picky-main",
      method: "askUserQuestion",
      title: "Continue?",
      questions: [],
      createdAt: "2026-05-01T00:00:00.000Z",
    } satisfies PickyExtensionUiRequest;
    vi.spyOn(supervisor, "mainPendingExtensionUi").mockReturnValue(pendingRequest);

    const received: EventEnvelope[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}?token=test-token`);
    ws.on("message", (data) => received.push(JSON.parse(data.toString()) as EventEnvelope));
    await once(ws, "open");
    await waitUntil(() => received.some((event) => event.type === "mainExtensionUiRequested"));

    expect(received).toContainEqual(expect.objectContaining({
      type: "mainExtensionUiRequested",
      request: expect.objectContaining({ id: "main-ui-pending", method: "askUserQuestion" }),
    }));
    ws.close();
  });

  it("broadcasts main activity and routes main extension UI answers", async () => {
    const { ws } = await connectWithHello();
    const answerMainExtensionUi = vi.spyOn(supervisor, "answerMainExtensionUi").mockResolvedValue();

    supervisor.emit("mainActivity", { kind: "tool", toolCallId: "tool-main-1", toolName: "read", status: "running" });
    await expect(nextEvent(ws)).resolves.toMatchObject({
      type: "mainActivityUpdated",
      activity: { kind: "tool", toolName: "read", status: "running" },
    });

    ws.send(JSON.stringify({
      id: "cmd-main-ui-answer",
      protocolVersion: PROTOCOL_VERSION,
      type: "answerMainExtensionUi",
      requestId: "main-ui-1",
      value: { choice: "continue" },
    }));
    await waitUntil(() => answerMainExtensionUi.mock.calls.length === 1);
    expect(answerMainExtensionUi).toHaveBeenCalledWith("main-ui-1", { choice: "continue" });
    ws.close();
  });

  it("replays active main activity after reconnect but not after it clears", async () => {
    await server.stop();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-server-main-activity-reconnect-"));
    const mainRuntime = new TrackingMainRuntime();
    supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(dir), { mainRuntime });
    await supervisor.load();
    server = new AgentdServer({ port: 0, token: "test-token", supervisor });
    port = await server.start();

    await supervisor.route(context("inspect the active task"));
    mainRuntime.handle?.emit({ type: "tool", toolCallId: "tool-main-reconnect", name: "read", status: "running" });
    await waitUntil(() => supervisor.mainActiveActivity()?.toolCallId === "tool-main-reconnect");

    const connectRecordingEvents = async (): Promise<{ ws: WebSocket; events: EventEnvelope[] }> => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}?token=test-token`);
      const events: EventEnvelope[] = [];
      ws.on("message", (data) => events.push(JSON.parse(data.toString()) as EventEnvelope));
      await once(ws, "open");
      await waitUntil(() => events.some((event) => event.type === "hello"));
      return { ws, events };
    };

    const first = await connectRecordingEvents();
    await waitUntil(() => first.events.some((event) => event.type === "mainActivityUpdated" && event.activity?.toolCallId === "tool-main-reconnect"));
    first.ws.close();
    await once(first.ws, "close");

    const reconnected = await connectRecordingEvents();
    await waitUntil(() => reconnected.events.some((event) => event.type === "mainActivityUpdated" && event.activity?.toolCallId === "tool-main-reconnect"));

    mainRuntime.handle?.emit({ type: "status", status: "completed", summary: "Completed" });
    await waitUntil(() => supervisor.mainActiveActivity() === undefined);
    await waitUntil(() => reconnected.events.some((event) => event.type === "mainActivityUpdated" && event.activity === undefined));
    reconnected.ws.close();
    await once(reconnected.ws, "close");

    const afterClear = await connectRecordingEvents();
    await sleep(25);
    expect(afterClear.events.filter((event) => event.type === "mainActivityUpdated")).toEqual([]);
    afterClear.ws.close();
  });

  it("includes the reloadPlugins command id on pluginsReloaded broadcasts", async () => {    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-reload-plugins", protocolVersion: PROTOCOL_VERSION, type: "reloadPlugins" }));
    const reloaded = await waitForEvent(ws, "pluginsReloaded");
    expect(reloaded).toMatchObject({ type: "pluginsReloaded", requestId: "cmd-reload-plugins" });
    ws.close();
  });

  it("wires the bundled npm command into the default package manager without persisting it", () => {
    const configuredSettings = SettingsManager.inMemory();
    const execPath = "/Applications/Picky.app/Contents/Resources/agentd-runtime/bin/node";
    const bundledNpmCli = "/Applications/Picky.app/Contents/Resources/agentd-runtime/lib/node_modules/npm/bin/npm-cli.js";
    const createPackageManager = vi.fn(({ settingsManager }) => {
      expect(settingsManager.getNpmCommand()).toEqual([
        execPath,
        "/Applications/Picky.app/Contents/Resources/agentd/application/npm-command-runner.js",
        "--timeout-ms",
        "90000",
        "--command-json",
        JSON.stringify([execPath, bundledNpmCli]),
        "--",
        "npm",
      ]);
      return {
        installAndPersist: async () => {},
        removeAndPersist: async () => false,
        checkAvailableUpdates: async () => [],
        update: async () => {},
        setProgressCallback: () => {},
      };
    });

    createDefaultPackageManager(
      { cwd: "/tmp/project", agentDir: "/tmp/picky-agent" },
      {
        createSettingsManager: () => configuredSettings,
        createPackageManager,
        execPath,
        fileExists: (path) => path === bundledNpmCli,
        npmCommandRunnerPath: "/Applications/Picky.app/Contents/Resources/agentd/application/npm-command-runner.js",
        npmCommandTimeoutMs: 90_000,
      },
    );

    expect(createPackageManager).toHaveBeenCalledOnce();
    expect(configuredSettings.getNpmCommand()).toBeUndefined();
  });

  it("runs package installs through an injected manager and relays progress to the requester", async () => {
    let progressCallback: ((event: { type: "start"; action: "install"; source: string; message: string }) => void) | undefined;
    let resolveInstall: (() => void) | undefined;
    const installAndPersist = vi.fn(async (source: string) => {
      progressCallback?.({ type: "start", action: "install", source, message: `Installing ${source}...` });
      await new Promise<void>((resolve) => { resolveInstall = resolve; });
    });
    const flush = vi.fn(async () => {});

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      getAgentDir: () => "/tmp/picky-agent",
      createPackageManager: () => ({
        installAndPersist,
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => []),
        update: vi.fn(async () => {}),
        setProgressCallback: (callback) => { progressCallback = callback as typeof progressCallback; },
        flush,
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    const received: EventEnvelope[] = [];
    ws.on("message", (data) => received.push(JSON.parse(data.toString()) as EventEnvelope));
    ws.send(JSON.stringify({ id: "cmd-package-install", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/plugin" }));

    await waitUntil(() => received.some((event) => event.type === "packageOperationProgress"));
    expect(received.find((event) => event.type === "packageOperationProgress")).toMatchObject({
      type: "packageOperationProgress",
      requestId: "cmd-package-install",
      operation: "install",
      source: "npm:@example/plugin",
      message: "Installing npm:@example/plugin...",
    });
    resolveInstall?.();
    await waitUntil(() => received.some((event) => event.type === "packageOperationCompleted"));
    expect(received.find((event) => event.type === "packageOperationCompleted")).toMatchObject({
      type: "packageOperationCompleted",
      requestId: "cmd-package-install",
      operation: "install",
      source: "npm:@example/plugin",
      ok: true,
    });
    expect(installAndPersist).toHaveBeenCalledWith("npm:@example/plugin");
    expect(flush).toHaveBeenCalledOnce();
    ws.close();
  });

  it("returns package installation failures as completion events without crashing the daemon", async () => {
    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      createPackageManager: () => ({
        installAndPersist: vi.fn(async () => { throw new Error("npm was not found"); }),
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => []),
        update: vi.fn(async () => {}),
        setProgressCallback: vi.fn(),
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-failure", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/plugin" }));
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      type: "packageOperationCompleted",
      requestId: "cmd-package-failure",
      operation: "install",
      source: "npm:@example/plugin",
      ok: false,
      errorMessage: "npm was not found",
    });
    ws.close();
  });

  it("returns available package update sources from an injected manager", async () => {
    const checkAvailableUpdates = vi.fn(async () => [{ source: "npm:@example/plugin" }]);

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      createPackageManager: () => ({
        installAndPersist: vi.fn(),
        removeAndPersist: vi.fn(),
        checkAvailableUpdates,
        update: vi.fn(),
        setProgressCallback: vi.fn(),
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-updates", protocolVersion: PROTOCOL_VERSION, type: "checkPackageUpdates" }));

    await expect(waitForEvent(ws, "packageUpdatesAvailable")).resolves.toMatchObject({
      type: "packageUpdatesAvailable",
      commandId: "cmd-package-updates",
      sources: ["npm:@example/plugin"],
    });
    expect(checkAvailableUpdates).toHaveBeenCalledOnce();
    ws.close();
  });

  it("returns an empty update list when the package update check fails", async () => {
    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      createPackageManager: () => ({
        installAndPersist: vi.fn(),
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => { throw new Error("npm registry unavailable"); }),
        update: vi.fn(),
        setProgressCallback: vi.fn(),
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-updates-failure", protocolVersion: PROTOCOL_VERSION, type: "checkPackageUpdates" }));

    await expect(waitForEvent(ws, "packageUpdatesAvailable")).resolves.toMatchObject({
      commandId: "cmd-package-updates-failure",
      sources: [],
      failed: true,
    });
    ws.close();
  });

  it("serializes update checks and explicit package updates", async () => {
    const lifecycle: string[] = [];
    let releaseCheck: (() => void) | undefined;
    const checkAvailableUpdates = vi.fn(async () => {
      lifecycle.push("check:start");
      await new Promise<void>((resolve) => { releaseCheck = resolve; });
      lifecycle.push("check:end");
      return [{ source: "npm:@example/plugin" }];
    });
    const update = vi.fn(async (source: string) => { lifecycle.push(`update:${source}`); });

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      getAgentDir: () => "/tmp/picky-agent",
      createPackageManager: () => ({
        installAndPersist: vi.fn(),
        removeAndPersist: vi.fn(),
        checkAvailableUpdates,
        update,
        setProgressCallback: vi.fn(),
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-check-serialized", protocolVersion: PROTOCOL_VERSION, type: "checkPackageUpdates" }));
    await waitUntil(() => releaseCheck !== undefined);
    ws.send(JSON.stringify({ id: "cmd-package-update-serialized", protocolVersion: PROTOCOL_VERSION, type: "updatePackage", source: "npm:@example/plugin" }));
    await sleep(20);
    expect(lifecycle).toEqual(["check:start"]);

    releaseCheck?.();
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      requestId: "cmd-package-update-serialized",
      operation: "update",
      source: "npm:@example/plugin",
      ok: true,
    });
    expect(lifecycle).toEqual(["check:start", "check:end", "update:npm:@example/plugin"]);
    ws.close();
  });

  it("returns explicit package update failures as completion events", async () => {
    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      createPackageManager: () => ({
        installAndPersist: vi.fn(),
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => []),
        update: vi.fn(async () => { throw new Error("npm was not found"); }),
        setProgressCallback: vi.fn(),
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-update-failure", protocolVersion: PROTOCOL_VERSION, type: "updatePackage", source: "npm:@example/plugin" }));

    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      requestId: "cmd-package-update-failure",
      operation: "update",
      source: "npm:@example/plugin",
      ok: false,
      errorMessage: "npm was not found",
    });
    ws.close();
  });

  it("times out the requester but keeps the queue serialized until the underlying mutation exits", async () => {
    const lifecycle: string[] = [];
    let releaseFirstInstall: (() => void) | undefined;
    const installAndPersist = vi.fn(async (source: string) => {
      lifecycle.push(`start:${source}`);
      if (source === "npm:@example/stuck") {
        await new Promise<void>((resolve) => { releaseFirstInstall = resolve; });
      }
      lifecycle.push(`end:${source}`);
    });
    const flush = vi.fn(async () => {});

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      getAgentDir: () => "/tmp/picky-agent",
      packageOperationTimeoutMs: 20,
      createPackageManager: () => ({
        installAndPersist,
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => []),
        update: vi.fn(async () => {}),
        setProgressCallback: vi.fn(),
        flush,
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-stuck", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/stuck" }));
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      requestId: "cmd-package-stuck",
      ok: false,
      errorMessage: "Package operation timed out after 20ms",
    });

    ws.send(JSON.stringify({ id: "cmd-package-after-timeout", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/next" }));
    await sleep(20);
    expect(lifecycle).toEqual(["start:npm:@example/stuck"]);
    expect(flush).not.toHaveBeenCalled();

    releaseFirstInstall?.();
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      requestId: "cmd-package-after-timeout",
      ok: true,
    });
    expect(lifecycle).toEqual([
      "start:npm:@example/stuck",
      "end:npm:@example/stuck",
      "start:npm:@example/next",
      "end:npm:@example/next",
    ]);
    expect(flush).toHaveBeenCalledOnce();
    ws.close();
  });

  it("cancels a timed-out package mutation before releasing the queue", async () => {
    const lifecycle: string[] = [];
    let releaseFirstInstall: (() => void) | undefined;
    const cancel = vi.fn(async () => {
      lifecycle.push("cancel:first");
      releaseFirstInstall?.();
    });

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      getAgentDir: () => "/tmp/picky-agent",
      packageOperationTimeoutMs: 20,
      createPackageManager: () => ({
        installAndPersist: async (source) => {
          lifecycle.push(`start:${source}`);
          if (source === "npm:@example/stuck") {
            await new Promise<void>((resolve) => { releaseFirstInstall = resolve; });
          }
          lifecycle.push(`end:${source}`);
        },
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => []),
        update: vi.fn(async () => {}),
        setProgressCallback: vi.fn(),
        cancel,
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-cancel", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/stuck" }));
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      requestId: "cmd-package-cancel",
      ok: false,
      errorMessage: "Package operation timed out after 20ms",
    });

    ws.send(JSON.stringify({ id: "cmd-package-after-cancel", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/next" }));
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      requestId: "cmd-package-after-cancel",
      ok: true,
    });
    expect(cancel).toHaveBeenCalledOnce();
    expect(lifecycle).toEqual([
      "start:npm:@example/stuck",
      "cancel:first",
      "end:npm:@example/stuck",
      "start:npm:@example/next",
      "end:npm:@example/next",
    ]);
    ws.close();
  });

  it("cancels active package mutations and never starts queued work during shutdown", async () => {
    let releaseInstall: (() => void) | undefined;
    const startedSources: string[] = [];
    const cancel = vi.fn(async () => releaseInstall?.());
    const createPackageManager = vi.fn(() => ({
      installAndPersist: async (source: string) => {
        startedSources.push(source);
        if (source.endsWith("/active")) {
          await new Promise<void>((resolve) => { releaseInstall = resolve; });
        }
      },
      removeAndPersist: vi.fn(),
      checkAvailableUpdates: vi.fn(async () => []),
      update: vi.fn(async () => {}),
      setProgressCallback: vi.fn(),
      cancel,
    }));

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      getAgentDir: () => "/tmp/picky-agent",
      createPackageManager,
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-shutdown-active", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "git:example.invalid/active" }));
    await waitUntil(() => startedSources.length === 1);
    ws.send(JSON.stringify({ id: "cmd-package-shutdown-queued", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "git:example.invalid/queued" }));
    await sleep(20);

    await server.stop();

    expect(cancel).toHaveBeenCalledOnce();
    expect(createPackageManager).toHaveBeenCalledOnce();
    expect(startedSources).toEqual(["git:example.invalid/active"]);
    ws.close();
  });

  it("returns a package failure when settings persistence reports an error", async () => {
    const settingsManager = SettingsManager.inMemory();
    vi.spyOn(settingsManager, "drainErrors").mockReturnValue([{
      scope: "global",
      error: new Error("settings are read-only"),
    }]);

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      createPackageManager: () => createDefaultPackageManager(
        { cwd: "/tmp/project", agentDir: "/tmp/picky-agent" },
        {
          createSettingsManager: () => settingsManager,
          createPackageManager: () => ({
            installAndPersist: async () => {},
            removeAndPersist: async () => false,
            checkAvailableUpdates: async () => [],
            update: async () => {},
            setProgressCallback: () => {},
          }),
        },
      ),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-package-persistence-failure", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/plugin" }));
    await expect(waitForEvent(ws, "packageOperationCompleted")).resolves.toMatchObject({
      type: "packageOperationCompleted",
      requestId: "cmd-package-persistence-failure",
      operation: "install",
      source: "npm:@example/plugin",
      ok: false,
      errorMessage: "Failed to persist global settings: settings are read-only",
    });
    ws.close();
  });

  it("serializes concurrent package operations for the same agent directory", async () => {
    const lifecycle: string[] = [];
    let releaseFirstInstall: (() => void) | undefined;
    const installAndPersist = vi.fn(async (source: string) => {
      lifecycle.push(`start:${source}`);
      if (source === "npm:@example/first") {
        await new Promise<void>((resolve) => { releaseFirstInstall = resolve; });
      }
      lifecycle.push(`end:${source}`);
    });

    await server.stop();
    server = new AgentdServer({
      port: 0,
      token: "test-token",
      supervisor,
      getAgentDir: () => "/tmp/picky-agent",
      createPackageManager: () => ({
        installAndPersist,
        removeAndPersist: vi.fn(),
        checkAvailableUpdates: vi.fn(async () => []),
        update: vi.fn(async () => {}),
        setProgressCallback: vi.fn(),
      }),
    });
    port = await server.start();

    const { ws } = await connectWithHello();
    const received: EventEnvelope[] = [];
    ws.on("message", (data) => received.push(JSON.parse(data.toString()) as EventEnvelope));
    ws.send(JSON.stringify({ id: "cmd-package-first", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/first" }));
    await waitUntil(() => releaseFirstInstall !== undefined);
    ws.send(JSON.stringify({ id: "cmd-package-second", protocolVersion: PROTOCOL_VERSION, type: "installPackage", source: "npm:@example/second" }));

    await sleep(20);
    expect(lifecycle).toEqual(["start:npm:@example/first"]);
    releaseFirstInstall?.();
    await waitUntil(() => received.filter((event) => event.type === "packageOperationCompleted").length === 2);

    expect(lifecycle).toEqual([
      "start:npm:@example/first",
      "end:npm:@example/first",
      "start:npm:@example/second",
      "end:npm:@example/second",
    ]);
    expect(received.filter((event) => event.type === "packageOperationCompleted")).toEqual(expect.arrayContaining([
      expect.objectContaining({ requestId: "cmd-package-first", ok: true }),
      expect.objectContaining({ requestId: "cmd-package-second", ok: true }),
    ]));
    ws.close();
  });

  it("broadcasts mainTurnSettled with its contextId", async () => {
    const { ws } = await connectWithHello();
    const pendingSettled = waitForEvent(ws, "mainTurnSettled");

    supervisor.emit("mainTurnSettled", "context-overlay-only-001");

    await expect(pendingSettled).resolves.toMatchObject({
      type: "mainTurnSettled",
      contextId: "context-overlay-only-001",
    });
    ws.close();
  });

  it("broadcasts progressive visual narration segment events in supervisor order", async () => {
    const { ws } = await connectWithHello();
    const identity = {
      contextId: "context-visual",
      contextGeneration: 1,
      turnToken: "main-turn-1",
      segmentId: "segment-1",
      ordinal: 0,
    };
    const visual = {
      kind: "point" as const,
      request: {
        id: "pointer-visual",
        contextId: "context-visual",
        contextGeneration: 1,
        x: 10,
        y: 20,
        screenBounds: { x: 0, y: 0, width: 100, height: 100 },
        screenshotSize: { width: 100, height: 100 },
      },
    };

    const prepared = waitForEvent(ws, "mainVisualNarrationSegmentPrepared");
    supervisor.emit("mainVisualNarrationSegmentPrepared", { identity, visual });
    await expect(prepared).resolves.toMatchObject({ type: "mainVisualNarrationSegmentPrepared", identity, visual });

    const sentence = waitForEvent(ws, "mainVisualNarrationSegmentSentence");
    supervisor.emit("mainVisualNarrationSegmentSentence", { identity, index: 0, text: "첫 문장.", replyKind: "main" });
    await expect(sentence).resolves.toMatchObject({ type: "mainVisualNarrationSegmentSentence", identity, index: 0, text: "첫 문장." });

    const committed = waitForEvent(ws, "mainVisualNarrationSegmentCommitted");
    supervisor.emit("mainVisualNarrationSegmentCommitted", { identity, text: "첫 문장.", sentenceCount: 1, replyKind: "main" });
    await expect(committed).resolves.toMatchObject({ type: "mainVisualNarrationSegmentCommitted", identity, sentenceCount: 1 });
    ws.close();
  });

  it("broadcasts toolActivityUpdated events", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-lock-tool-events-v1", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitForEvent(ws, "sessionSnapshot");
    await waitForEvent(ws, "ack");
    const pendingToolEvent = waitForEvent(ws, "toolActivityUpdated");

    supervisor.emit("toolActivityUpdated", "session-tools", { toolCallId: "tool-1", name: "bash", status: "running", preview: "npm test" });

    await expect(pendingToolEvent).resolves.toMatchObject({
      type: "toolActivityUpdated",
      sessionId: "session-tools",
      tool: { toolCallId: "tool-1", name: "bash", status: "running", preview: "npm test" },
    });
    ws.close();
  });

  it("broadcasts slim todo state updates including clear", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-lock-todo-events-v1", protocolVersion: PROTOCOL_VERSION, type: "listSessions" }));
    await waitForEvent(ws, "sessionSnapshot");
    await waitForEvent(ws, "ack");
    const pendingUpdate = waitForEvent(ws, "sessionTodoStateUpdated");
    supervisor.emit("todoStateUpdated", "session-todo", {
      tasks: [{ id: "todo-1", content: "Implement HUD", status: "in_progress" }],
      updatedAt: "2026-07-14T01:00:00.000Z",
    }, 4);

    await expect(pendingUpdate).resolves.toMatchObject({
      type: "sessionTodoStateUpdated",
      sessionId: "session-todo",
      todoState: { tasks: [{ id: "todo-1", status: "in_progress" }] },
      seq: 4,
    });

    const pendingClear = waitForEvent(ws, "sessionTodoStateUpdated");
    supervisor.emit("todoStateUpdated", "session-todo", undefined, 5);
    await expect(pendingClear).resolves.toMatchObject({
      type: "sessionTodoStateUpdated",
      sessionId: "session-todo",
      todoState: null,
      seq: 5,
    });
    ws.close();
  });

  it("broadcasts sessionArchivedAuthoritative when setSessionArchived runs (regression for picky_unarchive_pickle not reaching the dock)", async () => {
    const session = await supervisor.create(context("to be archived"));
    const { ws } = await connectWithHello();

    ws.send(JSON.stringify({ id: "cmd-archive", protocolVersion: PROTOCOL_VERSION, type: "setSessionArchived", sessionId: session.id, archived: true }));
    const archivedAuth = await waitForEvent(ws, "sessionArchivedAuthoritative");
    expect(archivedAuth).toMatchObject({ type: "sessionArchivedAuthoritative", sessionId: session.id, archived: true });

    ws.send(JSON.stringify({ id: "cmd-unarchive", protocolVersion: PROTOCOL_VERSION, type: "setSessionArchived", sessionId: session.id, archived: false }));
    const unarchivedAuth = await waitForEvent(ws, "sessionArchivedAuthoritative");
    expect(unarchivedAuth).toMatchObject({ type: "sessionArchivedAuthoritative", sessionId: session.id, archived: false });
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
    ws.send(JSON.stringify({ id: "cmd-steer", protocolVersion: PROTOCOL_VERSION, type: "steer", sessionId: session.id, text: "inspect this", context: steerContext, visualDslEnabled: true }));

    await waitUntil(() => steer.mock.calls.length > 0);

    expect(steer).toHaveBeenCalledWith(
      session.id,
      "inspect this",
      expect.objectContaining({ id: "context-visual-steer", screenshots: [expect.objectContaining({ path: "/tmp/shot.png" })] }),
      true,
    );
    ws.close();
  });

  it("routes Pickle session command names to the supervisor", async () => {
    const createEmptyPickleSession = vi.spyOn(supervisor, "createEmptyPickleSession");
    const createPickleFromHandoff = vi.spyOn(supervisor, "createPickleFromHandoff");
    const pinPickleSession = vi.spyOn(supervisor, "pinPickleSession");
    const duplicatePickleSession = vi.spyOn(supervisor, "duplicatePickleSession").mockResolvedValue(makeSession({ id: "session-copy" }));
    const { ws } = await connectWithHello();

    ws.send(JSON.stringify({ id: "cmd-empty-pickle", protocolVersion: PROTOCOL_VERSION, type: "createEmptyPickleSession", context: context("manual pickle") }));
    await waitUntil(() => createEmptyPickleSession.mock.calls.length === 1);
    ws.send(JSON.stringify({ id: "cmd-handoff-pickle", protocolVersion: PROTOCOL_VERSION, type: "createPickleFromHandoff", context: context("handoff pickle"), title: "Handoff", instructions: "Do it", cwd: "/tmp/product" }));
    await waitUntil(() => createPickleFromHandoff.mock.calls.length === 1);
    ws.send(JSON.stringify({ id: "cmd-pin-pickle", protocolVersion: PROTOCOL_VERSION, type: "pinPickleSession", context: context("pin pickle") }));
    await waitUntil(() => pinPickleSession.mock.calls.length === 1);
    ws.send(JSON.stringify({ id: "cmd-duplicate-pickle", protocolVersion: PROTOCOL_VERSION, type: "duplicatePickleSession", sessionId: "session-source" }));
    await waitUntil(() => duplicatePickleSession.mock.calls.length === 1);

    expect(createEmptyPickleSession).toHaveBeenCalledWith(expect.objectContaining({ id: "context-manual pickle" }));
    expect(createPickleFromHandoff).toHaveBeenCalledWith(expect.objectContaining({ id: "context-handoff pickle" }), { title: "Handoff", instructions: "Do it", cwd: "/tmp/product" });
    expect(pinPickleSession).toHaveBeenCalledWith(expect.objectContaining({ id: "context-pin pickle" }), undefined);
    expect(duplicatePickleSession).toHaveBeenCalledWith("session-source");
    ws.close();
  });

  it("rejects an app-owned Pickle handoff when no app client is connected", async () => {
    await expect(server.requestPickleHandoffFromApp({ context: context("app handoff"), title: "App Handoff", instructions: "Do it", cwd: "/tmp/product" })).rejects.toThrow(/handoff unavailable/);
  });

  it("requests an app-owned Pickle handoff only from a capable app client and resolves from completion command", async () => {
    const ignored = await connectWithHello();
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-register", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleHandoff", "pickleBridge"] }));
    await waitForRegisteredCapability("pickleHandoff");
    const pending = server.requestPickleHandoffFromApp({ context: context("app handoff"), title: "App Handoff", instructions: "Do it", cwd: "/tmp/product" });
    const request = await nextEvent(ws);
    expect(request.type).toBe("pickleHandoffRequested");
    if (request.type !== "pickleHandoffRequested") throw new Error("expected handoff request");
    expect(request.title).toBe("App Handoff");
    expect(request.cwd).toBe("/tmp/product");

    ws.send(JSON.stringify({ id: "cmd-complete-handoff", protocolVersion: PROTOCOL_VERSION, type: "completePickleHandoff", requestId: request.requestId, sessionId: "session-child", title: "App Handoff", cwd: "/tmp/product" }));

    await expect(pending).resolves.toEqual({ sessionId: "session-child", title: "App Handoff", cwd: "/tmp/product" });
    await expect(nextEventWithin(ignored.ws, 50)).resolves.toBeUndefined();
    ws.close();
    ignored.ws.close();
  });

  it("rejects app Pickle handoff when connected clients have not registered capability", async () => {
    const { ws } = await connectWithHello();
    await expect(server.requestPickleHandoffFromApp({ context: context("app handoff"), title: "App Handoff", instructions: "Do it", cwd: "/tmp/product" })).rejects.toThrow(/handoff unavailable/);
    ws.close();
  });

  it("resolves a pending app Pickle handoff completed after its recipient reconnects", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-register-handoff-reconnect", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleHandoff"] }));
    await waitForRegisteredCapability("pickleHandoff");

    const pending = server.requestPickleHandoffFromApp({ context: context("app handoff"), title: "App Handoff", instructions: "Do it", cwd: "/tmp/product" }, 5_000);
    const request = await waitForEvent(ws, "pickleHandoffRequested");
    if (request.type !== "pickleHandoffRequested") throw new Error("expected handoff request");
    ws.close();
    await sleep(50);

    const { ws: reconnected } = await connectWithHello();
    reconnected.send(JSON.stringify({ id: "cmd-complete-handoff-reconnect", protocolVersion: PROTOCOL_VERSION, type: "completePickleHandoff", requestId: request.requestId, sessionId: "session-child", title: "App Handoff", cwd: "/tmp/product" }));

    await expect(pending).resolves.toEqual({ sessionId: "session-child", title: "App Handoff", cwd: "/tmp/product" });
    reconnected.close();
  });

  it("times out a pending app Pickle handoff whose recipient disconnects and never completes", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-register-handoff-timeout", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleHandoff"] }));
    await waitForRegisteredCapability("pickleHandoff");

    const pending = server.requestPickleHandoffFromApp({ context: context("app handoff"), title: "App Handoff", instructions: "Do it", cwd: "/tmp/product" }, 200);
    await waitForEvent(ws, "pickleHandoffRequested");
    ws.close();

    await expect(pending).rejects.toThrow(/timed out/);
  });

  it("keeps a pending app Pickle handoff alive when another client disconnects", async () => {
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({ id: "cmd-register-handoff-primary", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleHandoff"] }));
    await waitForRegisteredCapability("pickleHandoff");
    const { ws: otherWs } = await connectWithHello();

    const pending = server.requestPickleHandoffFromApp({ context: context("app handoff"), title: "App Handoff", instructions: "Do it", cwd: "/tmp/product" });
    const request = await waitForEvent(appWs, "pickleHandoffRequested");
    if (request.type !== "pickleHandoffRequested") throw new Error("expected handoff request");
    otherWs.close();
    await sleep(50);
    appWs.send(JSON.stringify({ id: "cmd-complete-handoff-primary", protocolVersion: PROTOCOL_VERSION, type: "completePickleHandoff", requestId: request.requestId, sessionId: "session-child", title: "App Handoff", cwd: "/tmp/product" }));

    await expect(pending).resolves.toEqual({ sessionId: "session-child", title: "App Handoff", cwd: "/tmp/product" });
    appWs.close();
  });

  it("routes external push-to-talk control through a capable app client and acks the CLI", async () => {
    const ignored = await connectWithHello();
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({ id: "cmd-register-ptt", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pushToTalkControl"] }));
    await waitForRegisteredCapability("pushToTalkControl");

    const cli = await connectWithHello();
    cli.ws.send(JSON.stringify({ id: "cmd-ptt-press", protocolVersion: PROTOCOL_VERSION, type: "controlPushToTalkFromExternal", action: "press" }));

    const request = await nextEvent(app.ws);
    expect(request).toMatchObject({ type: "pushToTalkControlRequested", action: "press" });
    if (request.type !== "pushToTalkControlRequested") throw new Error("expected ptt request");
    await expect(nextEventWithin(ignored.ws, 50)).resolves.toBeUndefined();

    app.ws.send(JSON.stringify({ id: "cmd-complete-ptt", protocolVersion: PROTOCOL_VERSION, type: "completePushToTalkControlRequest", requestId: request.requestId }));

    const ack = await nextEvent(cli.ws);
    expect(ack).toMatchObject({ type: "pushToTalkControlAck", commandId: "cmd-ptt-press", action: "press" });
    ignored.ws.close();
    app.ws.close();
    cli.ws.close();
  });

  it("rejects external push-to-talk control when no capable app is connected", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-ptt-release", protocolVersion: PROTOCOL_VERSION, type: "controlPushToTalkFromExternal", action: "release" }));
    const error = await nextEvent(ws);
    expect(error).toMatchObject({ type: "error", commandId: "cmd-ptt-release" });
    if (error.type === "error") expect(error.message).toContain("push-to-talk control unavailable");
    ws.close();
  });

  it("round-trips list, get, and set settings commands through the settings-capable app", async () => {
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({
      id: "cmd-register-settings",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["settingsControl"],
    }));
    await waitForRegisteredCapability("settingsControl");
    const cli = await connectWithHello();

    for (const command of [
      { id: "cmd-settings-list", type: "listPickySettings" },
      { id: "cmd-settings-get", type: "getPickySettings", key: "cursor.visible" },
      { id: "cmd-settings-set", type: "setPickySettings", key: "hud.dockVisible", value: true, toggle: false, displayId: "display-1", caller: "mainAgent" },
    ]) {
      cli.ws.send(JSON.stringify({ protocolVersion: PROTOCOL_VERSION, ...command }));
      const request = await waitForEvent(app.ws, "pickySettingsRequested");
      expect(request).toMatchObject({
        type: "pickySettingsRequested",
        action: command.type === "listPickySettings" ? "list" : command.type === "getPickySettings" ? "get" : "set",
      });
      if (command.type === "setPickySettings") {
        expect(request).toMatchObject({ key: "hud.dockVisible", value: true, displayId: "display-1", caller: "mainAgent" });
      }
      if (request.type !== "pickySettingsRequested") throw new Error("expected settings request");
      app.ws.send(JSON.stringify({
        id: `complete-${command.id}`,
        protocolVersion: PROTOCOL_VERSION,
        type: "completePickySettingsRequest",
        requestId: request.requestId,
        result: command.type === "listPickySettings"
          ? { entries: [{ key: "cursor.visible", currentValue: true }] }
          : command.type === "getPickySettings"
            ? { key: "cursor.visible", value: true }
            : { key: "hud.dockVisible", value: true, persisted: true, applied: true, restartRequired: false, revision: 1 },
      }));
      const ack = await waitForEvent(cli.ws, "pickySettingsAck");
      expect(ack).toMatchObject({ type: "pickySettingsAck", commandId: command.id });
    }
    app.ws.close();
    cli.ws.close();
  });

  it("rejects settings commands when no settings-capable app is connected", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-settings-unavailable", protocolVersion: PROTOCOL_VERSION, type: "listPickySettings" }));
    await expect(waitForEvent(ws, "error")).resolves.toMatchObject({
      commandId: "cmd-settings-unavailable",
      code: "APP_SETTINGS_CONTROL_UNAVAILABLE",
    });
    ws.close();
  });

  it("preserves an app settings error code for the requesting CLI socket", async () => {
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({
      id: "cmd-register-settings-error",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["settingsControl"],
    }));
    await waitForRegisteredCapability("settingsControl");
    const cli = await connectWithHello();
    cli.ws.send(JSON.stringify({ id: "cmd-settings-disallowed", protocolVersion: PROTOCOL_VERSION, type: "setPickySettings", key: "cursor.visible", value: true, caller: "mainAgent" }));
    const request = await waitForEvent(app.ws, "pickySettingsRequested");
    if (request.type !== "pickySettingsRequested") throw new Error("expected settings request");
    app.ws.send(JSON.stringify({
      id: "cmd-complete-settings-disallowed",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickySettingsRequest",
      requestId: request.requestId,
      errorCode: "SETTINGS_KEY_NOT_ALLOWED_FOR_MAIN_AGENT",
      errorMessage: "This setting is not allowed for the Picky main agent",
    }));
    await expect(waitForEvent(cli.ws, "error")).resolves.toMatchObject({
      commandId: "cmd-settings-disallowed",
      code: "SETTINGS_KEY_NOT_ALLOWED_FOR_MAIN_AGENT",
      message: "This setting is not allowed for the Picky main agent",
    });
    app.ws.close();
    cli.ws.close();
  });

  it("times out a settings request when the recipient app does not complete it", async () => {
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({
      id: "cmd-register-settings-timeout",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["settingsControl"],
    }));
    await waitForRegisteredCapability("settingsControl");
    const serverForTest = server as unknown as { settingsControl: { request: (request: { action: "list" }, timeoutMs: number) => Promise<unknown> } };
    const pending = serverForTest.settingsControl.request({ action: "list" }, 20);
    const outcome = pending.then(
      () => ({ ok: true }),
      (error: unknown) => error,
    );
    await waitForEvent(app.ws, "pickySettingsRequested");
    await expect(outcome).resolves.toMatchObject({ code: "APP_SETTINGS_CONTROL_TIMEOUT" });
    app.ws.close();
  });

  it("ignores a settings completion from a socket other than the request recipient", async () => {
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({
      id: "cmd-register-settings-recipient",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["settingsControl"],
    }));
    await waitForRegisteredCapability("settingsControl");
    const impostor = await connectWithHello();
    const cli = await connectWithHello();
    cli.ws.send(JSON.stringify({ id: "cmd-settings-provenance", protocolVersion: PROTOCOL_VERSION, type: "getPickySettings", key: "cursor.visible" }));
    const request = await waitForEvent(app.ws, "pickySettingsRequested");
    if (request.type !== "pickySettingsRequested") throw new Error("expected settings request");
    impostor.ws.send(JSON.stringify({
      id: "cmd-settings-impostor-complete",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickySettingsRequest",
      requestId: request.requestId,
      result: { key: "cursor.visible", value: false },
    }));
    await expect(nextEventWithin(cli.ws, 50)).resolves.toBeUndefined();
    app.ws.send(JSON.stringify({
      id: "cmd-settings-recipient-complete",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickySettingsRequest",
      requestId: request.requestId,
      result: { key: "cursor.visible", value: true },
    }));
    await expect(waitForEvent(cli.ws, "pickySettingsAck")).resolves.toMatchObject({
      commandId: "cmd-settings-provenance",
      result: { key: "cursor.visible", value: true },
    });
    app.ws.close();
    impostor.ws.close();
    cli.ws.close();
  });

  it("rejects a pending settings request when its recipient app disconnects", async () => {
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({
      id: "cmd-register-settings-disconnect",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["settingsControl"],
    }));
    await waitForRegisteredCapability("settingsControl");
    const serverForTest = server as unknown as { settingsControl: { request: (request: { action: "list" }) => Promise<unknown> } };
    const pending = serverForTest.settingsControl.request({ action: "list" });
    const outcome = pending.then(
      () => ({ ok: true }),
      (error: unknown) => error,
    );
    await waitForEvent(app.ws, "pickySettingsRequested");
    app.ws.close();
    await expect(outcome).resolves.toMatchObject({ code: "APP_SETTINGS_CONTROL_UNAVAILABLE" });
  });

  it("creates a Pickle from the active main context despite a retired disabled setting", async () => {
    await supervisor.setDisabledBuiltinTools(["picky_start_pickle"]);
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({
      id: "cmd-register-main-cli-handoff",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["pickleHandoff", "externalEntry"],
    }));
    await waitForRegisteredCapability("pickleHandoff");
    const activeContext = context("delegate from main context");
    vi.spyOn(supervisor, "currentMainContext").mockReturnValue(activeContext);

    const cli = await connectWithHello();
    cli.ws.send(JSON.stringify({
      id: "cmd-main-cli-create",
      protocolVersion: PROTOCOL_VERSION,
      type: "createPickleFromMain",
      caller: "mainAgent",
      title: "Audit",
      instructions: "Inspect the release",
      group: "Release",
    }));

    const request = await waitForEvent(app.ws, "pickleHandoffRequested");
    expect(request).toMatchObject({
      type: "pickleHandoffRequested",
      context: { id: activeContext.id },
      title: "Audit",
      instructions: "Inspect the release",
    });
    if (request.type !== "pickleHandoffRequested") throw new Error("expected handoff request");
    const ackPromise = waitForEvent(cli.ws, "externalEntryAck");
    app.ws.send(JSON.stringify({
      id: "cmd-complete-main-cli-handoff",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickleHandoff",
      requestId: request.requestId,
      sessionId: "pickle-main-cli",
      title: "Audit",
      cwd: "/tmp",
    }));

    const accepted = await waitForEvent(app.ws, "externalEntryAccepted");
    expect(accepted).toMatchObject({ sessionId: "pickle-main-cli", group: "Release" });
    const ack = await ackPromise;
    expect(ack).toMatchObject({ commandId: "cmd-main-cli-create", kind: "createPickle", sessionId: "pickle-main-cli" });
    app.ws.close();
    cli.ws.close();
  });

  it("requests child-aware Pickle bridge operations from a capable app client", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-register", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");
    const pending = server.requestPickleBridgeFromApp({ operation: "listSessions" });
    const request = await nextEvent(ws);
    expect(request.type).toBe("pickleBridgeRequested");
    if (request.type !== "pickleBridgeRequested") throw new Error("expected bridge request");
    expect(request.operation).toBe("listSessions");

    const session = makeSession({ id: "child-pickle" });
    const groups = [{ id: "research", name: "Research", color: 6, memberSessionIds: ["child-pickle"], collapsed: false }];
    ws.send(JSON.stringify({ id: "cmd-complete-bridge", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: request.requestId, sessions: [session], groups }));

    await expect(pending).resolves.toMatchObject({
      sessions: [expect.objectContaining({ id: "child-pickle" })],
      groups: [expect.objectContaining({ id: "research", memberSessionIds: ["child-pickle"] })],
    });
    ws.close();
  });

  it("round-trips main-agent Pickle group management through the app bridge", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-register-group-bridge", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");

    const pending = server.requestPickleBridgeFromApp({
      operation: "manageGroups",
      groupAction: "addMembers",
      groupId: "research",
      sessionIds: ["pickle-1", "pickle-2"],
    });
    const request = await nextEvent(ws);
    expect(request).toMatchObject({
      type: "pickleBridgeRequested",
      operation: "manageGroups",
      groupAction: "addMembers",
      groupId: "research",
      sessionIds: ["pickle-1", "pickle-2"],
    });
    if (request.type !== "pickleBridgeRequested") throw new Error("expected bridge request");

    const groups = [{ id: "research", name: "Research", color: 6, memberSessionIds: ["pickle-1", "pickle-2"], collapsed: false }];
    ws.send(JSON.stringify({
      id: "cmd-complete-group-bridge",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickleBridgeRequest",
      requestId: request.requestId,
      groups,
    }));

    await expect(pending).resolves.toEqual({ sessions: undefined, groups, session: undefined, delivered: undefined });
    ws.close();
  });

  it("routes CLI dock-group mutations despite a retired disabled setting", async () => {
    await supervisor.setDisabledBuiltinTools(["picky_manage_pickle_groups"]);
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({ id: "cmd-register-cli-groups", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");
    const cli = await connectWithHello();

    cli.ws.send(JSON.stringify({
      id: "cmd-cli-group-add",
      protocolVersion: PROTOCOL_VERSION,
      type: "manageDockGroups",
      caller: "mainAgent",
      groupAction: "addMembers",
      groupId: "research",
      sessionIds: ["pickle-1", "pickle-2"],
    }));
    const request = await waitForEvent(app.ws, "pickleBridgeRequested");
    expect(request).toMatchObject({
      operation: "manageGroups",
      groupAction: "addMembers",
      groupId: "research",
      sessionIds: ["pickle-1", "pickle-2"],
    });
    if (request.type !== "pickleBridgeRequested") throw new Error("expected bridge request");
    const groups = [{ id: "research", name: "Research", color: 6, memberSessionIds: ["pickle-1", "pickle-2"], collapsed: false }];
    app.ws.send(JSON.stringify({
      id: "cmd-complete-cli-groups",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickleBridgeRequest",
      requestId: request.requestId,
      groups,
    }));

    const snapshot = await waitForEvent(cli.ws, "dockGroupsSnapshot");
    expect(snapshot).toMatchObject({ groups });
    app.ws.close();
    cli.ws.close();
  });

  it("routes main-agent CLI session operations despite retired disabled settings", async () => {
    await supervisor.setDisabledBuiltinTools(["picky_pickle_sessions", "picky_steer_pickle"]);
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({ id: "cmd-register-cli-sessions", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");
    const cli = await connectWithHello();
    const session = makeSession({ id: "pickle-cli" });

    cli.ws.send(JSON.stringify({ id: "cmd-cli-list", protocolVersion: PROTOCOL_VERSION, type: "listPickles", caller: "mainAgent" }));
    const listRequest = await waitForEvent(app.ws, "pickleBridgeRequested");
    expect(listRequest).toMatchObject({ operation: "listSessions" });
    if (listRequest.type !== "pickleBridgeRequested") throw new Error("expected list bridge request");
    const listSnapshot = waitForEvent(cli.ws, "sessionSnapshot");
    app.ws.send(JSON.stringify({ id: "cmd-complete-cli-list", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: listRequest.requestId, sessions: [session] }));
    await expect(listSnapshot).resolves.toMatchObject({ sessions: [expect.objectContaining({ id: "pickle-cli" })] });

    cli.ws.send(JSON.stringify({ id: "cmd-cli-steer", protocolVersion: PROTOCOL_VERSION, type: "controlPickle", caller: "mainAgent", pickleAction: "steer", sessionId: "pickle-cli", text: "focus" }));
    const steerRequest = await waitForEvent(app.ws, "pickleBridgeRequested");
    expect(steerRequest).toMatchObject({ operation: "steer", sessionId: "pickle-cli", text: "focus" });
    if (steerRequest.type !== "pickleBridgeRequested") throw new Error("expected steer bridge request");
    const steerUpdate = waitForEvent(cli.ws, "sessionUpdated");
    app.ws.send(JSON.stringify({ id: "cmd-complete-cli-steer", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: steerRequest.requestId, session }));
    await expect(steerUpdate).resolves.toMatchObject({ session: { id: "pickle-cli" } });

    cli.ws.send(JSON.stringify({ id: "cmd-cli-archive", protocolVersion: PROTOCOL_VERSION, type: "setPickleArchived", caller: "mainAgent", sessionId: "pickle-cli", archived: true }));
    const archiveRequest = await waitForEvent(app.ws, "pickleBridgeRequested");
    expect(archiveRequest).toMatchObject({ operation: "setArchived", sessionId: "pickle-cli", archived: true });
    if (archiveRequest.type !== "pickleBridgeRequested") throw new Error("expected archive bridge request");
    const archiveAck = waitForEvent(cli.ws, "sessionArchivedAuthoritative");
    app.ws.send(JSON.stringify({ id: "cmd-complete-cli-archive", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: archiveRequest.requestId, delivered: true }));
    await expect(archiveAck).resolves.toMatchObject({ sessionId: "pickle-cli", archived: true });

    cli.ws.send(JSON.stringify({ id: "cmd-cli-delete", protocolVersion: PROTOCOL_VERSION, type: "deletePickle", caller: "mainAgent", sessionId: "pickle-cli" }));
    const deleteRequest = await waitForEvent(app.ws, "pickleBridgeRequested");
    expect(deleteRequest).toMatchObject({ operation: "delete", sessionId: "pickle-cli" });
    if (deleteRequest.type !== "pickleBridgeRequested") throw new Error("expected delete bridge request");
    const deleteSnapshot = waitForEvent(cli.ws, "sessionSnapshot");
    app.ws.send(JSON.stringify({ id: "cmd-complete-cli-delete", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: deleteRequest.requestId, sessions: [], delivered: true }));
    await expect(deleteSnapshot).resolves.toMatchObject({ sessions: [] });

    app.ws.close();
    cli.ws.close();
  });

  it("routes main-agent CLI abort despite a retired disabled setting", async () => {
    await supervisor.setDisabledBuiltinTools(["picky_abort_pickle"]);
    const app = await connectWithHello();
    app.ws.send(JSON.stringify({ id: "cmd-register-cli-abort", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");
    const cli = await connectWithHello();
    const session = makeSession({ id: "pickle-1", status: "cancelled" });

    cli.ws.send(JSON.stringify({
      id: "cmd-main-cli-abort",
      protocolVersion: PROTOCOL_VERSION,
      type: "controlPickle",
      pickleAction: "abort",
      caller: "mainAgent",
      sessionId: "pickle-1",
    }));

    const request = await waitForEvent(app.ws, "pickleBridgeRequested");
    expect(request).toMatchObject({ operation: "abort", sessionId: "pickle-1" });
    if (request.type !== "pickleBridgeRequested") throw new Error("expected abort bridge request");
    const update = waitForEvent(cli.ws, "sessionUpdated");
    app.ws.send(JSON.stringify({
      id: "cmd-complete-cli-abort",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickleBridgeRequest",
      requestId: request.requestId,
      session,
    }));
    await expect(update).resolves.toMatchObject({ session: { id: "pickle-1", status: "cancelled" } });
    app.ws.close();
    cli.ws.close();
  });

  it("rejects a pending Pickle bridge request when its recipient disconnects", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-register-bridge-disconnect", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");

    const pending = server.requestPickleBridgeFromApp({ operation: "listSessions" }, 5_000);
    await waitForEvent(ws, "pickleBridgeRequested");
    const rejection = pending.then(
      () => { throw new Error("expected bridge request to reject"); },
      (error: Error) => error,
    );
    ws.close();

    await expect(Promise.race([
      rejection,
      sleep(100).then(() => { throw new Error("bridge request did not reject after recipient disconnect"); }),
    ])).resolves.toMatchObject({ message: expect.stringMatching(/handoff unavailable/) });
  });

  it("keeps a pending Pickle bridge request alive when another client disconnects", async () => {
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({ id: "cmd-register-bridge-primary", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["pickleBridge"] }));
    await waitForRegisteredCapability("pickleBridge");
    const { ws: otherWs } = await connectWithHello();

    const pending = server.requestPickleBridgeFromApp({ operation: "listSessions" });
    const request = await waitForEvent(appWs, "pickleBridgeRequested");
    if (request.type !== "pickleBridgeRequested") throw new Error("expected bridge request");
    otherWs.close();
    await sleep(50);
    appWs.send(JSON.stringify({ id: "cmd-complete-bridge-primary", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: request.requestId, sessions: [] }));

    await expect(pending).resolves.toEqual({ sessions: [] });
    appWs.close();
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

  it("keeps Edge TTS routes absent when the primary service is not injected", async () => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/edge-tts/voices`, {
      headers: { Authorization: "Bearer test-token" },
    });
    expect(response.status).toBe(404);
  });

  it("serves authenticated primary Edge TTS voices and MP3 while rejecting invalid requests", async () => {
    const edgeServer = new AgentdServer({
      port: 0,
      token: "edge-token",
      supervisor,
      edgeTTS: new EdgeTTSService(() => fakeEdgeClient()),
    });
    const edgePort = await edgeServer.start();
    const baseURL = `http://127.0.0.1:${edgePort}/v1/edge-tts`;
    try {
      const unauthorized = await fetch(`${baseURL}/voices`);
      expect(unauthorized.status).toBe(401);

      const voices = await fetch(`${baseURL}/voices`, { headers: { Authorization: "Bearer edge-token" } });
      expect(voices.status).toBe(200);
      await expect(voices.json()).resolves.toMatchObject({ voices: [{ shortName: "ko-KR-SunHiNeural" }] });

      const speech = await fetch(`${baseURL}/speech`, {
        method: "POST",
        headers: { Authorization: "Bearer edge-token", "Content-Type": "application/json" },
        body: JSON.stringify({ input: "안녕하세요", voice: "ko-KR-SunHiNeural" }),
      });
      expect(speech.status).toBe(200);
      expect(speech.headers.get("content-type")).toContain("audio/mpeg");
      expect(Buffer.from(await speech.arrayBuffer())).toEqual(Buffer.from("test-mp3"));

      const invalid = await fetch(`${baseURL}/speech`, {
        method: "POST",
        headers: { Authorization: "Bearer edge-token", "Content-Type": "application/json" },
        body: JSON.stringify({ input: "", voice: "ko-KR-SunHiNeural" }),
      });
      expect(invalid.status).toBe(400);

      const oversized = await fetch(`${baseURL}/speech`, {
        method: "POST",
        headers: { Authorization: "Bearer edge-token", "Content-Type": "application/json" },
        body: JSON.stringify({ input: "a".repeat(70_000), voice: "ko-KR-SunHiNeural" }),
      });
      expect(oversized.status).toBe(413);
    } finally {
      await edgeServer.stop();
    }
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

  it("submitMainFromExternal with captureContext=false routes via supervisor without involving the app", async () => {
    const route = vi.spyOn(supervisor, "route");
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-cli-submit",
      protocolVersion: PROTOCOL_VERSION,
      type: "submitMainFromExternal",
      text: "hello from cli",
      captureContext: false,
      cwd: "/tmp/cli-cwd",
    }));
    const ack = await waitForEvent(ws, "externalEntryAck");
    expect(ack).toMatchObject({ commandId: "cmd-cli-submit", kind: "submitMain" });
    expect(ack).not.toHaveProperty("errorMessage");
    expect(route).toHaveBeenCalledWith(
      expect.objectContaining({
        source: "cli",
        transcript: "hello from cli",
        cwd: "/tmp/cli-cwd",
      }),
    );
    ws.close();
  });

  it("locks submitMainFromExternal CLI sockets to v1 for created and terminal session projections", async () => {
    const { ws } = await connectWithHello();
    trackEvents(ws);

    ws.send(JSON.stringify({
      id: "cmd-cli-submit-wait-projection",
      protocolVersion: PROTOCOL_VERSION,
      type: "submitMainFromExternal",
      text: "create a Pickle and wait",
      captureContext: false,
    }));

    const created = await waitForEvent(ws, "sessionUpdated");
    expect(created).toMatchObject({ session: { status: "queued" } });
    if (created.type !== "sessionUpdated") throw new Error("Expected a session update");
    const sessionId = created.session.id;

    await expect(waitForEvent(ws, "externalEntryAck")).resolves.toMatchObject({
      commandId: "cmd-cli-submit-wait-projection",
      kind: "submitMain",
      sessionId,
    });

    await (supervisor as unknown as {
      patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
    }).patch(sessionId, { status: "completed" });
    await expect(waitForMatchingEvent(
      ws,
      (event) => event.type === "sessionMetaUpdated" && event.session.id === sessionId && event.session.status === "completed",
    )).resolves.toMatchObject({ session: { id: sessionId, status: "completed" } });
    ws.close();
  });

  it("createPickleFromExternal with captureContext=false creates a Pickle session and acks with sessionId", async () => {
    const create = vi.spyOn(supervisor, "createPickleFromHandoff");
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-cli-pickle",
      protocolVersion: PROTOCOL_VERSION,
      type: "createPickleFromExternal",
      title: "CLI pickle",
      instructions: "do the thing",
      captureContext: false,
      cwd: "/tmp/cli-pickle-cwd",
    }));
    const ack = await waitForEvent(ws, "externalEntryAck");
    expect(ack).toMatchObject({ commandId: "cmd-cli-pickle", kind: "createPickle" });
    if (ack.type === "externalEntryAck") expect(ack.sessionId).toBeDefined();
    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({ source: "cli", cwd: "/tmp/cli-pickle-cwd" }),
      expect.objectContaining({ title: "CLI pickle", instructions: "do the thing", cwd: "/tmp/cli-pickle-cwd" }),
    );
    ws.close();
  });

  it("submitMainFromExternal with captureContext=true acks with error when no app is registered", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({
      id: "cmd-cli-submit-no-app",
      protocolVersion: PROTOCOL_VERSION,
      type: "submitMainFromExternal",
      text: "need context",
      captureContext: true,
    }));
    const ack = await waitForEvent(ws, "externalEntryAck");
    expect(ack).toMatchObject({
      commandId: "cmd-cli-submit-no-app",
      kind: "submitMain",
      errorMessage: expect.stringContaining("unavailable"),
    });
    ws.close();
  });

  it("createPickleFromExternal with captureContext=true round-trips context through the registered app", async () => {
    const create = vi.spyOn(supervisor, "createPickleFromHandoff");
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({
      id: "cmd-register",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["externalEntry"],
    }));
    await waitForRegisteredCapability("externalEntry");

    const { ws: cliWs } = await connectWithHello();
    cliWs.send(JSON.stringify({
      id: "cmd-cli-pickle-bridge",
      protocolVersion: PROTOCOL_VERSION,
      type: "createPickleFromExternal",
      title: "Bridge pickle",
      instructions: "do the bridged thing",
      captureContext: true,
      group: "Research",
    }));

    const requested = await waitForEvent(appWs, "externalEntryRequested");
    expect(requested).toMatchObject({ kind: "createPickle", title: "Bridge pickle", instructions: "do the bridged thing" });
    const requestId = requested.type === "externalEntryRequested" ? requested.requestId : "";
    const capturedContext: PickyContextPacket = {
      ...context("captured by app"),
      id: "context-cli-bridge",
      source: "cli",
      cwd: "/tmp/captured",
    };
    trackEvents(cliWs);
    appWs.send(JSON.stringify({
      id: "cmd-complete-external",
      protocolVersion: PROTOCOL_VERSION,
      type: "completeExternalEntryRequest",
      requestId,
      context: capturedContext,
    }));

    const accepted = await waitForEvent(appWs, "externalEntryAccepted");
    expect(accepted).toMatchObject({ commandId: "cmd-cli-pickle-bridge", kind: "createPickle", contextId: "context-cli-bridge", group: "Research" });
    if (accepted.type === "externalEntryAccepted") expect(accepted.sessionId).toBeDefined();

    const ack = await waitForEvent(cliWs, "externalEntryAck");
    expect(ack).toMatchObject({ commandId: "cmd-cli-pickle-bridge", kind: "createPickle" });
    if (ack.type === "externalEntryAck") expect(ack.sessionId).toBeDefined();
    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({ id: "context-cli-bridge", source: "cli", cwd: "/tmp/captured" }),
      expect.objectContaining({ title: "Bridge pickle", instructions: "do the bridged thing" }),
    );
    appWs.close();
    cliWs.close();
  });

  it("listDockGroups round-trips groups through the registered app", async () => {
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({
      id: "cmd-register-groups",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["externalEntry"],
    }));
    await waitForRegisteredCapability("externalEntry");

    const { ws: cliWs } = await connectWithHello();
    cliWs.send(JSON.stringify({ id: "cmd-list-groups", protocolVersion: PROTOCOL_VERSION, type: "listDockGroups" }));

    const request = await waitForEvent(appWs, "dockGroupsRequested");
    const requestId = request.type === "dockGroupsRequested" ? request.requestId : "";
    appWs.send(JSON.stringify({
      id: "cmd-complete-groups",
      protocolVersion: PROTOCOL_VERSION,
      type: "completeDockGroupsRequest",
      requestId,
      groups: [{ id: "group-1", name: "Research", color: 6, memberSessionIds: ["p-1"], collapsed: false }],
    }));

    const snapshot = await waitForEvent(cliWs, "dockGroupsSnapshot");
    expect(snapshot).toMatchObject({ type: "dockGroupsSnapshot", groups: [{ id: "group-1", name: "Research", memberSessionIds: ["p-1"] }] });
    appWs.close();
    cliWs.close();
  });

  it("rejects pending dock group requests when the registered app disconnects", async () => {
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({
      id: "cmd-register-groups-disconnect",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["externalEntry"],
    }));
    await waitForRegisteredCapability("externalEntry");

    const { ws: cliWs } = await connectWithHello();
    cliWs.send(JSON.stringify({ id: "cmd-list-groups-disconnect", protocolVersion: PROTOCOL_VERSION, type: "listDockGroups" }));

    await waitForEvent(appWs, "dockGroupsRequested");
    const pendingError = waitForEvent(cliWs, "error", 500);
    appWs.close();

    await expect(pendingError).resolves.toMatchObject({
      type: "error",
      commandId: "cmd-list-groups-disconnect",
      message: expect.stringContaining("dock groups unavailable"),
    });
    cliWs.close();
  });

  it("keeps pending dock group requests alive when a different registered app disconnects", async () => {
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({
      id: "cmd-register-groups-primary",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["externalEntry"],
    }));
    await waitForRegisteredCapability("externalEntry");

    const { ws: otherAppWs } = await connectWithHello();
    otherAppWs.send(JSON.stringify({
      id: "cmd-register-groups-secondary",
      protocolVersion: PROTOCOL_VERSION,
      type: "registerAppCapabilities",
      capabilities: ["externalEntry"],
    }));
    await sleep(20);

    const { ws: cliWs } = await connectWithHello();
    cliWs.send(JSON.stringify({ id: "cmd-list-groups-survives-other-close", protocolVersion: PROTOCOL_VERSION, type: "listDockGroups" }));

    const request = await waitForEvent(appWs, "dockGroupsRequested");
    const requestId = request.type === "dockGroupsRequested" ? request.requestId : "";
    otherAppWs.close();
    await sleep(50);

    appWs.send(JSON.stringify({
      id: "cmd-complete-groups-primary",
      protocolVersion: PROTOCOL_VERSION,
      type: "completeDockGroupsRequest",
      requestId,
      groups: [{ id: "group-1", name: "Research", color: 6, memberSessionIds: [], collapsed: false }],
    }));

    const snapshot = await waitForEvent(cliWs, "dockGroupsSnapshot");
    expect(snapshot).toMatchObject({ type: "dockGroupsSnapshot", groups: [{ id: "group-1", name: "Research" }] });
    appWs.close();
    cliWs.close();
  });

  // MARK: - external entry serialisation (Q3)

  it("processes two captureContext=false CLI submits serially even when sent back-to-back", async () => {
    // Q3 policy: only one external CLI submission is processed at a time. Spy on
    // supervisor.route so we can see the exact order it was invoked, and assert
    // the acks arrive in the same FIFO order.
    const callOrder: string[] = [];
    const route = vi.spyOn(supervisor, "route").mockImplementation(async (context) => {
      callOrder.push(context.transcript ?? "<no-transcript>");
      // Force the first call to take noticeably longer than the second so a parallel
      // implementation would interleave and the ack order would diverge from the
      // submission order.
      const isFirst = context.transcript === "first cli";
      await sleep(isFirst ? 40 : 5);
      return undefined;
    });
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-cli-1", protocolVersion: PROTOCOL_VERSION, type: "submitMainFromExternal", text: "first cli", captureContext: false }));
    ws.send(JSON.stringify({ id: "cmd-cli-2", protocolVersion: PROTOCOL_VERSION, type: "submitMainFromExternal", text: "second cli", captureContext: false }));

    const firstAck = await waitForEvent(ws, "externalEntryAck");
    const secondAck = await waitForEvent(ws, "externalEntryAck");

    expect(firstAck).toMatchObject({ commandId: "cmd-cli-1", kind: "submitMain" });
    expect(secondAck).toMatchObject({ commandId: "cmd-cli-2", kind: "submitMain" });
    expect(callOrder).toEqual(["first cli", "second cli"]);
    expect(route).toHaveBeenCalledTimes(2);
    ws.close();
  });

  it("keeps the second CLI submit waiting until the first one's app-side context capture round-trip resolves", async () => {
    // Same FIFO guarantee but for the captureContext=true path — the app's context
    // capture round-trip can take hundreds of ms and is the most likely place for a
    // parallel implementation to surface as out-of-order acks.
    const create = vi.spyOn(supervisor, "createPickleFromHandoff");
    const { ws: appWs } = await connectWithHello();
    appWs.send(JSON.stringify({ id: "cmd-register", protocolVersion: PROTOCOL_VERSION, type: "registerAppCapabilities", capabilities: ["externalEntry"] }));
    await waitForRegisteredCapability("externalEntry");

    const { ws: cliWs } = await connectWithHello();
    cliWs.send(JSON.stringify({ id: "cmd-q3-1", protocolVersion: PROTOCOL_VERSION, type: "createPickleFromExternal", title: "first pickle", instructions: "first", captureContext: true }));
    cliWs.send(JSON.stringify({ id: "cmd-q3-2", protocolVersion: PROTOCOL_VERSION, type: "createPickleFromExternal", title: "second pickle", instructions: "second", captureContext: true }));

    // Only the first externalEntryRequested fires until we complete it; the second
    // entry stays queued.
    const firstRequest = await waitForEvent(appWs, "externalEntryRequested");
    expect(firstRequest).toMatchObject({ title: "first pickle" });

    // Confirm the second request has not been emitted yet by giving the chain time
    // to advance if it were going to.
    await sleep(50);
    const bufferedAppEvents = (eventBuffers.get(appWs) ?? []).map((event) => event.type);
    expect(bufferedAppEvents.filter((type) => type === "externalEntryRequested")).toHaveLength(0);

    // Complete the first capture so the chain advances to the second.
    const firstRequestId = firstRequest.type === "externalEntryRequested" ? firstRequest.requestId : "";
    appWs.send(JSON.stringify({
      id: "cmd-q3-complete-1",
      protocolVersion: PROTOCOL_VERSION,
      type: "completeExternalEntryRequest",
      requestId: firstRequestId,
      context: { ...context("first capture"), id: "context-q3-1", source: "cli" },
    }));

    const firstAck = await waitForEvent(cliWs, "externalEntryAck");
    expect(firstAck).toMatchObject({ commandId: "cmd-q3-1" });

    // Now the second entry is in flight — second externalEntryRequested fires.
    const secondRequest = await waitForEvent(appWs, "externalEntryRequested");
    expect(secondRequest).toMatchObject({ title: "second pickle" });
    const secondRequestId = secondRequest.type === "externalEntryRequested" ? secondRequest.requestId : "";
    appWs.send(JSON.stringify({
      id: "cmd-q3-complete-2",
      protocolVersion: PROTOCOL_VERSION,
      type: "completeExternalEntryRequest",
      requestId: secondRequestId,
      context: { ...context("second capture"), id: "context-q3-2", source: "cli" },
    }));

    const secondAck = await waitForEvent(cliWs, "externalEntryAck");
    expect(secondAck).toMatchObject({ commandId: "cmd-q3-2" });

    expect(create).toHaveBeenCalledTimes(2);
    expect((create.mock.calls[0]?.[1] as { title?: string }).title).toBe("first pickle");
    expect((create.mock.calls[1]?.[1] as { title?: string }).title).toBe("second pickle");
    appWs.close();
    cliWs.close();
  });

  it("continues processing the queue when a CLI submit's supervisor call throws", async () => {
    // A bug in one CLI submit must not poison the chain. Force the first route call
    // to throw; the second must still receive its ack.
    const route = vi.spyOn(supervisor, "route")
      .mockRejectedValueOnce(new Error("deliberate boom"))
      .mockResolvedValueOnce(undefined);
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-poison-1", protocolVersion: PROTOCOL_VERSION, type: "submitMainFromExternal", text: "bad", captureContext: false }));
    ws.send(JSON.stringify({ id: "cmd-poison-2", protocolVersion: PROTOCOL_VERSION, type: "submitMainFromExternal", text: "good", captureContext: false }));

    const firstAck = await waitForEvent(ws, "externalEntryAck");
    expect(firstAck).toMatchObject({ commandId: "cmd-poison-1", errorMessage: expect.stringContaining("deliberate boom") });
    const secondAck = await waitForEvent(ws, "externalEntryAck");
    expect(secondAck).toMatchObject({ commandId: "cmd-poison-2" });
    expect(secondAck).not.toHaveProperty("errorMessage");
    expect(route).toHaveBeenCalledTimes(2);
    ws.close();
  });

  it("stop() does not hang when external entries are still queued", async () => {
    // Real life: agentd is shutting down while a CLI submit is still queued. The
    // chain must short-circuit so stop() returns promptly instead of waiting for
    // every pending route call to settle naturally. We can't reliably assert that
    // the queued entries receive an ack — stop() closes their ws before the chain
    // reaches them — but the externalEntryStopping flag must drain the queue.
    const route = vi.spyOn(supervisor, "route").mockImplementation(async () => {
      await sleep(500);
      return undefined;
    });
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-stop-1", protocolVersion: PROTOCOL_VERSION, type: "submitMainFromExternal", text: "slow", captureContext: false }));
    ws.send(JSON.stringify({ id: "cmd-stop-2", protocolVersion: PROTOCOL_VERSION, type: "submitMainFromExternal", text: "queued", captureContext: false }));
    await sleep(10);

    const stopStartedAt = Date.now();
    await server.stop();
    const stopDurationMs = Date.now() - stopStartedAt;

    // Without the stopping flag the chain would block stop() until both 500ms
    // route mocks settled (>1s total); the short-circuit keeps it well under that.
    expect(stopDurationMs).toBeLessThan(800);
    void route;
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
      // 15 user_text turns, each followed by 9 assistant messages (thinking + activity + text).
      // The snapshot must slice from the 10th-last user turn onward to match the HUD's
      // visibleMessages window so the first sessionUpdated arrives without a layout shift.
      messages: Array.from({ length: 150 }, (_, index) => ({
        id: `msg-${index}`,
        kind: (index % 10 === 0 ? "user_text" : "agent_text") as "user_text" | "agent_text",
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
    // 15 user turns total → snapshot keeps the last 10 user turns and everything after
    // (msg-50 onward = 100 messages). Earlier history is dropped.
    expect(compact.messages?.length).toBe(100);
    expect(compact.messages?.[0]?.id).toBe("msg-50");
    expect(compact.messages?.[0]?.kind).toBe("user_text");
    expect(compact.messages?.filter((m) => m.kind === "user_text").length).toBe(10);
    // User-visible message text is sent in full — the snapshot only trims the message
    // window, never per-message bodies, so the report viewer cannot show a truncated
    // copy that lingers between the initial sessionSnapshot and the next sessionUpdated event.
    const lastMessageText = compact.messages?.at(-1)?.text ?? "";
    expect(lastMessageText.endsWith("…")).toBe(false);
    expect(lastMessageText.length).toBeGreaterThan(10_000);
  });

  it("returns all messages when fewer than the user-turn window exists", () => {
    const session = makeSession({
      messages: [
        { id: "m1", kind: "system", createdAt: "2026-05-03T00:00:00.000Z", text: "hello" },
        { id: "m2", kind: "user_text", createdAt: "2026-05-03T00:00:00.000Z", text: "first" },
        { id: "m3", kind: "agent_text", createdAt: "2026-05-03T00:00:00.000Z", text: "reply" },
        { id: "m4", kind: "user_text", createdAt: "2026-05-03T00:00:00.000Z", text: "second" },
        { id: "m5", kind: "agent_text", createdAt: "2026-05-03T00:00:00.000Z", text: "reply" },
      ],
    });

    const [compact] = compactSessionsForSnapshot([session]);

    // Only 2 user turns (< window of 10) → snapshot keeps everything, including the
    // leading system message, so the HUD's visibleMessages fallback path matches.
    expect(compact.messages?.map((m) => m.id)).toEqual(["m1", "m2", "m3", "m4", "m5"]);
  });
});

function fakeEdgeClient(): EdgeTTSClient {
  return {
    getVoices: async () => [{
      ShortName: "ko-KR-SunHiNeural",
      Locale: "ko-KR",
      Gender: "Female",
      FriendlyName: "SunHi",
      Name: "Microsoft Server Speech Text to Speech Voice (ko-KR, SunHiNeural)",
      SuggestedCodec: "audio-24khz-48kbitrate-mono-mp3",
      Status: "GA",
    }],
    setMetadata: async () => {},
    toStream: () => ({ audioStream: Readable.from([Buffer.from("test-mp3")]) }),
    close: () => {},
  };
}

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

function makeLargeSessionSnapshotFixtures(): PickyAgentSession[] {
  const largeMessageText = "m".repeat(1_000_000);
  return Array.from({ length: 20 }, (_, index) => makeSession({
    id: `large-session-${index}`,
    title: `Large session ${index}`,
    messages: [{
      id: `large-message-${index}`,
      kind: "agent_text",
      createdAt: "2026-08-23T00:00:01.000Z",
      text: largeMessageText,
    }],
  }));
}

function makeNormalSessionBootstrapFixtures(): PickyAgentSession[] {
  return Array.from({ length: 94 }, (_, index) => makeSession({
    id: `bootstrap-session-${index}`,
    title: `Bootstrap session ${index}`,
    messages: [{
      id: `bootstrap-message-${index}`,
      kind: "agent_text",
      createdAt: "2026-08-23T00:00:01.000Z",
      text: `Normal bootstrap message ${index}`,
    }],
  }));
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

async function registerV2(ws: WebSocket, id: string): Promise<void> {
  ws.send(JSON.stringify({
    id,
    protocolVersion: PROTOCOL_VERSION,
    type: "registerAppCapabilities",
    capabilities: ["sessionProjectionV2"],
  }));
  await waitForEvent(ws, "ack");
}

const eventBuffers = new WeakMap<WebSocket, EventEnvelope[]>();

function trackEvents(ws: WebSocket): void {
  if (eventBuffers.has(ws)) return;
  const buffer: EventEnvelope[] = [];
  eventBuffers.set(ws, buffer);
  ws.on("message", (data) => {
    try { buffer.push(JSON.parse(data.toString()) as EventEnvelope); } catch { /* ignore */ }
  });
}

async function waitForEvent(ws: WebSocket, type: EventEnvelope["type"], timeoutMs = 2_000): Promise<EventEnvelope> {
  trackEvents(ws);
  const buffer = eventBuffers.get(ws)!;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const index = buffer.findIndex((event) => event.type === type);
    if (index >= 0) {
      const [match] = buffer.splice(index, 1);
      return match!;
    }
    await sleep(20);
  }
  throw new Error(`Timed out waiting for event ${type}; buffered=${buffer.map((e) => e.type).join(",")}`);
}

async function waitForMatchingEvent(
  ws: WebSocket,
  predicate: (event: EventEnvelope) => boolean,
  timeoutMs = 2_000,
): Promise<EventEnvelope> {
  trackEvents(ws);
  const buffer = eventBuffers.get(ws)!;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const index = buffer.findIndex(predicate);
    if (index >= 0) {
      const [match] = buffer.splice(index, 1);
      return match!;
    }
    await sleep(20);
  }
  throw new Error(`Timed out waiting for matching event; buffered=${buffer.map((event) => event.type).join(",")}`);
}

async function nextEventWithin(ws: WebSocket, timeoutMs: number): Promise<EventEnvelope | undefined> {
  return await Promise.race([
    nextEvent(ws),
    new Promise<undefined>((resolve) => setTimeout(() => resolve(undefined), timeoutMs)),
  ]);
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function waitForRegisteredCapability(capability: string): Promise<void> {
  const visibleServer = server as unknown as { firstClientWithCapability: (capability: string) => WebSocket | undefined };
  await waitUntil(() => Boolean(visibleServer.firstClientWithCapability(capability)));
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
