import { applySubagentRunUpdate, capSubagentRuns, retainSubagentRunResultText } from "../domain/subagent-run-state.js";
import type { PickyAgentSession, PickySubagentRun } from "../protocol.js";

export interface SubagentRunUpdaterDependencies {
  currentRuns(sessionId: string): readonly PickySubagentRun[];
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>, options: { emitSession: false }): Promise<void>;
  nextSeq(sessionId: string): number;
  emitUpdated(sessionId: string, runs: readonly PickySubagentRun[], seq: number): Promise<void>;
}

/** Applies a runtime subagent update, persists the bounded projection, then emits it in session order. */
export class SubagentRunUpdater {
  constructor(private readonly dependencies: SubagentRunUpdaterDependencies) {}

  async update(sessionId: string, update: PickySubagentRun): Promise<void> {
    const current = this.dependencies.currentRuns(sessionId);
    const runs = retainSubagentRunResultText(capSubagentRuns(applySubagentRunUpdate(current, update)));
    if (sameSubagentRuns(current, runs)) return;
    await this.dependencies.patchSession(sessionId, { subagentRuns: runs }, { emitSession: false });
    const seq = this.dependencies.nextSeq(sessionId);
    await this.dependencies.emitUpdated(sessionId, runs, seq);
  }
}

function sameSubagentRuns(left: readonly PickySubagentRun[], right: readonly PickySubagentRun[]): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}
