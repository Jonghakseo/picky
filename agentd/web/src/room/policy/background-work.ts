/**
 * The "Background work" footer above the composer.
 *
 * Port of Picky/HUD/Conversation/PickyBackgroundWorkFooterPresentation.swift
 * and the root/member/ticket helpers it uses from
 * PickyAsyncTaskShelfPresentation.swift. The canonical tasks, tickets and
 * summary stay the lifecycle authority; subagent runs only name an agent and
 * supply its timing.
 */
import type { PickyAgentSession, PickySubagentRun } from "../../../../src/protocol";
import type { AsyncTask, AsyncWorkSummary, CompletionTicket } from "../../../../src/domain/async-task-contract";
import { t } from "../i18n";

export type BackgroundWorkState = "running" | "queued" | "stopping" | "completed" | "failed" | "cancelled" | "interrupted" | "unknown";
export type BackgroundWorkResult = "pending" | "processing" | "failed" | "unverified";
export type BackgroundWorkTiming = { kind: "none" } | { kind: "elapsed"; since: number } | { kind: "fixed"; seconds: number };

export interface BackgroundWorkRow {
  id: string;
  title: string;
  state: BackgroundWorkState;
  timing: BackgroundWorkTiming;
}

export interface BackgroundWorkGroup extends BackgroundWorkRow {
  children: BackgroundWorkRow[];
  result?: BackgroundWorkResult;
}

export interface BackgroundWorkFooterModel {
  groups: BackgroundWorkGroup[];
  status: { text: string; state: BackgroundWorkState };
  note?: "detailUnavailable" | "attention";
}

/** Unfinished work is named before finished work, and attention before history. */
const SUMMARY_ORDER: BackgroundWorkState[] = ["running", "queued", "stopping", "completed", "failed", "cancelled", "interrupted", "unknown"];
/** When only one state can be named, the one a person still has to act on wins. */
const STATUS_FALLBACK_ORDER: BackgroundWorkState[] = ["stopping", "running", "queued", "unknown", "interrupted", "failed", "cancelled", "completed"];
const SUBAGENT_KINDS = new Set(["subagent", "subagent_group", "subagent-group"]);
const MAXIMUM_REPORTED_SECONDS = 100 * 365 * 24 * 3600;

export const STATE_LABEL_KEY: Record<BackgroundWorkState, string> = {
  running: "hud.asyncTasks.execution.running.short",
  queued: "hud.asyncTasks.execution.queued.short",
  stopping: "hud.asyncTasks.execution.cancelling.short",
  completed: "hud.asyncTasks.execution.succeeded.short",
  failed: "hud.asyncTasks.execution.failed.short",
  cancelled: "hud.asyncTasks.execution.cancelled.short",
  interrupted: "hud.asyncTasks.execution.interrupted.short",
  unknown: "hud.asyncTasks.execution.unknown.short",
};

export const RESULT_LABEL_KEY: Record<BackgroundWorkResult, string> = {
  pending: "hud.asyncTasks.result.pending",
  processing: "hud.asyncTasks.result.processing",
  failed: "hud.asyncTasks.result.failed",
  unverified: "hud.asyncTasks.result.unknown",
};

export const NOTE_KEY = {
  detailUnavailable: "hud.asyncTasks.detailUnavailable",
  attention: "hud.asyncTasks.attentionUnknown",
} as const;

export function isExceptional(state: BackgroundWorkState): boolean {
  return state === "failed" || state === "cancelled" || state === "interrupted" || state === "unknown" || state === "stopping";
}

export function resultNeedsAttention(result: BackgroundWorkResult): boolean {
  return result === "failed" || result === "unverified";
}

/** The invocation itself failed or stopped while its agents report something else. */
export function rootIssue(group: BackgroundWorkGroup): BackgroundWorkState | undefined {
  if (group.children.length === 0 || !isExceptional(group.state)) return undefined;
  return group.children.some((child) => child.state === group.state) ? undefined : group.state;
}

export function groupCounts(group: BackgroundWorkGroup): Array<{ state: BackgroundWorkState; count: number }> {
  return SUMMARY_ORDER.flatMap((state) => {
    const count = group.children.filter((child) => child.state === state).length;
    return count === 0 ? [] : [{ state, count }];
  });
}

/** `mm:ss`, or `h:mm:ss` past an hour. */
export function durationText(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0 || seconds >= MAXIMUM_REPORTED_SECONDS) return "";
  const total = Math.round(seconds);
  const s = total % 60;
  const m = Math.floor(total / 60) % 60;
  const h = Math.floor(total / 3600);
  const pad = (value: number) => String(value).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/**
 * `null` when there is no background work to show. `asyncTasks` missing from
 * the projection means the detail is unavailable, not that there is none.
 */
export function backgroundWorkModel(session: PickyAgentSession | undefined, now: number = Date.now()): BackgroundWorkFooterModel | null {
  const summary = session?.asyncWorkSummary;
  if (!session || !summary) return null;
  if (session.asyncTasks === undefined) {
    const status = canonicalStatus(summary);
    return status ? { groups: [], status, note: "detailUnavailable" } : null;
  }
  const detail: Detail = { tasks: session.asyncTasks, tickets: session.completionTickets ?? [] };
  const runtimeInstanceId = session.agentCycle?.runtimeInstanceId;
  const currentRoots = roots(detail).filter((root) => isCurrent(root, detail));
  const runs = currentRoots.some((root) => SUBAGENT_KINDS.has(root.kind)) ? session.subagentRuns ?? [] : [];
  const groups = currentRoots.map((root) => group(root, detail, runs, summary, runtimeInstanceId, now));
  const note = footerNote(groups, summary);
  const progress = statusFor(groups);
  const canonical = note === "attention" ? canonicalStatus(summary) : undefined;
  const status = merge(canonical, progress) ?? canonicalStatus(summary);
  if (!status) return null;
  return { groups, status, ...(note ? { note } : {}) };
}

interface Detail {
  tasks: readonly AsyncTask[];
  tickets: readonly CompletionTicket[];
}

function ownerKey(task: { sessionId: string; piSessionId: string; runtimeInstanceId: string; providerId: string; providerInstanceId: string }): string {
  return JSON.stringify([task.sessionId, task.piSessionId, task.runtimeInstanceId, task.providerId, task.providerInstanceId]);
}

function identity(task: AsyncTask): string {
  return `${ownerKey(task)}#${task.taskId}`;
}

function members(root: AsyncTask, detail: Detail): AsyncTask[] {
  const owner = ownerKey(root);
  return detail.tasks.filter((task) => ownerKey(task) === owner && task.rootTaskId === root.taskId);
}

function tickets(root: AsyncTask, detail: Detail): CompletionTicket[] {
  const owner = ownerKey(root);
  return detail.tickets.filter((ticket) => ownerKey(ticket) === owner && ticket.rootTaskId === root.taskId);
}

function hasWork(task: AsyncTask): boolean {
  return task.presence !== "settled"
    || task.execution === "queued" || task.execution === "running" || task.execution === "cancelling"
    || task.registration === "reserved" || task.registration === "approved";
}

function hasPendingResult(root: AsyncTask, detail: Detail): boolean {
  return tickets(root, detail).some((ticket) => ticket.state !== "handled" && ticket.state !== "suppressed");
}

/** `PickyAsyncTaskShelfPresentation.roots`: current work first, then newest. */
function roots(detail: Detail): AsyncTask[] {
  const current = (root: AsyncTask) => members(root, detail).some(hasWork) || hasPendingResult(root, detail);
  return detail.tasks
    .filter((task) => task.taskId === task.rootTaskId && task.parentTaskId === undefined)
    .filter((root) => members(root, detail).some((task) => hasWork(task) || task.execution === "failed" || task.execution === "interrupted")
      || hasPendingResult(root, detail))
    .sort((left, right) => {
      const leftCurrent = current(left);
      const rightCurrent = current(right);
      if (leftCurrent !== rightCurrent) return leftCurrent ? -1 : 1;
      return right.createdAt.localeCompare(left.createdAt);
    });
}

/** Settled history must not come back because unrelated work later needed attention. */
function isCurrent(root: AsyncTask, detail: Detail): boolean {
  return members(root, detail).some(hasWork) || hasPendingResult(root, detail);
}

function executionState(task: AsyncTask, summary: AsyncWorkSummary, runtimeInstanceId: string | undefined): BackgroundWorkState {
  // Only a ready, canonically certain grant of this runtime can still register.
  const registering = summary.tracking === "ready" && summary.uncertainExecutionCount === 0
    && (runtimeInstanceId === undefined || runtimeInstanceId === task.runtimeInstanceId)
    && task.execution === "queued" && (task.registration === "reserved" || task.registration === "approved");
  if (task.presence === "unknown" && !registering) return "unknown";
  switch (task.execution) {
    case "running": return "running";
    case "queued": return "queued";
    case "cancelling": return "stopping";
    case "succeeded": return "completed";
    case "failed": return "failed";
    case "cancelled": return "cancelled";
    case "interrupted": return "interrupted";
  }
}

function resultOf(list: readonly CompletionTicket[]): BackgroundWorkResult | undefined {
  if (list.some((ticket) => ticket.state === "failed")) return "failed";
  if (list.some((ticket) => ticket.state === "unknown")) return "unverified";
  if (list.some((ticket) => ticket.state === "processing")) return "processing";
  if (list.some((ticket) => ticket.state === "pending" || ticket.state === "submitted" || ticket.state === "observed")) return "pending";
  return undefined;
}

function group(
  root: AsyncTask,
  detail: Detail,
  runs: readonly PickySubagentRun[],
  summary: AsyncWorkSummary,
  runtimeInstanceId: string | undefined,
  now: number,
): BackgroundWorkGroup {
  const isSubagent = SUBAGENT_KINDS.has(root.kind);
  const children = members(root, detail)
    .filter((task) => task.taskId !== root.taskId)
    .map((child): BackgroundWorkRow => {
      const run = isSubagent ? subagentRun(child, root, runs) : undefined;
      const name = run?.agent.trim();
      const state = executionState(child, summary, runtimeInstanceId);
      return {
        id: identity(child),
        // A subagent child's title is the delegation instruction, so it is never shown.
        title: isSubagent ? (name || t("hud.backgroundWork.unnamedAgent")) : child.title,
        state,
        timing: timing(child, run, state, now),
      };
    });
  const state = executionState(root, summary, runtimeInstanceId);
  const result = resultOf(tickets(root, detail));
  return {
    id: identity(root),
    title: isSubagent ? t("hud.backgroundWork.subagentGroup") : root.title,
    state,
    timing: children.length === 0 ? timing(root, undefined, state, now) : { kind: "none" },
    children,
    ...(result ? { result } : {}),
  };
}

function subagentRun(task: AsyncTask, root: AsyncTask, runs: readonly PickySubagentRun[]): PickySubagentRun | undefined {
  const runId = task.details?.runId;
  if (!root.invocationId || typeof runId !== "number") return undefined;
  return runs.find((run) => run.runId === runId && run.invocationId === root.invocationId);
}

/** `createdAt` includes queue wait, so it is never used as an execution start. */
function timing(task: AsyncTask, run: PickySubagentRun | undefined, state: BackgroundWorkState, now: number): BackgroundWorkTiming {
  const started = date(task.details?.startedAt) ?? date(run?.startedAt);
  if ((state === "running" || state === "stopping") && task.presence === "active") {
    if (started === undefined || duration((now - started) / 1000).kind !== "fixed") return { kind: "none" };
    return { kind: "elapsed", since: started };
  }
  if (state !== "completed" && state !== "failed" && state !== "cancelled" && state !== "interrupted") return { kind: "none" };
  const elapsedMs = typeof task.details?.elapsedMs === "number" ? task.details.elapsedMs : run?.elapsedMs;
  if (typeof elapsedMs === "number") return duration(elapsedMs / 1000);
  const finished = date(task.details?.finishedAt);
  if (started !== undefined && finished !== undefined && finished >= started) return duration((finished - started) / 1000);
  return { kind: "none" };
}

function duration(seconds: number): BackgroundWorkTiming {
  return Number.isFinite(seconds) && seconds >= 0 && seconds < MAXIMUM_REPORTED_SECONDS ? { kind: "fixed", seconds } : { kind: "none" };
}

function date(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function reported(groups: readonly BackgroundWorkGroup[]): { states: Set<BackgroundWorkState>; results: Set<BackgroundWorkResult> } {
  const states = new Set<BackgroundWorkState>();
  const results = new Set<BackgroundWorkResult>();
  for (const entry of groups) {
    states.add(entry.state);
    for (const child of entry.children) states.add(child.state);
    if (entry.result) results.add(entry.result);
  }
  return { states, results };
}

function footerNote(groups: readonly BackgroundWorkGroup[], summary: AsyncWorkSummary): BackgroundWorkFooterModel["note"] {
  const { states, results } = reported(groups);
  const explainsAttention = states.has("failed") || states.has("interrupted") || states.has("unknown")
    || [...results].some(resultNeedsAttention);
  if (summary.attentionCount > 0 && !explainsAttention) return "attention";
  if (summary.uncertainExecutionCount > 0 && !states.has("unknown") && !results.has("unverified")) return "attention";
  return groups.length === 0 ? "detailUnavailable" : undefined;
}

type Status = BackgroundWorkFooterModel["status"];

function merge(first: Status | undefined, second: Status | undefined): Status | undefined {
  if (!first) return second;
  if (!second || second.text === first.text) return first;
  return { text: `${first.text} · ${second.text}`, state: first.state };
}

/** Up to one attention segment and one progress segment, highest priority first. */
function statusFor(groups: readonly BackgroundWorkGroup[]): Status | undefined {
  const { states, results } = reported(groups);
  const segments: Status[] = [];
  if (states.has("failed")) segments.push({ text: t("hud.backgroundWork.needsAttention"), state: "failed" });
  else if (results.has("failed")) segments.push({ text: t("hud.asyncTasks.result.failed"), state: "failed" });
  else if (states.has("unknown")) segments.push({ text: t("hud.backgroundWork.statusUnknown"), state: "unknown" });
  else if (results.has("unverified")) segments.push({ text: t("hud.asyncTasks.result.unknown"), state: "unknown" });
  else if (states.has("interrupted")) segments.push({ text: t("hud.backgroundWork.needsAttention"), state: "interrupted" });

  if (states.has("stopping")) segments.push({ text: t("hud.asyncTasks.execution.cancelling.short"), state: "stopping" });
  else if (states.has("running")) segments.push({ text: t("hud.asyncTasks.execution.running.short"), state: "running" });
  else if (states.has("queued")) segments.push({ text: t("hud.asyncTasks.execution.queued.short"), state: "queued" });
  else if (results.has("processing")) segments.push({ text: t("hud.asyncTasks.result.processing"), state: "running" });
  else if (results.has("pending")) segments.push({ text: t("hud.asyncTasks.result.pending"), state: "queued" });

  if (segments.length === 0) {
    const remaining = STATUS_FALLBACK_ORDER.find((state) => states.has(state));
    if (remaining) segments.push({ text: t(STATE_LABEL_KEY[remaining]), state: remaining });
  }
  const first = segments[0];
  if (!first) return undefined;
  return { text: segments.map((segment) => segment.text).join(" · "), state: first.state };
}

/** Counts alone never prove a failure; without detail the footer says the state needs checking. */
function canonicalStatus(summary: AsyncWorkSummary): Status | undefined {
  if (summary.uncertainExecutionCount > 0) return { text: t("hud.backgroundWork.statusUnknown"), state: "unknown" };
  if (summary.attentionCount > 0) return { text: t("hud.backgroundWork.needsAttention"), state: "unknown" };
  if (summary.activeRootCount > 0) return { text: t("hud.asyncTasks.execution.running.short"), state: "running" };
  if (summary.pendingCompletionCount > 0) return { text: t("hud.asyncTasks.result.pending"), state: "queued" };
  return undefined;
}
