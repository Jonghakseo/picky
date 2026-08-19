import type { BuiltPrompt } from "../prompt-builder.js";
import { logAgentd } from "../local-log.js";

export type PiPromptStreamingBehavior = "steer" | "followUp";

export interface PiQueueSnapshot {
  steering: readonly string[];
  followUp: readonly string[];
}

interface CompactionQueuedPrompt {
  prompt: BuiltPrompt;
  streamingBehavior: PiPromptStreamingBehavior;
}

interface PendingSlashSubmission {
  raw: string;
  beforeQueue: ReadonlyMap<string, number>;
}

interface FlushCompactionQueueOptions {
  willRetry: boolean;
  isCompacting: () => boolean;
  startPrompt: (prompt: BuiltPrompt, streamingBehavior: PiPromptStreamingBehavior) => Promise<void>;
  queuePrompt: (prompt: BuiltPrompt, streamingBehavior: PiPromptStreamingBehavior) => Promise<void>;
  onQueueChanged: () => void;
  onError: (error: unknown) => void;
}

/**
 * Owns the adapter-only queue state that Pi does not expose directly: prompts held during
 * compaction and reverse mappings for slash commands that Pi expands before enqueueing.
 */
export class PiPromptQueue {
  private compactionPrompts: CompactionQueuedPrompt[] = [];
  private isFlushingCompactionQueue = false;
  private slashExpansions = new Map<string, { raw: string; count: number }>();
  private pendingSlashSubmissions: PendingSlashSubmission[] = [];

  constructor(
    private readonly sessionId: string,
    private readonly slashExpansionCap: number,
  ) {}

  get hasCompactionPrompts(): boolean {
    return this.compactionPrompts.length > 0;
  }

  enqueueDuringCompaction(prompt: BuiltPrompt, streamingBehavior: PiPromptStreamingBehavior): void {
    this.compactionPrompts.push({ prompt, streamingBehavior });
  }

  discardCompactionPrompts(): boolean {
    if (this.compactionPrompts.length === 0) return false;
    this.compactionPrompts = [];
    return true;
  }

  combinedSnapshot(piQueues: PiQueueSnapshot): { steering: string[]; followUp: string[] } {
    return {
      steering: [
        ...piQueues.steering.map((entry) => this.translate(entry)),
        ...this.compactionPrompts.filter((entry) => entry.streamingBehavior === "steer").map((entry) => entry.prompt.text),
      ],
      followUp: [
        ...piQueues.followUp.map((entry) => this.translate(entry)),
        ...this.compactionPrompts.filter((entry) => entry.streamingBehavior === "followUp").map((entry) => entry.prompt.text),
      ],
    };
  }

  clear(clearedPiQueues: PiQueueSnapshot): { steering: string[]; followUp: string[] } {
    const queuedDuringCompaction = this.compactionPrompts;
    this.compactionPrompts = [];
    for (const entry of [...clearedPiQueues.steering, ...clearedPiQueues.followUp]) {
      this.slashExpansions.delete(this.normalizedExpansionKey(entry));
    }
    return {
      steering: [
        ...clearedPiQueues.steering.map((entry) => this.translate(entry)),
        ...queuedDuringCompaction.filter((entry) => entry.streamingBehavior === "steer").map((entry) => entry.prompt.text),
      ],
      followUp: [
        ...clearedPiQueues.followUp.map((entry) => this.translate(entry)),
        ...queuedDuringCompaction.filter((entry) => entry.streamingBehavior === "followUp").map((entry) => entry.prompt.text),
      ],
    };
  }

  translate(text: string): string {
    return this.slashExpansions.get(this.normalizedExpansionKey(text))?.raw ?? text;
  }

  registerAlias(expansion: string, rawText: string): void {
    this.registerSlashExpansion(expansion, rawText);
  }

  consumeExpansion(expansion: string): boolean {
    const expansionKey = this.normalizedExpansionKey(expansion);
    const existing = this.slashExpansions.get(expansionKey);
    if (!existing) return false;
    existing.count -= 1;
    if (existing.count <= 0) this.slashExpansions.delete(expansionKey);
    return true;
  }

  beginSlashSubmission(rawText: string, piQueues: PiQueueSnapshot): PendingSlashSubmission | undefined {
    if (!rawText.trim().startsWith("/")) return undefined;
    const counts = new Map<string, number>();
    for (const entry of [...piQueues.steering, ...piQueues.followUp]) {
      const key = this.normalizedExpansionKey(entry);
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    const pending = { raw: rawText.trim(), beforeQueue: counts };
    this.pendingSlashSubmissions.push(pending);
    return pending;
  }

  completeSlashSubmission(pending: PendingSlashSubmission | undefined, piQueues: PiQueueSnapshot): void {
    if (!pending) return;
    const after = [...piQueues.steering, ...piQueues.followUp];
    const hasPendingRaw = this.pendingSlashSubmissions.some((submission) => submission.raw === pending.raw);
    const seen = new Map<string, number>();
    for (const entry of after) {
      const entryKey = this.normalizedExpansionKey(entry);
      const occurrence = (seen.get(entryKey) ?? 0) + 1;
      seen.set(entryKey, occurrence);
      if (entryKey === pending.raw) continue;
      if (occurrence <= (pending.beforeQueue.get(entryKey) ?? 0)) continue;
      if (this.slashExpansions.has(entryKey) && !hasPendingRaw) continue;
      this.registerSlashExpansion(entry, pending.raw);
    }
    this.removePendingSlashSubmission(pending);
  }

  cancelSlashSubmission(pending: PendingSlashSubmission | undefined): void {
    this.removePendingSlashSubmission(pending);
  }

  rememberQueueUpdate(entries: readonly string[]): void {
    const seen = new Map<string, number>();
    for (const entry of entries) {
      const entryKey = this.normalizedExpansionKey(entry);
      const occurrence = (seen.get(entryKey) ?? 0) + 1;
      seen.set(entryKey, occurrence);
      if (!entryKey || this.slashExpansions.has(entryKey)) continue;
      const pending = this.pendingSlashSubmissions.find((submission) => submission.raw !== entryKey && occurrence > (submission.beforeQueue.get(entryKey) ?? 0));
      if (!pending) continue;
      this.registerSlashExpansion(entry, pending.raw);
      this.removePendingSlashSubmission(pending);
    }
  }

  async flushCompactionQueue(options: FlushCompactionQueueOptions): Promise<void> {
    if (this.isFlushingCompactionQueue || this.compactionPrompts.length === 0) return;
    this.isFlushingCompactionQueue = true;
    let restoredAfterPreflightFailure = false;
    const queuedPrompts = this.compactionPrompts;
    this.compactionPrompts = [];
    options.onQueueChanged();

    try {
      for (let index = 0; index < queuedPrompts.length; index += 1) {
        const queued = queuedPrompts[index]!;
        try {
          if (options.willRetry || index > 0) {
            await options.queuePrompt(queued.prompt, queued.streamingBehavior);
          } else {
            await options.startPrompt(queued.prompt, queued.streamingBehavior);
          }
        } catch (error) {
          this.compactionPrompts = [...queuedPrompts.slice(index), ...this.compactionPrompts];
          restoredAfterPreflightFailure = true;
          options.onQueueChanged();
          options.onError(error);
          return;
        }
      }
    } finally {
      this.isFlushingCompactionQueue = false;
      if (!restoredAfterPreflightFailure && !options.isCompacting() && this.compactionPrompts.length > 0) {
        queueMicrotask(() => void this.flushCompactionQueue(options));
      }
    }
  }

  private normalizedExpansionKey(text: string): string {
    return text.trim();
  }

  private registerSlashExpansion(expansion: string, rawText: string): void {
    const expansionKey = this.normalizedExpansionKey(expansion);
    const raw = rawText.trim();
    if (!expansionKey || !raw || expansionKey === raw) return;
    const existing = this.slashExpansions.get(expansionKey);
    if (existing) {
      existing.count += 1;
      return;
    }
    while (this.slashExpansions.size >= this.slashExpansionCap) {
      const oldestKey = this.slashExpansions.keys().next().value;
      if (oldestKey === undefined) break;
      this.slashExpansions.delete(oldestKey);
    }
    this.slashExpansions.set(expansionKey, { raw, count: 1 });
    logAgentd("pi slash expansion captured", {
      sessionId: this.sessionId,
      rawChars: raw.length,
      expansionChars: expansionKey.length,
    });
  }

  private removePendingSlashSubmission(pending: PendingSlashSubmission | undefined): void {
    if (!pending) return;
    const index = this.pendingSlashSubmissions.indexOf(pending);
    if (index >= 0) this.pendingSlashSubmissions.splice(index, 1);
  }
}

export function isRegisteredExtensionCommand(text: string, registeredCommands: readonly { invocationName: string }[]): boolean {
  const trimmed = text.trim();
  if (!trimmed.startsWith("/")) return false;
  const commandName = trimmed.slice(1).split(/\s/, 1)[0];
  return commandName !== undefined && commandName.length > 0
    && registeredCommands.some((command) => command.invocationName === commandName);
}
