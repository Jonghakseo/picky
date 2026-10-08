import { execFile } from "node:child_process";
import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installInternalPickyCli } from "../../application/internal-picky-cli.js";
import { writeConnectionInfo } from "../../connection-info-store.js";
import { PROTOCOL_VERSION, type EventEnvelope, type PickyAgentSession, type PickyContextPacket } from "../../protocol.js";
import { MockRuntime } from "../../runtime/mock-runtime.js";
import { AgentdServer } from "../../server.js";
import { SessionStore } from "../../session-store.js";
import { SessionSupervisor } from "../../session-supervisor.js";
import { createPickyCliCallerBinding, type PickyCliCallerBinding } from "../../runtime/picky-cli-context.js";
import { applySessionProjectionSnapshot, applySessionProjectionTransaction, emptySessionProjectionState, materializeSessionProjection } from "../../domain/session-projection-reducer.js";

const execFileAsync = promisify(execFile);
const here = fileURLToPath(new URL(".", import.meta.url));
const cliEntry = resolve(here, "..", "..", "cli.ts");
const tsxBin = resolve(here, "..", "..", "..", "node_modules", ".bin", "tsx");
const tsxLoader = resolve(here, "..", "..", "..", "node_modules", "tsx", "dist", "loader.mjs");
const internalCliModuleUrl = pathToFileURL(resolve(here, "..", "..", "application", "internal-picky-cli.ts")).href;

let server: AgentdServer;
let supervisor: SessionSupervisor;
let port: number;
let appSupportDir: string;
let appSockets: WebSocket[];
let appCommandSequence = 0;
const callerBindings: PickyCliCallerBinding[] = [];

beforeEach(async () => {
  appSupportDir = await mkdtemp(join(tmpdir(), "picky-cli-e2e-"));
  supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(appSupportDir));
  await supervisor.load();
  server = new AgentdServer({ port: 0, token: "cli-e2e-token", supervisor });
  port = await server.start();
  appSockets = [];
  appCommandSequence = 0;
  await writeConnectionInfo(appSupportDir, {
    protocolVersion: PROTOCOL_VERSION,
    url: `ws://127.0.0.1:${port}`,
    token: "cli-e2e-token",
    port,
    pid: process.pid,
    appSupportDir,
    defaultCwd: appSupportDir,
    startedAt: new Date().toISOString(),
  });
});

afterEach(async () => {
  for (const binding of callerBindings.splice(0)) binding.dispose();
  for (const socket of appSockets) socket.close();
  await Promise.all(appSockets.map(async (socket) => {
    if (socket.readyState !== WebSocket.CLOSED) await once(socket, "close");
  }));
  await server.stop();
});

async function runCli(args: string[], env: NodeJS.ProcessEnv = {}, timeoutMs?: number): Promise<{ stdout: string; stderr: string; code: number }> {
  return await runExecutable(tsxBin, [cliEntry, ...args], {
    ...process.env,
    PICKY_APP_SUPPORT_DIR: appSupportDir,
    ...env,
  }, timeoutMs);
}

async function runExecutable(executable: string, args: string[], env: NodeJS.ProcessEnv, timeoutMs?: number): Promise<{ stdout: string; stderr: string; code: number }> {
  try {
    const result = await execFileAsync(executable, args, { env, timeout: timeoutMs });
    return { stdout: result.stdout, stderr: result.stderr, code: 0 };
  } catch (error) {
    const result = error as { stdout?: string; stderr?: string; code?: number };
    return { stdout: result.stdout ?? "", stderr: result.stderr ?? "", code: result.code ?? 1 };
  }
}

async function connectApp(
  capabilities: Array<"pickleBridge" | "externalEntry" | "sessionProjectionV2">,
  onEvent: (event: EventEnvelope, socket: WebSocket) => void,
): Promise<WebSocket> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}?token=cli-e2e-token`);
  let registered = false;
  const registrationId = `app-command-${appCommandSequence + 1}`;
  socket.on("message", (data) => {
    const event = JSON.parse(data.toString()) as EventEnvelope;
    if (event.type === "ack" && event.commandId === registrationId) registered = true;
    onEvent(event, socket);
  });
  await once(socket, "open");
  sendAppCommand(socket, { type: "registerAppCapabilities", capabilities });
  appSockets.push(socket);
  await waitUntil(() => registered);
  return socket;
}

function sendAppCommand(socket: WebSocket, command: Record<string, unknown>): void {
  socket.send(JSON.stringify({
    id: `app-command-${++appCommandSequence}`,
    protocolVersion: PROTOCOL_VERSION,
    ...command,
  }));
}

async function waitUntil(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function context(text: string): PickyContextPacket {
  return {
    id: `context-${text}`,
    source: "text",
    capturedAt: "2026-08-25T00:00:00.000Z",
    transcript: text,
    cwd: appSupportDir,
    screenshots: [],
    inkMarks: [],
    warnings: [],
  };
}

describe("picky CLI against a real agentd server", () => {
  it("reports an unconfirmed result without retrying when the app disconnects after durable rename", async () => {
    const created = await supervisor.createEmptyPickleSession(context("lost-rename"));
    let renameRequests = 0;
    await connectApp(["pickleBridge"], (event, socket) => {
      if (event.type === "pickleBridgeRequested" && event.operation === "rename") {
        renameRequests += 1;
        sendAppCommand(socket, { id: "rename-before-disconnect", type: "renameSession", sessionId: event.sessionId, title: event.title });
      }
      if (event.type === "pickleSessionUpdated" && event.commandId === "rename-before-disconnect") socket.close();
    });
    const result = await runCli(["pickle-rename", created.id, "Persisted without reply", "--json"]);
    expect(result.code).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("result is unconfirmed");
    expect(renameRequests).toBe(1);
    expect((await new SessionStore(appSupportDir).loadReadOnly(created.id))?.title).toBe("Persisted without reply");
  });

  it.each(["pickle", "picky"])("resolves a live %s caller through the real owner and rejects its expired generation", async (kind) => {
    const created = kind === "pickle" ? await supervisor.createEmptyPickleSession(context("identity")) : undefined;
    const binding = createPickyCliCallerBinding(created?.id ?? "picky");
    callerBindings.push(binding);
    binding.bindPiSession("pi-identity");
    const pending = new Map<string, string>();
    await connectApp(["pickleBridge"], (event, socket) => {
      if (event.type === "pickleBridgeRequested" && event.operation === "resolveCaller") {
        const ownerId = `validate-${event.requestId}`;
        pending.set(ownerId, event.requestId);
        sendAppCommand(socket, { id: ownerId, type: "validateCliCaller", callerContext: event.callerContext });
      }
      if ((event.type === "ack" || event.type === "error") && event.commandId && pending.has(event.commandId)) {
        sendAppCommand(socket, {
          type: "completePickleBridgeRequest", requestId: pending.get(event.commandId),
          ...(event.type === "error" ? { errorMessage: event.message } : {
            delivered: true, session: created ? supervisor.get(created.id) : undefined,
            groups: created ? [{ id: "group-research", name: "Research", color: 0, collapsed: false, memberSessionIds: [created.id] }] : [],
          }),
        });
        pending.delete(event.commandId);
      }
    });
    const env = { PICKY_CLI_CONTEXT: JSON.stringify(binding.current()), PI_SESSION_ID: "pi-identity" };
    const result = await runCli(["whoami", "--json"], env);
    expect(result, result.stderr).toMatchObject({ code: 0 });
    if (created) {
      expect(JSON.parse(result.stdout)).toEqual({ schemaVersion: 1, kind: "pickle", id: created.id, name: created.title, status: created.status, cwd: created.cwd, createdAt: created.createdAt, group: { id: "group-research", name: "Research" } });
    } else {
      expect(JSON.parse(result.stdout)).toMatchObject({ schemaVersion: 1, kind: "picky", id: "picky", name: "Picky", status: "idle", createdAt: null, group: null });
      expect(supervisor.list()).toEqual([]);
    }
    binding.invalidate();
    const stale = await runCli(["whoami", "--json"], env);
    expect(stale.code).toBe(1);
    expect(stale.stdout).toBe("");
    expect(stale.stderr).toContain("replaced");
  });

  it("renames an empty Pickle through the owner command and durable v2 projection without starting work", async () => {
    const created = await supervisor.createEmptyPickleSession(context("rename empty"));
    const before = supervisor.get(created.id)!;
    const binding = createPickyCliCallerBinding(created.id);
    callerBindings.push(binding);
    binding.bindPiSession("pi-rename");
    let projection = emptySessionProjectionState(created.id);
    const pending = new Map<string, string>();
    await connectApp(["pickleBridge", "sessionProjectionV2"], (event, socket) => {
      if (event.type === "sessionProjectionSnapshot" && event.sessionId === created.id) projection = applySessionProjectionSnapshot(projection, event);
      if (event.type === "sessionProjectionTransaction" && event.sessionId === created.id) projection = applySessionProjectionTransaction(projection, event) ?? projection;
      if (event.type === "pickleBridgeRequested" && event.operation === "rename") {
        const ownerId = `owner-${event.requestId}`;
        pending.set(ownerId, event.requestId);
        sendAppCommand(socket, { id: ownerId, type: "renameSession", sessionId: event.sessionId, title: event.title, callerContext: event.callerContext });
      }
      if ((event.type === "ack" || event.type === "error") && event.commandId && pending.has(event.commandId)) {
        sendAppCommand(socket, { type: "completePickleBridgeRequest", requestId: pending.get(event.commandId),
          ...(event.type === "error" ? { errorMessage: event.message } : { session: materializeSessionProjection(projection), delivered: true }),
        });
        pending.delete(event.commandId);
      }
    });
    await waitUntil(() => Boolean(materializeSessionProjection(projection)));

    const result = await runCli(["pickle-rename", "--self", "Saved label", "--json"], { PICKY_CLI_CONTEXT: JSON.stringify(binding.current()), PI_SESSION_ID: "pi-rename" });
    expect(result, result.stderr).toMatchObject({ code: 0 });
    const saved = await new SessionStore(appSupportDir).loadReadOnly(created.id);
    const rendered = materializeSessionProjection(projection)!;
    expect(saved).toMatchObject({ title: "Saved label", titleOrigin: "user", status: before.status });
    expect(saved?.archived).toBe(before.archived);
    expect(rendered).toMatchObject({ title: "Saved label", titleOrigin: "user", status: before.status });
    expect(rendered.messages).toEqual(before.messages ?? []);
    expect(JSON.parse(result.stdout)).toEqual({ schemaVersion: 1, id: created.id, name: "Saved label", revision: saved!.revision });
    expect(rendered.revision).toBe(saved!.revision);

    const repeated = await runCli(["pickle-rename", created.id, "Saved label", "--json"]);
    expect(repeated.code).toBe(0);
    expect(JSON.parse(repeated.stdout).revision).toBe(saved!.revision);
    const expiredEnv = { PICKY_CLI_CONTEXT: JSON.stringify(binding.current()), PI_SESSION_ID: "pi-rename" };
    binding.invalidate();
    const staleNoOp = await runCli(["pickle-rename", "--self", "Saved label", "--json"], expiredEnv);
    expect(staleNoOp.code).toBe(1);
    expect(staleNoOp.stderr).toContain("replaced");
    expect((await new SessionStore(appSupportDir).loadReadOnly(created.id))?.revision).toBe(saved!.revision);
  });

  it("does not let an ordinary CLI socket bypass app ownership for a stored rename", async () => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}?token=cli-e2e-token`);
    appSockets.push(socket);
    const errors: Array<Extract<EventEnvelope, { type: "error" }>> = [];
    socket.on("message", (data) => {
      const event = JSON.parse(data.toString()) as EventEnvelope;
      if (event.type === "error") errors.push(event);
    });
    await once(socket, "open");
    sendAppCommand(socket, { type: "renameStoredPickle", sessionId: "not-owned", title: "Do not write" });
    await waitUntil(() => errors.length > 0);
    expect(errors[0].message).toContain("app owner connection");
    expect(await new SessionStore(appSupportDir).loadReadOnly("not-owned")).toBeUndefined();
  });

  it("reports an idle main-turn handoff failure from the real server", async () => {
    // Regression: an incorrectly inherited main-agent identity must surface the
    // server's missing-main-context error instead of silently creating a Pickle.
    const result = await runCli([
      "pickle-create", "Main handoff", "--instructions", "Use the main turn", "--from-main",
    ]);

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("No active Picky main context to hand off");
  });

  it("creates an external no-context Pickle through the supervisor", async () => {
    // Regression: a caller-neutral Pickle must not inherit main-agent routing from
    // the daemon environment and be rejected for lacking a main-turn context.
    const result = await runCli([
      "pickle-create", "External Pickle", "--instructions", "Use the external route", "--no-context", "--json",
    ]);

    expect(result.code).toBe(0);
    const ack = JSON.parse(result.stdout) as { sessionId?: string };
    expect(ack.sessionId).toBeDefined();
    expect(supervisor.get(ack.sessionId!)).toMatchObject({
      id: ack.sessionId,
      title: "External Pickle",
    });
  });

  it("waits for the terminal pickleSessionUpdated reply after creating a Pickle", async () => {
    // The CLI never subscribes to session projection; `--wait` relies on the
    // daemon answering `awaitPickleSessionTerminal` once the session finishes.
    type ServerSend = {
      send(socket: WebSocket, payload: { type: string; sessionId?: string; session?: PickyAgentSession }): unknown;
    };
    const privateServer = server as unknown as ServerSend;
    const originalSend = privateServer.send.bind(server);
    let terminalPatch: Promise<void> | undefined;
    const sentTypes: string[] = [];
    vi.spyOn(privateServer, "send").mockImplementation((socket, payload) => {
      const result = originalSend(socket, payload);
      sentTypes.push(payload.type);
      if (payload.type === "externalEntryAck" && payload.sessionId && !terminalPatch) {
        // Queue after the ack frame, so the child CLI has installed its --wait
        // reply matcher before it receives the terminal event.
        terminalPatch = (supervisor as unknown as {
          patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
        }).patch(payload.sessionId, { status: "completed", finalAnswer: "Thin terminal answer" });
      }
      return result;
    });

    const result = await runCli([
      "pickle-create", "Wait for thin event", "--instructions", "Wait until done", "--no-context", "--wait",
    ]);

    await terminalPatch;
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Thin terminal answer");
    expect(sentTypes.filter((type) => type === "pickleSessionUpdated")).toEqual(["pickleSessionUpdated"]);
    expect(sentTypes.some((type) => type.startsWith("sessionProjection") || type === "sessionUpdated" || type === "sessionMetaUpdated")).toBe(false);
  });

  it("waits through blocked and resumed Pickle states before printing the final answer", async () => {
    type ServerDispatch = {
      dispatchCommand(socket: WebSocket, command: { type: string; sessionId?: string }): Promise<void>;
    };
    const privateServer = server as unknown as ServerDispatch;
    const originalDispatch = privateServer.dispatchCommand.bind(server);
    let waitedSessionId: string | undefined;
    vi.spyOn(privateServer, "dispatchCommand").mockImplementation(async (socket, command) => {
      await originalDispatch(socket, command);
      if (command.type !== "awaitPickleSessionTerminal") return;
      // The real handler has installed its waiter. A broadcaster also listens
      // for projection commits, so listenerCount alone cannot prove readiness.
      waitedSessionId = command.sessionId!;
      const patch = supervisor as unknown as {
        patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
      };
      await patch.patch(waitedSessionId, { status: "blocked", lastSummary: "Waiting for input" });
      await patch.patch(waitedSessionId, { status: "running", lastSummary: "Resumed" });
      await patch.patch(waitedSessionId, { status: "completed", finalAnswer: "Recovered final answer" });
    });

    const result = await runCli([
      "pickle-create", "Wait through block", "--instructions", "Resume after input", "--no-context", "--wait",
    ], {}, 10_000);

    expect(waitedSessionId).toBeDefined();
    expect(supervisor.get(waitedSessionId!)?.status).toBe("completed");
    expect(result).toMatchObject({ code: 0 });
    expect(result.stdout).toContain("Recovered final answer");
  }, 15_000);

  it("reports a missing Pickle from the real getPickle handler", async () => {
    // Regression: a bad session id must travel through the real bridge/getPickle
    // error envelope instead of a CLI process exiting successfully without notice.
    await connectApp(["pickleBridge"], (event, socket) => {
      if (event.type !== "pickleBridgeRequested") return;
      sendAppCommand(socket, {
        type: "completePickleBridgeRequest",
        requestId: event.requestId,
        sessions: [],
      });
    });

    const result = await runCli(["pickle-steer", "missing-pickle", "focus", "--from-main"]);

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Pickle session not found: missing-pickle");
  });

  it("prints v2 projection-backed bridge summaries without inventing a message journal", async () => {
    // Regression: an app registered for the v2 dialect receives bootstrap
    // snapshots, not v1 sessionUpdated events. Keep this harness state fed by
    // that actual frame before completing the same bridge request the CLI uses.
    const created = await supervisor.create(context("v2 bridge summary"));
    const projectionBackedSessions: PickyAgentSession[] = [];
    await connectApp(["pickleBridge", "externalEntry", "sessionProjectionV2"], (event, socket) => {
      if (event.type === "sessionProjectionSnapshot") {
        projectionBackedSessions.push({
          ...event.projection,
          messages: [],
          messageJournalAvailable: false,
        });
      }
      if (event.type === "pickleBridgeRequested") {
        sendAppCommand(socket, {
          type: "completePickleBridgeRequest",
          requestId: event.requestId,
          sessions: projectionBackedSessions,
        });
      }
      if (event.type === "dockGroupsRequested") {
        sendAppCommand(socket, {
          type: "completeDockGroupsRequest",
          requestId: event.requestId,
          groups: [],
        });
      }
    });
    await waitUntil(() => projectionBackedSessions.some((session) => session.id === created.id));

    const result = await runCli(["pickle-list", "--raw-json"]);

    expect(result.code).toBe(0);
    const snapshot = JSON.parse(result.stdout) as { sessions: Array<{ id: string; messages: unknown[]; messageJournalAvailable?: boolean }> };
    expect(snapshot.sessions).toEqual([expect.objectContaining({
      id: created.id,
      messages: [],
      messageJournalAvailable: false,
    })]);
  });

  it("executes the installed wrapper as a caller-neutral external CLI", async () => {
    // Regression: the generated wrapper must execute with shell-safe arguments and
    // must not let ambient PICKY_CLI_CALLER route a Pickle through main handoff.
    const wrapperEnv: NodeJS.ProcessEnv = { ...process.env, PATH: process.env.PATH };
    const wrapper = await installInternalPickyCli({
      appSupportDir,
      env: wrapperEnv,
      execPath: process.execPath,
      execArgv: ["--import", tsxLoader],
      moduleUrl: internalCliModuleUrl,
    });

    const version = await runExecutable(wrapper, ["--version"], wrapperEnv);
    const creation = await runExecutable(wrapper, [
      "pickle-create", "Wrapped Pickle", "--instructions", "Use the wrapper", "--no-context", "--json",
    ], { ...wrapperEnv, PICKY_CLI_CALLER: "mainAgent" });

    expect(version).toMatchObject({ code: 0, stdout: "0.1.0\n" });
    expect(creation.code).toBe(0);
    const ack = JSON.parse(creation.stdout) as { sessionId?: string };
    expect(supervisor.get(ack.sessionId!)).toMatchObject({
      id: ack.sessionId,
      title: "Wrapped Pickle",
    });
  });
});
