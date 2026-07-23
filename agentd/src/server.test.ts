import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import WebSocket from "ws";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, parseCommand, type EventEnvelope, type PickyAgentSession, type PickyContextPacket, type PickyExtensionUiRequest } from "./protocol.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { AgentdServer, commandLogFields, compactSessionsForSnapshot, createDefaultPackageManager, sanitizeForJson } from "./server.js";
import { EdgeTTSService, type EdgeTTSClient } from "./edge-tts-service.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import type { PiOAuthHandling } from "./application/pi-oauth-service.js";

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
    await expect(nextEvent(requester.ws)).resolves.toMatchObject({
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
    await expect(nextEvent(requester.ws)).resolves.toMatchObject({
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
    await expect(nextEvent(requester.ws)).resolves.toMatchObject({
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
