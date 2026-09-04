import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { LogField } from "../local-log.js";
import type { AgentRuntime } from "../runtime/types.js";
import type { TaskRouter } from "../task-router.js";

export interface ReloadPluginsSummary {
  pickyReloaded: boolean;
  pickleReloadedCount: number;
  pickleAbortedCount: number;
  pickleDeferredCount: number;
}

/** Configuration seams for SessionSupervisor runtime orchestration. */
export interface SessionSupervisorOptions {
  taskRouter?: TaskRouter;
  mainRuntime?: AgentRuntime;
  // Optional factory used to mint new session ids. Defaults to a random UUID generator. Child
  // daemons (per-Pickle agentd plan §3.2) override this with a single-use factory that returns
  // the env-supplied PICKY_AGENTD_SESSION_ID so the scoped SessionStore accepts the first save.
  sessionIdFactory?: () => string;
  // Defaults to 1s; tests may lower it to avoid waiting on real-time intervals.
  userBashLiveUpdateIntervalMs?: number;
  // Idle window before a threshold-triggered in-place main compaction runs. Defaults to
  // MAIN_AGENT_COMPACT_IDLE_MS; tests lower it to avoid waiting on real-time timers.
  mainCompactionIdleMs?: number;
  // Child daemons have no `mainRuntime` of their own, so they cannot followUp the main Picky
  // agent directly. When set, `deliverPickleCompletionToMain` forwards one
  // durable completion envelope through the app, which selects macOS/Main
  // channels before optionally delivering to the primary daemon.
  forwardPickleCompletionToPrimary?: (request: {
    sessionId: string;
    prompt: string;
    cwd?: string;
    completionId: string;
    title: string;
    status: "completed";
    summary?: string;
  }) => Promise<void>;
  // Builds the customTools array to apply to the main runtime after the user
  // toggles built-in tool availability. Called with the current disabled set;
  // returns the filtered ToolDefinition[] that should be active. bootstrap.ts
  // owns the tool registry; supervisor only stores the disabled set and asks
  // for a refreshed list when it changes.
  mainCustomToolsBuilder?: (disabled: ReadonlySet<string>) => ToolDefinition[];
  // Notifies the composition root that the disabled set changed, so the main runtime's
  // system-prompt contract picks up prompt-gated identifiers on the next turn. Kept separate
  // from mainCustomToolsBuilder: prompt content and the tool registry have different
  // invalidation costs, and only the latter needs a fresh handle.
  onDisabledBuiltinToolsChanged?: (disabled: ReadonlySet<string>) => void;
  /** Test seam for privacy-safe lifecycle evidence; production defaults to logLifecycleEvent. */
  lifecycleEventLogger?: (event: string, fields: Record<string, LogField>) => void;
  /** Injectable timer boundary keeps follow-up stall detection deterministic in tests. */
  followUpStallDelayMs?: number;
  scheduleFollowUpStall?: (callback: () => void, delayMs: number) => unknown;
  clearFollowUpStall?: (timer: unknown) => void;
}
