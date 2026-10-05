/**
 * Where a `RemoteCommand` goes (docs/remote-pwa-implementation.md 2.7).
 *
 * Session control is a thin wrapper around one daemon command, exactly the one
 * the HUD sends, so the phone and the Mac drive a session through the same
 * path. Only actions the app owns (Pickle creation, the main conversation,
 * unread, archive) become hub requests.
 *
 * Pure: the text is already built (uploads resolved) by the caller.
 */
import type { HubRequest } from "../remote/hub-protocol.js";
import type { RemoteCommand } from "../remote/protocol.js";
import type { DaemonCommand } from "./daemon-link.js";

export type CommandPlan =
  | { target: "daemon"; sessionId: string; command: DaemonCommand }
  | { target: "hub"; request: HubRequest }
  /** Two steps: the hub creates the Pickle, then the owning daemon gets the text. */
  | { target: "pickleCreate"; cwd: string; text?: string };

export interface CommandPlanInput {
  command: RemoteCommand;
  /** Draft plus attachment paths, already merged by `submissionTextWithAttachments`. */
  text?: string;
}

type PlannerFor<Type extends RemoteCommand["type"]> = (
  command: Extract<RemoteCommand, { type: Type }>,
  text: string | undefined,
) => CommandPlan;

type CommandPlanners = { [Type in RemoteCommand["type"]]: PlannerFor<Type> };

/**
 * One entry per `RemoteCommand`. A table rather than a switch so adding a
 * command fails to compile until it is routed somewhere.
 */
const PLANNERS: CommandPlanners = {
  "session.send": (command, text) => daemon(command.sessionId, { type: command.kind, sessionId: command.sessionId, text: text ?? command.text }),
  "session.schedule": (command, text) => daemon(command.sessionId, { type: "scheduleMessage", sessionId: command.sessionId, text: text ?? command.text, delayMs: command.delayMs }),
  "session.abort": (command) => daemon(command.sessionId, { type: "abort", sessionId: command.sessionId, scope: command.scope }),
  "session.answer": (command) => daemon(command.sessionId, { type: "answerExtensionUi", sessionId: command.sessionId, requestId: command.requestId, value: command.value }),
  "session.queue.remove": (command) => daemon(command.sessionId, { type: "removeQueuedInput", sessionId: command.sessionId, itemId: command.itemId }),
  "session.queue.edit": (command) => daemon(command.sessionId, { type: "editQueuedFollowUp", sessionId: command.sessionId, itemId: command.itemId, text: command.text }),
  "session.queue.sendNow": (command) => daemon(command.sessionId, { type: "sendQueuedFollowUpNow", sessionId: command.sessionId, itemId: command.itemId }),
  "session.queue.clear": (command) => daemon(command.sessionId, { type: "clearQueue", sessionId: command.sessionId, kind: command.kind }),
  "session.scheduled.cancel": (command) => daemon(command.sessionId, { type: "cancelScheduledMessage", sessionId: command.sessionId, scheduledId: command.scheduledId }),
  "session.scheduled.sendNow": (command) => daemon(command.sessionId, { type: "sendScheduledMessageNow", sessionId: command.sessionId, scheduledId: command.scheduledId }),
  "session.scheduled.edit": (command) => daemon(command.sessionId, { type: "editScheduledMessage", sessionId: command.sessionId, scheduledId: command.scheduledId, text: command.text }),
  "session.setModel": (command) => daemon(command.sessionId, { type: "setSessionModel", sessionId: command.sessionId, provider: command.provider, modelId: command.modelId }),
  "session.setThinking": (command) => daemon(command.sessionId, { type: "setSessionThinkingLevel", sessionId: command.sessionId, thinkingLevel: command.thinkingLevel }),
  "session.setFast": (command) => daemon(command.sessionId, { type: "setSessionFastMode", sessionId: command.sessionId, enabled: command.enabled }),
  "session.setNotify": (command) => daemon(command.sessionId, {
    type: command.target === "main" ? "setNotifyMainOnCompletion" : "setNotifyMacOSOnCompletion",
    sessionId: command.sessionId,
    enabled: command.enabled,
  }),
  "session.markRead": (command) => ({ target: "hub", request: { type: "session.markRead", sessionId: command.sessionId } }),
  "session.archive": (command) => ({ target: "hub", request: { type: "session.archive", sessionId: command.sessionId, archived: command.archived } }),
  "pickle.create": (command, text) => {
    const prompt = text ?? command.text;
    return { target: "pickleCreate", cwd: command.cwd, ...(prompt ? { text: prompt } : {}) };
  },
  "main.send": (command, text) => ({ target: "hub", request: { type: "main.send", text: text ?? command.text } }),
  "main.abort": () => ({ target: "hub", request: { type: "main.abort" } }),
  "main.answer": (command) => ({ target: "hub", request: { type: "main.answer", requestId: command.requestId, value: command.value } }),
};

export function planCommand({ command, text }: CommandPlanInput): CommandPlan {
  const planner = PLANNERS[command.type] as PlannerFor<RemoteCommand["type"]>;
  return planner(command, text);
}

/** The room a command belongs to, for `macOffline` gating and push suppression. */
export function roomIdForCommand(command: RemoteCommand): string | undefined {
  if ("sessionId" in command) return command.sessionId;
  if (command.type === "main.send" || command.type === "main.abort" || command.type === "main.answer") return "main";
  return undefined;
}

/** Commands whose text the user typed, used for the audit log's length field. */
export function commandText(command: RemoteCommand): string | undefined {
  return "text" in command ? command.text : undefined;
}

function daemon(sessionId: string, command: DaemonCommand): CommandPlan {
  return { target: "daemon", sessionId, command };
}
