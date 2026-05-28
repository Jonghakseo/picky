import { watch, type FSWatcher } from "node:fs";
import { open, type FileHandle } from "node:fs/promises";

export interface PiSessionTailEntry {
  type?: string;
  id?: string;
  parentId?: string | null;
  timestamp?: string;
  message?: { role?: string; content?: unknown };
}

export interface PiSessionTailWatcherOptions {
  /** Where to start reading from. Defaults to `"eof"` so existing transcript isn't replayed as fake transitions. */
  startAt?: "eof" | "beginning";
  /**
   * Fired when the watched file shrinks below the current cursor, which Pi triggers when a
   * `pi --session` TUI / `/compact` rewrites the JSONL. Used by the supervisor to invalidate
   * the in-memory Pi runtime handle so the next user input re-resumes from the (now
   * post-compaction) on-disk transcript instead of replaying the stale pre-compaction context.
   */
  onTruncate?: () => void | Promise<void>;
}

/**
 * Tails a Pi JSONL session file while an inline-terminal/Pickle overlay is driving
 * the session. Emits parsed JSONL entries to `onEntries` whenever the file grows so
 * the supervisor can derive live status transitions (running/completed) for the HUD
 * dock icon. Status inference is intentionally kept out of this module so the watcher
 * stays a pure file primitive.
 */
export class PiSessionTailWatcher {
  private fsWatcher?: FSWatcher;
  private handle?: FileHandle;
  private cursor = 0;
  private buffer = "";
  private inflight = false;
  private pending = false;
  private stopped = false;
  /**
   * Set when we detect a truncation/rotation (`size < cursor`). The next read drain
   * skips emit so a `pi --compact` rewrite isn't mis-read as a fresh
   * `completed -> running -> completed` sequence.
   */
  private suppressNextEmit = false;

  constructor(
    private readonly filePath: string,
    private readonly onEntries: (entries: PiSessionTailEntry[]) => void | Promise<void>,
    private readonly onError: (error: unknown) => void,
    private readonly options: PiSessionTailWatcherOptions = {},
  ) {}

  async start(): Promise<void> {
    this.handle = await open(this.filePath, "r");
    const stat = await this.handle.stat();
    this.cursor = this.options.startAt === "beginning" ? 0 : stat.size;
    this.fsWatcher = watch(this.filePath, { persistent: false }, () => {
      void this.scheduleRead();
    });
    this.fsWatcher.on("error", (error) => this.onError(error));
    // Pi may flush right after we attach but before the watcher arms; drain once
    // up front so the first turn doesn't sit invisible until the next write.
    void this.scheduleRead();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.fsWatcher?.close();
    this.fsWatcher = undefined;
    const handle = this.handle;
    this.handle = undefined;
    await handle?.close().catch(() => undefined);
  }

  private async scheduleRead(): Promise<void> {
    if (this.stopped) return;
    if (this.inflight) {
      this.pending = true;
      return;
    }
    this.inflight = true;
    try {
      do {
        this.pending = false;
        await this.drainNewBytes();
      } while (this.pending && !this.stopped);
    } catch (error) {
      this.onError(error);
    } finally {
      this.inflight = false;
    }
  }

  private async drainNewBytes(): Promise<void> {
    if (!this.handle || this.stopped) return;
    const { size } = await this.handle.stat();
    if (size < this.cursor) {
      // Truncation/rotation: re-anchor to the new EOF and skip the next emit so
      // we don't fabricate status transitions out of the rewritten prefix.
      this.cursor = size;
      this.buffer = "";
      this.suppressNextEmit = true;
      // Notify the host (supervisor) so it can invalidate any in-memory runtime
      // bound to the pre-rewrite state. Failures are routed to `onError` so the
      // tail loop itself never tears down on a flaky callback.
      const onTruncate = this.options.onTruncate;
      if (onTruncate) {
        try {
          await onTruncate();
        } catch (error) {
          this.onError(error);
        }
      }
      return;
    }
    if (size === this.cursor) return;
    const length = size - this.cursor;
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await this.handle.read({ buffer, position: this.cursor, length });
    this.cursor += bytesRead;
    this.buffer += buffer.slice(0, bytesRead).toString("utf8");
    const lines = this.buffer.split(/\r?\n/);
    this.buffer = lines.pop() ?? "";
    if (this.suppressNextEmit) {
      this.suppressNextEmit = false;
      return;
    }
    const entries: PiSessionTailEntry[] = [];
    for (const raw of lines) {
      const line = raw.trim();
      if (!line) continue;
      try {
        entries.push(JSON.parse(line) as PiSessionTailEntry);
      } catch {
        // Skip malformed line (partial flush mid-write); the trailing buffer carries the rest.
      }
    }
    if (entries.length > 0) await this.onEntries(entries);
  }
}
