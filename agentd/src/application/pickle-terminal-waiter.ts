import type { PickyAgentSession } from "../protocol.js";
import { isFinalSessionStatus } from "../domain/session-status.js";

type ProjectionCommitListener = (sessionId: string, before: PickyAgentSession, after: PickyAgentSession) => void;

export interface PickleTerminalWaiterSource {
  get(sessionId: string): PickyAgentSession | undefined;
  on(event: "sessionProjectionTransaction", listener: ProjectionCommitListener): unknown;
  off(event: "sessionProjectionTransaction", listener: ProjectionCommitListener): unknown;
}

export interface PickleTerminalWaiterSocket {
  once(event: "close", listener: () => void): unknown;
  off(event: "close", listener: () => void): unknown;
}

/**
 * Resolves an external `awaitPickleSessionTerminal` request from the
 * supervisor's projection commits, so CLI waiters never depend on the app's
 * session projection wire dialect. Replies immediately for terminal sessions
 * and stops listening when the requesting socket closes.
 */
export function awaitPickleSessionTerminal(
  source: PickleTerminalWaiterSource,
  socket: PickleTerminalWaiterSocket,
  sessionId: string,
  reply: (session: PickyAgentSession) => void,
): void {
  const current = source.get(sessionId);
  if (!current) throw new Error(`Unknown session: ${sessionId}`);
  if (isFinalSessionStatus(current.status)) {
    reply(current);
    return;
  }
  const onCommit: ProjectionCommitListener = (committedSessionId, _before, after) => {
    if (committedSessionId !== sessionId || !isFinalSessionStatus(after.status)) return;
    cleanup();
    reply(after);
  };
  const cleanup = () => {
    source.off("sessionProjectionTransaction", onCommit);
    socket.off("close", cleanup);
  };
  source.on("sessionProjectionTransaction", onCommit);
  socket.once("close", cleanup);
}
