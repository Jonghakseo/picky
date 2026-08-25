export type SocketDialect = "negotiating" | "v1" | "v2";

const LEGACY_SESSION_PROJECTION_COMMANDS = new Set([
  "routeTask", "createTask", "createEmptyPickleSession", "createPickleFromHandoff", "submitMainFromExternal", "createPickleFromExternal", "createPickleFromMain",
  "duplicatePickleSession", "pinPickleSession", "setNotifyMainOnCompletion", "setSessionArchived", "deleteSession",
  "cycleSessionThinkingLevel", "cycleSessionModel", "clearQueue", "syncTerminalSession", "setTerminalSessionTailEnabled",
  "followUp", "steer", "abort", "answerExtensionUi", "rewindSession", "getSession", "listSessions",
  "listPickles", "getPickle", "controlPickle", "setPickleArchived", "deletePickle",
]);

// V2 sockets must never receive legacy sequence-based session state. Non-session
// controls remain available during negotiation and are intentionally excluded.
const LEGACY_SESSION_PROJECTION_EVENT_TYPES = new Set([
  "sessionSnapshot", "sessionUpdated", "sessionMetaUpdated", "sessionArchivedAuthoritative", "sessionResourcesReloaded",
  "sessionLogAppended", "extensionUiRequest", "toolActivityUpdated", "sessionTodoStateUpdated",
  "sessionSubagentRunsUpdated", "sessionQueueUpdated", "sessionActivityUpdated", "sessionMessageAppended",
  "sessionMessagesImported", "sessionMessageReplaced", "sessionMessageRemoved",
  "artifactUpdated", "terminalSessionSyncOutcome",
]);

export function isLegacySessionProjectionCommand(type: string): boolean {
  return LEGACY_SESSION_PROJECTION_COMMANDS.has(type);
}

const V2_SESSION_PROJECTION_EVENT_TYPES = new Set([
  "sessionProjectionSnapshot", "sessionProjectionTransaction",
]);

export function isLegacySessionProjectionEventType(type: string): boolean {
  return LEGACY_SESSION_PROJECTION_EVENT_TYPES.has(type);
}

export function isV2SessionProjectionEventType(type: string): boolean {
  return V2_SESSION_PROJECTION_EVENT_TYPES.has(type);
}

/**
 * Tracks the projection dialect selected by each connection. A socket begins in
 * `negotiating` and can lock exactly once; attempting to select the other
 * dialect is a protocol error rather than a mixed-dialect fallback.
 */
export class SocketDialectRegistry {
  private dialects = new WeakMap<object, SocketDialect>();

  get(socket: object): SocketDialect {
    return this.dialects.get(socket) ?? "negotiating";
  }

  lockFromCapabilities(socket: object, capabilities: readonly string[]): SocketDialect {
    return this.lock(socket, capabilities.includes("sessionProjectionV2") ? "v2" : "v1");
  }

  lockLegacyProjection(socket: object): SocketDialect {
    return this.lock(socket, "v1");
  }

  lockLegacyProjectionCommand(socket: object, commandType: string): SocketDialect {
    if (!isLegacySessionProjectionCommand(commandType) || this.get(socket) !== "negotiating") return this.get(socket);
    return this.lockLegacyProjection(socket);
  }

  private lock(socket: object, requested: Exclude<SocketDialect, "negotiating">): SocketDialect {
    const current = this.get(socket);
    if (current !== "negotiating" && current !== requested) {
      throw new Error(`Socket dialect is locked to ${current}; cannot change to ${requested}`);
    }
    this.dialects.set(socket, requested);
    return requested;
  }
}
