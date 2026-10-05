/**
 * The HTTP + WebSocket surface of the gateway.
 *
 * Binds `127.0.0.1` only. Reachability is the user's job (Tailscale Serve or a
 * Cloudflare Tunnel), which is also why the scheme and the client IP are read
 * from forwarding headers rather than from the socket.
 */
import { timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import { REMOTE_LIMITS } from "../remote/constants.js";
import { ApiRouter } from "./api-routes.js";
import { ClientConnection } from "./client-connection.js";
import { GATEWAY_LOOPBACK_HOST, type GatewayConfig } from "./config.js";
import { GatewayCore } from "./core.js";
import { HUB_PROTOCOL_VERSION } from "../remote/hub-protocol.js";
import { checkSameOrigin, deviceTokenOf, isLoopbackPeer, requestFacts } from "./http/request-context.js";
import { remoteError, sendError } from "./http/responses.js";
import { StaticSite } from "./http/static-files.js";
import { errorMessage, logGateway } from "./log.js";
import { ensureDirectory } from "./storage.js";
import type { PushFetch } from "./push/sender.js";

export interface GatewayServerOptions {
  config: GatewayConfig;
  pushFetch?: PushFetch;
}

/** Stderr marker the Swift launcher matches to stop its restart loop. */
export const GATEWAY_PORT_IN_USE_MARKER = "PICKY_GATEWAY_PORT_IN_USE";
/** Exit code that goes with the marker; anything else stays a plain failure. */
export const GATEWAY_PORT_IN_USE_EXIT_CODE = 3;

/**
 * The configured port is taken. Retrying cannot help, so the launcher has to
 * tell the user instead of restarting every 30 s with "exited with status 1".
 */
export class GatewayPortInUseError extends Error {
  constructor(readonly port: number) {
    super(`port ${port} is already in use`);
    this.name = "GatewayPortInUseError";
  }

  /** The one line the launcher parses, terminated so it is never merged. */
  get stderrLine(): string {
    return `${GATEWAY_PORT_IN_USE_MARKER}:${this.port}\n`;
  }
}

export class GatewayServer {
  readonly core: GatewayCore;
  private readonly api: ApiRouter;
  private readonly site: StaticSite;
  private readonly clientSockets = new WebSocketServer({ noServer: true, maxPayload: REMOTE_LIMITS.clientMessageBytes });
  private readonly hubSockets = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024 });
  private httpServer?: Server;
  private boundPort = 0;

  constructor(private readonly options: GatewayServerOptions) {
    this.core = new GatewayCore({
      config: options.config,
      ...(options.pushFetch ? { pushFetch: options.pushFetch } : {}),
    });
    this.api = new ApiRouter(this.core);
    this.site = new StaticSite(options.config.webRoot);
  }

  async start(): Promise<number> {
    await ensureDirectory(this.options.config.dataDir);
    await this.core.start();

    const server = createServer((request, response) => void this.handleRequest(request, response));
    server.on("upgrade", (request, socket, head) => this.handleUpgrade(request, socket, head));
    this.httpServer = server;

    try {
      this.boundPort = await new Promise<number>((resolve, reject) => {
        server.once("error", (error: NodeJS.ErrnoException) => {
          reject(error.code === "EADDRINUSE" ? new GatewayPortInUseError(this.options.config.port) : error);
        });
        server.listen(this.options.config.port, GATEWAY_LOOPBACK_HOST, () => {
          const address = server.address();
          resolve(typeof address === "object" && address ? address.port : this.options.config.port);
        });
      });
    } catch (error) {
      // The core is already running at this point; a start that never bound
      // must not leave daemon links and timers behind.
      this.core.stop();
      server.close();
      this.httpServer = undefined;
      throw error;
    }
    return this.boundPort;
  }

  async stop(): Promise<void> {
    this.core.stop();
    for (const socket of this.clientSockets.clients) socket.terminate();
    for (const socket of this.hubSockets.clients) socket.terminate();
    await new Promise<void>((resolve) => this.httpServer?.close(() => resolve()) ?? resolve());
    this.httpServer = undefined;
  }

  private async handleRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const facts = requestFacts(request);
    try {
      if (facts.path.startsWith("/api/")) {
        await this.api.handle(request, response, facts);
        return;
      }
      if (facts.method !== "GET" && facts.method !== "HEAD") {
        sendError(response, remoteError("notFound", "Unknown endpoint."));
        return;
      }
      await this.site.serve(response, facts.path, facts.host, facts.method);
    } catch (error) {
      logGateway("request failed", { path: facts.path, error: errorMessage(error) });
      if (!response.writableEnded) sendError(response, remoteError("internal", "The gateway could not handle this request."));
    }
  }

  private handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    const facts = requestFacts(request);
    if (facts.path === "/hub") {
      this.upgradeHub(request, socket, head);
      return;
    }
    if (facts.path !== "/api/ws") {
      rejectUpgrade(socket, 404, "Not Found");
      return;
    }
    this.upgradeClient(request, socket, head);
  }

  private upgradeClient(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    const facts = requestFacts(request);
    if (this.core.lockout.isBlocked(facts.clientIp)) {
      rejectUpgrade(socket, 429, "Too Many Requests");
      return;
    }
    if (!checkSameOrigin(request).ok) {
      rejectUpgrade(socket, 403, "Forbidden");
      return;
    }
    const token = deviceTokenOf(request);
    const device = token ? this.core.devices.findByToken(token) : undefined;
    if (!device) {
      this.core.lockout.recordFailure(facts.clientIp);
      rejectUpgrade(socket, 401, "Unauthorized");
      return;
    }
    this.clientSockets.handleUpgrade(request, socket, head, (ws: WebSocket) => {
      new ClientConnection(ws, device.id, device.name, this.core);
      logGateway("client connected", { deviceId: device.id });
    });
  }

  private upgradeHub(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    const authorized = matchesHubToken(request.headers.authorization, this.options.config.hubToken);
    if (!authorized || !isLoopbackPeer(request)) {
      rejectUpgrade(socket, 401, "Unauthorized");
      return;
    }
    this.hubSockets.handleUpgrade(request, socket, head, (ws: WebSocket) => {
      this.core.hub.attach(ws);
      this.core.hub.send({
        type: "gateway.hello",
        protocolVersion: HUB_PROTOCOL_VERSION,
        version: "1",
        port: this.boundPort,
      });
      logGateway("hub socket accepted");
    });
  }
}

/**
 * Constant time, because a `===` on the hub token leaks how many leading bytes
 * a guess got right. Only the length leaks, which a random 24-byte token makes
 * useless.
 */
function matchesHubToken(header: string | undefined, hubToken: string): boolean {
  const expected = Buffer.from(`Bearer ${hubToken}`, "utf8");
  const provided = Buffer.from(header ?? "", "utf8");
  return provided.byteLength === expected.byteLength && timingSafeEqual(provided, expected);
}

function rejectUpgrade(socket: Duplex, status: number, reason: string): void {
  socket.write(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}
