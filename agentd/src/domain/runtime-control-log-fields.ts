import type { parseCommand } from "../protocol.js";

/** Pure protocol projection: runtime-control commands to their structured log fields. */
type RuntimeControlCommand = Extract<ReturnType<typeof parseCommand>, {
  type: "cycleSessionThinkingLevel" | "listSessionRuntimeOptions" | "setSessionModel" | "setSessionThinkingLevel" | "cycleSessionModel";
}>;

export function runtimeControlCommandLogFields(command: RuntimeControlCommand): Record<string, string | number | undefined> {
  switch (command.type) {
    case "cycleSessionThinkingLevel":
    case "listSessionRuntimeOptions":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId };
    case "setSessionModel":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, provider: command.provider, modelId: command.modelId };
    case "setSessionThinkingLevel":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, thinkingLevel: command.thinkingLevel };
    case "cycleSessionModel":
      return { commandId: command.id, type: command.type, sessionId: command.sessionId, direction: command.direction };
  }
}
