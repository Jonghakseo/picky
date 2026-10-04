import { summaryFromFinalAnswer } from "./session-summary.js";
import type { PickyAgentSession } from "../protocol.js";
import type { AsyncTask, AsyncWorkSummary } from "./async-task-contract.js";

type Episode = NonNullable<AsyncWorkSummary["episode"]>;
export interface AsyncWorkObservation {
  tracking: AsyncWorkSummary["tracking"];
  runtimeBusy: boolean;
  queuedInput: boolean;
  runtimeInstanceId?: string;
}

/** Pure whole-work policy. Response finalization and persistence remain owner effects. */
export function aggregateAsyncWork(before: PickyAgentSession, proposed: PickyAgentSession, observation: AsyncWorkObservation): PickyAgentSession {
  let episode = episodeForCycle(proposed);
  const counts = rootCounts(proposed, observation);
  const pending = (proposed.completionTickets ?? []).filter((ticket) => !["handled", "suppressed"].includes(ticket.state));
  const failedDeliveryCount = pending.filter((ticket) => ["failed", "unknown"].includes(ticket.state)).length;
  const controls = controlObligations(proposed);
  const executionPending = hasUnfinishedWork(proposed, observation, counts.activeRootCount, pending.length);
  const unfinished = hasUnfinishedWork(proposed, observation, counts.activeRootCount, pending.length, controls.pending);
  const reason = attentionReason(counts.uncertainExecutionCount, failedDeliveryCount, controls.failures, parentOutcome(proposed, episode), executionPending, observation.tracking);
  const attentionCount = counts.uncertainExecutionCount + failedDeliveryCount + controls.failures + reason.extraCount;
  const quiescent = observation.tracking === "ready" && attentionCount === 0 && !unfinished
    && !proposed.pendingExtensionUiRequest && responseFinalized(proposed, episode);
  // A settled episode is historical until a real new cycle is admitted. Queued/preflight input
  // must not erase that marker and accidentally reuse the previous notification identity.
  if (episode && quiescent && !episode.settled) episode = { ...episode, settled: true };
  const status = aggregateStatus(proposed, attentionCount, executionPending, episode);
  const summary: AsyncWorkSummary = {
    tracking: observation.tracking, ...counts, pendingCompletionCount: pending.length, attentionCount,
    canReleaseRuntime: quiescent, workRevision: before.asyncWorkSummary?.workRevision ?? 0,
    ...(episode ? { episode } : {}),
  };
  if (safetySignature(before) !== safetySignature({ ...proposed, status, asyncWorkSummary: summary })) summary.workRevision++;
  const lastSummary = reason.text ?? summaryAfterRecovery(before, proposed, status);
  if (status === proposed.status && lastSummary === proposed.lastSummary && JSON.stringify(summary) === JSON.stringify(proposed.asyncWorkSummary)) return proposed;
  return { ...proposed, status, lastSummary, asyncWorkSummary: summary };
}

const ATTENTION_SUMMARIES = new Set([
  "Async execution outcome unknown",
  "Async result delivery needs recovery",
  "Async control needs recovery",
  "Agent failed with unfinished work",
  "Async tracking unsupported",
]);

/**
 * A failed response stays the parent's verdict only until a newer response cycle exists;
 * that cycle's own finalization replaces the outcome. Until then only its own failure counts.
 */
function parentOutcome(session: PickyAgentSession, episode: Episode | undefined): Episode["outcome"] {
  const cycle = session.agentCycle;
  const superseded = episode?.outcome === "failed" && !!cycle && cycle.cycleId !== episode.finalizedCycleId
    && cycle.outcome !== "failed";
  return superseded ? undefined : episode?.outcome;
}

function summaryAfterRecovery(before: PickyAgentSession, proposed: PickyAgentSession, status: PickyAgentSession["status"]): string | undefined {
  if (before.status !== "blocked" || status === "blocked") return proposed.lastSummary;
  if (proposed.finalAnswer) return summaryFromFinalAnswer(proposed.finalAnswer);
  // The attention reason no longer holds; do not keep presenting it as the current summary.
  return proposed.lastSummary && ATTENTION_SUMMARIES.has(proposed.lastSummary) ? undefined : proposed.lastSummary;
}

function hasUnfinishedWork(session: PickyAgentSession, observation: AsyncWorkObservation, activeRoots: number, pendingTickets: number, pendingControl = false): boolean {
  return activeRoots > 0 || pendingTickets > 0 || pendingControl || observation.runtimeBusy || observation.queuedInput
    || session.agentCycle?.phase === "responding" || session.agentCycle?.phase === "compacting";
}

export function shouldIgnoreAsyncCycleTerminal(session: PickyAgentSession, cycleId: string | undefined): boolean {
  if (!session.asyncWorkSummary || cycleId === undefined) return false;
  return session.agentCycle?.cycleId !== cycleId || session.asyncWorkSummary.episode?.finalizedCycleId === cycleId;
}

function episodeForCycle(session: PickyAgentSession): Episode | undefined {
  const episode = session.asyncWorkSummary?.episode;
  const cycle = session.agentCycle;
  if (cycle?.phase === "responding" && (!episode || episode.settled && cycle.cycleId !== episode.finalizedCycleId)) return { id: cycle.cycleId, settled: false };
  return episode;
}

function rootCounts(session: PickyAgentSession, observation: AsyncWorkObservation): Pick<AsyncWorkSummary, "activeRootCount" | "uncertainExecutionCount"> {
  const roots = new Map<string, { active: boolean; uncertain: boolean }>();
  for (const task of session.asyncTasks ?? []) {
    const key = JSON.stringify([task.runtimeInstanceId, task.providerId, task.providerInstanceId, task.rootTaskId]);
    const root = roots.get(key) ?? { active: false, uncertain: false };
    root.active ||= asyncExecutionIsActive(task);
    // A durable grant is unknown until the ready provider reports its start.
    // It is pending only while this same live owner can still complete registration.
    const pendingGrant = observation.tracking === "ready" && task.runtimeInstanceId === observation.runtimeInstanceId
      && task.registration === "approved" && task.execution === "queued";
    root.uncertain ||= task.presence === "unknown" && !pendingGrant;
    roots.set(key, root);
  }
  return { activeRootCount: [...roots.values()].filter((root) => root.active).length,
    uncertainExecutionCount: [...roots.values()].filter((root) => root.uncertain).length };
}

function controlObligations(session: PickyAgentSession): { pending: boolean; failures: number } {
  const control = session.asyncControl;
  return { pending: control?.admissionState === "closing" || control?.operations.some((operation) => operation.outcome === "accepted" && !asyncOperationResolved(session, operation.operationId)) === true,
    failures: control?.operations.filter((operation) => ["blocked_delivery", "blocked_cleanup"].includes(operation.outcome) && !asyncOperationResolved(session, operation.operationId)).length ?? 0 };
}

function attentionReason(uncertain: number, failedDelivery: number, failedControl: number, outcome: Episode["outcome"], unfinished: boolean, tracking: AsyncWorkSummary["tracking"]): { text?: string; extraCount: number } {
  const parentFailure = outcome === "failed" && unfinished;
  const extraCount = Number(parentFailure) + Number(tracking === "unsupported");
  if (uncertain) return { text: "Async execution outcome unknown", extraCount };
  if (failedDelivery) return { text: "Async result delivery needs recovery", extraCount };
  if (failedControl) return { text: "Async control needs recovery", extraCount };
  if (parentFailure) return { text: "Agent failed with unfinished work", extraCount };
  if (tracking === "unsupported") return { text: "Async tracking unsupported", extraCount };
  return { extraCount };
}

function responseFinalized(session: PickyAgentSession, episode: Episode | undefined): boolean {
  if (!session.agentCycle) return true;
  if (!episode && session.agentCycle.phase === "idle") return true;
  return episode?.finalizedCycleId === session.agentCycle.cycleId;
}

function aggregateStatus(session: PickyAgentSession, attentionCount: number, executionPending: boolean, episode: Episode | undefined): PickyAgentSession["status"] {
  if (attentionCount) return "blocked";
  if (session.pendingExtensionUiRequest) return "waiting_for_input";
  if (executionPending || !responseFinalized(session, episode)) return "running";
  // Provider negotiation and control-only admission closure fence release, not a new turn.
  return episode?.outcome ?? (!session.agentCycle && session.status === "running" ? "waiting_for_input" : session.status);
}

/** Progress, output, timestamps and provider sequence numbers are not archive/release permissions. */
function safetySignature(session: PickyAgentSession): string {
  const summary = session.asyncWorkSummary;
  return JSON.stringify({
    summary: summary ? { ...summary, workRevision: undefined } : undefined,
    cycle: session.agentCycle,
    status: session.status,
    question: session.pendingExtensionUiRequest?.id,
    queue: [...(session.queuedSteers ?? []), ...(session.queuedFollowUps ?? [])],
    control: session.asyncControl,
    tasks: session.asyncTasks?.map((task) => [task.runtimeInstanceId, task.providerId, task.providerInstanceId, task.taskId, task.rootTaskId, task.registration, task.execution, task.presence, task.controlGeneration]),
    tickets: session.completionTickets?.map((ticket) => [ticket.runtimeInstanceId, ticket.providerId, ticket.providerInstanceId, ticket.completionId, ticket.state, ticket.controlGeneration, ticket.cycleId]),
  });
}

export function asyncExecutionIsActive(task: AsyncTask): boolean {
  return task.presence === "active" || ["queued", "running", "cancelling"].includes(task.execution) && task.registration !== "abandoned"
    || ["reserved", "approved"].includes(task.registration) || task.registration === "starting" && task.presence !== "settled";
}
export function hasAsyncExecutionObligations(tasks: readonly AsyncTask[]): boolean {
  return tasks.some((task) => asyncExecutionIsActive(task) || task.presence === "unknown");
}
/**
 * Work a previous runtime left unsettled. Runtime instance IDs never repeat, so no live
 * provider can stop or settle it; only a late settlement may still arrive. It must not
 * fence explicit user input forever, but it still withholds release and deletion approval.
 */
export function isPreviousOwnerAsyncTask(task: AsyncTask, currentRuntimeInstanceId: string): boolean {
  return task.runtimeInstanceId !== currentRuntimeInstanceId && (asyncExecutionIsActive(task) || task.presence === "unknown");
}
export function asyncOperationResolved(session: PickyAgentSession, operationId: string): boolean {
  const record = session.asyncControlJournal?.find((entry) => entry.result.operationId === operationId);
  return !!record?.resolvedBy && session.asyncControlJournal?.some((entry) => entry.result.operationId === record.resolvedBy && entry.result.outcome === "settled") === true;
}
export function isAsyncTracked(session: PickyAgentSession): boolean {
  return [session.asyncControl, session.asyncTasks, session.completionTickets, session.asyncWorkSummary, session.agentCycle, session.asyncControlJournal].some((value) => value !== undefined);
}
