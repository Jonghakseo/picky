import { logAgentd } from "./local-log.js";

export type ParentExitReason = "ppid-changed" | "parent-not-running";

interface ParentExitWatcherHandle {
  stop: () => void;
}

interface ParentExitWatcherOptions {
  parentPid: number | undefined;
  intervalMs?: number;
  getCurrentParentPid?: () => number;
  isProcessAlive?: (pid: number) => boolean;
  onParentExit: (reason: ParentExitReason) => void;
  log?: (event: string, fields: Record<string, string | number | boolean | null | undefined>) => void;
  setIntervalFn?: (callback: () => void, intervalMs: number) => unknown;
  clearIntervalFn?: (timer: unknown) => void;
}

export function parseParentPid(raw: string | undefined): number | undefined {
  const trimmed = raw?.trim();
  if (!trimmed) return undefined;
  if (!/^[0-9]+$/.test(trimmed)) return undefined;
  const pid = Number(trimmed);
  return Number.isSafeInteger(pid) && pid > 0 ? pid : undefined;
}

export function startParentExitWatcher(options: ParentExitWatcherOptions): ParentExitWatcherHandle | undefined {
  const { parentPid } = options;
  if (!parentPid) return undefined;

  const intervalMs = options.intervalMs ?? 500;
  const getCurrentParentPid = options.getCurrentParentPid ?? (() => process.ppid);
  const isProcessAlive = options.isProcessAlive ?? defaultIsProcessAlive;
  const log = options.log ?? logAgentd;
  const setIntervalFn = options.setIntervalFn ?? ((callback, ms) => setInterval(callback, ms));
  const clearIntervalFn = options.clearIntervalFn ?? ((timer) => clearInterval(timer as NodeJS.Timeout));

  let stopped = false;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    clearIntervalFn(timer);
  };
  const notify = (reason: ParentExitReason) => {
    stop();
    log("parent process exited", { parentPid, currentParentPid: getCurrentParentPid(), reason });
    options.onParentExit(reason);
  };

  const timer = setIntervalFn(() => {
    if (stopped) return;
    if (getCurrentParentPid() !== parentPid) {
      notify("ppid-changed");
      return;
    }
    if (!isProcessAlive(parentPid)) {
      notify("parent-not-running");
    }
  }, intervalMs);
  if (typeof (timer as { unref?: () => void })?.unref === "function") {
    (timer as { unref: () => void }).unref();
  }

  return { stop };
}

function defaultIsProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    return code !== "ESRCH";
  }
}
