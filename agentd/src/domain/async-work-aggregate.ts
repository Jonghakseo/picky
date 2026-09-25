import { summaryFromFinalAnswer } from "./session-summary.js";
import type { PickyAgentSession } from "../protocol.js";
import type { AsyncWorkSummary } from "./async-task-contract.js";

type Episode = NonNullable<AsyncWorkSummary["episode"]>;
export interface AsyncWorkObservation {
  tracking: AsyncWorkSummary["tracking"];
  runtimeBusy: boolean;
  queuedInput: boolean;
}

/** Pure whole-work policy. Response finalization and persistence remain owner effects. */
export function aggregateAsyncWork(before: PickyAgentSession, proposed: PickyAgentSession, observation: AsyncWorkObservation): PickyAgentSession {
  let episode = episodeForCycle(proposed);
  const counts = rootCounts(proposed);
  const pending = (proposed.completionTickets ?? []).filter((ticket) => !["handled", "suppressed"].includes(ticket.state));
  const failedDeliveryCount = pending.filter((ticket) => ["failed", "unknown"].includes(ticket.state)).length;
  const controls = controlObligations(proposed);
  const unfinished = hasUnfinishedWork(proposed, observation, counts.activeRootCount, pending.length, controls.pending);
  const reason = attentionReason(counts.uncertainExecutionCount, failedDeliveryCount, controls.failures, episode?.outcome, unfinished, observation.tracking);
  const attentionCount = counts.uncertainExecutionCount + failedDeliveryCount + controls.failures + reason.extraCount;
  const quiescent = observation.tracking === "ready" && attentionCount === 0 && !unfinished
    && !proposed.pendingExtensionUiRequest && responseFinalized(proposed, episode);
  // A settled episode is historical until a real new cycle is admitted. Queued/preflight input
  // must not erase that marker and accidentally reuse the previous notification identity.
  if (episode && quiescent && !episode.settled) episode = { ...episode, settled: true };
  const status = aggregateStatus(proposed, attentionCount, quiescent, episode);
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

function summaryAfterRecovery(before: PickyAgentSession, proposed: PickyAgentSession, status: PickyAgentSession["status"]): string | undefined {
  if (before.status === "blocked" && status !== "blocked" && proposed.finalAnswer) return summaryFromFinalAnswer(proposed.finalAnswer);
  return proposed.lastSummary;
}

function hasUnfinishedWork(session: PickyAgentSession, observation: AsyncWorkObservation, activeRoots: number, pendingTickets: number, pendingControl: boolean): boolean {
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

function rootCounts(session: PickyAgentSession): Pick<AsyncWorkSummary, "activeRootCount" | "uncertainExecutionCount"> {
  const roots = new Map<string, { active: boolean; uncertain: boolean }>();
  for (const task of session.asyncTasks ?? []) {
    const key = JSON.stringify([task.runtimeInstanceId, task.providerId, task.providerInstanceId, task.rootTaskId]);
    const root = roots.get(key) ?? { active: false, uncertain: false };
    root.active ||= task.presence === "active" || ["queued", "running", "cancelling"].includes(task.execution) && task.registration !== "abandoned"
      || ["reserved", "approved"].includes(task.registration)
      || task.registration === "starting" && task.presence !== "settled";
    root.uncertain ||= task.presence === "unknown";
    roots.set(key, root);
  }
  return { activeRootCount: [...roots.values()].filter((root) => root.active).length,
    uncertainExecutionCount: [...roots.values()].filter((root) => root.uncertain).length };
}

function controlObligations(session: PickyAgentSession): { pending: boolean; failures: number } {
  const control = session.asyncControl;
  return { pending: control?.admissionState === "closing" || control?.operations.some((operation) => operation.outcome === "accepted") === true,
    failures: control?.operations.filter((operation) => ["blocked_delivery", "blocked_cleanup"].includes(operation.outcome)).length ?? 0 };
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

function aggregateStatus(session: PickyAgentSession, attentionCount: number, quiescent: boolean, episode: Episode | undefined): PickyAgentSession["status"] {
  if (attentionCount) return "blocked";
  if (session.pendingExtensionUiRequest) return "waiting_for_input";
  if (!quiescent) return "running";
  return episode?.outcome ?? session.status;
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
