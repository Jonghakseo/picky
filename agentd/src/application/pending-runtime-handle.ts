import type { RuntimeSessionHandle } from "../runtime/types.js";

export function awaitPendingRuntimeHandle(
  pending: Promise<RuntimeSessionHandle>,
  signal?: AbortSignal,
): Promise<RuntimeSessionHandle> {
  if (!signal) return pending;
  if (signal.aborted) return Promise.reject(abortSignalReason(signal));
  return new Promise<RuntimeSessionHandle>((resolve, reject) => {
    const onAbort = () => reject(abortSignalReason(signal));
    signal.addEventListener("abort", onAbort, { once: true });
    pending.then(resolve, reject).finally(() => signal.removeEventListener("abort", onAbort));
  });
}

export function createPendingRuntimeHandle(): {
  promise: Promise<RuntimeSessionHandle>;
  resolve: (handle: RuntimeSessionHandle) => void;
  reject: (error: unknown) => void;
} {
  let resolve!: (handle: RuntimeSessionHandle) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<RuntimeSessionHandle>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  // Startup failures are handled by the session creation path; avoid an unhandled rejection
  // when no slash-command request races the pending handle.
  promise.catch(() => undefined);
  return { promise, resolve, reject };
}

function abortSignalReason(signal: AbortSignal): unknown {
  return signal.reason ?? new Error("Pending runtime handle wait aborted");
}
