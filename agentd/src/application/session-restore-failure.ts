import { buildUnattachedRuntimeBlock } from "../domain/session-supervisor-projection-policy.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession } from "../protocol.js";

export interface SessionRestoreFailureSink {
  current(id: string): PickyAgentSession | undefined;
  commit(session: PickyAgentSession): Promise<unknown>;
  keepInMemory(session: PickyAgentSession): void;
}

/**
 * A session that cannot be restored at startup must not take the daemon or its neighbours down.
 * Park it as blocked (the same state an unattachable runtime gets) so the dock still shows it and
 * the user can decide what to do. If even persisting the block fails, keep it in memory only.
 */
export async function parkUnrestorableSession(persisted: PickyAgentSession, error: unknown, sink: SessionRestoreFailureSink): Promise<void> {
  logAgentd("session restore failed", { sessionId: persisted.id, error: error instanceof Error ? error.message : String(error) });
  const blocked = buildUnattachedRuntimeBlock(sink.current(persisted.id) ?? persisted, {}, new Date().toISOString(),
    "Session could not be restored after daemon restart; send a follow-up to try again");
  try {
    await sink.commit(blocked);
  } catch (commitError) {
    logAgentd("session restore block not persisted", { sessionId: persisted.id, error: commitError instanceof Error ? commitError.message : String(commitError) });
    sink.keepInMemory(blocked);
  }
}
