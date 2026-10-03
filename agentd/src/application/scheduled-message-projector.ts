import { readFile } from "node:fs/promises";
import { watch, type FSWatcher } from "node:fs";
import type { PickyScheduledMessage } from "../protocol.js";
import {
  delayedActionStoreDir,
  delayedActionStoreFileName,
  parseDelayedActionStore,
} from "../domain/delayed-action-store.js";
import { logAgentd } from "../local-log.js";

const WATCH_RETRY_COOLDOWN_MS = 1_000;

export interface ScheduledMessageProjectorOptions {
  /** Overridden in tests; production resolves `PI_DELAYED_ACTION_DIR` at call time. */
  dir?: () => string;
  readStoreFile?: (path: string) => Promise<string>;
  watchDir?: (dir: string, listener: () => void) => () => void;
  /** Coalesces the write + rename burst the extension performs on every mutation. */
  debounceMs?: number;
  /** Shortest gap between two attempts to watch a directory that does not exist yet. */
  watchRetryCooldownMs?: number;
}

/**
 * Projects the delayed-action extension's on-disk schedule into session state.
 *
 * The extension keeps one JSON file per Pi session and rewrites it on every schedule,
 * cancel, and fire. Watching the directory (rather than polling) keeps the projection
 * live for messages that fire on their own, while explicit refreshes after Picky-issued
 * commands remove the wait for the watcher.
 */
export class ScheduledMessageProjector {
  private readonly tracked = new Map<string, string>();
  private watcher: (() => void) | undefined;
  private watchedDir: string | undefined;
  private debounceTimer: ReturnType<typeof setTimeout> | undefined;
  private disposed = false;
  private lastFailedWatchAttempt: { dir: string; at: number } | undefined;

  constructor(
    private readonly onChange: (sessionId: string, messages: PickyScheduledMessage[]) => void | Promise<void>,
    private readonly options: ScheduledMessageProjectorOptions = {},
  ) {}

  private get dir(): string {
    return this.options.dir?.() ?? delayedActionStoreDir();
  }

  /** Associates a Picky session with the Pi session id the extension persists under. */
  async track(sessionId: string, piSessionId: string | undefined): Promise<void> {
    if (this.disposed) return;
    if (!piSessionId) {
      await this.untrack(sessionId);
      return;
    }
    if (this.tracked.get(sessionId) === piSessionId) return;
    this.tracked.set(sessionId, piSessionId);
    this.ensureWatching({ force: true });
    await this.refresh(sessionId);
  }

  async untrack(sessionId: string): Promise<void> {
    if (!this.tracked.delete(sessionId)) return;
    if (this.tracked.size === 0) this.stopWatching();
    // A detached runtime has no live schedule to manage, so the surface must empty out.
    await this.onChange(sessionId, []);
  }

  /**
   * Reads one session's store file and publishes it. The projector reports unconditionally
   * and leaves deduplication to the session owner, so a schedule persisted by a previous
   * daemon run cannot survive as a stale projection when the store file is already gone.
   */
  async refresh(sessionId: string): Promise<PickyScheduledMessage[]> {
    const piSessionId = this.tracked.get(sessionId);
    if (!piSessionId) return [];
    const read = await this.read(piSessionId);
    // The store directory is created by the extension's first write, so watching usually fails
    // on the first attempt. A readable store proves it exists now, which is worth a retry right
    // away; a session with nothing scheduled refreshes often and only retries on a cooldown.
    this.ensureWatching({ force: read.found });
    await this.onChange(sessionId, read.messages);
    return read.messages;
  }

  async refreshAll(): Promise<void> {
    for (const sessionId of [...this.tracked.keys()]) {
      await this.refresh(sessionId).catch(() => undefined);
    }
  }

  dispose(): void {
    this.disposed = true;
    this.tracked.clear();
    this.stopWatching();
  }

  private async read(piSessionId: string): Promise<{ messages: PickyScheduledMessage[]; found: boolean }> {
    const fileName = delayedActionStoreFileName(piSessionId);
    if (!fileName) return { messages: [], found: false };
    const path = `${this.dir}/${fileName}`;
    try {
      const raw = this.options.readStoreFile ? await this.options.readStoreFile(path) : await readFile(path, "utf8");
      return { messages: parseDelayedActionStore(raw), found: true };
    } catch {
      // Absent file is the common case: the session simply has nothing scheduled.
      return { messages: [], found: false };
    }
  }

  private ensureWatching(options: { force?: boolean } = {}): void {
    if (this.disposed) return;
    const dir = this.dir;
    if (this.watcher && this.watchedDir === dir) return;
    // Without a cooldown, every refresh of a session with no store file would pay for a failing
    // watch and write another log line.
    const cooldown = this.options.watchRetryCooldownMs ?? WATCH_RETRY_COOLDOWN_MS;
    const lastFailure = this.lastFailedWatchAttempt;
    if (!options.force && !this.watcher && lastFailure?.dir === dir && Date.now() - lastFailure.at < cooldown) return;
    this.stopWatching();
    const listener = () => this.scheduleRefreshAll();
    try {
      this.watcher = this.options.watchDir
        ? this.options.watchDir(dir, listener)
        : nodeWatch(dir, listener);
      this.watchedDir = dir;
      this.lastFailedWatchAttempt = undefined;
    } catch (error) {
      // No store directory yet. The next track()/refresh() after a schedule command
      // retries, and Picky-issued commands refresh explicitly anyway.
      this.lastFailedWatchAttempt = { dir, at: Date.now() };
      logAgentd("delayed-action watch unavailable", { dir, error: error instanceof Error ? error.message : String(error) });
    }
  }

  private stopWatching(): void {
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = undefined;
    this.watcher?.();
    this.watcher = undefined;
    this.watchedDir = undefined;
  }

  private scheduleRefreshAll(): void {
    if (this.disposed) return;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined;
      void this.refreshAll();
    }, this.options.debounceMs ?? 120);
    this.debounceTimer.unref?.();
  }
}

function nodeWatch(dir: string, listener: () => void): () => void {
  let watcher: FSWatcher | undefined = watch(dir, { persistent: false }, () => listener());
  watcher.on("error", () => { watcher?.close(); watcher = undefined; });
  return () => { watcher?.close(); watcher = undefined; };
}
