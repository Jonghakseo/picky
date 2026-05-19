import { randomUUID } from "node:crypto";
import { createServer, type Server as HttpServer } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { isAuthorized } from "./auth.js";
import { FOLLOWUP_PREFIX, HANDOFF_PREFIX, STEER_PREFIX } from "./domain/log-prefixes.js";
import { sliceUtf16Safe } from "./domain/safe-truncate.js";
import { PROTOCOL_VERSION, PickyAgentSessionSchema, parseCommand, type EventEnvelope, type PickyAgentSession, type PickyAgentSessionParsed, type PickyContextPacket } from "./protocol.js";
import type { SessionSupervisor } from "./session-supervisor.js";
import { logAgentd } from "./local-log.js";

interface AgentdServerOptions {
  port: number;
  token: string;
  supervisor: SessionSupervisor;
  setDefaultCwd?: (cwd: string) => void;
}

type ParsedCommand = ReturnType<typeof parseCommand>;
type CommandHandlerMap = {
  [Type in ParsedCommand["type"]]: (command: Extract<ParsedCommand, { type: Type }>) => unknown;
};

export interface AppPickleHandoffRequest {
  context: PickyContextPacket;
  title: string;
  instructions: string;
  cwd: string;
}

export interface AppPickleHandoffResult {
  sessionId: string;
  title: string;
  cwd?: string;
}

export type AppPickleBridgeRequest =
  | { operation: "listSessions" }
  | { operation: "steer"; sessionId: string; text: string }
  | { operation: "abort"; sessionId: string }
  | { operation: "notifyMainOfPickleCompletion"; sessionId: string; prompt: string; cwd?: string };

export interface AppPickleBridgeResult {
  sessions?: PickyAgentSession[];
  session?: PickyAgentSession;
  delivered?: boolean;
}

export const APP_PICKLE_HANDOFF_UNAVAILABLE = "Picky app handoff unavailable";
const APP_PICKLE_HANDOFF_TIMEOUT = "Picky app handoff timed out";
export const APP_EXTERNAL_ENTRY_UNAVAILABLE = "Picky app external entry unavailable";
const APP_EXTERNAL_ENTRY_TIMEOUT = "Picky app external entry timed out";
const EXTERNAL_ENTRY_TIMEOUT_MS = 10_000;

export class AgentdServer {
  private httpServer?: HttpServer;
  private wsServer?: WebSocketServer;
  private clients = new Set<WebSocket>();
  private appCapabilities = new WeakMap<WebSocket, Set<string>>();
  private pendingPickleHandoffs = new Map<string, { resolve: (result: AppPickleHandoffResult) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private pendingPickleBridgeRequests = new Map<string, { resolve: (result: AppPickleBridgeResult) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private pendingExternalEntries = new Map<string, ExternalEntryPending>();
  /**
   * FIFO queue of external CLI submissions. Per the agreed Q3 policy, only one
   * `submitMainFromExternal` / `createPickleFromExternal` is processed at a time;
   * the next entry waits until the current one's context capture + supervisor call
   * + ack have all completed. Implemented as a promise chain so each enqueue is a
   * single `then`, and a thrown error in one entry never blocks the next one
   * (the catch handler still tries to send the failing ack so --wait doesn't hang).
   */
  private externalEntryChain: Promise<void> = Promise.resolve();
  /** Diagnostics-only counter for entries that have not yet finished processing. */
  private externalEntryPendingCount = 0;
  /** Set when stop() begins so freshly-dequeued entries can short-circuit. */
  private externalEntryStopping = false;

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

    this.options.supervisor.on("session", (session) => this.broadcast({ type: "sessionUpdated", session: protocolSession(session) }));
    this.options.supervisor.on("resourcesReloaded", (sessionId) => this.broadcast({ type: "sessionResourcesReloaded", sessionId }));
    this.options.supervisor.on("log", (sessionId, line) => this.broadcast({ type: "sessionLogAppended", sessionId, line }));
    this.options.supervisor.on("extensionUiRequest", (request) => this.broadcast({ type: "extensionUiRequest", request }));
    this.options.supervisor.on("queueUpdated", (sessionId, steering, followUp, steeringMode, followUpMode, seq) => this.broadcast({ type: "sessionQueueUpdated", sessionId, steering, followUp, steeringMode, followUpMode, seq }));
    this.options.supervisor.on("activityUpdated", (sessionId, activitySummary, seq) => this.broadcast({ type: "sessionActivityUpdated", sessionId, activitySummary, seq }));
    this.options.supervisor.on("messageAppended", (sessionId, message, seq) => this.broadcast({ type: "sessionMessageAppended", sessionId, message, seq }));
    this.options.supervisor.on("messageReplaced", (sessionId, messageId, message, seq) => this.broadcast({ type: "sessionMessageReplaced", sessionId, messageId, message, seq }));
    this.options.supervisor.on("messageRemoved", (sessionId, messageId, seq) => this.broadcast({ type: "sessionMessageRemoved", sessionId, messageId, seq }));
    this.options.supervisor.on("quickReply", (contextId, text, metadata = {}) => this.broadcast({ type: "quickReply", contextId, text, ...metadata }));
    this.options.supervisor.on("mainMessage", (message) => this.broadcast({ type: "mainMessageAppended", message }));
    this.options.supervisor.on("mainAgentSessionInfo", (info: { sessionFilePath?: string; cwd?: string }) => this.broadcast({
      type: "mainAgentSessionInfoUpdated",
      ...(info.sessionFilePath ? { sessionFilePath: info.sessionFilePath } : {}),
      ...(info.cwd ? { cwd: info.cwd } : {}),
    }));
    this.options.supervisor.on("pointerOverlayRequested", (request) => this.broadcast({ type: "pointerOverlayRequested", request }));
    this.options.supervisor.on("narrateProgressRequested", (payload: { text: string }) => this.broadcast({ type: "narrateProgressRequested", text: payload.text }));
    this.options.supervisor.on("artifact", (sessionId, artifact) => this.broadcast({ type: "artifactUpdated", sessionId, artifact }));
    this.options.supervisor.on("terminalSessionSyncOutcome", (sessionId, outcome) => this.broadcast({
      type: "terminalSessionSyncOutcome",
      sessionId,
      baselineFound: outcome.baselineFound,
      importedMessageCount: outcome.importedMessageCount,
      activeLastMessageId: outcome.activeLastMessageId,
      baselinePiMessageId: outcome.baselinePiMessageId,
    }));

    await new Promise<void>((resolve) => this.httpServer!.listen(this.options.port, "127.0.0.1", resolve));
    const address = this.httpServer.address();
    const boundPort = typeof address === "object" && address ? address.port : this.options.port;
    logAgentd("server listening", { port: boundPort });
    return boundPort;
  }

  async requestPickleHandoffFromApp(request: AppPickleHandoffRequest, timeoutMs = 5_000): Promise<AppPickleHandoffResult> {
    const client = this.firstClientWithCapability("pickleHandoff");
    if (!client) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    const requestId = `handoff-${randomUUID()}`;
    return await new Promise<AppPickleHandoffResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingPickleHandoffs.delete(requestId);
        reject(new Error(APP_PICKLE_HANDOFF_TIMEOUT));
      }, timeoutMs);
      this.pendingPickleHandoffs.set(requestId, { resolve, reject, timer });
      this.send(client, { type: "pickleHandoffRequested", requestId, ...request });
    });
  }

  async requestPickleBridgeFromApp(request: AppPickleBridgeRequest, timeoutMs = 5_000): Promise<AppPickleBridgeResult> {
    const client = this.firstClientWithCapability("pickleBridge");
    if (!client) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    const requestId = `pickle-bridge-${randomUUID()}`;
    return await new Promise<AppPickleBridgeResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingPickleBridgeRequests.delete(requestId);
        reject(new Error(APP_PICKLE_HANDOFF_TIMEOUT));
      }, timeoutMs);
      this.pendingPickleBridgeRequests.set(requestId, { resolve, reject, timer });
      this.send(client, { type: "pickleBridgeRequested", requestId, ...request });
    });
  }

  async stop(): Promise<void> {
    for (const pending of this.pendingPickleHandoffs.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(APP_PICKLE_HANDOFF_UNAVAILABLE));
    }
    this.pendingPickleHandoffs.clear();
    for (const pending of this.pendingPickleBridgeRequests.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(APP_PICKLE_HANDOFF_UNAVAILABLE));
    }
    this.pendingPickleBridgeRequests.clear();
    this.externalEntryStopping = true;
    for (const pending of this.pendingExternalEntries.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(APP_EXTERNAL_ENTRY_UNAVAILABLE));
    }
    this.pendingExternalEntries.clear();
    for (const client of this.clients) client.close();
    await new Promise<void>((resolve) => this.wsServer?.close(() => resolve()) ?? resolve());
    await new Promise<void>((resolve) => this.httpServer?.close(() => resolve()) ?? resolve());
  }

  private accept(ws: WebSocket): void {
    this.clients.add(ws);
    logAgentd("ws connected", { clients: this.clients.size });
    ws.on("close", () => {
      this.clients.delete(ws);
      const lostCapabilities = this.appCapabilities.get(ws);
      this.appCapabilities.delete(ws);
      if (lostCapabilities?.has("externalEntry")) {
        for (const [requestId, pending] of this.pendingExternalEntries) {
          clearTimeout(pending.timer);
          pending.reject(new Error(APP_EXTERNAL_ENTRY_UNAVAILABLE));
          this.pendingExternalEntries.delete(requestId);
        }
      }
      logAgentd("ws disconnected", { clients: this.clients.size });
    });
    ws.on("message", (data) => void this.handleMessage(ws, data.toString()));
    this.send(ws, { type: "hello", serverName: "picky-agentd", supportedProtocolVersions: [PROTOCOL_VERSION] });
    const initialMainInfo = this.options.supervisor.mainAgentSessionInfo();
    if (initialMainInfo.sessionFilePath || initialMainInfo.cwd) {
      this.send(ws, {
        type: "mainAgentSessionInfoUpdated",
        ...(initialMainInfo.sessionFilePath ? { sessionFilePath: initialMainInfo.sessionFilePath } : {}),
        ...(initialMainInfo.cwd ? { cwd: initialMainInfo.cwd } : {}),
      });
    }
  }

  private async handleMessage(ws: WebSocket, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
      const command = parseCommand(parsed);
      logAgentd("command received", commandLogFields(command));
      await this.dispatchCommand(ws, command);
    } catch (error) {
      const commandId = typeof parsed === "object" && parsed && "id" in parsed ? String((parsed as { id: unknown }).id) : undefined;
      logAgentd("command failed", { commandId, error: error instanceof Error ? error.message : String(error) });
      this.send(ws, { type: "error", code: "bad_message", message: error instanceof Error ? error.message : String(error), commandId });
    }
  }

  private async dispatchCommand(ws: WebSocket, command: ParsedCommand): Promise<void> {
    const handlers: CommandHandlerMap = {
      listSessions: (cmd) => this.send(ws, { type: "sessionSnapshot", sessions: compactSessionsForSnapshot(this.options.supervisor.list()).map(protocolSession) }),
      listMainMessages: (cmd) => this.send(ws, { type: "mainMessagesSnapshot", messages: this.options.supervisor.listMainMessages() }),
      listMainAgentModels: async (cmd) => this.send(ws, { type: "mainAgentModelsSnapshot", models: await this.options.supervisor.listMainAgentModels() }),
      setDefaultCwd: (cmd) => this.options.setDefaultCwd?.(cmd.defaultCwd.trim()),
      setMainAgentModel: (cmd) => this.options.supervisor.setMainAgentModel(cmd.mainAgentModelPattern),
      setDisabledBuiltinTools: (cmd) => this.options.supervisor.setDisabledBuiltinTools(cmd.disabledBuiltinTools),
      setMainAgentNarrationEnabled: (cmd) => this.options.supervisor.setNarrationEnabled(cmd.enabled),
      resetMainAgent: async (cmd) => {
        await this.options.supervisor.resetMainAgent();
        this.broadcast({ type: "mainMessagesSnapshot", messages: this.options.supervisor.listMainMessages() });
      },
      abortMainAgent: (cmd) => this.options.supervisor.abortMainAgent(),
      setMainAgentThinkingLevel: (cmd) => this.options.supervisor.setMainAgentThinkingLevel(cmd.mainAgentThinkingLevel),
      listSlashCommands: async (cmd) => {
        const commands = await this.options.supervisor.listSlashCommands(cmd.sessionId);
        this.send(ws, { type: "slashCommandsSnapshot", sessionId: cmd.sessionId, requestId: cmd.id, commands });
      },
      getSession: (cmd) => {
        const session = this.options.supervisor.get(cmd.sessionId);
        if (!session) throw new Error(`Unknown session: ${cmd.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session: protocolSession(session) });
      },
      routeTask: (cmd) => this.options.supervisor.route(cmd.context),
      createTask: (cmd) => this.options.supervisor.create(cmd.context),
      createEmptyPickleSession: (cmd) => this.options.supervisor.createEmptyPickleSession(cmd.context),
      createPickleFromHandoff: (cmd) => this.options.supervisor.createPickleFromHandoff(cmd.context, { title: cmd.title, instructions: cmd.instructions, cwd: cmd.cwd }),
      completePickleHandoff: (cmd) => this.completePendingPickleHandoff(cmd),
      registerAppCapabilities: (cmd) => this.registerAppCapabilities(ws, cmd.capabilities),
      completePickleBridgeRequest: (cmd) => this.completePendingPickleBridgeRequest(cmd),
      submitMainFromExternal: (cmd) => this.enqueueExternalEntry(ws, cmd.id, "submitMain", { text: cmd.text, captureContext: cmd.captureContext, cwd: cmd.cwd }),
      createPickleFromExternal: (cmd) => this.enqueueExternalEntry(ws, cmd.id, "createPickle", { title: cmd.title, instructions: cmd.instructions, captureContext: cmd.captureContext, cwd: cmd.cwd }),
      completeExternalEntryRequest: (cmd) => this.completePendingExternalEntry(cmd),
      duplicatePickleSession: (cmd) => this.options.supervisor.duplicatePickleSession(cmd.sessionId),
      pinPickleSession: (cmd) => this.options.supervisor.pinPickleSession(cmd.context, cmd.title),
      setNotifyMainOnCompletion: (cmd) => this.options.supervisor.setNotifyMainOnCompletion(cmd.sessionId, cmd.enabled),
      notifyMainOfPickleCompletion: (cmd) => this.options.supervisor.deliverMainAgentPickleCompletion(cmd.sessionId, cmd.prompt, cmd.cwd),
      setSessionArchived: (cmd) => this.options.supervisor.setSessionArchived(cmd.sessionId, cmd.archived),
      cycleSessionThinkingLevel: (cmd) => this.options.supervisor.cycleSessionThinkingLevel(cmd.sessionId),
      cycleSessionModel: (cmd) => this.options.supervisor.cycleSessionModel(cmd.sessionId, cmd.direction),
      clearQueue: (cmd) => this.options.supervisor.clearQueue(cmd.sessionId, cmd.kind),
      syncTerminalSession: (cmd) => this.options.supervisor.syncTerminalSession(cmd.sessionId, cmd.baselinePiMessageId),
      followUp: (cmd) => this.options.supervisor.followUp(cmd.sessionId, cmd.text, cmd.context),
      steer: (cmd) => this.options.supervisor.steer(cmd.sessionId, cmd.text, cmd.context),
      abort: (cmd) => this.options.supervisor.abort(cmd.sessionId),
      answerExtensionUi: (cmd) => this.options.supervisor.answerExtensionUi(cmd.sessionId, cmd.requestId, cmd.value),
    };

    const handler = handlers[command.type] as (command: ParsedCommand) => unknown;
    await handler(command);
  }

  private registerAppCapabilities(ws: WebSocket, capabilities: string[]): void {
    this.appCapabilities.set(ws, new Set(capabilities));
    logAgentd("app capabilities registered", { capabilities: capabilities.join(",") });
  }

  private firstClientWithCapability(capability: string): WebSocket | undefined {
    for (const client of this.clients) {
      if (this.appCapabilities.get(client)?.has(capability)) return client;
    }
    return undefined;
  }

  private completePendingPickleHandoff(command: Extract<ReturnType<typeof parseCommand>, { type: "completePickleHandoff" }>): void {
    const pending = this.pendingPickleHandoffs.get(command.requestId);
    if (!pending) throw new Error(`Unknown Pickle handoff request: ${command.requestId}`);
    this.pendingPickleHandoffs.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorMessage) {
      pending.reject(new Error(command.errorMessage));
      return;
    }
    if (!command.sessionId) {
      pending.reject(new Error(`Missing sessionId for Pickle handoff request: ${command.requestId}`));
      return;
    }
    pending.resolve({ sessionId: command.sessionId, title: command.title ?? command.sessionId, cwd: command.cwd });
  }

  private completePendingPickleBridgeRequest(command: Extract<ReturnType<typeof parseCommand>, { type: "completePickleBridgeRequest" }>): void {
    const pending = this.pendingPickleBridgeRequests.get(command.requestId);
    if (!pending) throw new Error(`Unknown Pickle bridge request: ${command.requestId}`);
    this.pendingPickleBridgeRequests.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorMessage) {
      pending.reject(new Error(command.errorMessage));
      return;
    }
    pending.resolve({ sessions: command.sessions, session: command.session, delivered: command.delivered });
  }

  /**
   * Enqueue an external CLI submission onto the FIFO chain. Returns immediately;
   * the actual processing (context capture round-trip + supervisor call + ack) runs
   * inside `processExternalEntry` whenever the chain reaches this entry.
   */
  private enqueueExternalEntry(
    ws: WebSocket,
    commandId: string,
    kind: "submitMain" | "createPickle",
    payload: { text?: string; title?: string; instructions?: string; captureContext: boolean; cwd?: string },
  ): void {
    this.externalEntryPendingCount += 1;
    logAgentd("external entry queued", { commandId, kind, pending: this.externalEntryPendingCount });
    this.externalEntryChain = this.externalEntryChain.then(async () => {
      if (this.externalEntryStopping) {
        try { this.send(ws, { type: "externalEntryAck", commandId, kind, errorMessage: APP_EXTERNAL_ENTRY_UNAVAILABLE }); } catch { /* ws already closed */ }
        return;
      }
      try {
        await this.processExternalEntry(ws, commandId, kind, payload);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logAgentd("external entry processing failed", { commandId, kind, error: message });
        try { this.send(ws, { type: "externalEntryAck", commandId, kind, errorMessage: message }); } catch { /* ws already closed */ }
      }
    }).finally(() => {
      this.externalEntryPendingCount -= 1;
    });
  }

  private async processExternalEntry(
    ws: WebSocket,
    commandId: string,
    kind: "submitMain" | "createPickle",
    payload: { text?: string; title?: string; instructions?: string; captureContext: boolean; cwd?: string },
  ): Promise<void> {
    let context: PickyContextPacket;
    if (payload.captureContext) {
      try {
        context = await this.requestExternalEntryContext(kind, payload);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.send(ws, { type: "externalEntryAck", commandId, kind, errorMessage: message });
        return;
      }
    } else {
      context = buildNeutralCliContext({ cwd: payload.cwd, transcript: kind === "submitMain" ? payload.text : undefined });
    }
    const finalContext: PickyContextPacket = {
      ...context,
      source: "cli",
      ...(payload.cwd ? { cwd: payload.cwd } : context.cwd ? { cwd: context.cwd } : {}),
      ...(kind === "submitMain" && payload.text !== undefined ? { transcript: payload.text } : {}),
    };
    try {
      if (kind === "submitMain") {
        const session = await this.options.supervisor.route(finalContext);
        // Surface both the session id (when route created a Pickle) and the context id
        // (always available, used by the CLI's --wait flag to filter the matching
        // quickReply / main-message broadcast).
        this.send(ws, {
          type: "externalEntryAck",
          commandId,
          kind,
          contextId: finalContext.id,
          ...(session ? { sessionId: session.id } : {}),
        });
      } else {
        const session = await this.options.supervisor.createPickleFromHandoff(finalContext, {
          title: payload.title!,
          instructions: payload.instructions!,
          ...(payload.cwd ? { cwd: payload.cwd } : {}),
        });
        this.send(ws, {
          type: "externalEntryAck",
          commandId,
          kind,
          sessionId: session.id,
          contextId: finalContext.id,
        });
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.send(ws, { type: "externalEntryAck", commandId, kind, errorMessage: message });
    }
  }

  private requestExternalEntryContext(
    kind: "submitMain" | "createPickle",
    payload: { text?: string; title?: string; instructions?: string; cwd?: string },
  ): Promise<PickyContextPacket> {
    const app = this.firstClientWithCapability("externalEntry");
    if (!app) return Promise.reject(new Error(APP_EXTERNAL_ENTRY_UNAVAILABLE));
    const requestId = `external-entry-${randomUUID()}`;
    return new Promise<PickyContextPacket>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pendingExternalEntries.get(requestId);
        if (!pending) return;
        this.pendingExternalEntries.delete(requestId);
        pending.reject(new Error(APP_EXTERNAL_ENTRY_TIMEOUT));
      }, EXTERNAL_ENTRY_TIMEOUT_MS);
      this.pendingExternalEntries.set(requestId, { resolve, reject, timer });
      this.send(app, {
        type: "externalEntryRequested",
        requestId,
        kind,
        ...(payload.text !== undefined ? { text: payload.text } : {}),
        ...(payload.title !== undefined ? { title: payload.title } : {}),
        ...(payload.instructions !== undefined ? { instructions: payload.instructions } : {}),
        ...(payload.cwd !== undefined ? { cwd: payload.cwd } : {}),
      });
    });
  }

  private completePendingExternalEntry(command: Extract<ReturnType<typeof parseCommand>, { type: "completeExternalEntryRequest" }>): void {
    const pending = this.pendingExternalEntries.get(command.requestId);
    if (!pending) throw new Error(`Unknown external entry request: ${command.requestId}`);
    this.pendingExternalEntries.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorMessage) {
      pending.reject(new Error(command.errorMessage));
      return;
    }
    if (!command.context) {
      pending.reject(new Error(`Missing context for external entry request: ${command.requestId}`));
      return;
    }
    pending.resolve(command.context);
  }

  private broadcast(event: EventPayload): void {
    if (this.clients.size === 0) return;
    let bytes = 0;
    let type: string | undefined;
    for (const client of this.clients) {
      const sent = this.send(client, event);
      bytes = sent.bytes;
      type = sent.type;
    }
    logAgentd("event broadcast", { type, clients: this.clients.size, bytes });
  }

  private send(ws: WebSocket, payload: EventPayload): { bytes: number; type: string } {
    const event: EventEnvelope = sanitizeForJson({ id: `event-${randomUUID()}`, protocolVersion: PROTOCOL_VERSION, timestamp: new Date().toISOString(), ...payload } as EventEnvelope);
    const json = JSON.stringify(event);
    logAgentd("event sent", eventLogFields(event));
    ws.send(json);
    return { bytes: Buffer.byteLength(json, "utf8"), type: event.type };
  }
}

interface ExternalEntryPending {
  resolve: (context: PickyContextPacket) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

function buildNeutralCliContext(payload: { cwd?: string; transcript?: string }): PickyContextPacket {
  return {
    id: `context-cli-${randomUUID()}`,
    source: "cli",
    capturedAt: new Date().toISOString(),
    screenshots: [],
    inkMarks: [],
    warnings: [],
    ...(payload.transcript !== undefined ? { transcript: payload.transcript } : {}),
    ...(payload.cwd !== undefined ? { cwd: payload.cwd } : {}),
  };
}

export function sanitizeForJson<T>(value: T): T {
  if (typeof value === "string") return repairLoneSurrogates(value) as T;
  if (Array.isArray(value)) return value.map((item) => sanitizeForJson(item)) as T;
  if (value && typeof value === "object") {
    const sanitized: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value)) sanitized[key] = sanitizeForJson(child);
    return sanitized as T;
  }
  return value;
}

function repairLoneSurrogates(value: string): string {
  let result = "";
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        result += value[index] + value[index + 1];
        index += 1;
      } else {
        result += "\uFFFD";
      }
      continue;
    }
    if (code >= 0xdc00 && code <= 0xdfff) {
      result += "\uFFFD";
      continue;
    }
    result += value[index];
  }
  return result;
}

export function commandLogFields(command: ReturnType<typeof parseCommand>): Record<string, string | number | undefined> {
  switch (command.type) {
    case "routeTask":
    case "createTask":
    case "createEmptyPickleSession":
    case "pinPickleSession":
      return { commandId: command.id, type: command.type, contextId: command.context.id, source: command.context.source, transcriptChars: command.context.transcript?.length, screenshots: command.context.screenshots.length };
    case "createPickleFromHandoff":
      return { commandId: command.id, type: command.type, contextId: command.context.id, source: command.context.source, titleChars: command.title.length, instructionChars: command.instructions.length, cwd: command.cwd };
    case "completePickleHandoff":
      return { commandId: command.id, type: command.type, requestId: command.requestId, sessionId: command.sessionId, errorChars: command.errorMessage?.length };
    case "registerAppCapabilities":
      return { commandId: command.id, type: command.type, capabilities: command.capabilities.join(",") };
    case "completePickleBridgeRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, sessions: command.sessions?.length, sessionId: command.session?.id, delivered: command.delivered === undefined ? undefined : command.delivered ? 1 : 0, errorChars: command.errorMessage?.length };
    case "submitMainFromExternal":
      return { commandId: command.id, type: command.type, textChars: command.text.length, captureContext: command.captureContext ? 1 : 0, cwd: command.cwd };
    case "createPickleFromExternal":
      return { commandId: command.id, type: command.type, titleChars: command.title.length, instructionChars: command.instructions.length, captureContext: command.captureContext ? 1 : 0, cwd: command.cwd };
    case "completeExternalEntryRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, hasContext: command.context ? 1 : 0, errorChars: command.errorMessage?.length };
    case "notifyMainOfPickleCompletion":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, promptChars: command.prompt.length, cwd: command.cwd };
    case "followUp":
    case "steer":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, textChars: command.text.length, contextId: command.context?.id, screenshots: command.context?.screenshots.length };
    case "setNotifyMainOnCompletion":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, enabled: command.enabled ? 1 : 0 };
    case "setSessionArchived":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, archived: command.archived ? 1 : 0 };
    case "cycleSessionThinkingLevel":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId };
    case "cycleSessionModel":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, direction: command.direction };
    case "clearQueue":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, kind: command.kind };
    case "syncTerminalSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, baselinePiMessageId: command.baselinePiMessageId };
    case "abort":
    case "getSession":
    case "listSlashCommands":
    case "duplicatePickleSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId };
    case "answerExtensionUi":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, requestId: command.requestId };
    case "setDefaultCwd":
      return { commandId: command.id, type: command.type, cwdChars: command.defaultCwd.length };
    case "setMainAgentModel":
      return { commandId: command.id, type: command.type, modelPatternChars: command.mainAgentModelPattern.length };
    case "setDisabledBuiltinTools":
      return { commandId: command.id, type: command.type, count: command.disabledBuiltinTools.length };
    case "setMainAgentNarrationEnabled":
      return { commandId: command.id, type: command.type, enabled: command.enabled ? 1 : 0 };
    case "listSessions":
    case "listMainMessages":
    case "listMainAgentModels":
    case "resetMainAgent":
    case "abortMainAgent":
      return { commandId: command.id, type: command.type };
    case "setMainAgentThinkingLevel":
      return { commandId: command.id, type: command.type, mainAgentThinkingLevel: command.mainAgentThinkingLevel };
  }
}

function eventLogFields(event: EventEnvelope): Record<string, string | number | undefined> {
  switch (event.type) {
    case "hello":
      return { eventId: event.id, type: event.type };
    case "quickReply":
      return { eventId: event.id, type: event.type, contextId: event.contextId, textChars: event.text.length, originSource: event.originSource, replyKind: event.replyKind, sessionId: event.sessionId };
    case "mainMessagesSnapshot":
      return { eventId: event.id, type: event.type, messages: event.messages.length };
    case "mainMessageAppended":
      return { eventId: event.id, type: event.type, role: event.message.role, textChars: event.message.text.length };
    case "mainAgentModelsSnapshot":
      return { eventId: event.id, type: event.type, models: event.models.length };
    case "mainAgentSessionInfoUpdated":
      return { eventId: event.id, type: event.type, hasSessionFile: event.sessionFilePath ? 1 : 0, hasCwd: event.cwd ? 1 : 0 };
    case "sessionSnapshot":
      return { eventId: event.id, type: event.type, sessions: event.sessions.length };
    case "sessionUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.session.id, status: event.session.status };
    case "sessionResourcesReloaded":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId };
    case "sessionLogAppended":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, lineChars: event.line.length };
    case "toolActivityUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, tool: event.tool.name, status: event.tool.status };
    case "extensionUiRequest":
      return { eventId: event.id, type: event.type, sessionId: event.request.sessionId, requestId: event.request.id, method: event.request.method };
    case "artifactUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, artifactId: event.artifact.id, kind: event.artifact.kind };
    case "pointerOverlayRequested":
      return { eventId: event.id, type: event.type, requestId: event.request.id, screenId: event.request.screenId };
    case "narrateProgressRequested":
      return { eventId: event.id, type: event.type, textChars: event.text.length };
    case "pickleHandoffRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, contextId: event.context.id, titleChars: event.title.length, instructionChars: event.instructions.length, cwd: event.cwd };
    case "pickleBridgeRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, operation: event.operation, sessionId: event.sessionId, textChars: event.text?.length, promptChars: event.prompt?.length, cwd: event.cwd };
    case "externalEntryRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, kind: event.kind, textChars: event.text?.length, titleChars: event.title?.length, instructionChars: event.instructions?.length, cwd: event.cwd };
    case "externalEntryAck":
      return { eventId: event.id, type: event.type, commandId: event.commandId, kind: event.kind, sessionId: event.sessionId, contextId: event.contextId, errorChars: event.errorMessage?.length };
    case "slashCommandsSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, commands: event.commands.length };
    case "sessionMessageAppended":
    case "sessionMessageReplaced":
    case "sessionMessageRemoved":
    case "sessionQueueUpdated":
    case "sessionActivityUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, seq: event.seq };
    case "terminalSessionSyncOutcome":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, baselineFound: event.baselineFound ? 1 : 0, importedMessageCount: event.importedMessageCount };
    case "error":
      return { eventId: event.id, type: event.type, commandId: event.commandId, code: event.code };
  }
}

const SNAPSHOT_LOG_LIMIT = 16;
const SNAPSHOT_IMPORTANT_LOG_LIMIT = 6;
const SNAPSHOT_LOG_CHAR_LIMIT = 600;
const SNAPSHOT_TOOL_LIMIT = 200;
const SNAPSHOT_TOOL_PREVIEW_CHAR_LIMIT = 240;
const SNAPSHOT_THINKING_PREVIEW_CHAR_LIMIT = 240;
const SNAPSHOT_CHANGED_FILE_LIMIT = 20;
const SNAPSHOT_CHANGED_FILE_SUMMARY_CHAR_LIMIT = 240;
const SNAPSHOT_MESSAGE_LIMIT = 12;
const SNAPSHOT_FINAL_ANSWER_CHAR_LIMIT = 1_500;
const SNAPSHOT_LAST_SUMMARY_CHAR_LIMIT = 700;

export function compactSessionsForSnapshot(sessions: PickyAgentSession[]): PickyAgentSession[] {
  return sessions.map((session) => ({
    ...session,
    lastSummary: session.lastSummary ? truncateText(session.lastSummary, SNAPSHOT_LAST_SUMMARY_CHAR_LIMIT) : session.lastSummary,
    finalAnswer: session.finalAnswer ? truncateText(session.finalAnswer, SNAPSHOT_FINAL_ANSWER_CHAR_LIMIT) : session.finalAnswer,
    thinkingPreview: session.thinkingPreview ? truncateText(session.thinkingPreview, SNAPSHOT_THINKING_PREVIEW_CHAR_LIMIT) : session.thinkingPreview,
    logs: compactSnapshotLogs(session.logs),
    tools: compactSnapshotTools(session.tools),
    changedFiles: compactSnapshotChangedFiles(session.changedFiles),
    messages: compactSnapshotMessages(session.messages),
  }));
}

// Snapshot only caps the message count, not the body of any individual message.
// User-visible fields (text/errorContext/errorMessage/question.prompt/question.description)
// must be sent in full so the report viewer doesn't render a truncated copy that lingers
// between the initial sessionSnapshot and the next sessionUpdated/messageReplaced event.
function compactSnapshotMessages(messages: PickyAgentSession["messages"]): PickyAgentSession["messages"] {
  return messages?.slice(-SNAPSHOT_MESSAGE_LIMIT);
}

function compactSnapshotLogs(logs: string[]): string[] {
  if (logs.length <= SNAPSHOT_LOG_LIMIT && logs.every((line) => line.length <= SNAPSHOT_LOG_CHAR_LIMIT)) return logs;

  // Pick up to N most-recent important indices, scanning newest-first so the latest
  // important entries win when capped.
  const importantIndices = new Set<number>();
  for (let index = logs.length - 1; index >= 0 && importantIndices.size < SNAPSHOT_IMPORTANT_LOG_LIMIT; index -= 1) {
    if (isImportantSnapshotLog(logs[index]!)) importantIndices.add(index);
  }

  const recentSlots = Math.max(SNAPSHOT_LOG_LIMIT - importantIndices.size, 0);
  const recentStart = logs.length - recentSlots;

  // Walk the original array in order so important entries that fall outside the recent
  // window stay at their original chronological position rather than being prepended.
  const kept: string[] = [];
  for (let index = 0; index < logs.length; index += 1) {
    if (index >= recentStart || importantIndices.has(index)) kept.push(logs[index]!);
  }
  return kept.slice(-SNAPSHOT_LOG_LIMIT).map(truncateSnapshotLogLine);
}

function compactSnapshotTools(tools: PickyAgentSession["tools"]): PickyAgentSession["tools"] {
  return tools.slice(-SNAPSHOT_TOOL_LIMIT).map((tool) => ({
    ...tool,
    preview: tool.preview ? truncateText(tool.preview, SNAPSHOT_TOOL_PREVIEW_CHAR_LIMIT) : tool.preview,
  }));
}

function compactSnapshotChangedFiles(changedFiles: PickyAgentSession["changedFiles"]): PickyAgentSession["changedFiles"] {
  return changedFiles.slice(-SNAPSHOT_CHANGED_FILE_LIMIT).map((file) => ({
    ...file,
    summary: file.summary ? truncateText(file.summary, SNAPSHOT_CHANGED_FILE_SUMMARY_CHAR_LIMIT) : file.summary,
  }));
}

function isImportantSnapshotLog(line: string): boolean {
  const trimmed = line.trimStart();
  return trimmed.startsWith("pi session: ")
    || trimmed.startsWith("- Session file: ")
    || trimmed.startsWith("source transcript:")
    || trimmed.startsWith(FOLLOWUP_PREFIX)
    || trimmed.startsWith(STEER_PREFIX)
    || trimmed.startsWith("steer rejected:")
    || trimmed.startsWith(HANDOFF_PREFIX)
    || trimmed.includes("Runtime session is not attached after daemon restart")
    || trimmed.includes("Runtime not attached after daemon restart");
}

function protocolSession(session: PickyAgentSession): PickyAgentSessionParsed {
  return PickyAgentSessionSchema.parse(session);
}

function truncateSnapshotLogLine(line: string): string {
  return truncateText(line, SNAPSHOT_LOG_CHAR_LIMIT);
}

function truncateText(text: string, limit: number): string {
  if (text.length <= limit) return text;
  return `${sliceUtf16Safe(text, limit)}…`;
}

type RemoveEnvelope<T> = T extends unknown ? Omit<T, "id" | "protocolVersion" | "timestamp"> : never;
type EventPayload = RemoveEnvelope<EventEnvelope>;
