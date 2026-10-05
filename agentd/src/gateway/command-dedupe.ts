/**
 * Per-device command deduplication (docs/remote-pwa-implementation.md 2.7).
 *
 * A phone retries after a dropped socket, and the composer cannot tell whether
 * its `session.send` reached the Mac. Replaying the first result keeps a retry
 * from sending the same message twice; the in-flight promise is shared so a
 * retry that races the original still gets one outcome.
 */
export const DEDUPE_HISTORY_PER_DEVICE = 1000;

export class CommandDeduplicator<Result> {
  private readonly byDevice = new Map<string, Map<string, Promise<Result>>>();

  run(deviceId: string, commandId: string, work: () => Promise<Result>): Promise<Result> {
    const history = this.byDevice.get(deviceId) ?? new Map<string, Promise<Result>>();
    this.byDevice.set(deviceId, history);

    const existing = history.get(commandId);
    if (existing) return existing;

    // A rejected command is not remembered: the phone is allowed to retry
    // something that failed, which is the opposite of a duplicate submit.
    const result = work().catch((error: unknown) => {
      if (history.get(commandId) === result) history.delete(commandId);
      throw error;
    });
    history.set(commandId, result);
    while (history.size > DEDUPE_HISTORY_PER_DEVICE) {
      const oldest = history.keys().next();
      if (oldest.done) break;
      history.delete(oldest.value);
    }
    return result;
  }

  forget(deviceId: string): void {
    this.byDevice.delete(deviceId);
  }
}
