import { sliceUtf16Safe } from "../domain/safe-truncate.js";
import { logAgentd } from "../local-log.js";

/** Default model used for one-shot tool-output summarization. Configured by
 *  the user as a small, cheap reasoning model. Override via the constructor
 *  option or PICKY_REALTIME_SUMMARIZER_MODEL env var. */
export const DEFAULT_REALTIME_SUMMARIZER_MODEL = "openai-codex/gpt-5.3-codex-spark";

/** Hard upper bound on raw bytes we'll feed into the summarizer. Even with
 *  the 256 KB raw cap in realtime-fs-tools we trim again here to keep the
 *  summarizer prompt under any single-message ceiling and to avoid burning
 *  tokens on output that no longer carries new signal (e.g. a 2 MB JSON dump
 *  the user almost certainly does not need summarized in full). */
const SUMMARIZER_INPUT_MAX_BYTES = 64 * 1024;
const DEFAULT_TIMEOUT_MS = 6_000;

/** Hint about the source of the raw output the summarizer is being asked to
 *  compact. Drives the system prompt template so the model knows whether to
 *  format the summary as a shell-command digest or a file-content digest. */
export type RealtimeSummaryKind = "bash" | "read";

export interface RealtimeSummaryRequest {
  kind: RealtimeSummaryKind;
  /** Original command for kind === "bash" */
  command?: string;
  /** Original file path for kind === "read" */
  path?: string;
  /** Working directory if relevant */
  cwd?: string;
  /** Exit code for kind === "bash" */
  exitCode?: number | null;
  /** Captured stdout+stderr (bash) or file content (read). May be truncated by caller. */
  rawOutput: string;
}

export interface RealtimeSummarizerCompleterRequest {
  model: string;
  systemPrompt: string;
  userPrompt: string;
  signal: AbortSignal;
}

/**
 * Pluggable model-call surface so we can swap a real pi-ai backed completer
 * for a stub in tests without dragging the SDK into the test runtime. The
 * implementation MUST resolve to a short summary string. Throwing or
 * resolving to an empty string signals "no summary available" and the
 * caller falls back to the truncated tail.
 */
export type RealtimeSummarizerCompleter = (
  request: RealtimeSummarizerCompleterRequest,
) => Promise<string>;

export interface RealtimeOutputSummarizerOptions {
  completer: RealtimeSummarizerCompleter;
  model?: string;
  timeoutMs?: number;
  inputMaxBytes?: number;
  now?: () => number;
}

const SYSTEM_PROMPT_BASH = [
  "You compact long shell command outputs into a 2-4 line digest for a voice assistant.",
  "Preserve key facts: exit status, file/path names, counts, error messages, branch names, IDs.",
  "Never speculate beyond the captured output. Reply with the digest only — no preamble, no markdown.",
].join("\n");

const SYSTEM_PROMPT_READ = [
  "You compact long file contents into a 2-4 line digest for a voice assistant.",
  "Preserve key facts: structure (sections, top-level keys), important values, error/warning markers, total length if obvious.",
  "Never invent content. Reply with the digest only — no preamble, no markdown.",
].join("\n");

export class RealtimeOutputSummarizer {
  private model: string;
  private readonly completer: RealtimeSummarizerCompleter;
  private readonly timeoutMs: number;
  private readonly inputMaxBytes: number;
  private readonly now: () => number;

  constructor(options: RealtimeOutputSummarizerOptions) {
    this.completer = options.completer;
    this.model = options.model?.trim() || DEFAULT_REALTIME_SUMMARIZER_MODEL;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.inputMaxBytes = options.inputMaxBytes ?? SUMMARIZER_INPUT_MAX_BYTES;
    this.now = options.now ?? (() => Date.now());
  }

  setModel(model: string): void {
    const trimmed = model.trim();
    if (trimmed) this.model = trimmed;
  }

  getModel(): string {
    return this.model;
  }

  /** Best-effort summary. Resolves to undefined on timeout, missing auth, or
   *  any thrown error so the caller can keep going with just the truncated
   *  tail. Never throws. */
  async summarize(request: RealtimeSummaryRequest): Promise<string | undefined> {
    const raw = (request.rawOutput ?? "").trim();
    if (!raw) return undefined;
    const trimmedInput = clampByBytes(raw, this.inputMaxBytes);
    const systemPrompt = request.kind === "bash" ? SYSTEM_PROMPT_BASH : SYSTEM_PROMPT_READ;
    const userPrompt = buildUserPrompt(request, trimmedInput);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    if (typeof (timer as { unref?: () => void }).unref === "function") {
      (timer as { unref: () => void }).unref();
    }
    const startedAt = this.now();
    try {
      const text = await this.completer({
        model: this.model,
        systemPrompt,
        userPrompt,
        signal: controller.signal,
      });
      const trimmed = (text ?? "").trim();
      if (!trimmed) {
        logAgentd("realtime summarizer empty", { model: this.model, kind: request.kind });
        return undefined;
      }
      const elapsed = this.now() - startedAt;
      logAgentd("realtime summarizer ok", { model: this.model, kind: request.kind, chars: trimmed.length, elapsedMs: elapsed });
      return trimmed;
    } catch (error) {
      const elapsed = this.now() - startedAt;
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("realtime summarizer failed", { model: this.model, kind: request.kind, elapsedMs: elapsed, error: message });
      return undefined;
    } finally {
      clearTimeout(timer);
    }
  }
}

function buildUserPrompt(request: RealtimeSummaryRequest, body: string): string {
  if (request.kind === "bash") {
    const headerLines = ["[bash output to summarize]"];
    if (request.command) headerLines.push(`Command: ${request.command}`);
    if (request.cwd) headerLines.push(`Cwd: ${request.cwd}`);
    if (request.exitCode !== undefined && request.exitCode !== null) headerLines.push(`Exit code: ${request.exitCode}`);
    return `${headerLines.join("\n")}\n\n---\n${body}`;
  }
  const headerLines = ["[file content to summarize]"];
  if (request.path) headerLines.push(`Path: ${request.path}`);
  return `${headerLines.join("\n")}\n\n---\n${body}`;
}

function clampByBytes(text: string, maxBytes: number): string {
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text;
  let low = 0;
  let high = text.length;
  while (low < high) {
    const mid = Math.floor((low + high + 1) / 2);
    const slice = sliceUtf16Safe(text, mid);
    if (Buffer.byteLength(slice, "utf8") <= maxBytes) low = mid; else high = mid - 1;
  }
  return sliceUtf16Safe(text, low);
}
