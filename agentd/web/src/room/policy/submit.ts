/**
 * One composer send at a time.
 *
 * A send waits for the gateway and then the daemon to acknowledge it, which can
 * take seconds. Each Return makes a new command id, so the gateway's id dedupe
 * cannot fold repeats together: the composer must refuse a second send while
 * the first is still in flight. A plain send clears the draft before the round
 * trip (the Return visibly worked) and puts it back if the send fails.
 */

export interface SubmitAttempt<Snapshot> {
  /** Captures what will be sent. `null` means there is nothing to send. May clear the composer. */
  take(): Snapshot | null;
  send(snapshot: Snapshot): Promise<boolean>;
  onSuccess?(snapshot: Snapshot): void;
  /** The send failed: give the snapshot back to the composer. */
  onFailure?(snapshot: Snapshot): void;
}

export type SubmitOutcome = "sent" | "failed" | "busy" | "empty";

export class SingleFlightSubmitter {
  private inFlight = false;

  constructor(private readonly onBusyChange: (busy: boolean) => void = () => {}) {}

  get busy(): boolean {
    return this.inFlight;
  }

  async run<Snapshot>(attempt: SubmitAttempt<Snapshot>): Promise<SubmitOutcome> {
    if (this.inFlight) return "busy";
    const snapshot = attempt.take();
    if (snapshot === null) return "empty";
    this.inFlight = true;
    this.onBusyChange(true);
    let ok = false;
    try {
      ok = await attempt.send(snapshot);
    } catch {
      ok = false;
    } finally {
      this.inFlight = false;
      this.onBusyChange(false);
    }
    if (ok) attempt.onSuccess?.(snapshot);
    else attempt.onFailure?.(snapshot);
    return ok ? "sent" : "failed";
  }
}

/**
 * The draft to show after a failed send. The sent text comes back; anything the
 * user typed while waiting stays below it, so neither is lost.
 */
export function draftAfterFailedSend(current: string, sent: string): string {
  if (current.trim().length === 0) return sent;
  return `${sent}\n${current}`;
}
