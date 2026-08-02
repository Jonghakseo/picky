import {
  subagentLaunchIntentFromToolArgs,
  subagentRunActivityUpdateFromDiagnostic,
  subagentRunUpdateFromDiagnostic,
  subagentRunUpdatesFromToolResult,
  type SubagentDiagnosticRunUpdate,
  type SubagentGroupRunUpdate,
  type SubagentLaunchIntentEntry,
} from "../domain/subagent-run-state.js";
import type { PickySubagentInvocation, PickySubagentRun } from "../protocol.js";
import { asRecord, stringValue } from "./pi-sdk-runtime-helpers.js";

/** Owns the per-runtime correlation between Pi subagent events and HUD run state. */
export class SubagentInvocationTracker {
  private pendingLaunches: Array<SubagentLaunchIntentEntry & { invocationId: string }> = [];
  private activeInvocationIDs: string[] = [];
  private invocationsByID = new Map<string, PickySubagentInvocation>();
  private runsById = new Map<number, PickySubagentRun>();

  captureLaunchIntent(event: Record<string, unknown>): PickySubagentInvocation | undefined {
    if (event.type !== "tool_execution_start" || event.toolName !== "subagent") return undefined;
    const invocationId = stringValue(event.toolCallId);
    const intent = subagentLaunchIntentFromToolArgs(event.args);
    if (!invocationId || !intent) return undefined;
    this.activeInvocationIDs.push(invocationId);
    this.pendingLaunches.push(...intent.entries.map((entry) => ({ ...entry, invocationId })));
    const invocation: PickySubagentInvocation = {
      invocationId,
      action: intent.action,
      planned: intent.entries,
    };
    this.invocationsByID.set(invocationId, invocation);
    return invocation;
  }

  closeInvocationIfSettled(event: Record<string, unknown>): PickySubagentInvocation | undefined {
    if (event.type !== "tool_execution_end" || event.toolName !== "subagent") return undefined;
    const invocationId = stringValue(event.toolCallId);
    const invocation = invocationId ? this.invocationsByID.get(invocationId) : undefined;
    if (!invocationId || !invocation) return undefined;
    const index = this.activeInvocationIDs.lastIndexOf(invocationId);
    if (index >= 0) this.activeInvocationIDs.splice(index, 1);
    this.pendingLaunches = this.pendingLaunches.filter((launch) => launch.invocationId !== invocationId);
    this.invocationsByID.delete(invocationId);
    return { ...invocation, completed: true };
  }

  diagnosticRunUpdateFromPiEvent(event: Record<string, unknown>): PickySubagentRun | undefined {
    if (event.type !== "entry_appended") return undefined;
    const entry = asRecord(event.entry);
    if (entry.type !== "custom") return undefined;
    if (entry.customType === "subagent-runner-diagnostic") {
      const diagnostic = subagentRunUpdateFromDiagnostic(entry.data);
      return diagnostic ? this.runFromDiagnostic(diagnostic) : undefined;
    }
    if (entry.customType !== "subagent-activity") return undefined;
    const activity = subagentRunActivityUpdateFromDiagnostic(entry.data);
    const existing = activity ? this.runsById.get(activity.runId) : undefined;
    if (!activity || !existing) return undefined;
    const update = { ...existing, lastActivity: activity.lastActivity };
    this.runsById.set(update.runId, update);
    return update;
  }

  attachRunUpdate(update: PickySubagentRun): PickySubagentRun {
    const existing = this.runsById.get(update.runId);
    const isFreshSpawn = update.status === "running" && isTerminalSubagentRun(existing);
    const invocationId = isFreshSpawn
      ? this.activeInvocationIDs.at(-1)
      : existing?.invocationId ?? this.activeInvocationIDs.at(-1);
    const run = {
      ...(isFreshSpawn ? {} : existing),
      ...update,
      ...(invocationId ? { invocationId } : {}),
    };
    this.runsById.set(run.runId, run);
    return run;
  }

  attachGroupRunUpdate(update: SubagentGroupRunUpdate): PickySubagentRun | undefined {
    const existing = this.runsById.get(update.runId);
    if (!existing) return undefined;
    const run = { ...existing, ...update };
    this.runsById.set(run.runId, run);
    return run;
  }

  toolResultRunUpdates(event: Record<string, unknown>): PickySubagentRun[] {
    if (event.type !== "tool_execution_end" || event.toolName !== "subagent") return [];
    return subagentRunUpdatesFromToolResult(event.result, [...this.runsById.values()]).flatMap((update) => {
      const existing = this.runsById.get(update.runId);
      if (!existing || existing.agent !== update.agent) return [];
      const run = {
        ...existing,
        ...update,
        ...(isTerminalSubagentRun(existing) ? { status: existing.status } : {}),
      };
      this.runsById.set(run.runId, run);
      return [run];
    });
  }

  knownTasksByRunId(): ReadonlyMap<number, string> {
    return new Map([...this.runsById].map(([runId, run]) => [runId, run.task]));
  }

  reset(): void {
    this.pendingLaunches = [];
    this.activeInvocationIDs = [];
    this.invocationsByID.clear();
    this.runsById.clear();
  }

  private runFromDiagnostic(diagnostic: SubagentDiagnosticRunUpdate): PickySubagentRun {
    const { recordedAt, ...update } = diagnostic;
    const existing = this.runsById.get(update.runId);
    const launch = update.status === "running" ? this.consumeLaunch(update.agent) : undefined;
    const isFreshSpawn = update.status === "running" && isTerminalSubagentRun(existing);
    const task = launch?.task ?? (isFreshSpawn ? update.agent : existing?.task) ?? update.agent;
    const elapsedMs = update.status === "running" ? undefined : elapsedSince(existing?.startedAt, recordedAt);
    const run: PickySubagentRun = {
      ...(isFreshSpawn ? {} : existing),
      ...update,
      task,
      ...(launch ? { invocationId: launch.invocationId } : {}),
      ...(elapsedMs !== undefined ? { elapsedMs } : {}),
    };
    this.runsById.set(run.runId, run);
    return run;
  }

  private consumeLaunch(agent: string): (SubagentLaunchIntentEntry & { invocationId: string }) | undefined {
    const index = this.pendingLaunches.findIndex((entry) => entry.agent === agent);
    return index < 0 ? undefined : this.pendingLaunches.splice(index, 1)[0];
  }
}

function elapsedSince(startedAt: string | undefined, endedAt: string): number | undefined {
  if (!startedAt) return undefined;
  const elapsed = Date.parse(endedAt) - Date.parse(startedAt);
  return Number.isFinite(elapsed) ? Math.max(0, elapsed) : undefined;
}

function isTerminalSubagentRun(run: PickySubagentRun | undefined): boolean {
  return run?.status === "done" || run?.status === "error";
}

