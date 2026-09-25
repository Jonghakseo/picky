import type { PickyAgentSession, PickySessionProjectionMutation } from "../protocol.js";
import { buildSessionProjectionMutations } from "../domain/terminal-session-finalization.js";
import { nextRevision } from "../domain/session-revision-policy.js";

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

/**
 * `revision` is the client's ordering chain, not a change counter. Transactions
 * carry `baseRevision = before.revision`, so a commit that produces no
 * projection mutation must leave the revision alone: bumping it without
 * emitting anything leaves a hole the client can never close, and its cursor
 * then buffers that session forever.
 *
 * Emitting an empty transaction instead is not an option; clients reject
 * mutation-less transactions, so the gap would survive anyway.
 */
export function projectionCommitRevision(
  beforeRevision: number,
  mutations: readonly PickySessionProjectionMutation[],
): number {
  return nextRevision(beforeRevision, mutations.length > 0);
}

/**
 * Mutations for a commit that has not yet chosen its revision. `proposed` still
 * carries the previous revision, which is fine because `revision` is not part
 * of the projected metadata.
 */
export function sessionProjectionCommitMutations(
  before: PickyAgentSession,
  proposed: PickyAgentSession,
  options: { forceCollectionReplacements?: boolean } = {},
): readonly PickySessionProjectionMutation[] {
  return buildSessionProjectionMutations(before, proposed, options);
}

/** Publishes the v2 projection event that corresponds to one successful durable commit. */
export function publishSessionProjectionCommit(
  emitter: SessionProjectionCommitEmitter,
  before: PickyAgentSession | undefined,
  after: PickyAgentSession,
  mutations: readonly PickySessionProjectionMutation[],
  epoch: string,
): void {
  if (!before) {
    emitter.emit("sessionProjectionSnapshot", after, epoch);
    return;
  }

  if (mutations.length === 0) return;
  emitter.emit("sessionProjectionTransaction", after.id, before, after, mutations, epoch);
}

interface SessionCommitDependencies {
  read(id: string): PickyAgentSession | undefined;
  save(session: PickyAgentSession): Promise<void>;
  set(id: string, session: PickyAgentSession): void;
  runWrite(id: string, work: () => Promise<void>): Promise<void>;
  emitter: SessionProjectionCommitEmitter;
  epoch: string;
  aggregate(before: PickyAgentSession, proposed: PickyAgentSession): PickyAgentSession;
  afterCommit(commit: SessionCommit): Promise<void>;
}

/** Uses the owner's existing serializer. No memory, projection or effect precedes save. */
export async function commitSessionProjection(
  dependencies: SessionCommitDependencies,
  sessionOrId: PickyAgentSession | string,
  build?: (current: PickyAgentSession) => PickyAgentSession,
  options: { forceCollectionReplacements?: boolean } = {},
): Promise<SessionCommit> {
  const sessionId = typeof sessionOrId === "string" ? sessionOrId : sessionOrId.id;
  let result!: SessionCommit;
  await dependencies.runWrite(sessionId, async () => {
    const before = dependencies.read(sessionId);
    if (typeof sessionOrId === "string" && (!before || !build)) throw new Error(`Unknown session: ${sessionId}`);
    const built = typeof sessionOrId === "string" ? build!(before!) : sessionOrId;
    const proposed = before ? dependencies.aggregate(before, built) : built;
    const changed = proposed !== before;
    const mutations = changed && before ? sessionProjectionCommitMutations(before, proposed, options) : [];
    const after = changed && before ? { ...proposed, revision: projectionCommitRevision(before.revision ?? 0, mutations) } : proposed;
    if (changed) {
      await dependencies.save(after);
      dependencies.set(sessionId, after);
      publishSessionProjectionCommit(dependencies.emitter, before, after, mutations, dependencies.epoch);
    }
    result = { before, after, changed };
  });
  await dependencies.afterCommit(result);
  return result;
}
