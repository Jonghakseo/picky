/**
 * Runs work serially per key, so two callers for the same session never interleave.
 * A rejected job does not poison the chain: the next job still runs, and the rejection
 * is delivered only to the caller that submitted it.
 */
export class KeyedSerialQueue {
  private chains = new Map<string, Promise<void>>();

  /** True while a job for this key is still in flight. Used by durability diagnostics. */
  has(key: string): boolean {
    return this.chains.has(key);
  }

  async run<T>(key: string, work: () => Promise<T>): Promise<T> {
    const previous = this.chains.get(key) ?? Promise.resolve();
    let result: T | undefined;
    const next = previous.catch(() => undefined).then(async () => { result = await work(); });
    const tracked = next.catch(() => undefined);
    this.chains.set(key, tracked);
    try {
      await next;
    } finally {
      if (this.chains.get(key) === tracked) this.chains.delete(key);
    }
    return result!;
  }
}
