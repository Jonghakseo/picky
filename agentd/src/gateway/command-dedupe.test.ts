/**
 * A phone that loses its socket mid-send retries with the same commandId. The
 * contract: the message is delivered once, and both attempts hear the same
 * answer.
 */
import { describe, expect, it } from "vitest";
import { CommandDeduplicator, DEDUPE_HISTORY_PER_DEVICE } from "./command-dedupe.js";

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void; reject: (error: Error) => void } {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((resolveFn, rejectFn) => {
    resolve = resolveFn;
    reject = rejectFn;
  });
  return { promise, resolve, reject };
}

describe("command deduplication", () => {
  it("runs the work once and replays the first result", async () => {
    const dedupe = new CommandDeduplicator<string>();
    let runs = 0;
    const work = async () => {
      runs += 1;
      return `result-${runs}`;
    };

    expect(await dedupe.run("device-1", "c1", work)).toBe("result-1");
    expect(await dedupe.run("device-1", "c1", work)).toBe("result-1");
    expect(runs).toBe(1);
  });

  it("gives a retry that races the original the same single outcome", async () => {
    const dedupe = new CommandDeduplicator<string>();
    const gate = deferred<string>();
    let runs = 0;
    const work = () => {
      runs += 1;
      return gate.promise;
    };

    const first = dedupe.run("device-1", "c1", work);
    const retry = dedupe.run("device-1", "c1", work);
    gate.resolve("sent");

    expect(await Promise.all([first, retry])).toEqual(["sent", "sent"]);
    expect(runs).toBe(1);
  });

  it("lets a command that failed be retried, because that is not a duplicate submit", async () => {
    const dedupe = new CommandDeduplicator<string>();
    let runs = 0;
    const work = async () => {
      runs += 1;
      if (runs === 1) throw new Error("mac offline");
      return "sent";
    };

    await expect(dedupe.run("device-1", "c1", work)).rejects.toThrow("mac offline");
    expect(await dedupe.run("device-1", "c1", work)).toBe("sent");
    expect(runs).toBe(2);
  });

  it("keeps devices apart, so two phones can use the same id", async () => {
    const dedupe = new CommandDeduplicator<string>();
    expect(await dedupe.run("device-1", "c1", async () => "one")).toBe("one");
    expect(await dedupe.run("device-2", "c1", async () => "two")).toBe("two");
  });

  it("forgets a device when it disconnects for good", async () => {
    const dedupe = new CommandDeduplicator<string>();
    expect(await dedupe.run("device-1", "c1", async () => "one")).toBe("one");
    dedupe.forget("device-1");
    expect(await dedupe.run("device-1", "c1", async () => "again")).toBe("again");
  });

  it("drops the oldest ids instead of growing forever", async () => {
    const dedupe = new CommandDeduplicator<string>();
    for (let index = 0; index <= DEDUPE_HISTORY_PER_DEVICE; index += 1) {
      await dedupe.run("device-1", `c${index}`, async () => `r${index}`);
    }
    // The first id aged out, the most recent ones are still deduplicated.
    expect(await dedupe.run("device-1", "c0", async () => "rerun")).toBe("rerun");
    expect(await dedupe.run("device-1", `c${DEDUPE_HISTORY_PER_DEVICE}`, async () => "rerun"))
      .toBe(`r${DEDUPE_HISTORY_PER_DEVICE}`);
  });
});
