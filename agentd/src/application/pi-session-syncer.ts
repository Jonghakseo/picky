import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { hasActivity, zeroActivitySummary } from "../domain/activity-summary.js";
import { categorizeTool } from "../domain/tool-categorizer.js";
import { resolveTodoStateFromPiSessionEntries } from "../domain/todo-state.js";
import type { PickyActivitySummary, PickySessionMessage, PickyTodoState } from "../protocol.js";

interface PiSessionEntry {
  type?: string;
  id?: string;
  parentId?: string | null;
  timestamp?: string;
  customType?: string;
  data?: unknown;
  message?: PiSessionMessage;
}

interface PiSessionMessage {
  role?: string;
  content?: unknown;
  timestamp?: number | string;
}

interface PiContentBlock {
  type?: string;
  text?: string;
  thinking?: string;
  name?: string;
}

interface PiTerminalSessionSyncResult {
  messages: PickySessionMessage[];
  todoState?: PickyTodoState;
  todoStateResolved: boolean;
  activeLastMessageId?: string;
  baselineFound: boolean;
  baselineCreatedAt?: string;
}

export async function readPiSessionInfoName(sessionFilePath: string): Promise<string | undefined> {
  let text: string;
  try {
    text = await readFile(sessionFilePath, "utf8");
  } catch {
    return undefined;
  }
  const lines = text.split(/\r?\n/);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index]?.trim();
    if (!line) continue;
    let entry: { type?: string; name?: unknown } | undefined;
    try {
      entry = JSON.parse(line) as { type?: string; name?: unknown };
    } catch {
      continue;
    }
    if (entry?.type !== "session_info") continue;
    const name = typeof entry.name === "string" ? entry.name.trim() : "";
    if (name) return name;
  }
  return undefined;
}

export async function readPiTerminalSessionMessages(sessionFilePath: string, baselinePiMessageId?: string): Promise<PiTerminalSessionSyncResult> {
  const text = await readFile(sessionFilePath, "utf8");
  const entries = parseMessageEntries(text);
  const activePath = activeBranchPath(entries);
  const activeLastMessageId = [...activePath].reverse().find(isImportableMessageEntry)?.id;
  const todoResolution = resolveTodoStateFromPiSessionEntries(activePath);
  const startIndex = baselinePiMessageId ? activePath.findIndex((entry) => entry.id === baselinePiMessageId) : -1;
  const baselineFound = baselinePiMessageId ? startIndex >= 0 : true;
  if (baselinePiMessageId && startIndex < 0) {
    return {
      messages: [],
      todoStateResolved: todoResolution.resolved,
      ...(todoResolution.todoState ? { todoState: todoResolution.todoState } : {}),
      activeLastMessageId,
      baselineFound,
    };
  }

  const baselineEntry = startIndex >= 0 ? activePath[startIndex] : undefined;
  const baselineCreatedAt = baselineEntry ? isoTimestamp(baselineEntry.timestamp, baselineEntry.message?.timestamp) : undefined;
  const candidates = baselinePiMessageId ? activePath.slice(startIndex + 1) : activePath;
  const messages = candidates.flatMap(toPickySessionMessages);
  return {
    messages,
    todoStateResolved: todoResolution.resolved,
    ...(todoResolution.todoState ? { todoState: todoResolution.todoState } : {}),
    activeLastMessageId,
    baselineFound,
    baselineCreatedAt,
  };
}

function parseMessageEntries(text: string): PiSessionEntry[] {
  return text
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => {
      try {
        return JSON.parse(line) as PiSessionEntry;
      } catch {
        return undefined;
      }
    })
    .filter((entry): entry is PiSessionEntry => Boolean(entry?.id));
}

function activeBranchPath(entries: PiSessionEntry[]): PiSessionEntry[] {
  let current = lastBranchEntry(entries);
  if (!current) return [];
  const byId = new Map(entries.flatMap((entry) => entry.id ? [[entry.id, entry] as const] : []));
  const path: PiSessionEntry[] = [];
  const seen = new Set<string>();
  while (current) {
    path.push(current);
    const parentId = current.parentId ?? undefined;
    if (!parentId || seen.has(parentId)) break;
    seen.add(parentId);
    current = byId.get(parentId);
  }
  return path.reverse();
}

function lastBranchEntry(entries: PiSessionEntry[]): PiSessionEntry | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry && entry.parentId !== undefined) return entry;
  }
  return undefined;
}

function isImportableMessageEntry(entry: PiSessionEntry): boolean {
  const role = entry.message?.role;
  return role === "user" || role === "assistant";
}

function toPickySessionMessages(entry: PiSessionEntry): PickySessionMessage[] {
  const role = entry.message?.role;
  if (role !== "user" && role !== "assistant") return [];
  const text = plainText(entry.message?.content).trim();
  const piMessageId = entry.id ?? stableHash(`${role}:${entry.timestamp ?? ""}:${text}`);
  const safePiMessageId = safeId(piMessageId);
  const createdAt = isoTimestamp(entry.timestamp, entry.message?.timestamp);
  if (role === "user") {
    if (!text) return [];
    return [{
      id: `msg-pi-user-${safePiMessageId}`,
      kind: "user_text",
      createdAt,
      originatedBy: "pi_extension",
      text,
    }];
  }

  const messages: PickySessionMessage[] = [];
  const thinkingText = thinkingPlainText(entry.message?.content).trim();
  if (thinkingText) {
    messages.push({
      id: `msg-pi-thinking-${safePiMessageId}`,
      kind: "agent_thinking",
      createdAt,
      text: thinkingText,
    });
  }
  if (text) {
    messages.push({
      id: `msg-pi-agent-${safePiMessageId}`,
      kind: "agent_text",
      createdAt,
      text,
    });
  }
  const activitySnapshot = toolActivitySnapshot(entry.message?.content);
  if (activitySnapshot && hasActivity(activitySnapshot)) {
    messages.push({
      id: `msg-pi-activity-${safePiMessageId}`,
      kind: "agent_activity",
      createdAt,
      activitySnapshot,
    });
  }
  return messages;
}

function plainText(content: unknown): string {
  if (typeof content === "string") return content;
  return contentBlocks(content)
    .map((block) => block.type === "text" && typeof block.text === "string" ? block.text : "")
    .join("");
}

function thinkingPlainText(content: unknown): string {
  return contentBlocks(content)
    .map((block) => block.type === "thinking" && typeof block.thinking === "string" ? block.thinking : "")
    .filter((text) => text.trim().length > 0)
    .join("\n\n");
}

function toolActivitySnapshot(content: unknown): PickyActivitySummary | undefined {
  const summary = zeroActivitySummary();
  for (const block of contentBlocks(content)) {
    if (block.type !== "toolCall" || typeof block.name !== "string") continue;
    const category = categorizeTool(block.name);
    summary[category] += 1;
  }
  return hasActivity(summary) ? summary : undefined;
}

function contentBlocks(content: unknown): PiContentBlock[] {
  if (!Array.isArray(content)) return [];
  return content.filter((block): block is PiContentBlock => Boolean(block && typeof block === "object"));
}

function isoTimestamp(...candidates: unknown[]): string {
  for (const candidate of candidates) {
    if (typeof candidate === "string") {
      const date = new Date(candidate);
      if (!Number.isNaN(date.getTime())) return date.toISOString();
    }
    if (typeof candidate === "number" && Number.isFinite(candidate)) {
      const date = new Date(candidate);
      if (!Number.isNaN(date.getTime())) return date.toISOString();
    }
  }
  return new Date().toISOString();
}

function safeId(value: string): string {
  const safe = value.replace(/[^a-zA-Z0-9._-]/g, "_");
  return safe || stableHash(value);
}

function stableHash(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}
