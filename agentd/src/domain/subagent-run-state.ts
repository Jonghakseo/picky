import { sliceUtf16Safe } from "./safe-truncate.js";
import type { PickySubagentRun } from "../protocol.js";

export type SubagentRunUpdate = PickySubagentRun;
export type SubagentGroupRunUpdate = Pick<PickySubagentRun, "runId" | "agent" | "status">
  & Partial<Omit<PickySubagentRun, "runId" | "agent" | "status" | "task">>;
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
const resultTextLimit = 32_000;

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
  const text = identity.status !== "running" ? resultText(content) : undefined;
  return {
    ...identity,
    ...optionalRunFields(details),
    ...(preview ? { resultPreview: preview } : {}),
    ...(text ? { resultText: text } : {}),
  };
}

/** Best-effort parses batch and chain completion content into updates for existing run state. */
export function subagentGroupRunUpdatesFromCustomMessage(
  customType: unknown,
  details: unknown,
  content?: unknown,
  knownTasks: ReadonlyMap<number, string> = new Map(),
): SubagentGroupRunUpdate[] {
  if (typeof customType !== "string" || !supportedCustomTypes.has(customType)) return [];
  if (!isRecord(details)) return [];
  const text = contentText(content);
  if (!text) return [];

  const group = groupDetails(details);
  if (!group) return [];
  const summaries = group.runIds.flatMap((runId) => {
    const summary = group.summaries.get(runId);
    return summary ? [summary] : [];
  });
  if (summaries.length === 0) return [];

  const sections = group.kind === "batch"
    ? batchSections(text, summaries)
    : chainSections(text, summaries);
  return resultUpdatesFromSections(sections, group.kind, knownTasks);
}

/** Extracts completed headless subagent responses from a `tool_execution_end` result. */
export function subagentRunUpdatesFromToolResult(
  result: unknown,
  knownRuns: readonly PickySubagentRun[],
): SubagentGroupRunUpdate[] {
  const content = contentAfterFirstSubagentMarker(contentText(result));
  if (!content) return [];

  const single = /^\[subagent:([^#\]]+)#(\d+)\]\s+(completed|failed|escalated)\s*$/.exec(content.marker);
  if (single) {
    const [, agent, runIdText, markerStatus] = single;
    const runId = Number(runIdText);
    const knownRun = knownRuns.find((run) => run.runId === runId && run.agent === agent);
    if (!knownRun) return [];
    const response = firstResponseBody(content.text);
    const text = response ? cappedResultText(response) : undefined;
    return [{
      runId,
      agent,
      status: markerStatus === "completed" ? "done" : "error",
      ...(text ? { resultText: text, resultPreview: resultPreview(text) } : {}),
    }];
  }

  const batch = /^\[subagent-batch#([^\]]+)\]/.exec(content.marker);
  if (batch) {
    const summaries = knownRuns
      .filter((run) => run.batchId === batch[1])
      .map(groupSummaryFromKnownRun);
    return resultUpdatesFromSections(batchSections(content.text, summaries), "batch", new Map());
  }

  const chain = /^\[subagent-chain#([^\]]+)\]/.exec(content.marker);
  if (!chain) return [];
  const runs = knownRuns.filter((run) => run.pipelineId === chain[1]);
  const summaries = runs.map(groupSummaryFromKnownRun);
  const knownTasks = new Map(runs.map((run) => [run.runId, run.task]));
  return resultUpdatesFromSections(chainSections(content.text, summaries), "chain", knownTasks);
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

interface GroupDetails {
  kind: "batch" | "chain";
  runIds: number[];
  summaries: Map<number, SubagentGroupRunUpdate>;
}

interface GroupSection {
  summary: SubagentGroupRunUpdate;
  body: string;
}

function groupDetails(details: Record<string, unknown>): GroupDetails | undefined {
  const kind = nonEmptyString(details.batchId) && Array.isArray(details.runIds)
    ? "batch"
    : nonEmptyString(details.pipelineId) && Array.isArray(details.stepRunIds)
      ? "chain"
      : undefined;
  if (!kind || !Array.isArray(details.runSummaries)) return undefined;

  const rawRunIds = kind === "batch" ? details.runIds : details.stepRunIds;
  if (!Array.isArray(rawRunIds)) return undefined;
  const runIds = rawRunIds.flatMap((value): number[] => {
    const runId = integer(value);
    return runId !== undefined && runId >= 0 ? [runId] : [];
  });
  if (runIds.length === 0 || new Set(runIds).size !== runIds.length) return undefined;

  const summaries = new Map<number, SubagentGroupRunUpdate>();
  for (const value of details.runSummaries) {
    const summary = groupRunSummary(value, kind, details);
    if (!summary || !runIds.includes(summary.runId) || summaries.has(summary.runId)) continue;
    summaries.set(summary.runId, summary);
  }
  return { kind, runIds, summaries };
}

function groupRunSummary(
  value: unknown,
  kind: GroupDetails["kind"],
  details: Record<string, unknown>,
): SubagentGroupRunUpdate | undefined {
  if (!isRecord(value)) return undefined;
  const runId = integer(value.runId);
  const agent = nonEmptyString(value.agent) ? value.agent : undefined;
  const status = value.status === "done" || value.status === "error" ? value.status : undefined;
  if (runId === undefined || runId < 0 || !agent || !status) return undefined;
  const pipelineStepIndex = integer(value.stepIndex);
  return {
    runId,
    agent,
    status,
    ...(finiteNonnegativeNumber(value.elapsedMs) ? { elapsedMs: value.elapsedMs } : {}),
    ...(nonEmptyString(value.model) ? { model: value.model } : {}),
    ...(nonEmptyString(value.errorClass) ? { errorClass: value.errorClass } : {}),
    ...(kind === "batch" && nonEmptyString(details.batchId) ? { batchId: details.batchId } : {}),
    ...(kind === "chain" && nonEmptyString(details.pipelineId) ? { pipelineId: details.pipelineId } : {}),
    ...(pipelineStepIndex !== undefined ? { pipelineStepIndex } : {}),
  };
}

function batchSections(text: string, summaries: readonly SubagentGroupRunUpdate[]): GroupSection[] {
  return sectionsForHeaders(text, summaries, (summary) => `#${summary.runId} ${summary.agent}`);
}

function chainSections(text: string, summaries: readonly SubagentGroupRunUpdate[]): GroupSection[] {
  return sectionsForHeaders(text, summaries.filter(hasUsablePipelineStepIndex), (summary) => (
    `Step ${summary.pipelineStepIndex! + 1} · #${summary.runId} ${summary.agent} · ${summary.status}`
  ));
}

function hasUsablePipelineStepIndex(summary: SubagentGroupRunUpdate): boolean {
  return typeof summary.pipelineStepIndex === "number"
    && Number.isInteger(summary.pipelineStepIndex)
    && summary.pipelineStepIndex >= 0;
}

function sectionsForHeaders(
  text: string,
  summaries: readonly SubagentGroupRunUpdate[],
  headerFor: (summary: SubagentGroupRunUpdate) => string,
): GroupSection[] {
  const byHeader = new Map(summaries.map((summary) => [headerFor(summary), summary]));
  const lines = text.replaceAll("\r\n", "\n").split("\n");
  const matches: Array<{ index: number; summary: SubagentGroupRunUpdate }> = [];
  for (let index = 1; index < lines.length; index += 1) {
    const summary = byHeader.get(lines[index] ?? "");
    if (summary && lines[index - 1] === "") matches.push({ index, summary });
  }
  return matches.map(({ index, summary }, matchIndex) => ({
    summary,
    body: lines.slice(index + 1, matches[matchIndex + 1]?.index).join("\n"),
  }));
}

function resultUpdatesFromSections(
  sections: readonly GroupSection[],
  kind: GroupDetails["kind"],
  knownTasks: ReadonlyMap<number, string>,
): SubagentGroupRunUpdate[] {
  return sections.flatMap(({ summary, body }) => {
    const response = kind === "chain" ? stripChainTask(body, knownTasks.get(summary.runId)) : stripBatchBullet(body);
    const text = cappedResultText(response);
    return [{
      ...summary,
      ...(text ? { resultText: text, resultPreview: resultPreview(text) } : {}),
    }];
  });
}

function groupSummaryFromKnownRun(run: PickySubagentRun): SubagentGroupRunUpdate {
  return {
    runId: run.runId,
    agent: run.agent,
    status: run.status,
    ...(run.batchId ? { batchId: run.batchId } : {}),
    ...(run.pipelineId ? { pipelineId: run.pipelineId } : {}),
    ...(run.pipelineStepIndex !== undefined ? { pipelineStepIndex: run.pipelineStepIndex } : {}),
  };
}

function contentAfterFirstSubagentMarker(text: string | undefined): { marker: string; text: string } | undefined {
  if (!text) return undefined;
  const lines = text.replaceAll("\r\n", "\n").split("\n");
  const index = lines.findIndex((line) => line.startsWith("[subagent:") || line.startsWith("[subagent-batch#") || line.startsWith("[subagent-chain#"));
  const marker = lines[index];
  return index >= 0 && marker ? { marker, text: lines.slice(index).join("\n") } : undefined;
}

function firstResponseBody(text: string): string | undefined {
  const separator = text.indexOf("\n\n");
  return separator >= 0 ? text.slice(separator + 2) : undefined;
}

function stripBatchBullet(body: string): string {
  return body.startsWith("- ") ? body.slice(2) : body;
}

function stripChainTask(body: string, knownTask: string | undefined): string {
  if (!body.startsWith("Task: ")) return body;
  const normalizedTask = knownTask?.trim().replace(/\s+/g, " ");
  if (normalizedTask) {
    const escapedWords = normalizedTask.split(" ").map(escapeRegExp).join("\\s+");
    const match = new RegExp(`^Task:\\s*${escapedWords}(?:\\s|$)`).exec(body);
    if (match) return body.slice(match[0].length);
  }
  return body.replace(/^Task:[^\n]*(?:\n|$)/, "");
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function applySubagentRunUpdate(runs: readonly PickySubagentRun[], update: SubagentRunUpdate): PickySubagentRun[] {
  const existingIndex = matchingRunIndex(runs, update);
  if (existingIndex < 0) return [...runs, update].sort((left, right) => left.runId - right.runId);

  const existing = runs[existingIndex]!;
  const next = isFreshSpawn(update, existing) ? update : { ...existing, ...update };
  return runs.map((run, index) => index === existingIndex ? next : run).sort((left, right) => left.runId - right.runId);
}

function matchingRunIndex(runs: readonly PickySubagentRun[], update: SubagentRunUpdate): number {
  if (update.invocationId !== undefined) return runs.findIndex((run) => sameRunIdentity(run, update));
  for (let index = runs.length - 1; index >= 0; index -= 1) {
    if (sameRunIdentity(runs[index]!, update)) return index;
  }
  return -1;
}

function sameRunIdentity(run: PickySubagentRun, update: SubagentRunUpdate): boolean {
  if (run.runId !== update.runId) return false;
  return update.invocationId === undefined || run.invocationId === update.invocationId;
}

function isFreshSpawn(update: SubagentRunUpdate, existing: PickySubagentRun): boolean {
  return update.status === "running" && (existing.status === "done" || existing.status === "error");
}

/** Retains bounded invocation history, dropping the oldest runs first. */
export function capSubagentRuns(runs: readonly PickySubagentRun[], limit = 100): PickySubagentRun[] {
  return runs.length <= limit ? [...runs] : runs.slice(runs.length - limit);
}

/** Keeps full responses only for recent runs so persisted session snapshots stay bounded. */
export function retainSubagentRunResultText(runs: readonly PickySubagentRun[], limit = 30): PickySubagentRun[] {
  const retainedCount = Math.max(0, Math.floor(limit));
  const retainedIndexes = new Set(runs
    .map((run, index) => ({ index, settledAt: settledAt(run) }))
    .sort((left, right) => {
      if (left.settledAt !== undefined && right.settledAt !== undefined) return right.settledAt - left.settledAt;
      if (left.settledAt !== undefined) return -1;
      if (right.settledAt !== undefined) return 1;
      return right.index - left.index;
    })
    .slice(0, retainedCount)
    .map(({ index }) => index));
  return runs.map((run, index) => {
    if (retainedIndexes.has(index) || run.resultText === undefined) return run;
    const { resultText: _, ...withoutResultText } = run;
    return withoutResultText;
  });
}

function settledAt(run: PickySubagentRun): number | undefined {
  if (run.status !== "done" && run.status !== "error") return undefined;
  const startedAt = run.startedAt ? new Date(run.startedAt).getTime() : Number.NaN;
  if (!Number.isFinite(startedAt)) return undefined;
  return startedAt + (finiteNonnegativeNumber(run.elapsedMs) ? run.elapsedMs : 0);
}

function resultPreview(content: unknown): string | undefined {
  const text = contentText(content)?.trim();
  if (!text) return undefined;
  const separator = text.lastIndexOf("\n\n");
  return sliceUtf16Safe((separator >= 0 ? text.slice(separator + 2) : text).trim(), resultPreviewLimit) || undefined;
}

function resultText(content: unknown): string | undefined {
  const text = contentText(content);
  if (!text) return undefined;
  const separator = text.indexOf("\n\n");
  return separator >= 0 ? cappedResultText(text.slice(separator + 2)) : undefined;
}

function cappedResultText(text: string): string | undefined {
  return sliceUtf16Safe(text.trim(), resultTextLimit) || undefined;
}

function contentText(content: unknown): string | undefined {
  if (typeof content === "string") return content;
  if (isRecord(content)) return contentText(content.content);
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
