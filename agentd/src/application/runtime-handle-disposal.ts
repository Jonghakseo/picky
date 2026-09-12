import { logAgentd } from "../local-log.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

/**
 * Permanently release a detached runtime. Callers that must prevent a successor
 * from reopening the same Pi session can inspect the boolean and fail closed.
 */
export async function disposeRuntimeHandle(handle: RuntimeSessionHandle, label: string): Promise<boolean> {
  try {
    if (handle.dispose) await handle.dispose();
    else await handle.abort();
    return true;
  } catch (error) {
    logAgentd("runtime dispose failed", { sessionId: handle.id, label, error: error instanceof Error ? error.message : String(error) });
    return false;
  }
}
