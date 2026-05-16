import { createServer, type Server } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocket, WebSocketServer } from "ws";
import { PROTOCOL_VERSION } from "../../protocol.js";

export type MockAgentdEvent = { type: string; [key: string]: unknown };

export interface MockAgentd {
  port: number;
  token: string;
  received: unknown[];
  onCommand: (type: string, handler: (command: unknown, send: (event: MockAgentdEvent) => void) => void) => void;
  stop: () => Promise<void>;
}

export async function startMockAgentd(): Promise<MockAgentd> {
  const token = `tok-${randomUUID()}`;
  const httpServer: Server = createServer();
  const wsServer = new WebSocketServer({ noServer: true });
  const received: unknown[] = [];
  const handlers = new Map<string, (command: unknown, send: (event: MockAgentdEvent) => void) => void>();

  httpServer.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    if (url.searchParams.get("token") !== token) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }
    wsServer.handleUpgrade(request, socket, head, (ws) => onConnection(ws));
  });

  function send(ws: WebSocket, payload: MockAgentdEvent): void {
    const event = {
      id: `event-${randomUUID()}`,
      protocolVersion: PROTOCOL_VERSION,
      timestamp: new Date().toISOString(),
      ...payload,
    };
    ws.send(JSON.stringify(event));
  }

  function onConnection(ws: WebSocket): void {
    send(ws, { type: "hello", serverName: "picky-agentd", supportedProtocolVersions: [PROTOCOL_VERSION] });
    ws.on("message", (data) => {
      let command: { type?: string };
      try { command = JSON.parse(data.toString()) as { type?: string }; } catch { return; }
      received.push(command);
      const handler = handlers.get(command.type ?? "");
      if (handler) handler(command, (event) => send(ws, event));
    });
  }

  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
  const address = httpServer.address();
  const port = typeof address === "object" && address ? address.port : 0;

  return {
    port,
    token,
    received,
    onCommand(type, handler) { handlers.set(type, handler); },
    async stop() {
      for (const client of wsServer.clients) client.close();
      await new Promise<void>((resolve) => wsServer.close(() => resolve()));
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    },
  };
}
