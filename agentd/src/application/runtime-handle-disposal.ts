import { logAgentd } from "../local-log.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

/** Permanently release a detached runtime without letting teardown failures block session cleanup. */
export async function disposeRuntimeHandle(handle: RuntimeSessionHandle, label: string): Promise<void> {
  try {
    if (handle.dispose) await handle.dispose();
    else await handle.abort();
  } catch (error) {
    logAgentd("runtime dispose failed", { sessionId: handle.id, label, error: error instanceof Error ? error.message : String(error) });
  }
}
