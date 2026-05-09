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
  setDefaultCwd?: (cwd: string) => void;
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
    this.options.supervisor.on("mainRealtimeStateChanged", (state, message) => this.broadcast({ type: "mainRealtimeStateChanged", state, ...(message ? { message } : {}) }));
    this.options.supervisor.on("mainRealtimeInputTranscriptDelta", (inputId, delta) => this.broadcast({ type: "mainRealtimeInputTranscriptDelta", inputId, delta }));
    this.options.supervisor.on("mainRealtimeInputTranscriptCompleted", (inputId, transcript) => this.broadcast({ type: "mainRealtimeInputTranscriptCompleted", inputId, transcript }));
    this.options.supervisor.on("mainRealtimeOutputAudioDelta", (inputId, audioBase64) => this.broadcast({ type: "mainRealtimeOutputAudioDelta", ...(inputId ? { inputId } : {}), audioBase64 }));
    this.options.supervisor.on("mainRealtimeOutputAudioDone", (inputId) => this.broadcast({ type: "mainRealtimeOutputAudioDone", ...(inputId ? { inputId } : {}) }));
    this.options.supervisor.on("mainRealtimeOutputTranscriptDelta", (inputId, delta) => this.broadcast({ type: "mainRealtimeOutputTranscriptDelta", ...(inputId ? { inputId } : {}), delta }));
    this.options.supervisor.on("mainRealtimeOutputTranscriptCompleted", (inputId, transcript) => this.broadcast({ type: "mainRealtimeOutputTranscriptCompleted", ...(inputId ? { inputId } : {}), transcript }));
    this.options.supervisor.on("mainRealtimeTurnDone", (inputId, status, finalTranscript) => this.broadcast({ type: "mainRealtimeTurnDone", ...(inputId ? { inputId } : {}), status, ...(finalTranscript ? { finalTranscript } : {}) }));
    this.options.supervisor.on("pointerOverlayRequested", (request) => this.broadcast({ type: "pointerOverlayRequested", request }));
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
      if (command.type === "listMainAgentModels") this.send(ws, { type: "mainAgentModelsSnapshot", models: await this.options.supervisor.listMainAgentModels() });
      if (command.type === "setDefaultCwd") this.options.setDefaultCwd?.(command.defaultCwd.trim());
      if (command.type === "setMainAgentModel") await this.options.supervisor.setMainAgentModel(command.mainAgentModelPattern);
      if (command.type === "setMainAgentRuntimeMode") await this.options.supervisor.setMainAgentRuntimeMode(command.mode);
      if (command.type === "configureMainRealtimeAuth") await this.options.supervisor.configureMainRealtimeAuth(command);
      if (command.type === "beginMainRealtimeVoiceTurn") await this.options.supervisor.beginMainRealtimeVoiceTurn(command.inputId, command.context);
      if (command.type === "appendMainRealtimeInputAudio") await this.options.supervisor.appendMainRealtimeInputAudio(command.inputId, command.audioBase64);
      if (command.type === "commitMainRealtimeVoiceTurn") await this.options.supervisor.commitMainRealtimeVoiceTurn(command.inputId, command.context);
      if (command.type === "cancelMainRealtimeVoiceTurn") await this.options.supervisor.cancelMainRealtimeVoiceTurn(command.inputId, command.playedAudioMs);
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
      if (command.type === "createEmptyPickleSession") await this.options.supervisor.createEmptyPickleSession(command.context);
      if (command.type === "duplicatePickleSession") await this.options.supervisor.duplicatePickleSession(command.sessionId);
      if (command.type === "pinPickleSession") await this.options.supervisor.pinPickleSession(command.context, command.title);
      if (command.type === "setNotifyMainOnCompletion") await this.options.supervisor.setNotifyMainOnCompletion(command.sessionId, command.enabled);
      if (command.type === "setSessionArchived") await this.options.supervisor.setSessionArchived(command.sessionId, command.archived);
      if (command.type === "cycleSessionThinkingLevel") await this.options.supervisor.cycleSessionThinkingLevel(command.sessionId);
      if (command.type === "cycleSessionModel") await this.options.supervisor.cycleSessionModel(command.sessionId, command.direction);
      if (command.type === "clearQueue") await this.options.supervisor.clearQueue(command.sessionId, command.kind);
      if (command.type === "syncTerminalSession") await this.options.supervisor.syncTerminalSession(command.sessionId, command.baselinePiMessageId);
      if (command.type === "followUp") await this.options.supervisor.followUp(command.sessionId, command.text, command.context);
      if (command.type === "steer") await this.options.supervisor.steer(command.sessionId, command.text, command.context);
      if (command.type === "abort") await this.options.supervisor.abort(command.sessionId);
      if (command.type === "answerExtensionUi") await this.options.supervisor.answerExtensionUi(command.sessionId, command.requestId, command.value);
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

export function commandLogFields(command: ReturnType<typeof parseCommand>): Record<string, string | number | undefined> {
  switch (command.type) {
    case "routeTask":
    case "createTask":
    case "createEmptyPickleSession":
    case "pinPickleSession":
      return { commandId: command.id, type: command.type, contextId: command.context.id, source: command.context.source, transcriptChars: command.context.transcript?.length, screenshots: command.context.screenshots.length };
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
    case "setMainAgentRuntimeMode":
      return { commandId: command.id, type: command.type, mode: command.mode };
    case "setMainAgentModel":
      return { commandId: command.id, type: command.type, modelPatternChars: command.mainAgentModelPattern.length };
    case "configureMainRealtimeAuth":
      return { commandId: command.id, type: command.type, provider: command.provider, modelOrDeployment: command.modelOrDeployment, voice: command.voice, keyPresent: command.apiKey ? 1 : 0, endpointHost: endpointHostForLog(command.azure?.resourceEndpoint) };
    case "beginMainRealtimeVoiceTurn":
      return { commandId: command.id, type: command.type, inputId: command.inputId, contextId: command.context.id, source: command.context.source, screenshots: command.context.screenshots.length };
    case "appendMainRealtimeInputAudio":
      return { commandId: command.id, type: command.type, inputId: command.inputId, audioBytesBase64Chars: command.audioBase64.length };
    case "commitMainRealtimeVoiceTurn":
      return { commandId: command.id, type: command.type, inputId: command.inputId, contextId: command.context?.id, screenshots: command.context?.screenshots.length, inkMarks: command.context?.inkMarks.length };
    case "cancelMainRealtimeVoiceTurn":
      return { commandId: command.id, type: command.type, inputId: command.inputId, playedAudioMs: command.playedAudioMs };
    case "listSessions":
    case "listMainMessages":
    case "listMainAgentModels":
    case "resetMainAgent":
    case "abortMainAgent":
      return { commandId: command.id, type: command.type };
    case "setMainAgentThinkingLevel":
      return { commandId: command.id, type: command.type, mainAgentThinkingLevel: command.mainAgentThinkingLevel };
    case "setMainAgentExtraInstructions":
      return { commandId: command.id, type: command.type, instructionChars: command.mainAgentExtraInstructions.length };
  }
}

function endpointHostForLog(endpoint: string | undefined): string | undefined {
  if (!endpoint) return undefined;
  const trimmed = endpoint.trim();
  if (!trimmed) return undefined;
  const candidate = /^wss?:\/\//i.test(trimmed)
    ? trimmed.replace(/^wss:/i, "https:").replace(/^ws:/i, "http:")
    : /^https?:\/\//i.test(trimmed)
      ? trimmed
      : `https://${trimmed}`;
  try {
    return new URL(candidate).host;
  } catch {
    return "<invalid>";
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
    case "mainRealtimeStateChanged":
      return { eventId: event.id, type: event.type, state: event.state, messageChars: event.message?.length };
    case "mainRealtimeInputTranscriptDelta":
    case "mainRealtimeOutputTranscriptDelta":
      return { eventId: event.id, type: event.type, inputId: event.inputId, deltaChars: event.delta.length };
    case "mainRealtimeInputTranscriptCompleted":
      return { eventId: event.id, type: event.type, inputId: event.inputId, transcriptChars: event.transcript.length };
    case "mainRealtimeOutputTranscriptCompleted":
      return { eventId: event.id, type: event.type, inputId: event.inputId, transcriptChars: event.transcript.length };
    case "mainRealtimeOutputAudioDelta":
      return { eventId: event.id, type: event.type, inputId: event.inputId, audioBase64Chars: event.audioBase64.length };
    case "mainRealtimeOutputAudioDone":
      return { eventId: event.id, type: event.type, inputId: event.inputId };
    case "mainRealtimeTurnDone":
      return { eventId: event.id, type: event.type, inputId: event.inputId, status: event.status, finalTranscriptChars: event.finalTranscript?.length };
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
    case "pointerOverlayRequested":
      return { eventId: event.id, type: event.type, requestId: event.request.id, screenId: event.request.screenId };
    case "slashCommandsSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, commands: event.commands.length };
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
const SNAPSHOT_MESSAGE_TEXT_CHAR_LIMIT = 700;
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

function compactSnapshotMessages(messages: PickyAgentSession["messages"]): PickyAgentSession["messages"] {
  return messages?.slice(-SNAPSHOT_MESSAGE_LIMIT).map((message) => ({
    ...message,
    text: message.text ? truncateText(message.text, SNAPSHOT_MESSAGE_TEXT_CHAR_LIMIT) : message.text,
    errorContext: message.errorContext ? truncateText(message.errorContext, SNAPSHOT_MESSAGE_TEXT_CHAR_LIMIT) : message.errorContext,
    errorMessage: message.errorMessage ? truncateText(message.errorMessage, SNAPSHOT_MESSAGE_TEXT_CHAR_LIMIT) : message.errorMessage,
    question: message.question
      ? {
          ...message.question,
          prompt: message.question.prompt ? truncateText(message.question.prompt, SNAPSHOT_MESSAGE_TEXT_CHAR_LIMIT) : message.question.prompt,
          description: message.question.description ? truncateText(message.question.description, SNAPSHOT_MESSAGE_TEXT_CHAR_LIMIT) : message.question.description,
        }
      : message.question,
  }));
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
