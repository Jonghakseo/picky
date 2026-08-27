import type { PickyAgentSession, PickySessionProjectionMutation } from "../protocol.js";
import { buildSessionProjectionMutations } from "../domain/terminal-session-finalization.js";

export interface SessionCommit {
  readonly before?: PickyAgentSession;
  readonly after: PickyAgentSession;
  readonly changed: boolean;
}

interface SessionProjectionCommitEmitter {
  emit(
    ...event:
      | [
        "sessionProjectionTransaction",
        sessionId: string,
        before: PickyAgentSession,
        after: PickyAgentSession,
        mutations: readonly PickySessionProjectionMutation[],
        epoch: string,
      ]
      | ["sessionProjectionSnapshot", session: PickyAgentSession, epoch: string]
  ): unknown;
}

/** Publishes the v2 projection event that corresponds to one successful durable commit. */
export function publishSessionProjectionCommit(
  emitter: SessionProjectionCommitEmitter,
  before: PickyAgentSession | undefined,
  after: PickyAgentSession,
  options: { forceCollectionReplacements?: boolean },
  epoch: string,
): void {
  if (!before) {
    emitter.emit("sessionProjectionSnapshot", after, epoch);
    return;
  }

  const mutations = buildSessionProjectionMutations(before, after, options);
  if (mutations.length === 0) return;
  emitter.emit("sessionProjectionTransaction", after.id, before, after, mutations, epoch);
}
