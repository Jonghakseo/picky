import { describe, expect, it } from "vitest";
import { parseParentPid, startParentExitWatcher } from "./parent-watchdog.js";

describe("parent watchdog", () => {
  it("parses positive numeric parent pids only", () => {
    expect(parseParentPid("123")).toBe(123);
    expect(parseParentPid(" 456 ")).toBe(456);
    expect(parseParentPid(undefined)).toBeUndefined();
    expect(parseParentPid("")).toBeUndefined();
    expect(parseParentPid("0")).toBeUndefined();
    expect(parseParentPid("abc")).toBeUndefined();
  });

  it("keeps running while the recorded app parent pid is alive", () => {
    let tick: (() => void) | undefined;
    const events: string[] = [];
    const watcher = startParentExitWatcher({
      parentPid: 42,
      intervalMs: 10,
      isProcessAlive: () => true,
      setIntervalFn: (callback) => {
        tick = callback;
        return "timer";
      },
      clearIntervalFn: () => events.push("cleared"),
      log: (event, fields) => events.push(`${event}:${fields.reason}`),
      onParentExit: (reason) => events.push(`exit:${reason}`),
    });

    expect(watcher).toBeDefined();
    tick?.();
    tick?.();

    expect(events).toEqual([]);
    watcher?.stop();
    expect(events).toEqual(["cleared"]);
  });

  it("notifies when the parent process is no longer alive", () => {
    let tick: (() => void) | undefined;
    const events: string[] = [];
    startParentExitWatcher({
      parentPid: 42,
      isProcessAlive: () => false,
      setIntervalFn: (callback) => {
        tick = callback;
        return "timer";
      },
      clearIntervalFn: () => events.push("cleared"),
      log: (event, fields) => events.push(`${event}:${fields.reason}`),
      onParentExit: (reason) => events.push(`exit:${reason}`),
    });

    tick?.();

    expect(events).toEqual(["cleared", "parent process exited:parent-not-running", "exit:parent-not-running"]);
  });
});
