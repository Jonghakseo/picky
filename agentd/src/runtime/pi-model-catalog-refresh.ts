import type { AgentSessionServices } from "@earendil-works/pi-coding-agent";
import { logAgentd } from "../local-log.js";

const REFRESH_TIMEOUT_MS = 5_000;
const RETRY_INTERVAL_MS = 60_000;
const refreshes = new WeakMap<AgentSessionServices["modelRuntime"], { attemptedAt: number; pending?: Promise<void> }>();

/** Pi owns catalog persistence/freshness; Picky bounds latency and coalesces picker requests. */
export async function refreshModelCatalog(services: AgentSessionServices): Promise<void> {
  const runtime = services.modelRuntime;
  // Compatibility runtimes without the services bridge have no catalog to refresh.
  if (typeof runtime?.refresh !== "function") return;
  const previous = refreshes.get(runtime);
  if (previous?.pending) return previous.pending;
  if (previous && Date.now() - previous.attemptedAt < RETRY_INTERVAL_MS) return;

  const state: { attemptedAt: number; pending?: Promise<void> } = { attemptedAt: Date.now() };
  refreshes.set(runtime, state);
  state.pending = (async () => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REFRESH_TIMEOUT_MS);
    try {
      // Do not override allowNetwork or force: Pi owns PI_OFFLINE and cache TTL semantics.
      const result = await runtime.refresh({ signal: controller.signal });
      if (result.aborted || result.errors.size > 0) {
        logAgentd("pi model catalog refresh incomplete", { aborted: result.aborted, failedProviders: result.errors.size });
      }
    } catch {
      logAgentd("pi model catalog refresh failed", { aborted: controller.signal.aborted });
    } finally {
      clearTimeout(timeout);
    }
  })();
  try {
    await state.pending;
  } finally {
    state.pending = undefined;
  }
}
