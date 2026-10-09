import type { MainDelegationDecision, MainTask, MainTasksSnapshot } from "../features/main-tasks/schema.js";
import type { TaskRecord, TaskStatus } from "./task-record.js";

/**
 * Pure rules for the main agent's Tasks and Pickle delegation decisions: what the app sees, what
 * the main model is told when a Task finishes, and what a Pickle receives on a handoff.
 */

export type DelegationState = MainDelegationDecision["state"];
export type DelegationChoice = "pickle" | "task" | "cancel";

export interface DelegationDecisionRecord {
  id: string;
  state: DelegationState;
  title: string;
  instructions: string;
  cwd?: string;
  question?: string;
  /** The request that led to the question; reference data for the Pickle or Task that follows. */
  origin?: { contextId?: string; source?: string; text?: string };
  createdAt: string;
  updatedAt: string;
  fromTaskId?: string;
  taskId?: string;
  pickle?: { state: "creating" | "created" | "failed"; sessionId?: string; error?: string };
}

/**
 * Provisional limit carried over from the original extension's default. The product values for
 * concurrency and budgets are open (docs/picky-task-routing-plan.md section 12); change them there first.
 */
export const MAIN_TASK_MAX_CONCURRENCY = 4;

const ACTIVE: ReadonlySet<TaskStatus> = new Set(["queued", "evaluating", "running", "waiting"]);
const RESUMABLE: ReadonlySet<TaskStatus> = new Set(["failed", "blocked", "cancelled", "interrupted"]);
const MAX_FINISHED_TASKS = 30;
const MAX_RESOLVED_DECISIONS = 10;
const TEXT_LIMIT = 4_000;
const SUMMARY_LIMIT = 8_000;
const LIST_LIMIT = 50;

export const isActiveTaskStatus = (status: TaskStatus): boolean => ACTIVE.has(status);

const clip = (text: string, limit = TEXT_LIMIT): string => (text.length <= limit ? text : `${text.slice(0, limit - 1)}…`);
const clipList = (items: readonly string[]): string[] => items.slice(0, LIST_LIMIT).map((item) => clip(item));

export function canStopTask(record: Pick<TaskRecord, "status">): boolean {
  return ACTIVE.has(record.status);
}

/** A Task that a Pickle took over is finished from the Task's side; resuming it would duplicate the work. */
export function canResumeTask(record: Pick<TaskRecord, "status" | "handoff">): boolean {
  return RESUMABLE.has(record.status) && !record.handoff?.pickleSessionId;
}

export function projectMainTask(record: TaskRecord): MainTask {
  return {
    id: record.id,
    revision: record.revision,
    title: clip(record.title, 200),
    status: record.status,
    cwd: record.cwd,
    readonly: record.readonly,
    instructions: record.instructions.length ? record.instructions.map((text) => clip(text)) : [""],
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    ...(record.revisionStartedAt ? { revisionStartedAt: record.revisionStartedAt } : {}),
    ...(record.tier ? { tier: record.tier } : {}),
    ...(record.selection ? { selection: { provider: record.selection.provider, model: record.selection.model, thinking: record.selection.thinking } } : {}),
    ...(record.report ? {
      report: {
        status: record.report.status,
        summary: clip(record.report.summary, SUMMARY_LIMIT),
        artifacts: clipList(record.report.artifacts),
        verification: clipList(record.report.verification),
        blockers: clipList(record.report.blockers),
        ...(record.report.escalation ? { escalation: record.report.escalation } : {}),
      },
    } : {}),
    ...(record.error ? { error: clip(record.error) } : {}),
    ...(record.cleanup ? { cleanup: record.cleanup } : {}),
    ...(record.decisionId ? { decisionId: record.decisionId } : {}),
    ...(record.handoff ? { handoff: { ...record.handoff } } : {}),
    canStop: canStopTask(record),
    canResume: canResumeTask(record),
  };
}

export function projectDelegationDecision(record: DelegationDecisionRecord): MainDelegationDecision {
  return {
    id: record.id,
    state: record.state,
    title: clip(record.title, 200),
    instructions: clip(record.instructions, SUMMARY_LIMIT),
    ...(record.cwd ? { cwd: record.cwd } : {}),
    ...(record.question ? { question: clip(record.question, 1_000) } : {}),
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    ...(record.fromTaskId ? { fromTaskId: record.fromTaskId } : {}),
    ...(record.taskId ? { taskId: record.taskId } : {}),
    ...(record.pickle ? { pickle: { ...record.pickle, ...(record.pickle.error ? { error: clip(record.pickle.error, 1_000) } : {}) } } : {}),
  };
}

const newestFirst = <T extends { updatedAt: string }>(left: T, right: T): number => right.updatedAt.localeCompare(left.updatedAt);

/** Everything still running or waiting on the user, then the most recent history. */
export function projectMainTasksSnapshot(tasks: readonly TaskRecord[], decisions: readonly DelegationDecisionRecord[]): MainTasksSnapshot {
  const sortedTasks = [...tasks].sort(newestFirst);
  const live = sortedTasks.filter((task) => ACTIVE.has(task.status) || task.status === "stopping");
  const finished = sortedTasks.filter((task) => !live.includes(task)).slice(0, MAX_FINISHED_TASKS);
  const sortedDecisions = [...decisions].sort(newestFirst);
  const open = sortedDecisions.filter((decision) => isOpenDecision(decision));
  const resolved = sortedDecisions.filter((decision) => !open.includes(decision)).slice(0, MAX_RESOLVED_DECISIONS);
  // While the user is asked whether a Task's work goes to a Pickle, the question's answers are the
  // way forward. A plain resume would rerun the worker without that choice and stop at the same place.
  const askingTaskIds = new Set(open.flatMap((decision) => (decision.fromTaskId ? [decision.fromTaskId] : [])));
  return {
    tasks: [...live, ...finished].map((task) => {
      const projected = projectMainTask(task);
      return askingTaskIds.has(task.id) ? { ...projected, canResume: false } : projected;
    }),
    decisions: [...open, ...resolved].map(projectDelegationDecision),
  };
}

/** A decision the user still has to act on: never answered, or a Pickle creation that failed. */
export function isOpenDecision(decision: Pick<DelegationDecisionRecord, "state" | "pickle">): boolean {
  return decision.state === "pending" || (decision.state === "pickle" && decision.pickle?.state === "failed");
}

/** Whether a choice can still change this decision. Repeating an executed choice is a no-op, not a second run. */
export function delegationChoiceOutcome(
  decision: Pick<DelegationDecisionRecord, "state" | "pickle" | "taskId">,
  choice: DelegationChoice,
): "apply" | "already" | "rejected" {
  if (decision.state === "pending") return "apply";
  if (decision.state === "cancelled") return choice === "cancel" ? "already" : "rejected";
  if (decision.state === "task") return choice === "task" && decision.taskId ? "already" : "rejected";
  // state === "pickle"
  if (decision.pickle?.state === "failed") return "apply";
  return choice === "pickle" ? "already" : "rejected";
}

const bulletList = (title: string, items: readonly string[], empty?: string): string[] =>
  items.length ? [`${title}:`, ...items.map((item) => `- ${item}`)] : empty ? [`${title}: ${empty}`] : [];

/**
 * The internal message that tells the main model a Task finished. It arrives as its own turn, at a
 * moment the user is not mid-conversation, and is phrased so the reply is short.
 */
export function buildTaskCompletionPrompt(record: TaskRecord): string {
  const report = record.report;
  return [
    `[Picky Task result] The Task "${record.title}" (${record.id}, revision ${record.revision}) finished with status ${report?.status ?? record.status}.`,
    ...(record.origin?.text ? [`Original request: ${clip(record.origin.text, 1_000)}`] : []),
    `Summary: ${report ? clip(report.summary, SUMMARY_LIMIT) : record.error ?? "No report."}`,
    ...bulletList("Artifacts", report?.artifacts ?? []),
    ...bulletList("Verification actually run", report?.verification ?? [], "none"),
    ...bulletList("Blockers", report?.blockers ?? []),
    ...completionGuidance(record),
    "Reply to the user in their language in one or two short sentences; the full report stays in the Task details in Picky. Do not start new work unless the user asks.",
  ].join("\n");
}

/**
 * The one-time notice about Tasks that a quit stopped. The main agent was told at creation that a
 * result arrives on its own, so it has to hear that none will; it offers to continue rather than
 * restarting anything, because a resumed revision may repeat writes. Given only titles and IDs,
 * the model listed near-identical Tasks by the codes that told them apart ("ticks2, ticks3"),
 * so each line carries the user's request and the IDs are marked as tool input.
 */
export function buildTaskInterruptionPrompt(records: readonly TaskRecord[]): string {
  return [
    "[Picky Task interrupted] Picky quit while these Tasks were running. They stopped, were not restarted, and no result will arrive for them:",
    ...records.map(interruptedTaskLine),
    "Tell the user in their language, in one or two short sentences, that this work stopped when Picky quit, and offer to continue it. The user hears this after a restart, without the conversation in front of them: describe each piece of work by what it was for, the way they asked for it. If several stopped, say how many and group similar ones; do not list titles or names that differ only by a number or code. Never say Task IDs, revision numbers, or folder paths. Resume a Task with Task action resume and its taskId only after the user asks; do not start or redo anything now.",
  ].join("\n");
}

/** The title the conversation shows and the user's own request, so the work can be named in their words. */
function interruptedTaskLine(record: TaskRecord): string {
  const request = record.origin?.text ? ` The user asked: "${clip(record.origin.text, 300)}".` : "";
  return `- "${clip(record.title, 200)}".${request} (taskId ${record.id}, for Task action resume only)`;
}

/** What the main agent does next for a result that is not a plain success. */
function completionGuidance(record: TaskRecord): string[] {
  const report = record.report;
  if (report?.escalation === "production_code") {
    return [`The worker stopped because finishing needs production-level code work that was not approved for a Task. Tell the user briefly, then call pickle_delegation with action ask and fromTaskId ${record.id}. Do not continue the code work unless the user chooses Task.`];
  }
  if (report?.status === "blocked") return [`The worker needs a decision. Ask the user with ask_user_question, then send the answer with Task action revise and taskId ${record.id}.`];
  if (report?.status === "failed") return ["Do not retry automatically or switch to a stronger model or a Pickle. Tell the user what failed and what they can do next."];
  return [];
}

/**
 * What a new Pickle receives when it takes over. A Task handoff carries what the Task already did,
 * so the Pickle neither repeats nor discards it.
 */
export function buildPickleHandoffInstructions(decision: DelegationDecisionRecord, task?: TaskRecord): string {
  const lines = [decision.instructions.trim()];
  if (decision.origin?.text) lines.push("", `Original request: ${clip(decision.origin.text, 2_000)}`);
  if (task) {
    const report = task.report;
    lines.push(
      "",
      `This continues Picky Task ${task.id} ("${task.title}"), which stopped before production-level code work. Inspect its changes before editing; do not redo finished work.`,
      `Task working folder: ${task.cwd}`,
      ...bulletList("Task instructions so far", task.instructions.map((text) => clip(text, 1_000))),
      ...(report ? [`Task summary: ${clip(report.summary, 4_000)}`] : []),
      ...bulletList("Files and results from the Task", report?.artifacts ?? []),
      ...bulletList("Verification the Task ran", report?.verification ?? [], "none"),
      ...bulletList("What remains", report?.blockers ?? []),
    );
  }
  return lines.join("\n");
}

/** A short display title when the model did not give one. */
export function deriveTaskTitle(title: string | undefined, instruction: string): string {
  const explicit = title?.trim();
  if (explicit) return clip(explicit.replace(/\s+/g, " "), 120);
  const firstLine = instruction.trim().split("\n")[0] ?? "";
  return clip(firstLine.replace(/\s+/g, " "), 80) || "Task";
}
