import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { PickySessionMessage } from "../protocol.js";

interface PiSessionEntry {
  type?: string;
  id?: string;
  parentId?: string | null;
  timestamp?: string;
  message?: PiSessionMessage;
}

interface PiSessionMessage {
  role?: string;
  content?: unknown;
  timestamp?: number | string;
}

export interface PiTerminalSessionSyncResult {
  messages: PickySessionMessage[];
  activeLastMessageId?: string;
  baselineFound: boolean;
}

export async function readPiTerminalSessionMessages(sessionFilePath: string, baselinePiMessageId?: string): Promise<PiTerminalSessionSyncResult> {
  const text = await readFile(sessionFilePath, "utf8");
  const entries = parseMessageEntries(text);
  const activePath = activeMessagePath(entries);
  const activeLastMessageId = activePath.at(-1)?.id;
  const startIndex = baselinePiMessageId ? activePath.findIndex((entry) => entry.id === baselinePiMessageId) : -1;
  const baselineFound = baselinePiMessageId ? startIndex >= 0 : true;
  if (baselinePiMessageId && startIndex < 0) return { messages: [], activeLastMessageId, baselineFound };

  const candidates = baselinePiMessageId ? activePath.slice(startIndex + 1) : activePath;
  const messages = candidates.map(toPickySessionMessage).filter((message): message is PickySessionMessage => Boolean(message));
  return { messages, activeLastMessageId, baselineFound };
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
    .filter((entry): entry is PiSessionEntry => entry?.type === "message" && Boolean(entry.message));
}

function activeMessagePath(entries: PiSessionEntry[]): PiSessionEntry[] {
  let current = entries.at(-1);
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

function toPickySessionMessage(entry: PiSessionEntry): PickySessionMessage | undefined {
  const role = entry.message?.role;
  if (role !== "user" && role !== "assistant") return undefined;
  const text = plainText(entry.message?.content).trim();
  if (!text) return undefined;
  const piMessageId = entry.id ?? stableHash(`${role}:${entry.timestamp ?? ""}:${text}`);
  const createdAt = isoTimestamp(entry.timestamp, entry.message?.timestamp);
  if (role === "user") {
    return {
      id: `msg-pi-user-${safeId(piMessageId)}`,
      kind: "user_text",
      createdAt,
      originatedBy: "pi_extension",
      text,
    };
  }
  return {
    id: `msg-pi-agent-${safeId(piMessageId)}`,
    kind: "agent_text",
    createdAt,
    text,
  };
}

function plainText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      if (!block || typeof block !== "object") return "";
      const record = block as Record<string, unknown>;
      return record.type === "text" && typeof record.text === "string" ? record.text : "";
    })
    .join("");
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
