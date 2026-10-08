import { PickyCliCallerContextSchema } from "../protocol.js";
import type { PickyCliCallerContext } from "../domain/picky-cli-context.js";

/** Context is a runtime-issued hint; only the owning daemon can validate it. */
export function readCliCallerContext(env: NodeJS.ProcessEnv = process.env): PickyCliCallerContext {
  const raw = env.PICKY_CLI_CONTEXT;
  if (!raw || raw.length > 4_096) throw new Error("Caller identity is unavailable. Run this command from a Picky-hosted session.");
  let parsed: unknown;
  try { parsed = JSON.parse(raw); }
  catch { throw new Error("Caller context is invalid. Run this command again from the current Picky session."); }
  const result = PickyCliCallerContextSchema.safeParse(parsed);
  if (!result.success || !env.PI_SESSION_ID || result.data.piSessionId !== env.PI_SESSION_ID) {
    throw new Error("Caller context does not match the current Pi session. Inherited or replaced sessions cannot use --self.");
  }
  return result.data;
}
