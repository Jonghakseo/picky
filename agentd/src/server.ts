import { randomUUID } from "node:crypto";
import { createServer, type Server as HttpServer } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { isAuthorized } from "./auth.js";
import { PROTOCOL_VERSION, parseCommand, type EventEnvelope } from "./protocol.js";
import type { SessionSupervisor } from "./session-supervisor.js";

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
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
        socket.destroy();
        return;
      }
      this.wsServer?.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
    });

    this.options.supervisor.on("session", (session) => this.broadcast({ type: "sessionUpdated", session }));
    this.options.supervisor.on("log", (sessionId, line) => this.broadcast({ type: "sessionLogAppended", sessionId, line }));
    this.options.supervisor.on("extensionUiRequest", (request) => this.broadcast({ type: "extensionUiRequest", request }));
    this.options.supervisor.on("artifact", (sessionId, artifact) => this.broadcast({ type: "artifactUpdated", sessionId, artifact }));

    await new Promise<void>((resolve) => this.httpServer!.listen(this.options.port, "127.0.0.1", resolve));
    const address = this.httpServer.address();
    return typeof address === "object" && address ? address.port : this.options.port;
  }

  async stop(): Promise<void> {
    for (const client of this.clients) client.close();
    await new Promise<void>((resolve) => this.wsServer?.close(() => resolve()) ?? resolve());
    await new Promise<void>((resolve) => this.httpServer?.close(() => resolve()) ?? resolve());
  }

  private accept(ws: WebSocket): void {
    this.clients.add(ws);
    ws.on("close", () => this.clients.delete(ws));
    ws.on("message", (data) => void this.handleMessage(ws, data.toString()));
    this.send(ws, { type: "hello", serverName: "picky-agentd", supportedProtocolVersions: [PROTOCOL_VERSION] });
  }

  private async handleMessage(ws: WebSocket, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
      const command = parseCommand(parsed);
      if (command.type === "listSessions") this.send(ws, { type: "sessionSnapshot", sessions: this.options.supervisor.list() });
      if (command.type === "getSession") {
        const session = this.options.supervisor.get(command.sessionId);
        if (!session) throw new Error(`Unknown session: ${command.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session });
      }
      if (command.type === "createTask") await this.options.supervisor.create(command.context);
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
      this.send(ws, { type: "error", code: "bad_message", message: error instanceof Error ? error.message : String(error), commandId });
    }
  }

  private broadcast(event: EventPayload): void {
    for (const client of this.clients) this.send(client, event);
  }

  private send(ws: WebSocket, payload: EventPayload): void {
    const event: EventEnvelope = { id: `event-${randomUUID()}`, protocolVersion: PROTOCOL_VERSION, timestamp: new Date().toISOString(), ...payload } as EventEnvelope;
    ws.send(JSON.stringify(event));
  }
}

type RemoveEnvelope<T> = T extends unknown ? Omit<T, "id" | "protocolVersion" | "timestamp"> : never;
type EventPayload = RemoveEnvelope<EventEnvelope>;
