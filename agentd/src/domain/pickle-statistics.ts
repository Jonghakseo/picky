import { createHash } from "node:crypto";
import { basename } from "node:path";
import type { PickyAgentSession } from "../protocol.js";

export type PickleStatisticsCategory = "fix" | "research" | "create" | "review" | "unclassified";

export interface PickleClassificationEntry {
  category: PickleStatisticsCategory;
  fingerprint: string;
  classifiedAt: string;
  attempts: number;
}

export interface PickleClassifications {
  version: 1;
  entries: Record<string, PickleClassificationEntry>;
}

export interface PickleStatisticsRecord {
  id: string;
  title: string;
  project: string;
  cwd?: string;
  createdAt: string;
  lastActivityAt: string;
  followUpCount: number;
  delegationCount: number;
  reviewCount: number;
  category: PickleStatisticsCategory;
}

export interface PickleUsageSample {
  day: string;
  provider: string;
  model: string;
  project?: string;
  inputTokens: number;
  outputTokens: number;
  cacheTokens: number;
}

/** An assistant entry's Pi JSONL ID is stable when Pi forks a transcript. */
export interface PiUsageEntry {
  messageId: string;
  timestamp: number | string | undefined;
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

const REVIEW_AGENT_PATTERN = /review|verif|challeng|audit|critic/i;

export function projectNameForCwd(cwd: string | undefined, homeDir?: string): string {
  const trimmed = cwd?.trim();
  if (!trimmed || trimmed === "~") return "Picky";
  const normalized = trimmed.replace(/\/+$/, "");
  if (!normalized) return "Picky";
  if (homeDir && normalized === homeDir.replace(/\/+$/, "")) return "Home";
  return basename(normalized) || "Picky";
}

export function pickleStatisticsRecord(
  session: PickyAgentSession,
  classification: PickleClassificationEntry | undefined = undefined,
  options: { homeDir?: string } = {},
): PickleStatisticsRecord {
  const messageJournalAvailable = session.messageJournalAvailable !== false;
  const messages = messageJournalAvailable ? session.messages ?? [] : [];
  const userMessageCount = messages.filter((message) => message.kind === "user_text" && message.originatedBy === "user").length;
  const initialInstruction = messages.find((message) => (
    message.kind === "user_text"
    && (message.originatedBy === "user" || message.originatedBy === "main_agent")
  ));
  const delegationCount = messages.filter((message) => message.kind === "user_text" && message.originatedBy === "main_agent").length;
  const reviewCount = (session.subagentRuns ?? []).filter((run) => REVIEW_AGENT_PATTERN.test(run.agent)).length;

  return {
    id: session.id,
    title: session.title,
    project: projectNameForCwd(session.cwd, options.homeDir),
    ...(session.cwd ? { cwd: session.cwd } : {}),
    createdAt: session.createdAt,
    lastActivityAt: session.updatedAt,
    followUpCount: Math.max(0, userMessageCount - (initialInstruction?.originatedBy === "user" ? 1 : 0)),
    delegationCount,
    reviewCount,
    category: classification?.category ?? "unclassified",
  };
}

export function aggregateUsageSamples(entries: readonly PiUsageEntry[], project: string | undefined): PickleUsageSample[] {
  const totals = new Map<string, PickleUsageSample>();
  for (const entry of entries) {
    const day = localDay(entry.timestamp);
    if (!day) continue;
    const key = [day, entry.provider, entry.model, project ?? ""].join("\u0000");
    const current = totals.get(key) ?? {
      day,
      provider: entry.provider,
      model: entry.model,
      ...(project ? { project } : {}),
      inputTokens: 0,
      outputTokens: 0,
      cacheTokens: 0,
    };
    current.inputTokens += entry.inputTokens;
    // Pi's Usage.reasoning is a breakdown of output, not additional output.
    current.outputTokens += entry.outputTokens;
    current.cacheTokens += entry.cacheReadTokens + entry.cacheWriteTokens;
    totals.set(key, current);
  }
  return sortedUsageSamples(totals.values());
}

export function mergeUsageSamples(samples: readonly PickleUsageSample[]): PickleUsageSample[] {
  const totals = new Map<string, PickleUsageSample>();
  for (const sample of samples) {
    const key = [sample.day, sample.provider, sample.model, sample.project ?? ""].join("\u0000");
    const current = totals.get(key) ?? { ...sample, inputTokens: 0, outputTokens: 0, cacheTokens: 0 };
    current.inputTokens += sample.inputTokens;
    current.outputTokens += sample.outputTokens;
    current.cacheTokens += sample.cacheTokens;
    totals.set(key, current);
  }
  return sortedUsageSamples(totals.values());
}

export function classificationFingerprint(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function sortedUsageSamples(samples: Iterable<PickleUsageSample>): PickleUsageSample[] {
  return [...samples].sort((lhs, rhs) => (
    lhs.day.localeCompare(rhs.day)
    || lhs.provider.localeCompare(rhs.provider)
    || lhs.model.localeCompare(rhs.model)
    || (lhs.project ?? "").localeCompare(rhs.project ?? "")
  ));
}

function localDay(timestamp: PiUsageEntry["timestamp"]): string | undefined {
  const date = typeof timestamp === "number"
    ? new Date(timestamp)
    : typeof timestamp === "string"
      ? new Date(timestamp)
      : undefined;
  if (!date || Number.isNaN(date.getTime())) return undefined;
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}
