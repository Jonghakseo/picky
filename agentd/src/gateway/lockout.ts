/**
 * Per-IP lockout (docs/remote-pwa-implementation.md 2.3).
 *
 * Five failures in ten minutes block that IP for fifteen. Failures are wrong
 * pairing codes and cookies that match no device: both are guesses at a secret.
 */
export const LOCKOUT_WINDOW_MS = 10 * 60 * 1000;
export const LOCKOUT_THRESHOLD = 5;
export const LOCKOUT_DURATION_MS = 15 * 60 * 1000;

interface IpState {
  failures: number[];
  blockedUntilMs?: number;
}

export class LockoutTracker {
  private readonly states = new Map<string, IpState>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  isBlocked(ip: string): boolean {
    return this.blockedUntil(ip) !== undefined;
  }

  /** Epoch ms the block lifts, or undefined when the IP is free. */
  blockedUntil(ip: string): number | undefined {
    const state = this.states.get(ip);
    if (!state?.blockedUntilMs) return undefined;
    if (state.blockedUntilMs <= this.now()) {
      this.states.delete(ip);
      return undefined;
    }
    return state.blockedUntilMs;
  }

  /** Returns the block expiry when this failure crossed the threshold. */
  recordFailure(ip: string): number | undefined {
    const now = this.now();
    const state = this.states.get(ip) ?? { failures: [] };
    state.failures = [...state.failures.filter((at) => now - at < LOCKOUT_WINDOW_MS), now];
    if (state.failures.length >= LOCKOUT_THRESHOLD) {
      state.blockedUntilMs = now + LOCKOUT_DURATION_MS;
      state.failures = [];
      this.states.set(ip, state);
      return state.blockedUntilMs;
    }
    this.states.set(ip, state);
    return undefined;
  }

  recordSuccess(ip: string): void {
    this.states.delete(ip);
  }
}
