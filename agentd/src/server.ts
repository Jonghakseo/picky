import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from "node:http";
import { WebSocketServer } from "ws";
import type { WebSocket } from "ws";
import { isAuthorized } from "./auth.js";
import { FOLLOWUP_PREFIX, HANDOFF_PREFIX, STEER_PREFIX } from "./domain/log-prefixes.js";
import { PROTOCOL_VERSION, PickyAgentSessionMetaSchema, PickyAgentSessionSchema, parseCommand, type DockGroup, type EventEnvelope, type PickyAgentSession, type PickyAgentSessionMeta, type PickyAgentSessionParsed, type PickyContextPacket, type PickyPushToTalkControlAction } from "./protocol.js";
import { APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT, boundedSessionForAppHydration, compactSessionForAppSnapshot, eventPayloadByteLength, minimalSessionForAppSnapshot, truncateText } from "./application/app-session-snapshot-policy.js";
import { ProjectionRecoveryRequestGate } from "./application/session-projection-recovery.js";
import { SessionProjectionV2Broadcaster } from "./application/session-projection-v2-broadcaster.js";
import { assertProtocolVersion } from "./application/protocol-version-guard.js";
import { isLegacySessionProjectionEvent, isV2SessionProjectionEventType, SocketDialectRegistry, type SocketDialect } from "./application/socket-dialect.js";
import type { SessionSupervisor } from "./session-supervisor.js";
import { runtimeControlCommandLogFields } from "./domain/runtime-control-log-fields.js";
import { sanitizeForJson } from "./domain/sanitize-for-json.js";
import { logAgentd } from "./local-log.js";
import { EdgeTTSServiceError } from "./edge-tts-service.js";
import type { EdgeTTSService } from "./edge-tts-service.js";
import { packageOperationHandlers, PackageOperations, type CronPackageLifecycleLike, type PackageManager, type PackageManagerFactoryOptions } from "./application/package-operations.js";
export { createDefaultPackageManager, type DefaultPackageManagerDependencies } from "./application/package-operations.js";
import type { PiOAuthHandling } from "./application/pi-oauth-service.js";
import { SettingsControlBroker, SettingsControlError } from "./application/settings-control-broker.js";
import { PiModelScopeConflictError } from "./runtime/model-scope-errors.js";
export { APP_SETTINGS_CONTROL_UNAVAILABLE } from "./application/settings-control-broker.js";
export interface AgentdServerOptions {
  port: number;
  token: string;
  supervisor: SessionSupervisor;
  /** Creates a fresh user-scope Pi package manager for each package operation. */
  createPackageManager?: (options: PackageManagerFactoryOptions) => PackageManager;
  /** Overrides Pi's agent directory for package-manager isolation in tests. */
  getAgentDir?: () => string;
  /** Provides a hermetic Cron lifecycle seam for package-operation tests. */
  createCronLifecycle?: (packageManager: PackageManager) => CronPackageLifecycleLike;
  /** Bounds client-visible package operations; the queue remains held until underlying mutation exits. */
  packageOperationTimeoutMs?: number;
  setDefaultCwd?: (cwd: string) => void;
  getDefaultCwd?: () => string;
  /** Primary-only. Child daemons intentionally omit the local Edge TTS routes. */
  edgeTTS?: EdgeTTSService;
  /** Primary-only provider authentication coordinator. */
  piOAuth?: PiOAuthHandling;
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
  | { operation: "steer" | "followUp"; sessionId: string; text: string }
  | { operation: "abort"; sessionId: string }
  | { operation: "setArchived"; sessionId: string; archived: boolean }
  | { operation: "delete"; sessionId: string }
  | { operation: "manageGroups"; groupAction: "list" | "create" | "addMembers" | "removeMembers" | "removeGroup" | "archiveGroup"; groupId?: string; name?: string; sessionIds?: string[] }
  | { operation: "notifyMainOfPickleCompletion"; sessionId: string; prompt: string; cwd?: string };

export interface AppPickleBridgeResult {
  sessions?: PickyAgentSession[];
  groups?: DockGroup[];
  session?: PickyAgentSession;
  delivered?: boolean;
}

export const APP_PICKLE_HANDOFF_UNAVAILABLE = "Picky app handoff unavailable";
const APP_PICKLE_HANDOFF_TIMEOUT = "Picky app handoff timed out";
export const APP_EXTERNAL_ENTRY_UNAVAILABLE = "Picky app external entry unavailable";
const APP_EXTERNAL_ENTRY_TIMEOUT = "Picky app external entry timed out";
const EXTERNAL_ENTRY_TIMEOUT_MS = 10_000;
export const APP_PUSH_TO_TALK_CONTROL_UNAVAILABLE = "Picky app push-to-talk control unavailable";
const APP_PUSH_TO_TALK_CONTROL_TIMEOUT = "Picky app push-to-talk control timed out";
const PUSH_TO_TALK_CONTROL_TIMEOUT_MS = 2_000;
export const APP_DOCK_GROUPS_UNAVAILABLE = "Picky app dock groups unavailable";
const APP_DOCK_GROUPS_TIMEOUT = "Picky app dock groups request timed out";
const DOCK_GROUPS_TIMEOUT_MS = 4_000;
export class AgentdServer {
  private httpServer?: HttpServer;
  private wsServer?: WebSocketServer;
  private clients = new Set<WebSocket>();
  private appCapabilities = new WeakMap<WebSocket, Set<string>>();
  private readonly socketDialects = new SocketDialectRegistry();
  private readonly projectionRecoveryRequestGate = new ProjectionRecoveryRequestGate();
  private readonly v2ProjectionBroadcaster = new SessionProjectionV2Broadcaster<WebSocket>({ sockets: () => this.clients, getDialect: (socket) => this.socketDialects.get(socket), send: (socket, payload) => { this.send(socket, payload); }, close: (socket) => socket.close(1011, "Session projection bootstrap failed") });
  private pendingPickleHandoffs = new Map<string, { resolve: (result: AppPickleHandoffResult) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private pendingPickleBridgeRequests = new Map<string, { resolve: (result: AppPickleBridgeResult) => void; reject: (error: Error) => void; timer: NodeJS.Timeout; app: WebSocket }>();
  private pendingExternalEntries = new Map<string, ExternalEntryPending>();
  private pendingPushToTalkControls = new Map<string, PushToTalkControlPending>();
  private pendingDockGroupsRequests = new Map<string, DockGroupsPending>();
  private readonly settingsControl: SettingsControlBroker;
  private readonly packageOperations: PackageOperations;
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

  constructor(private readonly options: AgentdServerOptions) {
    this.packageOperations = new PackageOperations({
      createPackageManager: options.createPackageManager,
      createCronLifecycle: options.createCronLifecycle,
      getAgentDir: options.getAgentDir,
      packageOperationTimeoutMs: options.packageOperationTimeoutMs,
      send: (ws, event) => { this.send(ws, event); },
    });
    this.settingsControl = new SettingsControlBroker({
      firstSettingsControlApp: () => this.firstClientWithCapability("settingsControl"),
      send: (ws, event) => { this.send(ws, event); },
    });
  }

  async start(): Promise<number> {
    this.packageOperations.start();
    this.httpServer = createServer((request, response) => {
      void this.handleHttpRequest(request, response);
    });
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

    this.v2ProjectionBroadcaster.bind(this.options.supervisor);
    this.options.supervisor.on("session", (session) => this.broadcast({ type: "sessionUpdated", session: protocolSession(session) }));
    this.options.supervisor.on("sessionMeta", (session) => this.broadcast({ type: "sessionMetaUpdated", session: protocolSessionMeta(session) }));
    this.options.supervisor.on("sessionArchivedAuthoritative", (sessionId: string, archived: boolean) => this.broadcast({ type: "sessionArchivedAuthoritative", sessionId, archived }));
    this.options.supervisor.on("resourcesReloaded", (sessionId) => this.broadcast({ type: "sessionResourcesReloaded", sessionId }));
    this.options.supervisor.on("log", (sessionId, line) => this.broadcast({ type: "sessionLogAppended", sessionId, line }));
    this.options.supervisor.on("extensionUiRequest", (request) => this.broadcast({ type: "extensionUiRequest", request }));
    this.options.supervisor.on("toolActivityUpdated", (sessionId, tool) => this.broadcast({ type: "toolActivityUpdated", sessionId, tool }));
    this.options.supervisor.on("todoStateUpdated", (sessionId, todoState, seq) => this.broadcast({ type: "sessionTodoStateUpdated", sessionId, todoState: todoState ?? null, seq }));
    this.options.supervisor.on("subagentRunsUpdated", (sessionId, runs, seq) => this.broadcast({ type: "sessionSubagentRunsUpdated", sessionId, runs, seq }));
    this.options.supervisor.on("queueUpdated", (sessionId, steering, followUp, steeringMode, followUpMode, seq) => this.broadcast({ type: "sessionQueueUpdated", sessionId, steering, followUp, steeringMode, followUpMode, seq }));
    this.options.supervisor.on("activityUpdated", (sessionId, activitySummary, seq) => this.broadcast({ type: "sessionActivityUpdated", sessionId, activitySummary, seq }));
    this.options.supervisor.on("messageAppended", (sessionId, message, seq) => this.broadcast({ type: "sessionMessageAppended", sessionId, message, seq }));
    this.options.supervisor.on("messagesImported", (sessionId, messages, seq) => this.broadcast({ type: "sessionMessagesImported", sessionId, messages, seq }));
    this.options.supervisor.on("messageReplaced", (sessionId, messageId, message, seq) => this.broadcast({ type: "sessionMessageReplaced", sessionId, messageId, message, seq }));
    this.options.supervisor.on("messageRemoved", (sessionId, messageId, seq) => this.broadcast({ type: "sessionMessageRemoved", sessionId, messageId, seq }));
    this.options.supervisor.on("sessionRewound", (sessionId: string, editorText: string | undefined, removedIds: string[]) => this.broadcast({ type: "sessionRewound", sessionId, ...(editorText !== undefined ? { editorText } : {}), removedIds }));
    this.options.supervisor.on("quickReply", (contextId, text, metadata = {}) => this.broadcast({ type: "quickReply", contextId, text, ...metadata }));
    this.options.supervisor.on("mainTurnSettled", (contextId) => this.broadcast({ type: "mainTurnSettled", contextId }));
    this.options.supervisor.on("mainNarrationChunk", (chunk) => this.broadcast({ type: "mainNarrationChunk", ...chunk }));
    this.options.supervisor.on("mainVisualNarrationSegmentPrepared", (segment) => this.broadcast({ type: "mainVisualNarrationSegmentPrepared", ...segment }));
    this.options.supervisor.on("mainVisualNarrationSegmentSentence", (sentence) => this.broadcast({ type: "mainVisualNarrationSegmentSentence", ...sentence }));
    this.options.supervisor.on("mainVisualNarrationSegmentCommitted", (segment) => this.broadcast({ type: "mainVisualNarrationSegmentCommitted", ...segment }));
    this.options.supervisor.on("mainMessage", (message) => this.broadcast({ type: "mainMessageAppended", message }));
    this.options.supervisor.on("mainActivity", (activity) => this.broadcast({ type: "mainActivityUpdated", ...(activity ? { activity } : {}) }));
    this.options.supervisor.on("mainExtensionUiRequest", (request) => this.broadcast({ type: "mainExtensionUiRequested", request }));
    this.options.supervisor.on("mainExtensionUiCancelled", (requestId) => this.broadcast({ type: "mainExtensionUiCancelled", requestId }));
    this.options.supervisor.on("mainAgentSessionInfo", (info: { sessionFilePath?: string; cwd?: string }) => this.broadcast({
      type: "mainAgentSessionInfoUpdated",
      ...(info.sessionFilePath ? { sessionFilePath: info.sessionFilePath } : {}),
      ...(info.cwd ? { cwd: info.cwd } : {}),
    }));

    this.options.supervisor.on("pointerOverlayRequested", (request) => this.broadcast({ type: "pointerOverlayRequested", request }));
    this.options.supervisor.on("annotationOverlayRequested", (request) => this.broadcast({ type: "annotationOverlayRequested", request }));
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
      this.pendingPickleBridgeRequests.set(requestId, { resolve, reject, timer, app: client });
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
    for (const pending of this.pendingPushToTalkControls.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(APP_PUSH_TO_TALK_CONTROL_UNAVAILABLE));
    }
    this.pendingPushToTalkControls.clear();
    for (const pending of this.pendingDockGroupsRequests.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(APP_DOCK_GROUPS_UNAVAILABLE));
    }
    this.pendingDockGroupsRequests.clear();
    this.settingsControl.rejectAll();
    for (const client of this.clients) client.close();
    await this.packageOperations.stop();
    this.options.edgeTTS?.dispose();
    await new Promise<void>((resolve) => this.wsServer?.close(() => resolve()) ?? resolve());
    await new Promise<void>((resolve) => this.httpServer?.close(() => resolve()) ?? resolve());
  }

  private async handleHttpRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    const isEdgeRoute = url.pathname === "/v1/edge-tts/voices" || url.pathname === "/v1/edge-tts/speech";
    if (!isEdgeRoute || !this.options.edgeTTS) {
      writeJSON(response, 404, { error: { code: "not_found", message: "Not found." } });
      return;
    }
    if (!isAuthorized(request, this.options.token)) {
      writeJSON(response, 401, { error: { code: "unauthorized", message: "Unauthorized." } });
      return;
    }

    try {
      if (request.method === "GET" && url.pathname === "/v1/edge-tts/voices") {
        writeJSON(response, 200, { voices: await this.options.edgeTTS.listVoices() });
        return;
      }
      if (request.method === "POST" && url.pathname === "/v1/edge-tts/speech") {
        const body = await readEdgeTTSRequest(request);
        const controller = new AbortController();
        request.once("aborted", () => controller.abort());
        response.once("close", () => controller.abort());
        const audio = await this.options.edgeTTS.synthesize(body.input, body.voice, controller.signal);
        if (!response.writableEnded) {
          response.writeHead(200, {
            "Content-Type": "audio/mpeg",
            "Content-Length": String(audio.length),
            "Cache-Control": "no-store",
          });
          response.end(audio);
        }
        return;
      }
      writeJSON(response, 405, { error: { code: "method_not_allowed", message: "Method not allowed." } });
    } catch (error) {
      const serviceError = error instanceof EdgeTTSServiceError
        ? error
        : new EdgeTTSServiceError("Invalid Edge TTS request.", 400);
      if (!response.writableEnded) {
        writeJSON(response, serviceError.statusCode, { error: { code: "edge_tts_error", message: serviceError.message } });
      }
    }
  }

  private accept(ws: WebSocket): void {
    this.clients.add(ws);
    logAgentd("ws connected", { clients: this.clients.size });
    ws.on("close", () => {
      this.v2ProjectionBroadcaster.unregister(ws); this.clients.delete(ws);
      const lostCapabilities = this.appCapabilities.get(ws);
      this.appCapabilities.delete(ws);
      // Pickle handoffs are intentionally NOT rejected on socket close: the app
      // may be mid-creation across a transient ws drop, and its completion send
      // waits for reconnect and arrives on the new socket (matched by requestId).
      // The per-request timeout timer still bounds a recipient that never returns.
      for (const [requestId, pending] of this.pendingPickleBridgeRequests) {
        if (pending.app !== ws) continue;
        clearTimeout(pending.timer);
        pending.reject(new Error(APP_PICKLE_HANDOFF_UNAVAILABLE));
        this.pendingPickleBridgeRequests.delete(requestId);
      }
      if (lostCapabilities?.has("externalEntry")) {
        for (const [requestId, pending] of this.pendingExternalEntries) {
          clearTimeout(pending.timer);
          pending.reject(new Error(APP_EXTERNAL_ENTRY_UNAVAILABLE));
          this.pendingExternalEntries.delete(requestId);
        }
      }
      if (lostCapabilities?.has("pushToTalkControl")) {
        for (const [requestId, pending] of this.pendingPushToTalkControls) {
          clearTimeout(pending.timer);
          pending.reject(new Error(APP_PUSH_TO_TALK_CONTROL_UNAVAILABLE));
          this.pendingPushToTalkControls.delete(requestId);
        }
      }
      if (lostCapabilities?.has("externalEntry")) {
        for (const [requestId, pending] of this.pendingDockGroupsRequests) {
          if (pending.app !== ws) continue;
          clearTimeout(pending.timer);
          pending.reject(new Error(APP_DOCK_GROUPS_UNAVAILABLE));
          this.pendingDockGroupsRequests.delete(requestId);
        }
      }
      this.settingsControl.rejectForApp(ws);
      const cancelledOAuthLogins = this.options.piOAuth?.cancelOwnedBy(ws) ?? 0;
      logAgentd("ws disconnected", { clients: this.clients.size, cancelledOAuthLogins });
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
    const pendingMainExtensionUi = this.options.supervisor.mainPendingExtensionUi();
    if (pendingMainExtensionUi) {
      this.send(ws, { type: "mainExtensionUiRequested", request: pendingMainExtensionUi });
    }
    const activeMainActivity = this.options.supervisor.mainActiveActivity();
    if (activeMainActivity) {
      this.send(ws, { type: "mainActivityUpdated", activity: activeMainActivity });
    }
  }

  private async handleMessage(ws: WebSocket, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
      assertProtocolVersion(parsed, PROTOCOL_VERSION);
      const command = parseCommand(parsed);
      logAgentd("command received", commandLogFields(command));
      await this.dispatchCommand(ws, command);
      this.send(ws, { type: "ack", commandId: command.id });
    } catch (error) {
      const commandId = typeof parsed === "object" && parsed && "id" in parsed ? String((parsed as { id: unknown }).id) : undefined;
      logAgentd("command failed", { commandId, error: error instanceof Error ? error.message : String(error) });
      this.send(ws, {
        type: "error",
        code: error instanceof SettingsControlError || error instanceof PiModelScopeConflictError ? error.code : "bad_message",
        message: error instanceof Error ? error.message : String(error),
        commandId,
      });
    }
  }

  // eslint-disable-next-line max-lines-per-function -- The exhaustive typed command registry stays centralized so protocol commands cannot be registered without dispatch behavior.
  private async dispatchCommand(ws: WebSocket, command: ParsedCommand): Promise<void> {
    this.socketDialects.lockLegacyProjectionCommand(ws, command.type);
    const handlers: CommandHandlerMap = {
      listSessions: () => {
        const sessions = compactSessionsForSnapshot(this.options.supervisor.list()).map(protocolSession);
        this.sendSessionSnapshot(ws, sessions);
      },
      listMainMessages: (cmd) => this.send(ws, { type: "mainMessagesSnapshot", messages: this.options.supervisor.listMainMessages() }),
      listMainAgentModels: async (cmd) => this.send(ws, { type: "mainAgentModelsSnapshot", models: await this.options.supervisor.listMainAgentModels() }),
      getPiOAuthStatus: async (cmd) => {
        const status = await this.requirePiOAuth().status(cmd.providerId);
        this.send(ws, { type: "piOAuthStatus", requestId: cmd.id, providerId: cmd.providerId, ...status });
      },
      signInPiOAuth: async (cmd) => {
        const status = await this.requirePiOAuth().login({
          requestId: cmd.id,
          providerId: cmd.providerId,
          owner: ws,
          onNotify: (event) => {
            if (event.type === "auth_url") {
              this.send(ws, {
                type: "piOAuthUrlRequested",
                requestId: cmd.id,
                providerId: cmd.providerId,
                url: event.url,
                instructions: event.instructions,
              });
            } else if (event.type === "device_code") {
              this.send(ws, {
                type: "piOAuthUrlRequested",
                requestId: cmd.id,
                providerId: cmd.providerId,
                url: event.verificationUri,
                userCode: event.userCode,
              });
            } else {
              logAgentd("pi oauth progress", { requestId: cmd.id, providerId: cmd.providerId, eventType: event.type });
            }
          },
          onPrompt: (promptId, prompt) => this.send(ws, {
            type: "piOAuthPromptRequested",
            requestId: cmd.id,
            providerId: cmd.providerId,
            promptId,
            promptType: prompt.type,
            message: prompt.message,
            ...("placeholder" in prompt && prompt.placeholder ? { placeholder: prompt.placeholder } : {}),
            ...(prompt.type === "select" ? { options: [...prompt.options] } : {}),
          }),
        });
        this.send(ws, { type: "piOAuthStatus", requestId: cmd.id, providerId: cmd.providerId, ...status });
      },
      answerPiOAuthPrompt: (cmd) => this.requirePiOAuth().answerPrompt({
        owner: ws,
        requestId: cmd.requestId,
        promptId: cmd.promptId,
        value: cmd.value,
        cancelled: cmd.cancelled,
      }),
      cancelPiOAuth: (cmd) => { this.requirePiOAuth().cancel(ws, cmd.requestId); },
      reloadPiAuthentication: async (cmd) => {
        const reloadedHandleCount = await this.options.supervisor.reloadPiAuthentication();
        this.send(ws, { type: "piAuthenticationReloaded", requestId: cmd.id, reloadedHandleCount });
      },
      setDefaultCwd: (cmd) => this.options.setDefaultCwd?.(cmd.defaultCwd.trim()),
      setMainAgentModel: (cmd) => this.options.supervisor.setMainAgentModel(cmd.mainAgentModelPattern),
      setDisabledBuiltinTools: (cmd) => this.options.supervisor.setDisabledBuiltinTools(cmd.disabledBuiltinTools),
      setMainAgentTTSEnabled: (cmd) => this.options.supervisor.setTTSEnabled(cmd.enabled),
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
      getAutocompleteCapabilities: async (cmd) => {
        const capabilities = await this.options.supervisor.getAutocompleteCapabilities(cmd.sessionId);
        this.send(ws, {
          type: "autocompleteCapabilitiesSnapshot",
          sessionId: cmd.sessionId,
          requestId: cmd.id,
          generation: capabilities.generation,
          triggerCharacters: capabilities.triggerCharacters,
        });
      },
      autocompleteQuery: async (cmd) => {
        const suggestions = await this.options.supervisor.queryAutocomplete(cmd.sessionId, {
          generation: cmd.generation,
          lines: cmd.lines,
          cursorLine: cmd.cursorLine,
          cursorCol: cmd.cursorCol,
          force: cmd.force,
        });
        this.send(ws, {
          type: "autocompleteSuggestionsSnapshot",
          sessionId: cmd.sessionId,
          requestId: cmd.id,
          generation: suggestions.generation,
          draftRevision: cmd.draftRevision,
          draftFingerprint: cmd.draftFingerprint,
          cursorLine: cmd.cursorLine,
          cursorCol: cmd.cursorCol,
          prefix: suggestions.prefix,
          items: suggestions.items,
        });
      },
      autocompleteApply: async (cmd) => {
        const completion = await this.options.supervisor.applyAutocomplete(cmd.sessionId, {
          generation: cmd.generation,
          lines: cmd.lines,
          cursorLine: cmd.cursorLine,
          cursorCol: cmd.cursorCol,
          force: cmd.force,
          item: cmd.item,
          prefix: cmd.prefix,
        });
        this.send(ws, {
          type: "autocompleteCompletionApplied",
          sessionId: cmd.sessionId,
          requestId: cmd.id,
          generation: completion.generation,
          draftRevision: cmd.draftRevision,
          draftFingerprint: cmd.draftFingerprint,
          lines: completion.lines,
          cursorLine: completion.cursorLine,
          cursorCol: completion.cursorCol,
        });
      },
      listRewindTargets: async (cmd) => {
        const targets = await this.options.supervisor.listRewindTargets(cmd.sessionId);
        this.send(ws, { type: "rewindTargetsSnapshot", sessionId: cmd.sessionId, requestId: cmd.id, targets });
      },
      getSessionDiff: async (cmd) => {
        const result = await this.options.supervisor.getSessionDiff(cmd.sessionId, cmd.view);
        this.send(ws, { type: "sessionDiffResult", sessionId: cmd.sessionId, view: cmd.view, requestId: cmd.requestId, ...result });
      },
      rewindSession: async (cmd) => {
        const session = await this.options.supervisor.rewindToEntry(cmd.sessionId, cmd.entryId);
        this.broadcast({ type: "sessionUpdated", session: protocolSession(session) });
      },
      getSession: (cmd) => {
        const session = this.options.supervisor.get(cmd.sessionId);
        if (!session) throw new Error(`Unknown session: ${cmd.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session: protocolSession(session) });
      },
      // Recovery frames are v2-only until the W6.5 atomic cutover.
      getSessionProjectionSnapshot: (cmd) => {
        if (this.socketDialects.get(ws) !== "v2") throw new Error("Session projection recovery requires v2 socket dialect");
        return this.projectionRecoveryRequestGate.send(ws, { withSessionProjectionBarrier: (sessionId, work) => this.options.supervisor.withSessionProjectionBarrier(sessionId, work), send: (payload) => { this.send(ws, payload); } }, cmd);
      },
      routeTask: (cmd) => this.options.supervisor.route(cmd.context),
      createTask: (cmd) => this.options.supervisor.create(cmd.context),
      createEmptyPickleSession: (cmd) => this.options.supervisor.createEmptyPickleSession(cmd.context),
      createPickleFromHandoff: (cmd) => this.options.supervisor.createPickleFromHandoff(cmd.context, { title: cmd.title, instructions: cmd.instructions, cwd: cmd.cwd }),
      completePickleHandoff: (cmd) => this.completePendingPickleHandoff(cmd),
      registerAppCapabilities: (cmd) => this.registerAppCapabilities(ws, cmd.capabilities, cmd.id),
      listPickySettings: async (cmd) => {
        const result = await this.settingsControl.request({ action: "list", caller: cmd.caller });
        this.send(ws, { type: "pickySettingsAck", commandId: cmd.id, result });
      },
      getPickySettings: async (cmd) => {
        const result = await this.settingsControl.request({ action: "get", key: cmd.key, caller: cmd.caller });
        this.send(ws, { type: "pickySettingsAck", commandId: cmd.id, result });
      },
      setPickySettings: async (cmd) => {
        const result = await this.settingsControl.request({
          action: "set",
          key: cmd.key,
          value: cmd.value,
          ...(cmd.toggle !== undefined ? { toggle: cmd.toggle } : {}),
          ...(cmd.displayId !== undefined ? { displayId: cmd.displayId } : {}),
          caller: cmd.caller,
        });
        this.send(ws, { type: "pickySettingsAck", commandId: cmd.id, result });
      },
      completePickySettingsRequest: (cmd) => this.settingsControl.complete(ws, cmd),
      completePickleBridgeRequest: (cmd) => this.completePendingPickleBridgeRequest(cmd),
      submitMainFromExternal: (cmd) => this.enqueueExternalEntry(ws, cmd.id, "submitMain", { text: cmd.text, captureContext: cmd.captureContext, cwd: cmd.cwd }),
      createPickleFromExternal: (cmd) => this.enqueueExternalEntry(ws, cmd.id, "createPickle", { title: cmd.title, instructions: cmd.instructions, captureContext: cmd.captureContext, cwd: cmd.cwd, group: cmd.group }),
      createPickleFromMain: (cmd) => this.createPickleFromMainCli(ws, cmd),
      listPickles: async () => {
        const result = await this.requestPickleBridgeFromApp({ operation: "listSessions" });
        this.send(ws, { type: "sessionSnapshot", sessions: (result.sessions ?? []).map(protocolSession) });
      },
      getPickle: async (cmd) => {
        const result = await this.requestPickleBridgeFromApp({ operation: "listSessions" });
        const session = result.sessions?.find((candidate) => candidate.id === cmd.sessionId);
        if (!session) throw new Error(`Pickle session not found: ${cmd.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session: protocolSession(session) });
      },
      controlPickle: async (cmd) => {
        if ((cmd.pickleAction === "steer" || cmd.pickleAction === "followUp") && !cmd.text) {
          throw new Error(`${cmd.pickleAction} requires text`);
        }
        const result = await this.requestPickleBridgeFromApp(cmd.pickleAction === "abort"
          ? { operation: "abort", sessionId: cmd.sessionId }
          : { operation: cmd.pickleAction, sessionId: cmd.sessionId, text: cmd.text! });
        if (!result.session) throw new Error(`No Pickle session returned for ${cmd.pickleAction}: ${cmd.sessionId}`);
        this.send(ws, { type: "sessionUpdated", session: protocolSession(result.session) });
      },
      setPickleArchived: async (cmd) => {
        await this.requestPickleBridgeFromApp({ operation: "setArchived", sessionId: cmd.sessionId, archived: cmd.archived });
        this.send(ws, { type: "sessionArchivedAuthoritative", sessionId: cmd.sessionId, archived: cmd.archived });
      },
      deletePickle: async (cmd) => {
        const result = await this.requestPickleBridgeFromApp({ operation: "delete", sessionId: cmd.sessionId });
        this.send(ws, { type: "sessionSnapshot", sessions: (result.sessions ?? []).map(protocolSession) });
      },
      listDockGroups: async () => {
        const groups = await this.requestDockGroups();
        this.send(ws, { type: "dockGroupsSnapshot", groups });
      },
      manageDockGroups: async (cmd) => {
        const result = await this.requestPickleBridgeFromApp({
          operation: "manageGroups",
          groupAction: cmd.groupAction,
          ...(cmd.groupId ? { groupId: cmd.groupId } : {}),
          ...(cmd.name ? { name: cmd.name } : {}),
          ...(cmd.sessionIds ? { sessionIds: cmd.sessionIds } : {}),
        });
        this.send(ws, { type: "dockGroupsSnapshot", groups: result.groups ?? [] });
      },
      completeDockGroupsRequest: (cmd) => this.completePendingDockGroupsRequest(cmd),
      controlPushToTalkFromExternal: async (cmd) => {
        await this.requestPushToTalkControl(cmd.action);
        this.send(ws, { type: "pushToTalkControlAck", commandId: cmd.id, action: cmd.action });
      },
      completePushToTalkControlRequest: (cmd) => this.completePendingPushToTalkControl(cmd),
      completeExternalEntryRequest: (cmd) => this.completePendingExternalEntry(cmd),
      duplicatePickleSession: (cmd) => this.options.supervisor.duplicatePickleSession(cmd.sessionId),
      pinPickleSession: (cmd) => this.options.supervisor.pinPickleSession(cmd.context, cmd.title),
      setNotifyMainOnCompletion: (cmd) => this.options.supervisor.setNotifyMainOnCompletion(cmd.sessionId, cmd.enabled),
      notifyMainOfPickleCompletion: (cmd) => this.options.supervisor.deliverMainAgentPickleCompletion(cmd.sessionId, cmd.prompt, cmd.cwd),
      setSessionArchived: (cmd) => this.options.supervisor.setSessionArchived(cmd.sessionId, cmd.archived),
      deleteSession: async (cmd) => {
        await this.options.supervisor.deleteSession(cmd.sessionId);
        // V2 has no deletion mutation. Retain this v1 fallback until an external deletion producer exists.
        const sessions = compactSessionsForSnapshot(this.options.supervisor.list()).map(protocolSession);
        this.broadcastSessionSnapshot(sessions);
      },
      cycleSessionThinkingLevel: (cmd) => this.options.supervisor.cycleSessionThinkingLevel(cmd.sessionId),
      listSessionRuntimeOptions: async (cmd) => {
        const options = await this.options.supervisor.listSessionRuntimeOptions(cmd.sessionId);
        this.send(ws, { type: "sessionRuntimeOptionsSnapshot", sessionId: cmd.sessionId, requestId: cmd.id, ...options });
      },
      setGlobalModelScope: (cmd) => this.options.supervisor.setGlobalModelScope(cmd.mode, cmd.patterns, cmd.expectedRevision),
      setSessionModel: (cmd) => this.options.supervisor.setSessionModel(cmd.sessionId, cmd.provider, cmd.modelId),
      setSessionThinkingLevel: (cmd) => this.options.supervisor.setSessionThinkingLevel(cmd.sessionId, cmd.thinkingLevel),
      cycleSessionModel: (cmd) => this.options.supervisor.cycleSessionModel(cmd.sessionId, cmd.direction),
      clearQueue: (cmd) => this.options.supervisor.clearQueue(cmd.sessionId, cmd.kind),
      syncTerminalSession: (cmd) => this.options.supervisor.syncTerminalSession(cmd.sessionId, cmd.baselinePiMessageId),
      setTerminalSessionTailEnabled: (cmd) => this.options.supervisor.setTerminalSessionTailEnabled(cmd.sessionId, cmd.enabled),
      followUp: (cmd) => {
        return this.options.supervisor.followUp(cmd.sessionId, cmd.text, cmd.context, cmd.visualDslEnabled === true);
      },
      steer: (cmd) => {
        return this.options.supervisor.steer(cmd.sessionId, cmd.text, cmd.context, cmd.visualDslEnabled === true);
      },
      abort: (cmd) => {
        return this.options.supervisor.abort(cmd.sessionId);
      },
      answerExtensionUi: (cmd) => this.options.supervisor.answerExtensionUi(cmd.sessionId, cmd.requestId, cmd.value),
      answerMainExtensionUi: (cmd) => this.options.supervisor.answerMainExtensionUi(cmd.requestId, cmd.value),
      ...packageOperationHandlers(this.packageOperations, ws),
      reloadPlugins: async (cmd) => {
        const summary = await this.options.supervisor.reloadPlugins();
        this.broadcast({
          type: "pluginsReloaded",
          requestId: cmd.id,
          pickyReloaded: summary.pickyReloaded,
          pickleReloadedCount: summary.pickleReloadedCount,
          pickleAbortedCount: summary.pickleAbortedCount,
          pickleDeferredCount: summary.pickleDeferredCount,
        });
      },
    };

    const handler = handlers[command.type] as (command: ParsedCommand) => unknown;
    await handler(command);
  }
  private requirePiOAuth(): PiOAuthHandling {
    if (!this.options.piOAuth) throw new Error("Pi OAuth is available only on the primary daemon");
    return this.options.piOAuth;
  }
  private async registerAppCapabilities(ws: WebSocket, capabilities: string[], bootstrapId: string): Promise<void> {
    const previousDialect = this.socketDialects.get(ws);
    let dialect: SocketDialect;
    try {
      dialect = this.socketDialects.lockFromCapabilities(ws, capabilities);
    } catch (error) {
      logAgentd("app capability registration rejected by socket dialect", {
        previousDialect,
        requestedDialect: capabilities.includes("sessionProjectionV2") ? "v2" : "v1",
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
    this.appCapabilities.set(ws, new Set(capabilities)); logAgentd("app capabilities registered", { capabilities: capabilities.join(","), dialect });
    await this.v2ProjectionBroadcaster.register(ws, previousDialect, dialect, this.options.supervisor, bootstrapId);
  }
  private sendSessionSnapshot(ws: WebSocket, sessions: PickyAgentSessionParsed[]): void {
    if (this.socketDialects.get(ws) !== "v1") return;
    if (this.appCapabilities.has(ws)) {
      this.sendAppSessionSnapshot(ws, sessions);
      return;
    }
    this.send(ws, { type: "sessionSnapshot", sessions });
  }
  private broadcastSessionSnapshot(sessions: PickyAgentSessionParsed[]): void {
    for (const client of this.clients) this.sendSessionSnapshot(client, sessions);
  }
  private sendAppSessionSnapshot(ws: WebSocket, sessions: PickyAgentSessionParsed[]): void {
    const lightweightSessions = sessions.map(compactSessionForAppSnapshot);
    const lightweightPayload = { type: "sessionSnapshot", sessions: lightweightSessions } as const;
    if (eventPayloadByteLength(lightweightPayload) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) {
      this.send(ws, lightweightPayload);
    } else {
      const minimalSessions = sessions.map(minimalSessionForAppSnapshot);
      const minimalPayload = { type: "sessionSnapshot", sessions: minimalSessions } as const;
      if (eventPayloadByteLength(minimalPayload) <= APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT) {
        logAgentd("app session snapshot reduced to minimal metadata", { sessions: sessions.length });
        this.send(ws, minimalPayload);
      } else {
        logAgentd("app session snapshot metadata exceeds frame budget", { sessions: sessions.length });
        this.send(ws, {
          type: "error",
          code: "session_snapshot_too_large",
          message: "Session metadata exceeds the safe app transport limit.",
        });
        return;
      }
    }

    for (const session of sessions) {
      const hydration = boundedSessionForAppHydration(session);
      if (hydration.omittedFields.length > 0) {
        logAgentd("app session hydration reduced to frame budget", {
          sessionId: session.id,
          omittedFields: hydration.omittedFields.join(","),
        });
      }
      if (!hydration.session) continue;
      this.send(ws, { type: "sessionUpdated", session: hydration.session });
    }
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
    pending.resolve({ sessions: command.sessions, groups: command.groups, session: command.session, delivered: command.delivered });
  }

  private async createPickleFromMainCli(
    ws: WebSocket,
    command: Extract<ParsedCommand, { type: "createPickleFromMain" }>,
  ): Promise<void> {
    try {
      if (command.caller !== "mainAgent") throw new Error("createPickleFromMain is available only to the Picky main agent CLI");
      const context = this.options.supervisor.currentMainContext();
      if (!context) throw new Error("No active Picky main context to hand off");
      const cwd = command.cwd?.trim() || this.options.getDefaultCwd?.() || context.cwd?.trim() || process.cwd();
      const session = await this.requestPickleHandoffFromApp({
        context,
        title: command.title,
        instructions: command.instructions,
        cwd,
      });
      this.broadcastToCapability("externalEntry", {
        type: "externalEntryAccepted",
        commandId: command.id,
        kind: "createPickle",
        sessionId: session.sessionId,
        contextId: context.id,
        ...(command.group ? { group: command.group } : {}),
      });
      this.send(ws, {
        type: "externalEntryAck",
        commandId: command.id,
        kind: "createPickle",
        sessionId: session.sessionId,
        contextId: context.id,
      });
    } catch (error) {
      this.send(ws, {
        type: "externalEntryAck",
        commandId: command.id,
        kind: "createPickle",
        errorMessage: error instanceof Error ? error.message : String(error),
      });
    }
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
    payload: { text?: string; title?: string; instructions?: string; captureContext: boolean; cwd?: string; group?: string },
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
    payload: { text?: string; title?: string; instructions?: string; captureContext: boolean; cwd?: string; group?: string },
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
        this.broadcastToCapability("externalEntry", {
          type: "externalEntryAccepted",
          commandId,
          kind,
          contextId: finalContext.id,
          ...(session ? { sessionId: session.id } : {}),
        });
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
        this.broadcastToCapability("externalEntry", {
          type: "externalEntryAccepted",
          commandId,
          kind,
          sessionId: session.id,
          contextId: finalContext.id,
          ...(payload.group ? { group: payload.group } : {}),
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

  private requestPushToTalkControl(action: PickyPushToTalkControlAction, timeoutMs = PUSH_TO_TALK_CONTROL_TIMEOUT_MS): Promise<void> {
    const app = this.firstClientWithCapability("pushToTalkControl");
    if (!app) return Promise.reject(new Error(APP_PUSH_TO_TALK_CONTROL_UNAVAILABLE));
    const requestId = `ptt-control-${randomUUID()}`;
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pendingPushToTalkControls.get(requestId);
        if (!pending) return;
        this.pendingPushToTalkControls.delete(requestId);
        pending.reject(new Error(APP_PUSH_TO_TALK_CONTROL_TIMEOUT));
      }, timeoutMs);
      this.pendingPushToTalkControls.set(requestId, { resolve, reject, timer });
      this.send(app, { type: "pushToTalkControlRequested", requestId, action });
    });
  }

  private requestDockGroups(timeoutMs = DOCK_GROUPS_TIMEOUT_MS): Promise<DockGroup[]> {
    const app = this.firstClientWithCapability("externalEntry");
    if (!app) return Promise.reject(new Error(APP_DOCK_GROUPS_UNAVAILABLE));
    const requestId = `dock-groups-${randomUUID()}`;
    return new Promise<DockGroup[]>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pendingDockGroupsRequests.get(requestId);
        if (!pending) return;
        this.pendingDockGroupsRequests.delete(requestId);
        pending.reject(new Error(APP_DOCK_GROUPS_TIMEOUT));
      }, timeoutMs);
      this.pendingDockGroupsRequests.set(requestId, { resolve, reject, timer, app });
      this.send(app, { type: "dockGroupsRequested", requestId });
    });
  }

  private completePendingDockGroupsRequest(command: Extract<ReturnType<typeof parseCommand>, { type: "completeDockGroupsRequest" }>): void {
    const pending = this.pendingDockGroupsRequests.get(command.requestId);
    if (!pending) throw new Error(`Unknown dock groups request: ${command.requestId}`);
    this.pendingDockGroupsRequests.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorMessage) {
      pending.reject(new Error(command.errorMessage));
      return;
    }
    pending.resolve(command.groups ?? []);
  }

  private completePendingPushToTalkControl(command: Extract<ReturnType<typeof parseCommand>, { type: "completePushToTalkControlRequest" }>): void {
    const pending = this.pendingPushToTalkControls.get(command.requestId);
    if (!pending) throw new Error(`Unknown push-to-talk control request: ${command.requestId}`);
    this.pendingPushToTalkControls.delete(command.requestId);
    clearTimeout(pending.timer);
    if (command.errorMessage) {
      pending.reject(new Error(command.errorMessage));
      return;
    }
    pending.resolve();
  }

  private broadcast(event: EventPayload): void {
    if (this.clients.size === 0) return;
    let bytes = 0;
    let type: string | undefined;
    let clients = 0;
    for (const client of this.clients) {
      if (isLegacySessionProjectionEvent(event) && this.socketDialects.get(client) !== "v1") continue;
      const sent = this.send(client, event);
      bytes = sent.bytes;
      type = sent.type;
      clients += 1;
    }
    logAgentd("event broadcast", { type, clients, bytes });
  }

  private broadcastToCapability(capability: string, event: EventPayload): void {
    let bytes = 0;
    let type: string | undefined;
    let clients = 0;
    for (const client of this.clients) {
      if (!this.appCapabilities.get(client)?.has(capability)) continue;
      const sent = this.send(client, event);
      bytes = sent.bytes;
      type = sent.type;
      clients += 1;
    }
    logAgentd("event broadcast", { type, clients, bytes });
  }

  private send(ws: WebSocket, payload: EventPayload): { bytes: number; type: string } {
    if ((isLegacySessionProjectionEvent(payload) && this.socketDialects.get(ws) !== "v1") || (isV2SessionProjectionEventType(payload.type) && this.socketDialects.get(ws) !== "v2")) return { bytes: 0, type: payload.type };
    const event: EventEnvelope = sanitizeForJson({ id: `event-${randomUUID()}`, protocolVersion: PROTOCOL_VERSION, timestamp: new Date().toISOString(), ...payload } as EventEnvelope);
    const json = JSON.stringify(event);
    logAgentd("event sent", eventLogFields(event));
    ws.send(json);
    return { bytes: Buffer.byteLength(json, "utf8"), type: event.type };
  }
}
const EDGE_TTS_HTTP_BODY_LIMIT_BYTES = 64 * 1024;

async function readEdgeTTSRequest(request: IncomingMessage): Promise<{ input: string; voice: string }> {
  const chunks: Buffer[] = [];
  let byteLength = 0;
  let bodyTooLarge = false;
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk);
    byteLength += bytes.length;
    if (byteLength > EDGE_TTS_HTTP_BODY_LIMIT_BYTES) {
      // Drain without buffering the remainder so the client receives a
      // structured 413 rather than a transport-level socket failure.
      bodyTooLarge = true;
      continue;
    }
    chunks.push(bytes);
  }
  if (bodyTooLarge) throw new EdgeTTSServiceError("Edge TTS request body is too large.", 413);
  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new EdgeTTSServiceError("Edge TTS request body must be valid JSON.", 400);
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new EdgeTTSServiceError("Edge TTS request body must be an object.", 400);
  }
  const { input, voice } = payload as Record<string, unknown>;
  if (typeof input !== "string" || typeof voice !== "string") {
    throw new EdgeTTSServiceError("Edge TTS request requires string input and voice fields.", 400);
  }
  return { input, voice };
}

function writeJSON(response: ServerResponse, statusCode: number, payload: unknown): void {
  if (response.writableEnded) return;
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": String(Buffer.byteLength(body)),
    "Cache-Control": "no-store",
  });
  response.end(body);
}

interface ExternalEntryPending {
  resolve: (context: PickyContextPacket) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface PushToTalkControlPending {
  resolve: () => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface DockGroupsPending {
  resolve: (groups: DockGroup[]) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  app: WebSocket;
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

// eslint-disable-next-line complexity -- This exhaustive protocol projection intentionally mirrors every command variant without executing behavior.
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
    case "listPickySettings":
      return { commandId: command.id, type: command.type, caller: command.caller };
    case "getPickySettings":
      return { commandId: command.id, type: command.type, key: command.key, caller: command.caller };
    case "setPickySettings":
      return { commandId: command.id, type: command.type, key: command.key, toggle: command.toggle ? 1 : 0, displayId: command.displayId, caller: command.caller };
    case "completePickySettingsRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, errorCode: command.errorCode, errorChars: command.errorMessage?.length };
    case "completePickleBridgeRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, sessions: command.sessions?.length, sessionId: command.session?.id, delivered: command.delivered === undefined ? undefined : command.delivered ? 1 : 0, errorChars: command.errorMessage?.length };
    case "submitMainFromExternal":
      return { commandId: command.id, type: command.type, textChars: command.text.length, captureContext: command.captureContext ? 1 : 0, cwd: command.cwd };
    case "createPickleFromExternal":
      return { commandId: command.id, type: command.type, titleChars: command.title.length, instructionChars: command.instructions.length, captureContext: command.captureContext ? 1 : 0, cwd: command.cwd };
    case "createPickleFromMain":
      return { commandId: command.id, type: command.type, titleChars: command.title.length, instructionChars: command.instructions.length, cwd: command.cwd, caller: command.caller };
    case "controlPushToTalkFromExternal":
      return { commandId: command.id, type: command.type, action: command.action };
    case "completePushToTalkControlRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, errorChars: command.errorMessage?.length };
    case "completeExternalEntryRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, hasContext: command.context ? 1 : 0, errorChars: command.errorMessage?.length };
    case "completeDockGroupsRequest":
      return { commandId: command.id, type: command.type, requestId: command.requestId, groups: command.groups?.length, errorChars: command.errorMessage?.length };
    case "manageDockGroups":
      return { commandId: command.id, type: command.type, action: command.groupAction, groupId: command.groupId, sessions: command.sessionIds?.length, caller: command.caller };
    case "notifyMainOfPickleCompletion":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, promptChars: command.prompt.length, cwd: command.cwd };
    case "followUp":
    case "steer":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, textChars: command.text.length, contextId: command.context?.id, screenshots: command.context?.screenshots.length };
    case "setNotifyMainOnCompletion":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, enabled: command.enabled ? 1 : 0 };
    case "setSessionArchived":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, archived: command.archived ? 1 : 0 };
    case "setGlobalModelScope":
      return { commandId: command.id, type: command.type, mode: command.mode, patterns: command.patterns?.length, expectedRevision: command.expectedRevision };
    case "deleteSession":
    case "deletePickle":
    case "getPickle":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, caller: command.caller };
    case "controlPickle":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, action: command.pickleAction, textChars: command.text?.length, caller: command.caller };
    case "setPickleArchived":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, archived: command.archived ? 1 : 0, caller: command.caller };
    case "cycleSessionThinkingLevel": case "listSessionRuntimeOptions": case "setSessionModel": case "setSessionThinkingLevel": case "cycleSessionModel":
      return runtimeControlCommandLogFields(command);
    case "clearQueue":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, kind: command.kind };
    case "syncTerminalSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, baselinePiMessageId: command.baselinePiMessageId };
    case "setTerminalSessionTailEnabled":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, enabled: command.enabled ? 1 : 0 };
    case "abort":
    case "getSession":
    case "getSessionProjectionSnapshot":
    case "listSlashCommands":
    case "getAutocompleteCapabilities":
    case "listRewindTargets":
    case "getSessionDiff":
    case "duplicatePickleSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId };
    case "autocompleteQuery":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, generation: command.generation, lines: command.lines.length, draftRevision: command.draftRevision };
    case "autocompleteApply":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, generation: command.generation, lines: command.lines.length, draftRevision: command.draftRevision, itemChars: command.item.value.length };
    case "rewindSession":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, entryId: command.entryId };
    case "answerExtensionUi":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, requestId: command.requestId };
    case "answerMainExtensionUi":
      return { commandId: command.id, type: command.type, requestId: command.requestId };
    case "getPiOAuthStatus":
    case "signInPiOAuth":
      return { commandId: command.id, type: command.type, providerId: command.providerId };
    case "answerPiOAuthPrompt":
      return { commandId: command.id, type: command.type, requestId: command.requestId, promptId: command.promptId, cancelled: command.cancelled ? 1 : 0, valueChars: command.value?.length };
    case "cancelPiOAuth":
      return { commandId: command.id, type: command.type, requestId: command.requestId };
    case "installPackage": case "setupPackage":
    case "removePackage":
    case "updatePackage":
      return { commandId: command.id, type: command.type, sourceChars: command.source.length };
    case "checkPackageUpdates":
      return { commandId: command.id, type: command.type };
    case "setDefaultCwd":
      return { commandId: command.id, type: command.type, cwdChars: command.defaultCwd.length };
    case "setMainAgentModel":
      return { commandId: command.id, type: command.type, modelPatternChars: command.mainAgentModelPattern.length };
    case "setDisabledBuiltinTools":
      return { commandId: command.id, type: command.type, count: command.disabledBuiltinTools.length };
    case "setMainAgentTTSEnabled":
      return { commandId: command.id, type: command.type, enabled: command.enabled ? 1 : 0 };
    case "listSessions":
    case "listPickles":
    case "listDockGroups":
    case "listMainMessages":
    case "listMainAgentModels":
    case "resetMainAgent":
    case "abortMainAgent":
    case "reloadPlugins":
    case "reloadPiAuthentication":
      return { commandId: command.id, type: command.type };
    case "setMainAgentThinkingLevel":
      return { commandId: command.id, type: command.type, mainAgentThinkingLevel: command.mainAgentThinkingLevel };
  }
}

// eslint-disable-next-line complexity -- This exhaustive protocol projection intentionally mirrors every event variant without executing behavior.
function eventLogFields(event: EventEnvelope): Record<string, string | number | undefined> {
  switch (event.type) {
    case "hello": return { eventId: event.id, type: event.type };
    case "quickReply":
      return { eventId: event.id, type: event.type, contextId: event.contextId, textChars: event.text.length, originSource: event.originSource, replyKind: event.replyKind, sessionId: event.sessionId };
    case "mainTurnSettled": return { eventId: event.id, type: event.type, contextId: event.contextId };
    case "mainNarrationChunk":
      return { eventId: event.id, type: event.type, contextId: event.contextId, textChars: event.text.length, originSource: event.originSource, replyKind: event.replyKind, sessionId: event.sessionId };
    case "mainVisualNarrationSegmentPrepared":
      return { eventId: event.id, type: event.type, contextId: event.identity.contextId, turnToken: event.identity.turnToken, ordinal: event.identity.ordinal, visualKind: event.visual.kind };
    case "mainVisualNarrationSegmentSentence":
      return { eventId: event.id, type: event.type, contextId: event.identity.contextId, turnToken: event.identity.turnToken, ordinal: event.identity.ordinal, sentenceIndex: event.index, textChars: event.text.length };
    case "mainVisualNarrationSegmentCommitted":
      return { eventId: event.id, type: event.type, contextId: event.identity.contextId, turnToken: event.identity.turnToken, ordinal: event.identity.ordinal, sentenceCount: event.sentenceCount, textChars: event.text?.length ?? 0 };
    case "mainMessagesSnapshot": return { eventId: event.id, type: event.type, messages: event.messages.length };
    case "mainMessageAppended":
      return { eventId: event.id, type: event.type, role: event.message.role, textChars: event.message.text.length };
    case "mainAgentModelsSnapshot": return { eventId: event.id, type: event.type, models: event.models.length };
    case "sessionRuntimeOptionsSnapshot": return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, models: event.models.length, thinkingLevels: event.thinkingLevels.length };
    case "mainActivityUpdated":
      return { eventId: event.id, type: event.type, kind: event.activity?.kind, tool: event.activity?.toolName, status: event.activity?.status };
    case "mainExtensionUiRequested":
      return { eventId: event.id, type: event.type, sessionId: event.request.sessionId, requestId: event.request.id, method: event.request.method };
    case "mainExtensionUiCancelled":
      return { eventId: event.id, type: event.type, requestId: event.requestId };
    case "piOAuthStatus":
      return { eventId: event.id, type: event.type, requestId: event.requestId, providerId: event.providerId, configured: event.configured ? 1 : 0 };
    case "piOAuthUrlRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, providerId: event.providerId, hasUserCode: event.userCode ? 1 : 0 };
    case "piOAuthPromptRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, providerId: event.providerId, promptId: event.promptId, promptType: event.promptType, options: event.options?.length };
    case "piAuthenticationReloaded":
      return { eventId: event.id, type: event.type, requestId: event.requestId, reloadedHandles: event.reloadedHandleCount };
    case "mainAgentSessionInfoUpdated":
      return { eventId: event.id, type: event.type, hasSessionFile: event.sessionFilePath ? 1 : 0, hasCwd: event.cwd ? 1 : 0 };
    case "sessionSnapshot": return { eventId: event.id, type: event.type, sessions: event.sessions.length };
    case "sessionProjectionTransaction":
    case "sessionProjectionSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, revision: event.revision };
    case "sessionProjectionBootstrapComplete": return { eventId: event.id, type: event.type, epoch: event.epoch, bootstrapId: event.bootstrapId, sessionCount: event.sessionIds.length };
    case "sessionUpdated":
    case "sessionMetaUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.session.id, status: event.session.status };
    case "sessionArchivedAuthoritative":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, archived: event.archived ? 1 : 0 };
    case "sessionResourcesReloaded":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId };
    case "pluginsReloaded":
      return { eventId: event.id, type: event.type, requestId: event.requestId, pickyReloaded: event.pickyReloaded ? 1 : 0, pickleReloadedCount: event.pickleReloadedCount, pickleAbortedCount: event.pickleAbortedCount, pickleDeferredCount: event.pickleDeferredCount };
    case "packageUpdatesAvailable":
      return { eventId: event.id, type: event.type, commandId: event.commandId, sources: event.sources.length };
    case "packageOperationProgress":
      return { eventId: event.id, type: event.type, requestId: event.requestId, operation: event.operation, sourceChars: event.source.length, messageChars: event.message.length };
    case "packageOperationCompleted":
      return { eventId: event.id, type: event.type, requestId: event.requestId, operation: event.operation, sourceChars: event.source.length, ok: event.ok ? 1 : 0, errorChars: event.errorMessage?.length };
    case "sessionLogAppended":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, lineChars: event.line.length };
    case "toolActivityUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, tool: event.tool.name, status: event.tool.status };
    case "sessionTodoStateUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, tasks: event.todoState?.tasks.length ?? 0, seq: event.seq };
    case "sessionSubagentRunsUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, runs: event.runs.length, seq: event.seq };
    case "extensionUiRequest":
      return { eventId: event.id, type: event.type, sessionId: event.request.sessionId, requestId: event.request.id, method: event.request.method };
    case "artifactUpdated":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, artifactId: event.artifact.id, kind: event.artifact.kind };
    case "pointerOverlayRequested":
      return { eventId: event.id, type: event.type, requestId: event.request.id, screenId: event.request.screenId };
    case "annotationOverlayRequested":
      return { eventId: event.id, type: event.type, requestId: event.request.id, screenId: event.request.screenId, mode: event.request.mode, annotations: event.request.annotations.length };
    case "pickleHandoffRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, contextId: event.context.id, titleChars: event.title.length, instructionChars: event.instructions.length, cwd: event.cwd };
    case "pickleBridgeRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, operation: event.operation, sessionId: event.sessionId, textChars: event.text?.length, promptChars: event.prompt?.length, cwd: event.cwd };
    case "externalEntryRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, kind: event.kind, textChars: event.text?.length, titleChars: event.title?.length, instructionChars: event.instructions?.length, cwd: event.cwd };
    case "externalEntryAck":
      return { eventId: event.id, type: event.type, commandId: event.commandId, kind: event.kind, sessionId: event.sessionId, contextId: event.contextId, errorChars: event.errorMessage?.length };
    case "externalEntryAccepted":
      return { eventId: event.id, type: event.type, commandId: event.commandId, kind: event.kind, sessionId: event.sessionId, contextId: event.contextId, group: event.group };
    case "dockGroupsRequested": return { eventId: event.id, type: event.type, requestId: event.requestId };
    case "dockGroupsSnapshot":
      return { eventId: event.id, type: event.type, groups: event.groups.length };
    case "pickySettingsRequested": return { eventId: event.id, type: event.type, requestId: event.requestId, action: event.action, key: event.key, caller: event.caller };
    case "pickySettingsAck": return { eventId: event.id, type: event.type, commandId: event.commandId };
    case "pushToTalkControlRequested":
      return { eventId: event.id, type: event.type, requestId: event.requestId, action: event.action };
    case "pushToTalkControlAck":
      return { eventId: event.id, type: event.type, commandId: event.commandId, action: event.action };
    case "slashCommandsSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, commands: event.commands.length };
    case "autocompleteCapabilitiesSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, generation: event.generation, triggers: event.triggerCharacters.length };
    case "autocompleteSuggestionsSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, generation: event.generation, draftRevision: event.draftRevision, suggestions: event.items.length };
    case "autocompleteCompletionApplied":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, generation: event.generation, draftRevision: event.draftRevision, lines: event.lines.length };
    case "rewindTargetsSnapshot":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, targets: event.targets.length };
    case "sessionDiffResult":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, requestId: event.requestId, view: event.view, isGitRepo: event.isGitRepo ? 1 : 0, files: event.files.length, errorChars: event.errorMessage?.length };
    case "sessionRewound":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, editorTextChars: event.editorText?.length, removedIds: event.removedIds.length };
    case "sessionMessagesImported":
      return { eventId: event.id, type: event.type, sessionId: event.sessionId, messages: event.messages.length, seq: event.seq };
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
    case "ack":
      return { eventId: event.id, type: event.type, commandId: event.commandId };
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
// Keep in sync with `PickyConversationHistoryWindowPolicy.baseTurnCount` in
// Picky/HUD/Conversation/PickyConversationHistoryWindowPolicy.swift: the HUD
// renders "from the 10th-last user_text message onward", so the initial
// snapshot must include at least that window. Otherwise the snapshot lands with
// fewer turns than the next sessionUpdated, and the conversation list visibly
// reflows once the full session arrives.
const SNAPSHOT_VISIBLE_USER_TURN_COUNT = 10;
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

// Snapshot mirrors the HUD's visible window so the initial snapshot and the next
// full `sessionUpdated` render the same set of messages — no layout shift when
// the full session arrives. Per-message bodies are still sent in full so the
// report viewer never shows a truncated copy that lingers between the initial
// sessionSnapshot and the next sessionUpdated/messageReplaced event.
function compactSnapshotMessages(messages: PickyAgentSession["messages"]): PickyAgentSession["messages"] {
  if (!messages || messages.length === 0) return messages;
  const userTurnIndices: number[] = [];
  for (let index = 0; index < messages.length; index += 1) {
    if (messages[index]!.kind === "user_text") userTurnIndices.push(index);
  }
  if (userTurnIndices.length <= SNAPSHOT_VISIBLE_USER_TURN_COUNT) return messages;
  const firstVisibleUserIndex = userTurnIndices[userTurnIndices.length - SNAPSHOT_VISIBLE_USER_TURN_COUNT]!;
  return messages.slice(firstVisibleUserIndex);
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

function protocolSessionMeta(session: PickyAgentSession): PickyAgentSessionMeta {
  const { messages: _, logs: __, tools: ___, ...meta } = session;
  return PickyAgentSessionMetaSchema.parse(meta);
}

function truncateSnapshotLogLine(line: string): string {
  return truncateText(line, SNAPSHOT_LOG_CHAR_LIMIT);
}

type RemoveEnvelope<T> = T extends unknown ? Omit<T, "id" | "protocolVersion" | "timestamp"> : never;
type EventPayload = RemoveEnvelope<EventEnvelope>;
