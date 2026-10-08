/**
 * The Picky room's Tasks section: background work that belongs to the main
 * conversation, plus the "hand this to a Pickle?" decisions.
 *
 * Product rules: docs/picky-task-routing-plan.md 3, 6.2 and 9. A decision the
 * user has not answered blocks the work, so it is always on screen; Tasks
 * themselves live behind one summary line because they keep running whether or
 * not anyone is watching. The daemon decides what may be stopped or resumed
 * (`canStop` / `canResume`); the phone only draws what it is told.
 */
import type { RemoteMainDelegation, RemoteMainState, RemoteMainTask } from "../../../../src/remote/protocol";

export type MainTaskTone = "running" | "attention" | "done";

/**
 * `evaluating` (choosing a model) and `waiting` (the worker waits on its own
 * background job, not on the user) read as plain "running": the user has
 * nothing to do in either, matching the Mac.
 */
export const TASK_STATUS_KEY: Record<RemoteMainTask["status"], string> = {
  queued: "remote.room.tasks.status.queued",
  evaluating: "remote.room.tasks.status.running",
  running: "remote.room.tasks.status.running",
  waiting: "remote.room.tasks.status.running",
  stopping: "remote.room.tasks.status.stopping",
  completed: "remote.room.tasks.status.completed",
  failed: "remote.room.tasks.status.failed",
  blocked: "remote.room.tasks.status.blocked",
  cancelled: "remote.room.tasks.status.cancelled",
  interrupted: "remote.room.tasks.status.interrupted",
};

const ACTIVE: ReadonlySet<RemoteMainTask["status"]> = new Set(["queued", "evaluating", "running", "waiting", "stopping"]);
const ATTENTION: ReadonlySet<RemoteMainTask["status"]> = new Set(["failed", "blocked", "interrupted"]);

export function isActiveTask(task: RemoteMainTask): boolean {
  return ACTIVE.has(task.status);
}

export function taskTone(task: RemoteMainTask): MainTaskTone {
  if (ACTIVE.has(task.status)) return "running";
  return ATTENTION.has(task.status) ? "attention" : "done";
}

/** The user still has to answer this one: nothing runs until they do. */
export function decisionNeedsUser(decision: RemoteMainDelegation): boolean {
  return decision.state === "pending";
}

/** Creating the Pickle failed, so the choice the user already made did not happen. */
export function decisionFailed(decision: RemoteMainDelegation): boolean {
  return decision.pickle?.state === "failed";
}

export interface MainTasksModel {
  /** Decisions that are on screen: unanswered ones, and a failed Pickle creation to retry. */
  decisions: RemoteMainDelegation[];
  /** Active Tasks first, then finished ones newest first. */
  tasks: RemoteMainTask[];
  summary: { key: string; count: number };
}

/**
 * Null when the section has nothing to say, so the Picky room looks exactly as
 * it does today until the main agent actually runs something.
 */
export function mainTasksModel(main: RemoteMainState | undefined): MainTasksModel | null {
  if (!main) return null;
  const decisions = main.decisions.filter((decision) => decisionNeedsUser(decision) || decisionFailed(decision));
  const active = main.tasks.filter(isActiveTask);
  const finished = main.tasks
    .filter((task) => !isActiveTask(task))
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  if (decisions.length === 0 && active.length === 0 && finished.length === 0) return null;
  return { decisions, tasks: [...active, ...finished], summary: summaryOf(active, finished) };
}

function summaryOf(active: readonly RemoteMainTask[], finished: readonly RemoteMainTask[]): { key: string; count: number } {
  if (active.length > 0) return { key: "remote.room.tasks.summary.running", count: active.length };
  const resumable = finished.filter((task) => task.canResume).length;
  if (resumable > 0) return { key: "remote.room.tasks.summary.resumable", count: resumable };
  return { key: "remote.room.tasks.summary.finished", count: finished.length };
}

/** Result lines for an expanded Task: what it did, what stopped it, where it went. */
export function taskDetailLines(task: RemoteMainTask): string[] {
  const lines: string[] = [];
  if (task.report?.summary) lines.push(task.report.summary);
  else if (task.instructions) lines.push(task.instructions);
  if (task.error) lines.push(task.error);
  return lines;
}
