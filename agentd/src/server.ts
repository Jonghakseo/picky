import { randomUUID } from "node:crypto";
import { createServer, type Server as HttpServer } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { isAuthorized } from "./auth.js";
import { FOLLOWUP_PREFIX, HANDOFF_PREFIX, STEER_PREFIX } from "./domain/log-prefixes.js";
import { sliceUtf16Safe } from "./domain/safe-truncate.js";
import { PROTOCOL_VERSION, PickyAgentSessionSchema, parseCommand, type EventEnvelope, type PickyAgentSession, type PickyAgentSessionParsed } from "./protocol.js";
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

    this.options.supervisor.on("session", (session) => this.broadcast({ type: "sessionUpdated", session: protocolSession(session) }));
    this.options.supervisor.on("log", (sessionId, line) => this.broadcast({ type: "sessionLogAppended", sessionId, line }));
    this.options.supervisor.on("extensionUiRequest", (request) => this.broadcast({ type: "extensionUiRequest", request }));
    this.options.supervisor.on("queueUpdated", (sessionId, steering, followUp, steeringMode, followUpMode, seq) => this.broadcast({ type: "sessionQueueUpdated", sessionId, steering, followUp, steeringMode, followUpMode, seq }));
    this.options.supervisor.on("activityUpdated", (sessionId, activitySummary, seq) => this.broadcast({ type: "sessionActivityUpdated", sessionId, activitySummary, seq }));
    this.options.supervisor.on("messageAppended", (sessionId, message, seq) => this.broadcast({ type: "sessionMessageAppended", sessionId, message, seq }));
    this.options.supervisor.on("messageReplaced", (sessionId, messageId, message, seq) => this.broadcast({ type: "sessionMessageReplaced", sessionId, messageId, message, seq }));
    this.options.supervisor.on("messageRemoved", (sessionId, messageId, seq) => this.broadcast({ type: "sessionMessageRemoved", sessionId, messageId, seq }));
    this.options.supervisor.on("quickReply", (contextId, text, metadata = {}) => this.broadcast({ type: "quickReply", contextId, text, ...metadata }));
    this.options.supervisor.on("mainMessage", (message) => this.broadcast({ type: "mainMessageAppended", message }));
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
      if (command.type === "listSessions") this.send(ws, { type: "sessionSnapshot", sessions: compactSessionsForSnapshot(this.options.supervisor.list()).map(protocolSession) });
      if (command.type === "listMainMessages") this.send(ws, { type: "mainMessagesSnapshot", messages: this.options.supervisor.listMainMessages() });
      if (command.type === "resetMainAgent") {
        await this.options.supervisor.resetMainAgent();
        this.broadcast({ type: "mainMessagesSnapshot", messages: this.options.supervisor.listMainMessages() });
      }
      if (command.type === "abortMainAgent") await this.options.supervisor.abortMainAgent();
      if (command.type === "setMainAgentThinkingLevel") await this.options.supervisor.setMainAgentThinkingLevel(command.mainAgentThinkingLevel);
      if (command.type === "setMainAgentExtraInstructions") this.options.supervisor.setMainAgentExtraInstructions(command.mainAgentExtraInstructions);
      if (command.type === "listSlashCommands") {
        const commands = await this.options.supervisor.listSlashCommands(command.sessionId);
        this.send(ws, { type: "slashCommandsSnapshot", sessionId: command.sessionId, commands });
      }
      if (command.type === "getSession") {
        const session = this.options.supervisor.get(command.sessionId);
        if (!session) throw new Error(`Unknown session: ${command.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session: protocolSession(session) });
      }
      if (command.type === "routeTask") await this.options.supervisor.route(command.context);
      if (command.type === "createTask") await this.options.supervisor.create(command.context);
      if (command.type === "createEmptySideSession") await this.options.supervisor.createEmptySideSession(command.context);
      if (command.type === "pinSideSession") await this.options.supervisor.pinSideSession(command.context, command.title);
      if (command.type === "setNotifyMainOnCompletion") await this.options.supervisor.setNotifyMainOnCompletion(command.sessionId, command.enabled);
      if (command.type === "setSessionArchived") await this.options.supervisor.setSessionArchived(command.sessionId, command.archived);
      if (command.type === "clearQueue") await this.options.supervisor.clearQueue(command.sessionId, command.kind);
      if (command.type === "syncTerminalSession") await this.options.supervisor.syncTerminalSession(command.sessionId, command.baselinePiMessageId);
      if (command.type === "followUp") await this.options.supervisor.followUp(command.sessionId, command.text, command.context);
      if (command.type === "steer") await this.options.supervisor.steer(command.sessionId, command.text, command.context);
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
    const event: EventEnvelope = sanitizeForJson({ id: `event-${randomUUID()}`, protocolVersion: PROTOCOL_VERSION, timestamp: new Date().toISOString(), ...payload } as EventEnvelope);
    logAgentd("event sent", eventLogFields(event));
    ws.send(JSON.stringify(event));
  }
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

function commandLogFields(command: ReturnType<typeof parseCommand>): Record<string, string | number | undefined> {
  switch (command.type) {
    case "routeTask":
    case "createTask":
    case "createEmptySideSession":
    case "pinSideSession":
      return { commandId: command.id, type: command.type, contextId: command.context.id, source: command.context.source, transcriptChars: command.context.transcript?.length, screenshots: command.context.screenshots.length };
    case "followUp":
    case "steer":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, textChars: command.text.length, contextId: command.context?.id, screenshots: command.context?.screenshots.length };
    case "setNotifyMainOnCompletion":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, enabled: command.enabled ? 1 : 0 };
    case "setSessionArchived":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, archived: command.archived ? 1 : 0 };
    case "clearQueue":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, kind: command.kind };
    case "syncTerminalSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, baselinePiMessageId: command.baselinePiMessageId };
    case "abort":
    case "getSession":
    case "listSlashCommands":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId };
    case "answerExtensionUi":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, requestId: command.requestId };
    case "openArtifact":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, artifactId: command.artifactId };
    case "listSessions":
    case "listMainMessages":
    case "resetMainAgent":
    case "abortMainAgent":
      return { commandId: command.id, type: command.type };
    case "setMainAgentThinkingLevel":
      return { commandId: command.id, type: command.type, mainAgentThinkingLevel: command.mainAgentThinkingLevel };
    case "setMainAgentExtraInstructions":
      return { commandId: command.id, type: command.type, instructionChars: command.mainAgentExtraInstructions.length };
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
    case "slashCommandsSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, commands: event.commands.length };
    case "sessionMessageAppended":
    case "sessionMessageReplaced":
    case "sessionMessageRemoved":
    case "sessionQueueUpdated":
    case "sessionActivityUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, seq: event.seq };
    case "error":
      return { eventId: event.id, type: event.type, commandId: event.commandId, code: event.code };
  }
}

const SNAPSHOT_LOG_LIMIT = 24;
const SNAPSHOT_IMPORTANT_LOG_LIMIT = 8;
const SNAPSHOT_LOG_CHAR_LIMIT = 1_200;
const SNAPSHOT_TOOL_LIMIT = 16;
const SNAPSHOT_TOOL_PREVIEW_CHAR_LIMIT = 500;
const SNAPSHOT_THINKING_PREVIEW_CHAR_LIMIT = 240;
const SNAPSHOT_CHANGED_FILE_LIMIT = 30;
const SNAPSHOT_CHANGED_FILE_SUMMARY_CHAR_LIMIT = 500;
const SNAPSHOT_MESSAGE_LIMIT = 50;

export function compactSessionsForSnapshot(sessions: PickyAgentSession[]): PickyAgentSession[] {
  return sessions.map((session) => ({
    ...session,
    thinkingPreview: session.thinkingPreview ? truncateText(session.thinkingPreview, SNAPSHOT_THINKING_PREVIEW_CHAR_LIMIT) : session.thinkingPreview,
    logs: compactSnapshotLogs(session.logs),
    tools: compactSnapshotTools(session.tools),
    changedFiles: compactSnapshotChangedFiles(session.changedFiles),
    messages: compactSnapshotMessages(session.messages),
  }));
}

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
