import { disposeRuntimeHandle } from "./runtime-handle-disposal.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

/** Serializes teardown and a same-session successor so Pi lifecycle leases never overlap. */
export class RuntimeDisposalGate {
  private pending = new Map<string, Promise<boolean>>();
  private failed = new Set<string>();

  async wait(sessionId: string): Promise<void> {
    const disposal = this.pending.get(sessionId);
    if (disposal) await disposal;
    if (this.failed.has(sessionId)) {
      throw new Error(`Runtime teardown did not complete for session ${sessionId}; refusing an overlapping resume`);
    }
  }

  async waitOrDispose(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    try {
      await this.wait(sessionId);
    } catch (error) {
      await disposeRuntimeHandle(handle, "discarded-overlapping-runtime");
      throw error;
    }
  }

  async dispose(sessionId: string, handle: RuntimeSessionHandle | undefined, label: string): Promise<void> {
    const active = this.pending.get(sessionId);
    if (active) return await active.then(() => undefined);
    if (!handle) return;
    const disposal = disposeRuntimeHandle(handle, label);
    this.pending.set(sessionId, disposal);
    try {
      if (!await disposal) this.failed.add(sessionId);
    } finally {
      if (this.pending.get(sessionId) === disposal) this.pending.delete(sessionId);
    }
  }
}
