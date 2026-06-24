import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, parseCommand, type EventEnvelope, type PickyAgentSession, type PickyContextPacket } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { AgentdServer, commandLogFields, compactSessionsForSnapshot, sanitizeForJson } from "./server.js";
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

  it("broadcasts an empty Picky message snapshot after resetting Picky", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-reset-main", protocolVersion: PROTOCOL_VERSION, type: "resetMainAgent" }));
    const snapshot = await nextEvent(ws);
    expect(snapshot.type).toBe("mainMessagesSnapshot");
    if (snapshot.type === "mainMessagesSnapshot") expect(snapshot.messages).toEqual([]);
    ws.close();
  });

  it("includes the reloadPlugins command id on pluginsReloaded broadcasts", async () => {
    const { ws } = await connectWithHello();
    ws.send(JSON.stringify({ id: "cmd-reload-plugins", protocolVersion: PROTOCOL_VERSION, type: "reloadPlugins" }));
    const reloaded = await waitForEvent(ws, "pluginsReloaded");
    expect(reloaded).toMatchObject({ type: "pluginsReloaded", requestId: "cmd-reload-plugins" });
    ws.close();
  });

  it("broadcasts toolActivityUpdated events", async () => {
    const { ws } = await connectWithHello();
    const pendingToolEvent = waitForEvent(ws, "toolActivityUpdated");

    supervisor.emit("toolActivityUpdated", "session-tools", { toolCallId: "tool-1", name: "bash", status: "running", preview: "npm test" });

    await expect(pendingToolEvent).resolves.toMatchObject({
      type: "toolActivityUpdated",
      sessionId: "session-tools",
      tool: { toolCallId: "tool-1", name: "bash", status: "running", preview: "npm test" },
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
    ws.send(JSON.stringify({ id: "cmd-steer", protocolVersion: PROTOCOL_VERSION, type: "steer", sessionId: session.id, text: "inspect this", context: steerContext }));

    await waitUntil(() => steer.mock.calls.length > 0);

    expect(steer).toHaveBeenCalledWith(session.id, "inspect this", expect.objectContaining({ id: "context-visual-steer", screenshots: [expect.objectContaining({ path: "/tmp/shot.png" })] }));
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
    ws.send(JSON.stringify({ id: "cmd-complete-bridge", protocolVersion: PROTOCOL_VERSION, type: "completePickleBridgeRequest", requestId: request.requestId, sessions: [session] }));

    await expect(pending).resolves.toMatchObject({ sessions: [expect.objectContaining({ id: "child-pickle" })] });
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

  it("redacts realtime secrets and audio payloads from command logs", () => {
    const auth = parseCommand({
      id: "cmd-auth",
      protocolVersion: PROTOCOL_VERSION,
      type: "configureMainRealtimeAuth",
      provider: "openai",
      apiKey: "sk-secret-should-not-log",
      modelOrDeployment: "gpt-realtime-2",
      voice: "marin",
    });
    const audio = parseCommand({
      id: "cmd-audio",
      protocolVersion: PROTOCOL_VERSION,
      type: "appendMainRealtimeInputAudio",
      inputId: "input-1",
      audioBase64: "SECRET_AUDIO_BASE64",
    });

    const azureAuth = parseCommand({
      id: "cmd-azure-auth",
      protocolVersion: PROTOCOL_VERSION,
      type: "configureMainRealtimeAuth",
      provider: "azure_openai",
      apiKey: "azure-secret-should-not-log",
      modelOrDeployment: "gpt-realtime-1.5",
      voice: "marin",
      azure: {
        resourceEndpoint: "https://x.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5",
        apiShape: "preview",
        apiVersion: "2024-10-01-preview",
      },
    });

    expect(JSON.stringify(commandLogFields(auth))).not.toContain("sk-secret-should-not-log");
    expect(commandLogFields(auth)).toMatchObject({ keyPresent: 1 });
    expect(JSON.stringify(commandLogFields(azureAuth))).not.toContain("azure-secret-should-not-log");
    expect(JSON.stringify(commandLogFields(azureAuth))).not.toContain("api-version");
    expect(commandLogFields(azureAuth)).toMatchObject({ keyPresent: 1, endpointHost: "x.openai.azure.com" });
    expect(JSON.stringify(commandLogFields(audio))).not.toContain("SECRET_AUDIO_BASE64");
    expect(commandLogFields(audio)).toMatchObject({ audioBytesBase64Chars: "SECRET_AUDIO_BASE64".length });
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
      // 8 user_text turns, each followed by 9 assistant messages (thinking + activity + text).
      // The snapshot must slice from the 5th-last user turn onward to match the HUD's
      // visibleMessages window so the first sessionUpdated arrives without a layout shift.
      messages: Array.from({ length: 80 }, (_, index) => ({
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
    // 8 user turns total → snapshot keeps the last 5 user turns and everything after
    // (msg-30 onward = 50 messages). Earlier history is dropped.
    expect(compact.messages?.length).toBe(50);
    expect(compact.messages?.[0]?.id).toBe("msg-30");
    expect(compact.messages?.[0]?.kind).toBe("user_text");
    expect(compact.messages?.filter((m) => m.kind === "user_text").length).toBe(5);
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

    // Only 2 user turns (< window of 5) → snapshot keeps everything, including the
    // leading system message, so the HUD's visibleMessages fallback path matches.
    expect(compact.messages?.map((m) => m.id)).toEqual(["m1", "m2", "m3", "m4", "m5"]);
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
