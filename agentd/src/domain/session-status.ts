import type { PickyAgentSession } from "../protocol.js";

export function isTerminalStatus(status: PickyAgentSession["status"]): boolean {
  return ["completed", "failed", "cancelled", "blocked"].includes(status);
}

/** Statuses that carry a final reply for external Pickle waiters. `blocked` may resume. */
export function isFinalSessionStatus(status: PickyAgentSession["status"]): boolean {
  return ["completed", "failed", "cancelled"].includes(status);
}
