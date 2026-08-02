import { sliceUtf16Safe } from "./safe-truncate.js";
import type { PickySubagentRun } from "../protocol.js";

export type SubagentRunUpdate = PickySubagentRun;

const supportedCustomTypes = new Set(["subagent-tool", "subagent-command"]);
const resultPreviewLimit = 600;

/** Maps the subagent extension's opaque custom-message details into HUD state. */
export function subagentRunUpdateFromCustomMessage(
  customType: unknown,
  details: unknown,
  content?: unknown,
): SubagentRunUpdate | undefined {
  if (typeof customType !== "string" || !supportedCustomTypes.has(customType)) return undefined;
  if (!isRecord(details)) return undefined;

  const identity = runIdentity(details);
  if (!identity) return undefined;

  const preview = identity.status !== "running" ? resultPreview(content) : undefined;
  return {
    ...identity,
    ...optionalRunFields(details),
    ...(preview ? { resultPreview: preview } : {}),
  };
}

function runIdentity(
  details: Record<string, unknown>,
): Pick<PickySubagentRun, "runId" | "agent" | "task" | "status"> | undefined {
  const { runId, agent, task } = details;
  if (typeof runId !== "number" || !Number.isInteger(runId) || typeof agent !== "string" || typeof task !== "string") return undefined;
  const status = runStatus(details.status);
  if (!status) return undefined;
  return { runId, agent, task, status };
}

function runStatus(value: unknown): PickySubagentRun["status"] | undefined {
  if (value === "started" || value === "resumed") return "running";
  if (value === "done" || value === "error") return value;
  return undefined;
}

function optionalRunFields(details: Record<string, unknown>): Partial<PickySubagentRun> {
  const startedAt = isoTimestamp(details.startedAt);
  return {
    ...(nonEmptyString(details.displayTask) ? { displayTask: details.displayTask } : {}),
    ...(nonEmptyString(details.errorClass) ? { errorClass: details.errorClass } : {}),
    ...(startedAt ? { startedAt } : {}),
    ...(finiteNonnegativeNumber(details.elapsedMs) ? { elapsedMs: details.elapsedMs } : {}),
    ...(nonEmptyString(details.batchId) ? { batchId: details.batchId } : {}),
    ...(nonEmptyString(details.pipelineId) ? { pipelineId: details.pipelineId } : {}),
    ...(integer(details.pipelineStepIndex) ? { pipelineStepIndex: details.pipelineStepIndex } : {}),
    ...(nonEmptyString(details.model) ? { model: details.model } : {}),
  };
}

export function applySubagentRunUpdate(runs: readonly PickySubagentRun[], update: SubagentRunUpdate): PickySubagentRun[] {
  const existing = runs.find((run) => run.runId === update.runId);
  const next = existing ? { ...existing, ...update } : update;
  return [...runs.filter((run) => run.runId !== update.runId), next].sort((left, right) => left.runId - right.runId);
}

/** Settled runs are transient; retain only while a background run is still active. */
export function pruneSettledSubagentRuns(runs: readonly PickySubagentRun[]): PickySubagentRun[] {
  return runs.some((run) => run.status === "running") ? [...runs] : [];
}

function resultPreview(content: unknown): string | undefined {
  const text = contentText(content)?.trim();
  if (!text) return undefined;
  const separator = text.lastIndexOf("\n\n");
  return sliceUtf16Safe((separator >= 0 ? text.slice(separator + 2) : text).trim(), resultPreviewLimit) || undefined;
}

function contentText(content: unknown): string | undefined {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  return content
    .filter(isRecord)
    .filter((part) => part.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n");
}

function isoTimestamp(value: unknown): string | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

function finiteNonnegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function integer(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
