import type { PickyAgentSession } from "../protocol.js";

export function isTerminalStatus(status: PickyAgentSession["status"]): boolean {
  return ["completed", "failed", "cancelled", "blocked"].includes(status);
}
