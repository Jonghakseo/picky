import { logAgentd } from "../local-log.js";
import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeResourceReloadOutcome, RuntimeSessionHandle } from "../runtime/types.js";
import type { ReloadPluginsSummary } from "./session-supervisor-options.js";

export interface PluginReloadDeps {
  mainHandle(): RuntimeSessionHandle | undefined;
  pendingMainHandle(): Promise<RuntimeSessionHandle> | undefined;
  pickles(): PickyAgentSession[];
  pickleHandle(sessionId: string): RuntimeSessionHandle | undefined;
  isTerminal(session: PickyAgentSession): boolean;
  retainedAsyncWork(sessionId: string): boolean;
  /** Legacy runtimes without `requestResourceReload` reload through the `/reload` follow-up. */
  followUpReload(sessionId: string): Promise<void>;
  appendLog(sessionId: string, line: string): Promise<void>;
}

type SessionReloadResult = RuntimeResourceReloadOutcome | "skipped";

/**
 * Applies installed/removed plugins to every live session without interrupting anyone.
 * Idle sessions reload now. Busy sessions (responding, compacting, async work) reload at their
 * next safe point and hold follow-ups sent meanwhile, so nothing is aborted. Sessions reload in
 * parallel so one slow extension or MCP startup does not delay the rest. `pickleAbortedCount`
 * stays in the summary for protocol compatibility and is always 0.
 */
export async function reloadPluginsWithoutInterruption(deps: PluginReloadDeps): Promise<ReloadPluginsSummary> {
  const summary: ReloadPluginsSummary = { pickyReloaded: false, pickleReloadedCount: 0, pickleAbortedCount: 0, pickleDeferredCount: 0, failedCount: 0 };

  const main = (async (): Promise<SessionReloadResult> => {
    const handle = await resolveMainHandle(deps);
    if (!handle?.requestResourceReload) return "skipped";
    return handle.requestResourceReload();
  })();
  const pickles = deps.pickles()
    .filter((session) => session.archived !== true)
    .map((session) => reloadPickle(deps, session).catch((error): SessionReloadResult => {
      logAgentd("plugins reload pickle failed", { sessionId: session.id, error: messageOf(error) });
      return "failed";
    }));

  const [mainResult, ...pickleResults] = await Promise.allSettled([main, ...pickles]);
  const mainOutcome = settledValue(mainResult);
  if (mainOutcome === "failed") summary.failedCount += 1;
  else if (mainOutcome !== "skipped") summary.pickyReloaded = true;
  for (const result of pickleResults) {
    const outcome = settledValue(result);
    if (outcome === "failed") summary.failedCount += 1;
    else if (outcome === "deferred") summary.pickleDeferredCount += 1;
    else if (outcome === "reloaded" || outcome === "unchanged") summary.pickleReloadedCount += 1;
  }

  logAgentd("plugins reloaded", { pickyReloaded: summary.pickyReloaded ? 1 : 0, pickleReloadedCount: summary.pickleReloadedCount, pickleDeferredCount: summary.pickleDeferredCount, failedCount: summary.failedCount });
  return summary;
}

async function reloadPickle(deps: PluginReloadDeps, session: PickyAgentSession): Promise<SessionReloadResult> {
  const handle = deps.pickleHandle(session.id);
  if (!handle) return "skipped";
  // Finished Pickles keep a reusable runtime; reload them too so the next follow-up and
  // slash-command autocomplete already see the change.
  if (handle.requestResourceReload) return handle.requestResourceReload();
  if (deps.isTerminal(session)) return "skipped";
  if (deps.retainedAsyncWork(session.id) || handle.isStreaming || handle.isCompacting === true) {
    await deps.appendLog(session.id, "plugins reload skipped while the session is busy; this runtime applies plugins on its next session");
    return "deferred";
  }
  await deps.followUpReload(session.id);
  return "reloaded";
}

function settledValue(result: PromiseSettledResult<SessionReloadResult>): SessionReloadResult {
  if (result.status === "fulfilled") return result.value;
  logAgentd("plugins reload session failed", { error: messageOf(result.reason) });
  return "failed";
}

async function resolveMainHandle(deps: PluginReloadDeps): Promise<RuntimeSessionHandle | undefined> {
  const current = deps.mainHandle();
  if (current) return current;
  const pending = deps.pendingMainHandle();
  if (!pending) return undefined;
  try {
    return await pending;
  } catch (error) {
    logAgentd("plugins reload pending main handle skipped", { error: messageOf(error) });
    return undefined;
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
