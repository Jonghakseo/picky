import { randomUUID } from "node:crypto";
import { createServer, type Server as HttpServer } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { isAuthorized } from "./auth.js";
import { PROTOCOL_VERSION, parseCommand, type EventEnvelope, type PickyAgentSession } from "./protocol.js";
import type { SessionSupervisor } from "./session-supervisor.js";
import { logAgentd } from "./local-log.js";

export interface AgentdServerOptions {
  port: number;
  token: string;
  supervisor: SessionSupervisor;
}

export class AgentdServer {
  private httpServer?: HttpServer;
  private wsServer?: WebSocketServer;
  private clients = new Set<WebSocket>();

  constructor(private readonly options: AgentdServerOptions) {}

  async start(): Promise<number> {
    this.httpServer = createServer();
    this.wsServer = new WebSocketServer({ noServer: true });

    this.httpServer.on("upgrade", (request, socket, head) => {
      if (!isAuthorized(request, this.options.token)) {
        logAgentd("ws unauthorized", { remoteAddress: request.socket.remoteAddress });
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
        socket.destroy();
        return;
      }
      this.wsServer?.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
    });

    this.options.supervisor.on("session", (session) => this.broadcast({ type: "sessionUpdated", session }));
    this.options.supervisor.on("log", (sessionId, line) => this.broadcast({ type: "sessionLogAppended", sessionId, line }));
    this.options.supervisor.on("extensionUiRequest", (request) => this.broadcast({ type: "extensionUiRequest", request }));
    this.options.supervisor.on("quickReply", (contextId, text) => this.broadcast({ type: "quickReply", contextId, text }));
    this.options.supervisor.on("pointerOverlayRequested", (request) => this.broadcast({ type: "pointerOverlayRequested", request }));
    this.options.supervisor.on("artifact", (sessionId, artifact) => this.broadcast({ type: "artifactUpdated", sessionId, artifact }));

    await new Promise<void>((resolve) => this.httpServer!.listen(this.options.port, "127.0.0.1", resolve));
    const address = this.httpServer.address();
    const boundPort = typeof address === "object" && address ? address.port : this.options.port;
    logAgentd("server listening", { port: boundPort });
    return boundPort;
  }

  async stop(): Promise<void> {
    for (const client of this.clients) client.close();
    await new Promise<void>((resolve) => this.wsServer?.close(() => resolve()) ?? resolve());
    await new Promise<void>((resolve) => this.httpServer?.close(() => resolve()) ?? resolve());
  }

  private accept(ws: WebSocket): void {
    this.clients.add(ws);
    logAgentd("ws connected", { clients: this.clients.size });
    ws.on("close", () => {
      this.clients.delete(ws);
      logAgentd("ws disconnected", { clients: this.clients.size });
    });
    ws.on("message", (data) => void this.handleMessage(ws, data.toString()));
    this.send(ws, { type: "hello", serverName: "picky-agentd", supportedProtocolVersions: [PROTOCOL_VERSION] });
  }

  private async handleMessage(ws: WebSocket, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
      const command = parseCommand(parsed);
      logAgentd("command received", commandLogFields(command));
      if (command.type === "listSessions") this.send(ws, { type: "sessionSnapshot", sessions: compactSessionsForSnapshot(this.options.supervisor.list()) });
      if (command.type === "getSession") {
        const session = this.options.supervisor.get(command.sessionId);
        if (!session) throw new Error(`Unknown session: ${command.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session });
      }
      if (command.type === "routeTask") await this.options.supervisor.route(command.context);
      if (command.type === "createTask") await this.options.supervisor.create(command.context);
      if (command.type === "pinSideSession") await this.options.supervisor.pinSideSession(command.context, command.title);
      if (command.type === "setNotifyMainOnCompletion") await this.options.supervisor.setNotifyMainOnCompletion(command.sessionId, command.enabled);
      if (command.type === "followUp") await this.options.supervisor.followUp(command.sessionId, command.text, command.context);
      if (command.type === "steer") await this.options.supervisor.steer(command.sessionId, command.text);
      if (command.type === "abort") await this.options.supervisor.abort(command.sessionId);
      if (command.type === "answerExtensionUi") await this.options.supervisor.answerExtensionUi(command.sessionId, command.requestId, command.value);
      if (command.type === "openArtifact") {
        const path = await this.options.supervisor.openArtifact(command.sessionId, command.artifactId);
        this.send(ws, { type: "artifactOpened", sessionId: command.sessionId, artifactId: command.artifactId, path });
      }
    } catch (error) {
      const commandId = typeof parsed === "object" && parsed && "id" in parsed ? String((parsed as { id: unknown }).id) : undefined;
      logAgentd("command failed", { commandId, error: error instanceof Error ? error.message : String(error) });
      this.send(ws, { type: "error", code: "bad_message", message: error instanceof Error ? error.message : String(error), commandId });
    }
  }

  private broadcast(event: EventPayload): void {
    for (const client of this.clients) this.send(client, event);
  }

  private send(ws: WebSocket, payload: EventPayload): void {
    const event: EventEnvelope = { id: `event-${randomUUID()}`, protocolVersion: PROTOCOL_VERSION, timestamp: new Date().toISOString(), ...payload } as EventEnvelope;
    logAgentd("event sent", eventLogFields(event));
    ws.send(JSON.stringify(event));
  }
}

function commandLogFields(command: ReturnType<typeof parseCommand>): Record<string, string | number | undefined> {
  switch (command.type) {
    case "routeTask":
    case "createTask":
    case "pinSideSession":
      return { commandId: command.id, type: command.type, contextId: command.context.id, source: command.context.source, transcriptChars: command.context.transcript?.length, screenshots: command.context.screenshots.length };
    case "followUp":
    case "steer":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, textChars: command.text.length };
    case "setNotifyMainOnCompletion":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, enabled: command.enabled ? 1 : 0 };
    case "abort":
    case "getSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId };
    case "answerExtensionUi":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, requestId: command.requestId };
    case "openArtifact":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, artifactId: command.artifactId };
    case "listSessions":
      return { commandId: command.id, type: command.type };
  }
}

function eventLogFields(event: EventEnvelope): Record<string, string | number | undefined> {
  switch (event.type) {
    case "hello":
      return { eventId: event.id, type: event.type };
    case "quickReply":
      return { eventId: event.id, type: event.type, contextId: event.contextId, textChars: event.text.length };
    case "sessionSnapshot":
      return { eventId: event.id, type: event.type, sessions: event.sessions.length };
    case "sessionUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.session.id, status: event.session.status };
    case "sessionLogAppended":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, lineChars: event.line.length };
    case "toolActivityUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, tool: event.tool.name, status: event.tool.status };
    case "extensionUiRequest":
      return { eventId: event.id, type: event.type, sessionId: event.request.sessionId, requestId: event.request.id, method: event.request.method };
    case "artifactUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, artifactId: event.artifact.id, kind: event.artifact.kind };
    case "artifactOpened":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, artifactId: event.artifactId };
    case "pointerOverlayRequested":
      return { eventId: event.id, type: event.type, requestId: event.request.id, screenId: event.request.screenId, screenIndex: event.request.screenIndex };
    case "error":
      return { eventId: event.id, type: event.type, commandId: event.commandId, code: event.code };
  }
}

const SNAPSHOT_LOG_LIMIT = 24;
const SNAPSHOT_IMPORTANT_LOG_LIMIT = 8;
const SNAPSHOT_LOG_CHAR_LIMIT = 1_200;

export function compactSessionsForSnapshot(sessions: PickyAgentSession[]): PickyAgentSession[] {
  return sessions.map((session) => ({ ...session, logs: compactSnapshotLogs(session.logs) }));
}

function compactSnapshotLogs(logs: string[]): string[] {
  if (logs.length <= SNAPSHOT_LOG_LIMIT && logs.every((line) => line.length <= SNAPSHOT_LOG_CHAR_LIMIT)) return logs;

  const important = logs.filter(isImportantSnapshotLog).slice(-SNAPSHOT_IMPORTANT_LOG_LIMIT);
  const recentSlots = Math.max(SNAPSHOT_LOG_LIMIT - important.length, 0);
  const recent = logs.slice(-recentSlots);
  return uniqueInOrder([...important, ...recent])
    .slice(-SNAPSHOT_LOG_LIMIT)
    .map(truncateSnapshotLogLine);
}

function isImportantSnapshotLog(line: string): boolean {
  const trimmed = line.trimStart();
  return trimmed.startsWith("pi session: ")
    || trimmed.startsWith("- Session file: ")
    || trimmed.startsWith("source transcript:")
    || trimmed.startsWith("follow-up: ")
    || trimmed.startsWith("main-agent handoff: ")
    || trimmed.includes("Runtime session is not attached after daemon restart")
    || trimmed.includes("Runtime not attached after daemon restart");
}

function uniqueInOrder(lines: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const line of lines) {
    if (seen.has(line)) continue;
    seen.add(line);
    result.push(line);
  }
  return result;
}

function truncateSnapshotLogLine(line: string): string {
  if (line.length <= SNAPSHOT_LOG_CHAR_LIMIT) return line;
  return `${line.slice(0, SNAPSHOT_LOG_CHAR_LIMIT)}…`;
}

type RemoveEnvelope<T> = T extends unknown ? Omit<T, "id" | "protocolVersion" | "timestamp"> : never;
type EventPayload = RemoveEnvelope<EventEnvelope>;
