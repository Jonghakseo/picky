import { existsSync } from "node:fs";
import { mkdir, mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import type { PickyScheduledMessage } from "../protocol.js";
import { ScheduledMessageProjector } from "./scheduled-message-projector.js";

async function storeDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "picky-delayed-action-"));
}

async function writeStore(dir: string, piSessionId: string, tasks: Array<{ id: string; prompt: string; dueAt: number; createdAt?: number }>): Promise<void> {
  await writeFile(join(dir, `${piSessionId}.json`), JSON.stringify({
    version: 1,
    sessionId: piSessionId,
    tasks: tasks.map((task) => ({ createdAt: task.createdAt ?? 1_000, ...task })),
  }), "utf8");
}

describe("ScheduledMessageProjector", () => {
  it("publishes the extension's store for a tracked session", async () => {
    const dir = await storeDir();
    await writeStore(dir, "pi-session-1", [{ id: "delay-1", prompt: "check deploy", dueAt: 60_000 }]);
    const published: Array<{ sessionId: string; messages: PickyScheduledMessage[] }> = [];
    const projector = new ScheduledMessageProjector(
      (sessionId, messages) => { published.push({ sessionId, messages }); },
      { dir: () => dir, watchDir: () => () => undefined },
    );

    await projector.track("session-1", "pi-session-1");

    expect(published).toEqual([{
      sessionId: "session-1",
      messages: [{ id: "delay-1", text: "check deploy", dueAt: new Date(60_000).toISOString(), createdAt: new Date(1_000).toISOString() }],
    }]);
    projector.dispose();
  });

  it("clears the schedule when the store file disappears after a message fires", async () => {
    const dir = await storeDir();
    await writeStore(dir, "pi-session-1", [{ id: "delay-1", prompt: "check deploy", dueAt: 60_000 }]);
    const published: PickyScheduledMessage[][] = [];
    const projector = new ScheduledMessageProjector(
      (_sessionId, messages) => { published.push(messages); },
      { dir: () => dir, watchDir: () => () => undefined },
    );
    await projector.track("session-1", "pi-session-1");

    await rm(join(dir, "pi-session-1.json"));
    await projector.refresh("session-1");

    expect(published.at(-1)).toEqual([]);
    projector.dispose();
  });

  it("re-reads every tracked session when the store directory changes", async () => {
    const dir = await storeDir();
    let notifyWatcher = (): void => undefined;
    const published: PickyScheduledMessage[][] = [];
    const projector = new ScheduledMessageProjector(
      (_sessionId, messages) => { published.push(messages); },
      { dir: () => dir, watchDir: (_dir, listener) => { notifyWatcher = listener; return () => undefined; }, debounceMs: 0 },
    );
    await projector.track("session-1", "pi-session-1");
    published.length = 0;

    await writeStore(dir, "pi-session-1", [{ id: "delay-7", prompt: "scheduled elsewhere", dueAt: 90_000 }]);
    notifyWatcher();
    await vi.waitFor(() => expect(published.at(-1)?.map((message) => message.id)).toEqual(["delay-7"]));

    projector.dispose();
  });

  it("empties the surface when a session's runtime detaches", async () => {
    const dir = await storeDir();
    await writeStore(dir, "pi-session-1", [{ id: "delay-1", prompt: "check deploy", dueAt: 60_000 }]);
    const published: PickyScheduledMessage[][] = [];
    const projector = new ScheduledMessageProjector(
      (_sessionId, messages) => { published.push(messages); },
      { dir: () => dir, watchDir: () => () => undefined },
    );
    await projector.track("session-1", "pi-session-1");

    await projector.untrack("session-1");

    expect(published.at(-1)).toEqual([]);
    expect(await projector.refresh("session-1")).toEqual([]);
    projector.dispose();
  });

  it("starts watching once the store directory appears", async () => {
    const dir = join(tmpdir(), `picky-delayed-action-late-${process.pid}-${Date.now()}`);
    let notifyWatcher: (() => void) | undefined;
    const published: PickyScheduledMessage[][] = [];
    const projector = new ScheduledMessageProjector(
      (_sessionId, messages) => { published.push(messages); },
      {
        dir: () => dir,
        watchDir: (target, listener) => {
          if (!existsSync(target)) throw new Error(`ENOENT: ${target}`);
          notifyWatcher = listener;
          return () => { notifyWatcher = undefined; };
        },
        debounceMs: 0,
      },
    );
    // The extension creates the directory with its first schedule, so the initial watch fails.
    await projector.track("session-1", "pi-session-1");
    expect(notifyWatcher).toBeUndefined();

    await mkdir(dir, { recursive: true });
    await writeStore(dir, "pi-session-1", [{ id: "delay-1", prompt: "scheduled now", dueAt: 60_000 }]);
    await projector.refresh("session-1");

    expect(notifyWatcher).toBeTypeOf("function");
    // A message the extension fires on its own must now reach the projection.
    await writeStore(dir, "pi-session-1", [{ id: "delay-2", prompt: "fired elsewhere", dueAt: 90_000 }]);
    notifyWatcher!();
    await vi.waitFor(() => expect(published.at(-1)?.map((message) => message.id)).toEqual(["delay-2"]));

    projector.dispose();
    await rm(dir, { recursive: true, force: true });
  });

  /** A tracked session with nothing scheduled refreshes constantly; each refresh must not
   *  re-attempt (and re-log) a watch on a directory that is still missing. */
  it("throttles watch retries while the store directory is still missing", async () => {
    const dir = join(tmpdir(), `picky-delayed-action-missing-${process.pid}-${Date.now()}`);
    let attempts = 0;
    const projector = new ScheduledMessageProjector(
      () => undefined,
      {
        dir: () => dir,
        watchDir: (target) => { attempts += 1; throw new Error(`ENOENT: ${target}`); },
        watchRetryCooldownMs: 10_000,
      },
    );
    await projector.track("session-1", "pi-session-1");
    const afterTrack = attempts;

    for (let index = 0; index < 5; index += 1) await projector.refresh("session-1");

    expect(attempts).toBe(afterTrack);
    projector.dispose();
  });

  it("survives a missing store directory", async () => {
    const published: PickyScheduledMessage[][] = [];
    const projector = new ScheduledMessageProjector(
      (_sessionId, messages) => { published.push(messages); },
      { dir: () => join(tmpdir(), "picky-delayed-action-does-not-exist") },
    );

    await projector.track("session-1", "pi-session-1");

    expect(published.at(-1)).toEqual([]);
    projector.dispose();
  });
});
