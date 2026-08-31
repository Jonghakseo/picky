import { randomUUID } from "node:crypto";

import {
  appendLiveBashOutput,
  formatUserBashFailureSystemMessage,
  formatUserBashRunningSystemMessage,
  formatUserBashSystemMessage,
  userBashSummary,
  type UserBashInput,
} from "../domain/user-bash-format.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession, PickyContextPacket } from "../protocol.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

/**
 * Collaborators the user-bash turn needs from the supervisor. Passed as closures so the
 * feature lives outside the `session-supervisor.ts` facade without exposing its private surface.
 */
export interface UserBashDeps {
  session(sessionId: string): PickyAgentSession;
  prepareForUserInput(sessionId: string): Promise<void>;
  hasPendingRuntimeHandle(sessionId: string): boolean;
  handleForUserInput(session: PickyAgentSession, action: string): Promise<RuntimeSessionHandle | undefined>;
  terminalSessionForUserInput(sessionId: string, kind: string): Promise<PickyAgentSession | undefined>;
  appendLog(sessionId: string, line: string): Promise<void>;
  flushPendingAssistantOutput(sessionId: string): Promise<void>;
  upsertSystemMessage(sessionId: string, messageId: string, text: string): Promise<void>;
  recordError(sessionId: string, message: string): Promise<void>;
  patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
  liveUpdateIntervalMs: number;
}

export async function executeUserBash(
  deps: UserBashDeps,
  sessionId: string,
  input: UserBashInput,
  context?: PickyContextPacket,
): Promise<PickyAgentSession> {
  const session = deps.session(sessionId);
  await deps.prepareForUserInput(sessionId);
  const awaitedPendingHandle = deps.hasPendingRuntimeHandle(sessionId);
  const handle = await deps.handleForUserInput(session, "user bash");
  const terminalAfterHandle = awaitedPendingHandle ? await deps.terminalSessionForUserInput(sessionId, "bash") : undefined;
  if (terminalAfterHandle) return terminalAfterHandle;
  const terminalAfterMissingHandle = !handle ? await deps.terminalSessionForUserInput(sessionId, "bash") : undefined;
  if (terminalAfterMissingHandle) return terminalAfterMissingHandle;
  if (!handle?.executeUserBash) {
    const reason = handle ? "Runtime does not support direct bash execution" : "Runtime session is not attached";
    await deps.appendLog(sessionId, `bash rejected: ${reason}`);
    throw new Error(reason);
  }

  const wasRunning = deps.session(sessionId).status === "running";
  const prefix = input.excludeFromContext ? "!!" : "!";
  logAgentd("user bash requested", { sessionId, commandChars: input.command.length, excludeFromContext: input.excludeFromContext, contextId: context?.id });
  await deps.appendLog(sessionId, `${prefix}${input.command}`);
  await deps.flushPendingAssistantOutput(sessionId);
  await deps.patch(sessionId, { status: "running", lastSummary: `Running bash: ${input.command}`, finalAnswer: undefined, thinkingPreview: undefined });

  const liveMessageId = `msg-user-bash-${randomUUID()}`;
  const liveStartedAt = Date.now();
  let liveOutput = "";
  let lastLiveMessageText = "";
  let livePublishChain = Promise.resolve();
  const publishLiveMessage = (text: string): Promise<void> => {
    if (text === lastLiveMessageText) return livePublishChain;
    lastLiveMessageText = text;
    livePublishChain = livePublishChain.then(() => deps.upsertSystemMessage(sessionId, liveMessageId, text));
    return livePublishChain;
  };
  const publishRunningMessage = (): Promise<void> => publishLiveMessage(formatUserBashRunningSystemMessage(input, liveOutput, Date.now() - liveStartedAt));
  const liveTimer = setInterval(() => { void publishRunningMessage(); }, Math.max(1, deps.liveUpdateIntervalMs));

  try {
    await publishRunningMessage();
    const result = await handle.executeUserBash(input.command, {
      excludeFromContext: input.excludeFromContext,
      onOutputChunk: (chunk) => { liveOutput = appendLiveBashOutput(liveOutput, chunk); },
    });
    clearInterval(liveTimer);
    const afterExecution = deps.session(sessionId);
    if (["cancelled", "failed"].includes(afterExecution.status)) {
      await livePublishChain;
      return afterExecution;
    }
    await publishLiveMessage(formatUserBashSystemMessage(input, result));
    await livePublishChain;
    const summary = userBashSummary(input.command, result);
    await deps.patch(sessionId, wasRunning ? { lastSummary: summary, thinkingPreview: undefined } : { status: "completed", lastSummary: summary, thinkingPreview: undefined });
    return deps.session(sessionId);
  } catch (error) {
    clearInterval(liveTimer);
    const afterFailure = deps.session(sessionId);
    if (["cancelled", "failed"].includes(afterFailure.status)) {
      await livePublishChain;
      return afterFailure;
    }
    const message = error instanceof Error ? error.message : String(error);
    await publishLiveMessage(formatUserBashFailureSystemMessage(input, message, liveOutput));
    await livePublishChain;
    await deps.appendLog(sessionId, `bash failed: ${message}`);
    await deps.recordError(sessionId, `Bash failed: ${message}`);
    await deps.patch(sessionId, wasRunning ? { lastSummary: `Bash failed: ${message}`, thinkingPreview: undefined } : { status: "failed", lastSummary: `Bash failed: ${message}`, thinkingPreview: undefined });
    throw error;
  }
}
