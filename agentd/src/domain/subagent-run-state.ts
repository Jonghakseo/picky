import { sliceUtf16Safe } from "./safe-truncate.js";
import type { PickySubagentRun } from "../protocol.js";

export type SubagentRunUpdate = PickySubagentRun;
export type SubagentLaunchAction = "run" | "batch" | "chain";

export interface SubagentLaunchIntentEntry {
  agent: string;
  task: string;
}

export interface SubagentRunActivityUpdate {
  runId: number;
  lastActivity: NonNullable<PickySubagentRun["lastActivity"]>;
}

export interface SubagentLaunchIntent {
  action: SubagentLaunchAction;
  entries: SubagentLaunchIntentEntry[];
}

export interface SubagentDiagnosticRunUpdate extends Omit<PickySubagentRun, "task"> {
  recordedAt: string;
}

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

/** Parses the subagent CLI command passed through Pi's `subagent` tool. */
export function subagentLaunchIntentFromToolArgs(args: unknown): SubagentLaunchIntent | undefined {
  const command = commandFromToolArgs(args);
  if (!command) return undefined;

  const tokens = shellTokens(command);
  if (tokens[0]?.value !== "subagent") return undefined;
  const action = launchAction(tokens[1]?.value);
  if (!action) return undefined;

  if (action === "run") return runLaunchIntent(command, tokens);
  const entries = multiLaunchEntries(tokens);
  return entries.length > 0 ? { action, entries } : undefined;
}

/** Maps headless runner diagnostics into a run update without fabricating a task. */
export function subagentRunUpdateFromDiagnostic(data: unknown): SubagentDiagnosticRunUpdate | undefined {
  if (!isRecord(data)) return undefined;
  const identity = diagnosticIdentity(data);
  const recordedAt = isoTimestamp(data.recordedAt);
  if (!identity || !recordedAt) return undefined;

  const status = diagnosticStatus(data.event, data.code);
  if (!status) return undefined;
  return {
    ...identity,
    status: status.status,
    recordedAt,
    ...(status.errorClass ? { errorClass: status.errorClass } : {}),
    ...(status.status === "running" ? { startedAt: recordedAt } : {}),
    ...diagnosticGroupFields(data),
  };
}

/** Parses optional, forward-compatible live activity emitted by a future subagent extension. */
export function subagentRunActivityUpdateFromDiagnostic(data: unknown): SubagentRunActivityUpdate | undefined {
  if (!isRecord(data)) return undefined;
  const runId = integer(data.runId);
  if (runId === undefined || runId < 0 || !nonEmptyString(data.agent)) return undefined;
  const toolName = nonEmptyString(data.lastToolName) ? data.lastToolName : undefined;
  const toolCallCount = integer(data.toolCallCount);
  const lastLine = nonEmptyString(data.lastLine) ? data.lastLine : undefined;
  if (!toolName && toolCallCount === undefined && !lastLine) return undefined;
  return {
    runId,
    lastActivity: {
      ...(toolName ? { toolName } : {}),
      ...(toolCallCount !== undefined && toolCallCount >= 0 ? { toolCallCount } : {}),
      ...(lastLine ? { lastLine } : {}),
    },
  };
}

function commandFromToolArgs(args: unknown): string | undefined {
  if (isRecord(args)) return nonEmptyString(args.command) ? args.command : undefined;
  if (typeof args !== "string") return undefined;
  try {
    return commandFromToolArgs(JSON.parse(args));
  } catch {
    return undefined;
  }
}

interface ShellToken {
  value: string;
  start: number;
  end: number;
}

function shellTokens(command: string): ShellToken[] {
  const tokens: ShellToken[] = [];
  let index = 0;
  while (index < command.length) {
    while (/\s/.test(command[index] ?? "")) index += 1;
    if (index >= command.length) break;
    const start = index;
    let value = "";
    let quote: "'" | '"' | undefined;
    while (index < command.length) {
      const character = command[index]!;
      if (quote) {
        if (character === quote) quote = undefined;
        else if (character === "\\" && quote === '"' && index + 1 < command.length) value += command[++index]!;
        else value += character;
        index += 1;
        continue;
      }
      if (character === "'" || character === '"') {
        quote = character;
        index += 1;
      } else if (character === "\\" && index + 1 < command.length) {
        value += command[index + 1]!;
        index += 2;
      } else if (/\s/.test(character)) {
        break;
      } else {
        value += character;
        index += 1;
      }
    }
    tokens.push({ value, start, end: index });
  }
  return tokens;
}

function launchAction(value: string | undefined): SubagentLaunchAction | undefined {
  if (value === "continue") return "run";
  return value === "run" || value === "batch" || value === "chain" ? value : undefined;
}

function runLaunchIntent(command: string, tokens: ShellToken[]): SubagentLaunchIntent | undefined {
  const agent = tokens[2]?.value;
  const delimiter = tokens.slice(3).find((token) => token.value === "--");
  if (!nonEmptyString(agent) || !delimiter) return undefined;
  const task = command.slice(delimiter.end).trim();
  return task ? { action: "run", entries: [{ agent, task }] } : undefined;
}

function multiLaunchEntries(tokens: ShellToken[]): SubagentLaunchIntentEntry[] {
  const entries: SubagentLaunchIntentEntry[] = [];
  let agent: string | undefined;
  for (let index = 2; index < tokens.length; index += 1) {
    const token = tokens[index]?.value;
    if (token === "--agent") agent = tokens[++index]?.value;
    else if (token === "--task" && agent) {
      const task = tokens[++index]?.value;
      if (nonEmptyString(task)) entries.push({ agent, task });
      agent = undefined;
    }
  }
  return entries;
}

function diagnosticIdentity(data: Record<string, unknown>): Pick<SubagentDiagnosticRunUpdate, "runId" | "agent"> | undefined {
  const runId = integer(data.runId);
  const agent = nonEmptyString(data.agent) ? data.agent : undefined;
  return runId !== undefined && runId >= 0 && agent ? { runId, agent } : undefined;
}

function diagnosticStatus(event: unknown, code: unknown): Pick<SubagentDiagnosticRunUpdate, "status" | "errorClass"> | undefined {
  if (event === "spawn") return { status: "running" };
  if (event === "settled") return integer(code) === 0 ? { status: "done" } : { status: "error" };
  if (event === "kill_result") return { status: "error", errorClass: "aborted" };
  if (event === "process_error") return { status: "error", errorClass: "process_error" };
  return undefined;
}

function diagnosticGroupFields(data: Record<string, unknown>): Partial<PickySubagentRun> {
  return {
    ...(nonEmptyString(data.batchId) ? { batchId: data.batchId } : {}),
    ...(nonEmptyString(data.pipelineId) ? { pipelineId: data.pipelineId } : {}),
    ...(integer(data.pipelineStepIndex) !== undefined ? { pipelineStepIndex: integer(data.pipelineStepIndex) } : {}),
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
    ...(integer(details.pipelineStepIndex) !== undefined ? { pipelineStepIndex: integer(details.pipelineStepIndex) } : {}),
    ...(nonEmptyString(details.model) ? { model: details.model } : {}),
  };
}

export function applySubagentRunUpdate(runs: readonly PickySubagentRun[], update: SubagentRunUpdate): PickySubagentRun[] {
  const existing = runs.find((run) => run.runId === update.runId);
  const next = existing ? { ...existing, ...update } : update;
  return [...runs.filter((run) => run.runId !== update.runId), next].sort((left, right) => left.runId - right.runId);
}

/** Retains bounded invocation history, dropping the oldest runs first. */
export function capSubagentRuns(runs: readonly PickySubagentRun[], limit = 100): PickySubagentRun[] {
  return runs.length <= limit ? [...runs] : runs.slice(runs.length - limit);
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
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

function finiteNonnegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function integer(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) ? value : undefined;
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
