import { createHash, randomUUID } from "node:crypto";
import type { Stats } from "node:fs";
import { open, stat, type FileHandle } from "node:fs/promises";

export const TOOL_HISTORY_MAX_RECORD_BYTES = 8 * 1024 * 1024;
const MAX_FILE_BYTES = 256 * 1024 * 1024;
const MAX_RECORDS = 100_000;
const PAGE_UNITS = 32768;
const MAX_INDEXES = 4;
const MAX_CURSORS = 128;
export type ToolHistoryPart = "arguments" | "result";
export interface ToolHistoryDetail {
  status: "ready" | "pending" | "unavailable" | "sourceChanged" | "unsupported";
  text?: string;
  nextCursor?: string;
  reason?: string;
  attachmentsOmitted?: boolean;
}
interface Location { offset: number; length: number; slot?: number }
interface Index {
  identity: string; generation: string; size: number; mtimeMs: number; offset: number; records: number;
  calls: Map<string, Location | null>; results: Map<string, Location | null>; error?: string;
}
interface Cursor { path: string; generation: string; tool: string; part: ToolHistoryPart; digest: string; offset: number }
type ObjectValue = Record<string, unknown>;
const object = (value: unknown): ObjectValue | undefined => value !== null && typeof value === "object" && !Array.isArray(value) ? value as ObjectValue : undefined;
const unavailable = (reason: string): ToolHistoryDetail => ({ status: "unavailable", reason });

/** Read-only execution-history lookup, independent of the currently selected Pi branch. */
export class PiToolHistoryReader {
  private readonly indexes = new Map<string, Index>();
  private readonly cursors = new Map<string, Cursor>();
  // One bounded scan at a time also prevents concurrent requests from advancing the same index twice.
  private queue: Promise<unknown> = Promise.resolve();

  read(path: string, tool: string, part: ToolHistoryPart, cursor?: string): Promise<ToolHistoryDetail> {
    const work = this.queue.then(() => this.readPage(path, tool, part, cursor));
    this.queue = work.catch(() => undefined);
    return work;
  }

  private async readPage(path: string, tool: string, part: ToolHistoryPart, token?: string): Promise<ToolHistoryDetail> {
    let file: FileHandle | undefined;
    try {
      file = await open(path, "r");
      const before = await file.stat();
      if (!before.isFile()) return unavailable("notRegularFile");
      if (before.size > MAX_FILE_BYTES) return unavailable("fileTooLarge");
      const identity = fileIdentity(before);
      const index = this.indexFor(path, before);
      await this.scan(file, index, before.size);
      index.size = before.size; index.mtimeMs = before.mtimeMs;
      if (index.error) return unavailable(index.error);
      const selection = this.select(index, path, tool, part, token);
      if ("status" in selection) return selection;
      const { location, continuation } = selection;
      const record = await this.record(file, location);
      const rendered = renderRecord(record, location, tool, part);
      if ("status" in rendered) return rendered;
      const { text, attachmentsOmitted } = rendered;
      const after = await stat(path);
      if (fileIdentity(after) !== identity || fileRewritten(before, after)) {
        this.indexes.delete(path);
        return unavailable("sourceReplaced");
      }
      return this.page(text, attachmentsOmitted, path, index, tool, part, continuation);
    } catch (error) {
      return unavailable((error as NodeJS.ErrnoException).code === "ENOENT" ? "sourceMissing" : "unreadableSource");
    } finally { await file?.close(); }
  }

  private indexFor(path: string, before: Stats): Index {
    const identity = fileIdentity(before);
    let index = this.indexes.get(path);
    if (!index || index.identity !== identity || fileRewritten(index, before)) {
      index = { identity, generation: randomUUID(), size: before.size, mtimeMs: before.mtimeMs, offset: 0, records: 0, calls: new Map(), results: new Map() };
    }
    this.indexes.delete(path);
    this.indexes.set(path, index);
    while (this.indexes.size > MAX_INDEXES) this.indexes.delete(this.indexes.keys().next().value!);
    return index;
  }

  private select(index: Index, path: string, tool: string, part: ToolHistoryPart, token?: string): ToolHistoryDetail | { location: Location; continuation?: Cursor } {
    const call = index.calls.get(tool);
    const result = index.results.get(tool);
    if (call === null || result === null) return unavailable("ambiguousToolCall");
    const location = part === "arguments" ? call : result;
    const continuation = token ? this.cursors.get(token) : undefined;
    if (token && (!continuation || continuation.path !== path || continuation.generation !== index.generation || continuation.tool !== tool || continuation.part !== part)) return unavailable("invalidCursor");
    if (!call || !location) return { status: "pending", reason: "notPersisted" };
    return { location, continuation };
  }

  private page(text: string, attachmentsOmitted: boolean, path: string, index: Index, tool: string, part: ToolHistoryPart, continuation?: Cursor): ToolHistoryDetail {
    const digest = createHash("sha256").update(text).digest("hex");
    if (continuation && continuation.digest !== digest) return unavailable("invalidCursor");
    const start = continuation?.offset ?? 0;
    let end = Math.min(start + PAGE_UNITS, text.length);
    if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end -= 1;
    let nextCursor: string | undefined;
    if (end < text.length) {
      nextCursor = randomUUID();
      this.cursors.set(nextCursor, { path, generation: index.generation, tool, part, digest, offset: end });
      while (this.cursors.size > MAX_CURSORS) this.cursors.delete(this.cursors.keys().next().value!);
    }
    return { status: "ready", text: text.slice(start, end), ...(nextCursor ? { nextCursor } : {}), ...(attachmentsOmitted ? { attachmentsOmitted: true } : {}) };
  }

  private async record(file: FileHandle, location: Location): Promise<ObjectValue> {
    const buffer = Buffer.alloc(location.length);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, location.offset);
    if (bytesRead !== buffer.length) throw new Error("Source changed during read");
    const parsed = object(JSON.parse(buffer.toString("utf8")));
    if (!parsed) throw new Error("Invalid record");
    return parsed;
  }

  private indexRecord(index: Index, raw: string, location: Location): void {
    try {
      const record = object(JSON.parse(raw));
      if (!record) throw new Error("Invalid record");
      const message = record.type === "message" ? object(record.message) : undefined;
      if (message?.role === "assistant" && Array.isArray(message.content)) {
        for (const [slot, value] of message.content.entries()) {
          const entry = object(value);
          if (entry?.type !== "toolCall" || typeof entry.id !== "string") continue;
          if (index.calls.size >= MAX_RECORDS) { index.error = "tooManyToolCalls"; return; }
          index.calls.set(entry.id, index.calls.has(entry.id) ? null : { ...location, slot });
        }
      } else if (message?.role === "toolResult" && typeof message.toolCallId === "string") {
        index.results.set(message.toolCallId, index.results.has(message.toolCallId) ? null : location);
      }
    } catch { index.error = "malformedRecord"; }
  }

  private async scan(file: FileHandle, index: Index, size: number): Promise<void> {
    if (index.error) return;
    let position = index.offset;
    let fragments: Buffer[] = [];
    let length = 0;
    while (position < size) {
      const chunk = Buffer.alloc(Math.min(64 * 1024, size - position));
      const { bytesRead } = await file.read(chunk, 0, chunk.length, position);
      if (!bytesRead) break;
      let start = 0;
      for (let cursor = 0; cursor < bytesRead; cursor += 1) {
        if (chunk[cursor] !== 10) continue;
        const piece = chunk.subarray(start, cursor);
        length += piece.length;
        if (length > TOOL_HISTORY_MAX_RECORD_BYTES) { index.error = "recordTooLarge"; return; }
        fragments.push(piece);
        const location = { offset: index.offset, length };
        const raw = Buffer.concat(fragments, length).toString("utf8");
        if (++index.records > MAX_RECORDS) { index.error = "tooManyRecords"; return; }
        this.indexRecord(index, raw, location);
        if (index.error) return;
        index.offset = position + cursor + 1;
        fragments = []; length = 0; start = cursor + 1;
      }
      const rest = chunk.subarray(start, bytesRead);
      length += rest.length;
      if (length > TOOL_HISTORY_MAX_RECORD_BYTES) { index.error = "recordTooLarge"; return; }
      fragments.push(rest);
      position += bytesRead;
    }
    // Leave an incomplete trailing record uncommitted so a later append retries it.
  }
}

function fileIdentity(value: Stats): string { return `${value.dev}:${value.ino}:${value.birthtimeMs}`; }
function fileRewritten(before: { size: number; mtimeMs: number }, after: Stats): boolean {
  return after.size < before.size || (after.size === before.size && after.mtimeMs !== before.mtimeMs);
}

function renderRecord(record: ObjectValue, location: Location, tool: string, part: ToolHistoryPart): ToolHistoryDetail | { text: string; attachmentsOmitted: boolean } {
  const message = object(record.message);
  if (!message) return unavailable("malformedRecord");
  if (part === "arguments") {
    const savedCall = Array.isArray(message.content) ? object(message.content[location.slot!]) : undefined;
    if (!savedCall || savedCall.id !== tool || !("arguments" in savedCall)) return unavailable("malformedRecord");
    const text = JSON.stringify(savedCall.arguments, null, 2);
    return text === undefined ? unavailable("malformedRecord") : { text, attachmentsOmitted: false };
  }
  if (message.toolCallId !== tool || !Array.isArray(message.content)) return unavailable("malformedRecord");
  let attachmentsOmitted = false;
  const text = message.content.map((block: unknown) => {
    const content = object(block);
    if (content?.type === "text" && typeof content.text === "string") return content.text;
    return JSON.stringify(block, (key, item: unknown) => {
      const entry = object(item);
      if (entry?.type === "image") {
        attachmentsOmitted = true;
        return { type: "image", mimeType: entry.mimeType, omitted: true };
      }
      // Unknown attachment types may also carry embedded binary payloads.
      if ((key === "data" || key === "blob") && typeof item === "string") {
        attachmentsOmitted = true;
        return "[attachment omitted]";
      }
      if (typeof item === "string" && /^data:[^,]*;base64,/i.test(item)) {
        attachmentsOmitted = true;
        return "[attachment omitted]";
      }
      return item;
    }, 2);
  }).join("\n\n");
  return { text, attachmentsOmitted };
}
