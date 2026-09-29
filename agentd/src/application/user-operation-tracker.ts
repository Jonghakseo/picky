/**
 * Counts user work that runs without a Pi turn or a queued delivery: `!bash` and non-skill
 * slash commands (extension commands such as `/delay-list`). Async-task Pickles otherwise
 * aggregate straight back to the settled episode while that work runs, hiding the running
 * state and the Stop control. `onSettled` re-aggregates once a session's last operation ends.
 */
export class UserOperationTracker {
  private readonly counts = new Map<string, number>();

  constructor(private readonly onSettled: (sessionId: string) => Promise<void>) {}

  isActive(sessionId: string): boolean {
    return (this.counts.get(sessionId) ?? 0) > 0;
  }

  /** Returns an idempotent release for one tracked operation. */
  begin(sessionId: string): () => Promise<void> {
    this.counts.set(sessionId, (this.counts.get(sessionId) ?? 0) + 1);
    let released = false;
    return async () => {
      if (released) return;
      released = true;
      const remaining = (this.counts.get(sessionId) ?? 1) - 1;
      if (remaining > 0) this.counts.set(sessionId, remaining);
      else this.counts.delete(sessionId);
      if (remaining === 0) await this.onSettled(sessionId);
    };
  }

  async track<T>(sessionId: string, tracked: boolean, work: () => Promise<T>): Promise<T> {
    if (!tracked) return work();
    const release = this.begin(sessionId);
    try {
      return await work();
    } finally {
      await release();
    }
  }
}
