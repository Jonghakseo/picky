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

  it("notifies when the recorded app parent pid changes", () => {
    let tick: (() => void) | undefined;
    const events: string[] = [];
    let currentParentPid = 42;
    const watcher = startParentExitWatcher({
      parentPid: 42,
      intervalMs: 10,
      getCurrentParentPid: () => currentParentPid,
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
    currentParentPid = 1;
    tick?.();
    tick?.();

    expect(events).toEqual(["cleared", "parent process exited:ppid-changed", "exit:ppid-changed"]);
  });

  it("notifies when the parent process is no longer alive", () => {
    let tick: (() => void) | undefined;
    const events: string[] = [];
    startParentExitWatcher({
      parentPid: 42,
      getCurrentParentPid: () => 42,
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
