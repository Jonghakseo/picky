import { isDeepStrictEqual } from "node:util";
import type { PickyAgentSession } from "../protocol.js";

/**
 * Whether applying `patch` would leave every supplied session field unchanged.
 * `updatedAt` is assigned by the supervisor after this check, so it is not part
 * of the semantic patch contract.
 */
export function isSemanticNoOpPatch(current: PickyAgentSession, patch: Partial<PickyAgentSession>): boolean {
  return Object.entries(patch).every(([key, value]) => {
    if (key === "updatedAt") return true;
    return isDeepStrictEqual(current[key as keyof PickyAgentSession], value);
  });
}
