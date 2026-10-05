/**
 * Pairing codes (docs/remote-pwa-implementation.md 2.3).
 *
 * A code exists only while the user has "connect a phone" open on the Mac, so a
 * gateway reachable over a tunnel still cannot be joined unless somebody is
 * standing at the Mac. The alphabet drops the characters that are easy to
 * misread off a screen (0/O, 1/I/L, U/V ambiguity aside).
 */
import { randomInt } from "node:crypto";

export const PAIRING_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ";
export const PAIRING_CODE_LENGTH = 8;
export const PAIRING_TTL_MS = 5 * 60 * 1000;
export const PAIRING_MAX_ATTEMPTS = 5;

export type PairingEndReason = "paired" | "expired" | "cancelled" | "exhausted";

export interface PairingCode {
  /** Normalized code (no dashes, upper case). */
  code: string;
  /** `XXXX-XXXX`, the way the Mac and the phone show it. */
  display: string;
  expiresAt: string;
}

export type PairingCheck =
  | { ok: true }
  | { ok: false; reason: "noCode" | "expired" | "wrong" | "exhausted" };

export function formatPairingCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

export function normalizePairingCode(input: string): string {
  return input.replace(/[\s-]/g, "").toUpperCase();
}

export function generatePairingCode(): string {
  let code = "";
  for (let index = 0; index < PAIRING_CODE_LENGTH; index += 1) {
    code += PAIRING_ALPHABET[randomInt(PAIRING_ALPHABET.length)];
  }
  return code;
}

interface ActiveCode {
  code: string;
  expiresAtMs: number;
  attempts: number;
}

/**
 * One active code at a time. `start` replaces whatever was pending, which is
 * what the Mac UI implies: reopening the sheet shows a new code.
 */
export class PairingSession {
  private active?: ActiveCode;

  constructor(
    private readonly now: () => number = () => Date.now(),
    private readonly makeCode: () => string = generatePairingCode,
  ) {}

  start(): PairingCode {
    const code = this.makeCode();
    const expiresAtMs = this.now() + PAIRING_TTL_MS;
    this.active = { code, expiresAtMs, attempts: 0 };
    return { code, display: formatPairingCode(code), expiresAt: new Date(expiresAtMs).toISOString() };
  }

  current(): PairingCode | undefined {
    const active = this.activeIfFresh();
    if (!active) return undefined;
    return { code: active.code, display: formatPairingCode(active.code), expiresAt: new Date(active.expiresAtMs).toISOString() };
  }

  isActive(): boolean {
    return this.activeIfFresh() !== undefined;
  }

  cancel(): void {
    this.active = undefined;
  }

  /** Consumes the code on success: one code pairs exactly one device. */
  check(input: string): PairingCheck {
    const active = this.activeIfFresh();
    if (!active) return { ok: false, reason: this.active ? "expired" : "noCode" };

    if (normalizePairingCode(input) === active.code) {
      this.active = undefined;
      return { ok: true };
    }

    active.attempts += 1;
    if (active.attempts >= PAIRING_MAX_ATTEMPTS) {
      this.active = undefined;
      return { ok: false, reason: "exhausted" };
    }
    return { ok: false, reason: "wrong" };
  }

  private activeIfFresh(): ActiveCode | undefined {
    if (!this.active) return undefined;
    if (this.active.expiresAtMs <= this.now()) return undefined;
    return this.active;
  }
}
