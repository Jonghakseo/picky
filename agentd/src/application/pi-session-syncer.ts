import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { hasActivity, zeroActivitySummary } from "../domain/activity-summary.js";
import { categorizeTool } from "../domain/tool-categorizer.js";
import { toolImageMessage } from "../domain/tool-image-message.js";
import { resolveTodoStateFromPiSessionEntries } from "../domain/todo-state.js";
import type { PickyActivitySummary, PickySessionMessage, PickyTodoState } from "../protocol.js";

export interface PiSessionEntry {
  type?: string;
  id?: string;
  parentId?: string | null;
  timestamp?: string;
  customType?: string;
  data?: unknown;
  cwd?: string;
  message?: PiSessionMessage;
}

export interface PiSessionMessage {
  role?: string;
  content?: unknown;
  timestamp?: number | string;
  stopReason?: string;
  errorMessage?: string;
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
}

interface PiContentBlock {
  type?: string;
  text?: string;
  thinking?: string;
  name?: string;
  id?: string;
  arguments?: unknown;
  mimeType?: string;
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

export function piSessionEntriesToPickyMessages(entries: readonly PiSessionEntry[], cwd?: string): PickySessionMessage[] {
  // `read` image results carry no path; pair them with the earlier tool call in this batch.
  const readPathsByToolCallId = new Map<string, string>();
  return entries.flatMap((entry) => {
    if (entry.message?.role === "assistant") rememberReadPaths(entry.message.content, cwd, readPathsByToolCallId);
    if (entry.message?.role === "toolResult") return toolImageMessages(entry, readPathsByToolCallId);
    return toPickySessionMessages(entry);
  });
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
  const cwd = entries.find((entry) => entry.type === "session")?.cwd;
  const messages = piSessionEntriesToPickyMessages(candidates, cwd);
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
    // Pi stores submitted screenshots as image content blocks. Import their count so the HUD keeps
    // the same attachment evidence it had before the message came back through Pi's JSONL. Only
    // the count travels; base64 image data stays in the Pi session file.
    const attachedImagesCount = imageBlockCount(entry.message?.content);
    return [{
      id: `msg-pi-user-${safePiMessageId}`,
      kind: "user_text",
      createdAt,
      originatedBy: "pi_extension",
      text,
      ...(attachedImagesCount > 0 ? { attachedImagesCount } : {}),
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
    summary[category] = (summary[category] ?? 0) + 1;
  }
  return hasActivity(summary) ? summary : undefined;
}

function rememberReadPaths(content: unknown, cwd: string | undefined, paths: Map<string, string>): void {
  for (const block of contentBlocks(content)) {
    if (block.type !== "toolCall" || block.name !== "read" || typeof block.id !== "string") continue;
    const args = block.arguments && typeof block.arguments === "object" ? block.arguments as Record<string, unknown> : {};
    const path = resolveToolPath(args.path, cwd);
    if (path) paths.set(block.id, path);
  }
}

function resolveToolPath(rawPath: unknown, cwd: string | undefined): string | undefined {
  if (typeof rawPath !== "string" || !rawPath || rawPath.includes("\0")) return undefined;
  const expanded = rawPath === "~" || rawPath.startsWith("~/") ? `${homedir()}${rawPath.slice(1)}` : rawPath;
  if (isAbsolute(expanded)) return expanded;
  return cwd ? resolve(cwd, expanded) : undefined;
}

function toolImageMessages(entry: PiSessionEntry, readPaths: ReadonlyMap<string, string>): PickySessionMessage[] {
  const message = entry.message;
  const toolCallId = message?.toolCallId;
  if (!message || message.isError || message.toolName !== "read" || !toolCallId) return [];
  const path = readPaths.get(toolCallId);
  const image = contentBlocks(message.content).find((block) => block.type === "image");
  if (!path || !image) return [];
  return [toolImageMessage(
    `msg-pi-tool-image-${safeId(toolCallId)}`,
    isoTimestamp(entry.timestamp, message.timestamp),
    { toolCallId, toolName: "read", path, ...(typeof image.mimeType === "string" ? { mimeType: image.mimeType } : {}) },
  )];
}

function imageBlockCount(content: unknown): number {
  return contentBlocks(content).filter((block) => block.type === "image").length;
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
