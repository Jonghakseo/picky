/**
 * The main agent's Tasks and delegation decisions, trimmed for the phone.
 *
 * The daemon sends the whole snapshot on every change (`mainTasksUpdated`).
 * This module decides what crosses to a paired device: bounded lists, bounded
 * strings, and no instruction history, because the phone's Tasks section only
 * needs to show state, offer the controls the daemon allows, and read a short
 * result. The counts the room list shows are taken from the full snapshot, so
 * trimming never makes work disappear from the home screen.
 */
import type { MainDelegationDecision, MainTask, MainTaskStatus } from "../features/main-tasks/schema.js";
import { REMOTE_LIMITS } from "../remote/constants.js";
import type { RemoteMainDelegation, RemoteMainTask } from "../remote/protocol.js";

/**
 * Statuses that still occupy a worker, so they count as background work on the
 * room list. `stopping` is included: the Task is not gone until the daemon
 * confirms cleanup.
 */
const ACTIVE_STATUSES: ReadonlySet<MainTaskStatus> = new Set(["queued", "evaluating", "running", "waiting", "stopping"]);

export function isActiveMainTask(task: Pick<MainTask, "status">): boolean {
  return ACTIVE_STATUSES.has(task.status);
}

export function activeMainTaskCount(tasks: readonly MainTask[]): number {
  return tasks.filter(isActiveMainTask).length;
}

/** A decision nobody answered yet. The room needs the user the way a question does. */
export function hasPendingMainDecision(decisions: readonly MainDelegationDecision[]): boolean {
  return decisions.some((decision) => decision.state === "pending");
}

export interface RemoteMainTasksView {
  tasks: RemoteMainTask[];
  decisions: RemoteMainDelegation[];
}

export function remoteMainTasksView(
  tasks: readonly MainTask[],
  decisions: readonly MainDelegationDecision[],
): RemoteMainTasksView {
  return {
    tasks: bound(tasks, isActiveMainTask, REMOTE_LIMITS.mainTasks).map(remoteMainTask),
    decisions: bound(decisions, (decision) => decision.state === "pending", REMOTE_LIMITS.mainDecisions).map(remoteDelegation),
  };
}

function remoteMainTask(task: MainTask): RemoteMainTask {
  const instructions = task.instructions.find((line) => line.trim().length > 0);
  return {
    id: task.id,
    title: clamp(task.title, REMOTE_LIMITS.mainTaskTitleChars),
    status: task.status,
    ...(task.cwd ? { cwd: clamp(task.cwd, REMOTE_LIMITS.mainTaskTitleChars) } : {}),
    readonly: task.readonly,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
    canStop: task.canStop,
    canResume: task.canResume,
    ...(instructions ? { instructions: clamp(instructions, REMOTE_LIMITS.mainTaskTextChars) } : {}),
    ...(task.report
      ? {
          report: {
            status: task.report.status,
            summary: clamp(task.report.summary, REMOTE_LIMITS.mainTaskTextChars),
            blockers: task.report.blockers.slice(0, REMOTE_LIMITS.mainTaskListItems).map((line) => clamp(line, REMOTE_LIMITS.mainTaskTextChars)),
          },
        }
      : {}),
    ...(task.error ? { error: clamp(task.error, REMOTE_LIMITS.mainTaskTextChars) } : {}),
    ...(task.handoff?.pickleSessionId ? { handoffSessionId: task.handoff.pickleSessionId } : {}),
  };
}

function remoteDelegation(decision: MainDelegationDecision): RemoteMainDelegation {
  return {
    id: decision.id,
    state: decision.state,
    title: clamp(decision.title, REMOTE_LIMITS.mainTaskTitleChars),
    ...(decision.question ? { question: clamp(decision.question, REMOTE_LIMITS.mainTaskTextChars) } : {}),
    instructions: clamp(decision.instructions, REMOTE_LIMITS.mainTaskTextChars),
    ...(decision.cwd ? { cwd: clamp(decision.cwd, REMOTE_LIMITS.mainTaskTitleChars) } : {}),
    createdAt: decision.createdAt,
    updatedAt: decision.updatedAt,
    ...(decision.taskId ? { taskId: decision.taskId } : {}),
    ...(decision.pickle
      ? {
          pickle: {
            state: decision.pickle.state,
            ...(decision.pickle.sessionId ? { sessionId: decision.pickle.sessionId } : {}),
            ...(decision.pickle.error ? { error: clamp(decision.pickle.error, REMOTE_LIMITS.mainTaskTextChars) } : {}),
          },
        }
      : {}),
  };
}

/**
 * At most `limit` entries, keeping everything the user can still act on plus
 * the most recently updated of the rest, in the daemon's own order. Dropping
 * the tail instead would hide a running Task behind old finished ones.
 */
function bound<Item extends { updatedAt: string }>(
  items: readonly Item[],
  keep: (item: Item) => boolean,
  limit: number,
): Item[] {
  if (items.length <= limit) return [...items];
  const kept = new Set(items.filter(keep).slice(0, limit));
  const rest = items
    .filter((item) => !kept.has(item))
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
    .slice(0, Math.max(0, limit - kept.size));
  for (const item of rest) kept.add(item);
  return items.filter((item) => kept.has(item));
}

function clamp(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}
