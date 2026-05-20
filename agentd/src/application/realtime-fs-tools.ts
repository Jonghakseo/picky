import { spawn } from "node:child_process";
import { appendFile, readFile, stat, writeFile, mkdir } from "node:fs/promises";
import { dirname, isAbsolute, resolve } from "node:path";
import { sliceUtf16Safe } from "../domain/safe-truncate.js";

// Tight caps matching the "1-shot quick answer" UX agreed with the user.
// Outputs over these limits are tail-truncated for the realtime model and
// the raw bytes are routed to the summarizer + on-disk spill.
export const REALTIME_READ_DEFAULT_LIMIT_LINES = 40;
export const REALTIME_READ_HARD_BYTES = 2 * 1024;
export const REALTIME_READ_RAW_CAP_BYTES = 256 * 1024;

export const REALTIME_BASH_TAIL_BYTES = 2 * 1024;
export const REALTIME_BASH_TIMEOUT_MS = 10_000;
export const REALTIME_BASH_RAW_CAP_BYTES = 256 * 1024;

export type RealtimeWriteMode = "overwrite" | "append";

export interface RealtimeReadRequest {
  path: string;
  offset?: number;
  limit?: number;
  cwd?: string;
}

export interface RealtimeReadResult {
  path: string;
  resolvedPath: string;
  /** Body delivered to the realtime model (already byte-capped). */
  content: string;
  /** Full requested slice before byte-cap truncation — used by the summarizer. */
  fullContent: string;
  totalBytes: number;
  totalLines: number;
  /** True when EITHER the byte cap was hit OR the file has more lines than the requested slice. */
  truncated: boolean;
  /** True when the byte cap chopped bytes off the requested slice. Signals that
   *  the model is missing visible content and a summary call is worthwhile. */
  byteTruncated: boolean;
  offset: number;
  limit: number;
}

export interface RealtimeBashRequest {
  command: string;
  cwd?: string;
}

export interface RealtimeBashResult {
  command: string;
  cwd: string;
  exitCode: number | null;
  output: string;
  fullOutput: string;
  totalBytes: number;
  truncated: boolean;
  durationMs: number;
  timedOut: boolean;
  signal: string | null;
}

export interface RealtimeWriteRequest {
  path: string;
  content: string;
  mode?: RealtimeWriteMode;
  cwd?: string;
  createDirectories?: boolean;
}

export interface RealtimeWriteResult {
  path: string;
  resolvedPath: string;
  bytesWritten: number;
  mode: RealtimeWriteMode;
}

interface ReadOptions {
  maxLines?: number;
  maxBytes?: number;
  rawCapBytes?: number;
}

interface BashOptions {
  tailBytes?: number;
  timeoutMs?: number;
  rawCapBytes?: number;
  signal?: AbortSignal;
}

export async function executeRealtimeRead(request: RealtimeReadRequest, options: ReadOptions = {}): Promise<RealtimeReadResult> {
  const trimmedPath = request.path?.trim();
  if (!trimmedPath) throw new Error("read: path is required");
  const resolved = resolvePath(trimmedPath, request.cwd);
  const stats = await stat(resolved);
  if (!stats.isFile()) throw new Error(`read: ${resolved} is not a regular file`);
  const rawCap = options.rawCapBytes ?? REALTIME_READ_RAW_CAP_BYTES;
  const buffer = await readFile(resolved);
  const totalBytes = buffer.byteLength;
  const rawString = buffer.byteLength > rawCap
    ? buffer.subarray(0, rawCap).toString("utf8")
    : buffer.toString("utf8");
  const allLines = rawString.split(/\r?\n/);
  // readFile + split("\n") produces a trailing empty element when the file
  // ends with a newline. Drop it so totalLines matches a user's `wc -l`
  // intuition for non-truncated reads.
  if (allLines.length > 0 && allLines[allLines.length - 1] === "" && !rawString.endsWith("\r")) {
    allLines.pop();
  }
  const offset = normalizeOffset(request.offset);
  const limit = normalizeLimit(request.limit, options.maxLines ?? REALTIME_READ_DEFAULT_LIMIT_LINES);
  const slice = allLines.slice(offset, offset + limit);
  const fullContent = slice.join("\n");
  const maxBytes = options.maxBytes ?? REALTIME_READ_HARD_BYTES;
  const byteTruncated = Buffer.byteLength(fullContent, "utf8") > maxBytes;
  const content = byteTruncated ? sliceUtf16Safe(fullContent, charBudgetForBytes(fullContent, maxBytes)) : fullContent;
  const truncated = byteTruncated
    || allLines.length > offset + limit
    || totalBytes > rawCap;
  return {
    path: trimmedPath,
    resolvedPath: resolved,
    content,
    fullContent,
    totalBytes,
    totalLines: allLines.length,
    truncated,
    byteTruncated,
    offset,
    limit,
  };
}

export async function executeRealtimeBash(request: RealtimeBashRequest, options: BashOptions = {}): Promise<RealtimeBashResult> {
  const command = request.command?.trim();
  if (!command) throw new Error("bash: command is required");
  const cwd = resolveBashCwd(request.cwd);
  const tailBytes = options.tailBytes ?? REALTIME_BASH_TAIL_BYTES;
  const timeoutMs = options.timeoutMs ?? REALTIME_BASH_TIMEOUT_MS;
  const rawCap = options.rawCapBytes ?? REALTIME_BASH_RAW_CAP_BYTES;

  const child = spawn("/bin/bash", ["-lc", command], {
    cwd,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const chunks: Buffer[] = [];
  let totalBytes = 0;
  let rawCappedHit = false;
  const append = (chunk: Buffer) => {
    totalBytes += chunk.byteLength;
    if (rawCappedHit) return;
    const remaining = rawCap - sumLengths(chunks);
    if (remaining <= 0) {
      rawCappedHit = true;
      return;
    }
    if (chunk.byteLength <= remaining) {
      chunks.push(chunk);
    } else {
      chunks.push(chunk.subarray(0, remaining));
      rawCappedHit = true;
    }
  };
  child.stdout?.on("data", (chunk: Buffer) => append(chunk));
  child.stderr?.on("data", (chunk: Buffer) => append(chunk));

  const startedAt = Date.now();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGTERM");
    // Hard kill if the process refuses to exit within a small grace window.
    setTimeout(() => { try { child.kill("SIGKILL"); } catch { /* ignore */ } }, 500).unref();
  }, timeoutMs);
  if (typeof timer.unref === "function") timer.unref();

  let abortHandler: (() => void) | undefined;
  if (options.signal) {
    if (options.signal.aborted) {
      child.kill("SIGTERM");
    } else {
      abortHandler = () => {
        timedOut = true;
        child.kill("SIGTERM");
      };
      options.signal.addEventListener("abort", abortHandler, { once: true });
    }
  }

  const { code, signal } = await new Promise<{ code: number | null; signal: string | null }>((resolveExit) => {
    child.on("close", (exitCode, exitSignal) => resolveExit({ code: exitCode, signal: exitSignal }));
    child.on("error", () => resolveExit({ code: null, signal: null }));
  });
  clearTimeout(timer);
  if (options.signal && abortHandler) options.signal.removeEventListener("abort", abortHandler);

  const durationMs = Date.now() - startedAt;
  const rawBuffer = Buffer.concat(chunks);
  const fullOutput = rawBuffer.toString("utf8");
  const truncated = rawCappedHit || Buffer.byteLength(fullOutput, "utf8") > tailBytes;
  const output = truncated ? tailOfString(fullOutput, tailBytes) : fullOutput;

  return {
    command,
    cwd,
    exitCode: code,
    output,
    fullOutput,
    totalBytes,
    truncated,
    durationMs,
    timedOut,
    signal,
  };
}

export async function executeRealtimeWrite(request: RealtimeWriteRequest): Promise<RealtimeWriteResult> {
  const trimmedPath = request.path?.trim();
  if (!trimmedPath) throw new Error("write: path is required");
  if (typeof request.content !== "string") throw new Error("write: content is required");
  const mode: RealtimeWriteMode = request.mode === "append" ? "append" : "overwrite";
  const resolved = resolvePath(trimmedPath, request.cwd);
  if (request.createDirectories !== false) {
    await mkdir(dirname(resolved), { recursive: true });
  }
  const bytes = Buffer.byteLength(request.content, "utf8");
  if (mode === "append") {
    await appendFile(resolved, request.content, "utf8");
  } else {
    await writeFile(resolved, request.content, "utf8");
  }
  return { path: trimmedPath, resolvedPath: resolved, bytesWritten: bytes, mode };
}

function resolvePath(p: string, cwd: string | undefined): string {
  if (isAbsolute(p)) return resolve(p);
  return resolve(cwd ?? process.cwd(), p);
}

function resolveBashCwd(cwd: string | undefined): string {
  const candidate = cwd?.trim();
  if (!candidate) return process.cwd();
  return isAbsolute(candidate) ? candidate : resolve(process.cwd(), candidate);
}

function normalizeOffset(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  return Math.max(0, Math.floor(value));
}

function normalizeLimit(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  const floored = Math.floor(value);
  return floored > 0 ? Math.min(floored, fallback * 4) : fallback;
}

function charBudgetForBytes(text: string, maxBytes: number): number {
  // UTF-16 char length is an over-estimate of UTF-8 byte length only for ASCII;
  // for multi-byte sequences each char can be up to 3 bytes (4 for surrogate
  // pairs which count as 2 chars). Walk down until the encoded length fits.
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text.length;
  let low = 0;
  let high = text.length;
  while (low < high) {
    const mid = Math.floor((low + high + 1) / 2);
    const slice = sliceUtf16Safe(text, mid);
    if (Buffer.byteLength(slice, "utf8") <= maxBytes) low = mid; else high = mid - 1;
  }
  return low;
}

function tailOfString(text: string, maxBytes: number): string {
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text;
  // Walk in from the end so byte budget is exact and we avoid splitting a
  // multi-byte code point. UTF-16 char step is fine because Buffer.byteLength
  // re-encodes safely from any char position.
  let start = 0;
  let end = text.length;
  while (start < end) {
    const mid = Math.floor((start + end) / 2);
    if (Buffer.byteLength(text.slice(mid), "utf8") <= maxBytes) end = mid; else start = mid + 1;
  }
  return text.slice(start);
}

function sumLengths(chunks: Buffer[]): number {
  let total = 0;
  for (const chunk of chunks) total += chunk.byteLength;
  return total;
}
