/**
 * Running one `RemoteCommand` or `RemoteQuery` (docs/remote-pwa-implementation.md 2.7).
 *
 * Kept behind a small context interface rather than the whole gateway so the
 * mapping, the `macOffline` gate and the Pickle-create two-step can be tested
 * without sockets.
 */
import type { AuditLog } from "./audit.js";
import { HubRequestError } from "./hub-link.js";
import type { HubRequest } from "../remote/hub-protocol.js";
import type { RemoteCommand, RemoteError, RemoteErrorCode, RemoteQuery } from "../remote/protocol.js";
import { planCommand, roomIdForCommand } from "./command-router.js";
import type { DaemonLink } from "./daemon-link.js";
import { summarizeShellCommand } from "./shell-audit.js";
import { bashCommandIn, submissionTextWithAttachments } from "./submission-text.js";

/** How long a new Pickle has to show up in the projection before its first message. */
export const PICKLE_CREATE_SETTLE_MS = 15_000;

export interface CommandContext {
  hubConnected: boolean;
  hubRequest: (deviceId: string, request: HubRequest) => Promise<unknown>;
  ownerFor: (sessionId: string) => DaemonLink | undefined;
  /** The daemon that owns main-conversation state (Tasks, delegation decisions). */
  primaryDaemon: () => DaemonLink | undefined;
  resolveUploads: (uploadIds: readonly string[]) => Promise<string[]>;
  waitForSession: (sessionId: string, timeoutMs: number) => Promise<boolean>;
  audit: AuditLog;
  onMainSend: (deviceId: string) => void;
  /** The main turn ended without a daemon event: aborted, or the submit failed. */
  onMainSettled: () => void;
}

export class RemoteCommandError extends Error {
  constructor(readonly code: RemoteErrorCode, message: string) {
    super(message);
  }

  toRemoteError(): RemoteError {
    return { code: this.code, message: this.message };
  }
}

export async function executeCommand(
  context: CommandContext,
  deviceId: string,
  command: RemoteCommand,
): Promise<unknown> {
  if (!context.hubConnected) throw new RemoteCommandError("macOffline", "Picky on the Mac is not connected.");

  const text = await buildCommandText(context, command);
  recordCommandAudit(context, deviceId, command, text);
  const plan = planCommand({ command, ...(text !== undefined ? { text } : {}) });

  switch (plan.target) {
    case "daemon": {
      const owner = context.ownerFor(plan.sessionId);
      if (!owner) throw new RemoteCommandError("macOffline", "No Picky daemon owns this session right now.");
      await owner.send(plan.command).catch(rethrowAsRemote);
      return undefined;
    }
    case "primaryDaemon": {
      const primary = context.primaryDaemon();
      if (!primary) throw new RemoteCommandError("macOffline", "The primary Picky daemon is not connected.");
      await primary.send(plan.command).catch(rethrowAsRemote);
      return undefined;
    }
    case "hub": {
      if (plan.request.type === "main.send") context.onMainSend(deviceId);
      try {
        const result = await context.hubRequest(deviceId, plan.request);
        if (plan.request.type === "main.abort") context.onMainSettled();
        return result;
      } catch (error) {
        if (plan.request.type === "main.send") context.onMainSettled();
        return rethrowAsRemote(error);
      }
    }
    case "pickleCreate":
      return createPickle(context, deviceId, plan.cwd, plan.text);
  }
}

async function createPickle(
  context: CommandContext,
  deviceId: string,
  cwd: string,
  text: string | undefined,
): Promise<{ sessionId: string }> {
  const data = await context.hubRequest(deviceId, { type: "pickle.create", cwd }).catch(rethrowAsRemote);
  const sessionId = (data as { sessionId?: unknown } | undefined)?.sessionId;
  if (typeof sessionId !== "string" || !sessionId) {
    throw new RemoteCommandError("internal", "The Mac did not return the new Pickle.");
  }
  if (!text) return { sessionId };

  // The child daemon has to exist and project the session before it can accept
  // a message, so the first prompt waits for the projection rather than racing it.
  const ready = await context.waitForSession(sessionId, PICKLE_CREATE_SETTLE_MS);
  if (!ready) throw new RemoteCommandError("timeout", "The new Pickle did not start in time.");
  const owner = context.ownerFor(sessionId);
  if (!owner) throw new RemoteCommandError("macOffline", "No Picky daemon owns the new Pickle.");
  await owner.send({ type: "followUp", sessionId, text }).catch(rethrowAsRemote);
  return { sessionId };
}

async function buildCommandText(context: CommandContext, command: RemoteCommand): Promise<string | undefined> {
  if (!("text" in command) || command.text === undefined) return undefined;
  const uploadIds = "uploadIds" in command ? command.uploadIds ?? [] : [];
  if (uploadIds.length === 0) return command.text;
  const paths = await context.resolveUploads(uploadIds).catch((error: unknown) => {
    throw new RemoteCommandError("notFound", error instanceof Error ? error.message : "Attachment is unavailable.");
  });
  return submissionTextWithAttachments(command.text, paths);
}

function recordCommandAudit(context: CommandContext, deviceId: string, command: RemoteCommand, text: string | undefined): void {
  const shellCommand = text ? bashCommandIn(text) : undefined;
  context.audit.record({
    action: "command",
    deviceId,
    type: command.type,
    ...(roomIdForCommand(command) ? { sessionId: roomIdForCommand(command) } : {}),
    ...(text !== undefined ? { textChars: text.length } : {}),
    ...(shellCommand ? summarizeShellCommand(shellCommand) : {}),
  });
}

export async function executeQuery(context: CommandContext, query: RemoteQuery): Promise<unknown> {
  const owner = context.ownerFor(query.sessionId);
  if (!owner) throw new RemoteCommandError("macOffline", "No Picky daemon owns this session right now.");

  if (query.type === "session.runtimeOptions") {
    const event = await owner.request(
      { type: "listSessionRuntimeOptions", sessionId: query.sessionId },
      (candidate) => candidate.type === "sessionRuntimeOptionsSnapshot" && candidate.sessionId === query.sessionId,
    ).catch(rethrowAsRemote);
    return event;
  }

  if (query.type === "session.slashCommands") {
    const event = await owner.request(
      { type: "listSlashCommands", sessionId: query.sessionId },
      (candidate) => candidate.type === "slashCommandsSnapshot" && candidate.sessionId === query.sessionId,
    ).catch(rethrowAsRemote);
    return { commands: Array.isArray(event.commands) ? event.commands : [] };
  }

  if (query.type === "session.gitSummary") {
    return await owner.request(
      (commandId) => ({ type: "getSessionGitSummary", sessionId: query.sessionId, requestId: commandId }),
      (candidate) => candidate.type === "sessionGitSummaryResult" && candidate.sessionId === query.sessionId,
    ).catch(rethrowAsRemote);
  }

  const event = await owner.request(
    (commandId) => ({ type: "getSessionDiff", sessionId: query.sessionId, view: query.view, requestId: commandId }),
    (candidate) => candidate.type === "sessionDiffResult" && candidate.sessionId === query.sessionId,
  ).catch(rethrowAsRemote);
  return event;
}

function rethrowAsRemote(error: unknown): never {
  if (error instanceof RemoteCommandError) throw error;
  if (error instanceof HubRequestError) throw new RemoteCommandError(remoteCodeForHubError(error.code), error.message);
  const message = error instanceof Error ? error.message : String(error);
  throw new RemoteCommandError(/timed out/i.test(message) ? "timeout" : "rejected", message);
}

function remoteCodeForHubError(code: string): RemoteErrorCode {
  switch (code) {
    case "macOffline":
    case "macUnavailable":
      return "macOffline";
    case "timeout":
      return "timeout";
    case "notFound":
      return "notFound";
    case "invalid":
      return "invalid";
    default:
      return "rejected";
  }
}
