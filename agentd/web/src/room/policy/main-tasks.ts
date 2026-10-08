/**
 * The Picky room's Tasks and "hand this to a Pickle?" questions, placed inside
 * the conversation where each one started.
 *
 * Product rules: docs/picky-task-routing-plan.md 3, 6.2 and 9. A question the
 * user has not answered blocks the work, so it stays on screen even when the
 * messages around it have left the transcript; an answered one stays as one
 * line so the conversation keeps what was decided. The daemon decides what may
 * be stopped or resumed (`canStop` / `canResume`); the phone only draws what it
 * is told. The Mac applies the same placement in
 * `Picky/MainAgent/PickyMainTaskPresentation.swift`.
 */
import type { RemoteMainDelegation, RemoteMainMessage, RemoteMainState, RemoteMainTask } from "../../../../src/remote/protocol";
import { parseTimestamp } from "../format";

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

/** Creating the Pickle the user chose; it lasts seconds. */
export function decisionCreatingPickle(decision: RemoteMainDelegation): boolean {
  return decision.state === "pickle" && decision.pickle?.state === "creating";
}

/** Work still holding a worker, or a question the user can still answer or retry, or that is still being carried out. */
function isOpen(block: MainTimelineBlock): boolean {
  if (block.kind === "task") return isActiveTask(block.task);
  return decisionNeedsUser(block.decision) || decisionFailed(block.decision) || decisionCreatingPickle(block.decision);
}

export type MainTimelineBlock =
  | { kind: "task"; key: string; at: number; task: RemoteMainTask }
  | { kind: "decision"; key: string; at: number; decision: RemoteMainDelegation };

export type MainTimelineEntry = { kind: "message"; key: string; message: RemoteMainMessage } | MainTimelineBlock;

/**
 * The main conversation with each Task and question in the turn it started in.
 * Messages keep their order. A block older than the oldest message the phone
 * still holds leaves with those messages unless it is still open, and an empty
 * transcript (a new conversation) shows only open blocks.
 */
export function mainTimeline(main: Pick<RemoteMainState, "messages" | "tasks" | "decisions">): MainTimelineEntry[] {
  const times = main.messages.map((message) => ({ role: message.role, at: parseTimestamp(message.createdAt) ?? 0 }));
  const windowStart = times[0]?.at;
  const blocks: MainTimelineBlock[] = [];
  for (const task of main.tasks) {
    const at = parseTimestamp(task.createdAt);
    if (at !== null) blocks.push({ kind: "task", key: `task-${task.id}`, at, task });
  }
  for (const decision of main.decisions) {
    const at = parseTimestamp(decision.createdAt);
    if (at !== null) blocks.push({ kind: "decision", key: `decision-${decision.id}`, at, decision });
  }
  const kept = blocks
    .filter((block) => (windowStart === undefined ? isOpen(block) : block.at >= windowStart || isOpen(block)))
    .sort((left, right) => left.at - right.at || left.key.localeCompare(right.key));

  const bySlot = new Map<number, MainTimelineBlock[]>();
  for (const block of kept) {
    const slot = timelineSlot(block.at, times);
    bySlot.set(slot, [...(bySlot.get(slot) ?? []), block]);
  }
  const entries: MainTimelineEntry[] = [];
  main.messages.forEach((message, index) => {
    entries.push(...(bySlot.get(index) ?? []));
    entries.push({ kind: "message", key: message.id, message });
  });
  entries.push(...(bySlot.get(main.messages.length) ?? []));
  return entries;
}

/**
 * The index of the message a block that started at `at` goes before, or the
 * message count for the end. The block belongs to the turn it started in: the
 * messages after the last user message sent at or before it, up to the next
 * user message. Inside that turn it follows what Picky said last before it
 * started (a sentence Picky writes before calling a tool is recorded first),
 * or else Picky's first reply after it, the sentence announcing the work. With
 * no reply in the turn it closes the turn. Older than every message, it opens
 * the list.
 */
export function timelineSlot(at: number, messages: readonly { role: RemoteMainMessage["role"]; at: number }[]): number {
  const first = messages[0];
  if (!first || at < first.at) return 0;
  let turnStart = 0;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]!;
    if (message.role === "user" && message.at <= at) {
      turnStart = index + 1;
      break;
    }
  }
  let turnEnd = messages.length;
  for (let index = turnStart; index < messages.length; index += 1) {
    if (messages[index]!.role === "user") {
      turnEnd = index;
      break;
    }
  }
  for (let index = turnEnd - 1; index >= turnStart; index -= 1) {
    if (messages[index]!.at <= at) return index + 1;
  }
  for (let index = turnStart; index < turnEnd; index += 1) {
    if (messages[index]!.at > at) return index + 1;
  }
  return turnEnd;
}

/** The newest question still waiting on the user, for the pinned bar above the composer. */
export function waitingDecision(main: Pick<RemoteMainState, "decisions">): RemoteMainDelegation | undefined {
  let newest: RemoteMainDelegation | undefined;
  for (const decision of main.decisions) {
    if (!decisionNeedsUser(decision)) continue;
    if (!newest || decision.createdAt > newest.createdAt) newest = decision;
  }
  return newest;
}

/** Result lines for an expanded Task: what it did, what stopped it, where it went. */
export function taskDetailLines(task: RemoteMainTask): string[] {
  const lines: string[] = [];
  if (task.report?.summary) lines.push(task.report.summary);
  else if (task.instructions) lines.push(task.instructions);
  if (task.error) lines.push(task.error);
  return lines;
}
