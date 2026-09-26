import { aggregateAsyncWork } from "../domain/async-work-aggregate.js";
import { logAgentd } from "../local-log.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "../runtime/types.js";
import type { SessionCommit } from "./session-projection-commit-publisher.js";
import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeAsyncTaskOwner, RuntimeAsyncTaskState } from "../runtime/async-task-types.js";

/** Reuses the supervisor's save-before-publish boundary. No second registry or write chain. */
export function asyncTaskRuntimeOptions(
  enabled: boolean,
  read: () => PickyAgentSession,
  commit: (build: (session: PickyAgentSession) => PickyAgentSession) => Promise<{ after: PickyAgentSession }>,
  beforeModelRequest?: () => Promise<void>,
): { asyncTaskHost?: RuntimeAsyncTaskOwner } {
  if (!enabled) return {};
  return { asyncTaskHost: {
    beforeModelRequest,
    read: () => stateFromSession(read()),
    async transact(build) {
      const result = await commit((session) => {
        const current = stateFromSession(session);
        const next = build(current);
        if (next === current) return session;
        return { ...session, asyncTasks: next.tasks, completionTickets: next.tickets, asyncControl: next.control, agentCycle: next.cycle };
      });
      return stateFromSession(result.after);
    },
  } };
}
function stateFromSession(session: PickyAgentSession): RuntimeAsyncTaskState {
  return { tasks: session.asyncTasks ?? [], tickets: session.completionTickets ?? [], control: session.asyncControl, cycle: session.agentCycle };
}

export function aggregateAsyncSession(before: PickyAgentSession, proposed: PickyAgentSession, enabled: boolean, handle: RuntimeSessionHandle | undefined, pendingDeliveries: boolean): PickyAgentSession {
  if (!enabled || !proposed.asyncControl) return proposed;
  return aggregateAsyncWork(before, proposed, {
    tracking: handle ? handle.asyncTasks?.coverage().tracking ?? "unsupported" : "reconciling",
    runtimeInstanceId: handle?.asyncTasks?.coverage().runtimeInstanceId,
    runtimeBusy: handle?.isStreaming === true || handle?.isCompacting === true || handle?.hasPendingAsyncWork === true,
    queuedInput: hasQueuedInput(proposed, handle, pendingDeliveries),
  });
}

function hasQueuedInput(session: PickyAgentSession, handle: RuntimeSessionHandle | undefined, pendingDeliveries: boolean): boolean {
  return pendingDeliveries || (session.queuedSteers?.length ?? 0) > 0 || (session.queuedFollowUps?.length ?? 0) > 0
    || (handle?.getSteeringMessages().length ?? 0) > 0 || (handle?.getFollowUpMessages().length ?? 0) > 0;
}

/** Response identity is finalized independently from the whole work episode. */
export function finalizeAsyncCycle(before: PickyAgentSession, proposed: PickyAgentSession, event: Extract<RuntimeEvent, { type: "status" }>): PickyAgentSession {
  if (!before.asyncWorkSummary || !before.agentCycle || event.noTurnRan) return proposed;
  const cycleId = event.cycleId ?? before.agentCycle.cycleId;
  const episode = before.asyncWorkSummary.episode ?? { id: cycleId, settled: false };
  return { ...proposed, pendingExtensionUiRequest: before.pendingExtensionUiRequest,
    asyncWorkSummary: { ...before.asyncWorkSummary, episode: { ...episode, finalizedCycleId: cycleId,
      outcome: event.status === "failed" ? "failed" : event.status === "cancelled" ? "cancelled" : "completed" } } };
}

export async function publishAsyncWorkCompletion(commit: SessionCommit, effects: {
  isPickle(id: string): boolean; clear(id: string): void; emit(session: PickyAgentSession): void;
  notify(id: string, session: PickyAgentSession): Promise<void>;
}): Promise<void> {
  const { before, after } = commit;
  const summary = after.asyncWorkSummary;
  if (!commit.changed || !summary || !effects.isPickle(after.id)) return;
  const previousEpisode = before?.asyncWorkSummary?.episode;
  const episode = summary.episode;
  if (previousEpisode?.id !== episode?.id) effects.clear(after.id);
  if (previousEpisode?.settled === true || episode?.settled !== true) return;
  effects.emit(after);
  if (after.status !== "completed") return;
  try { await effects.notify(after.id, after); }
  catch (error) { logAgentd("Pickle completion notification failed after aggregate commit", { sessionId: after.id, error: error instanceof Error ? error.message : String(error) }); }
}

/** Retry bookkeeping and retained response commits, never model execution or admission reopen. */
export async function retryAsyncWorkPersistence(handle: RuntimeSessionHandle | undefined, drainEvents: () => Promise<void>, retryResponse: () => Promise<void>, reconcile: () => Promise<unknown>): Promise<void> {
  await handle?.asyncTasks?.retryPersistence();
  await drainEvents();
  await retryResponse();
  await reconcile();
}
