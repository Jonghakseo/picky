import { describe, expect, it, vi } from "vitest";
import { ResourceReloadScheduler, type ResourceReloadSchedulerDeps } from "./pi-resource-reload.js";

// Failure paths of the plugin reload scheduler. The happy paths and queue ordering run against
// real Pi sessions in plugin-reload.integration.test.ts.

function harness(reload: () => Promise<{ supported: boolean }>) {
  const state = { busy: false, held: ["held follow-up"], delivered: [] as string[], logs: [] as string[] };
  const deps: ResourceReloadSchedulerDeps = {
    sessionId: "s",
    isDisposed: () => false,
    isBusy: () => state.busy,
    isAdapterIdle: () => true,
    hasPendingExtensionUi: () => false,
    prepareReplacement: async () => {},
    reload,
    waitForReadiness: async () => {},
    hasHeldPrompts: () => state.held.length > 0,
    flushHeldPrompts: async () => { state.delivered.push(...state.held.splice(0)); },
    log: (line) => state.logs.push(line),
    emitReloaded: () => {},
  };
  const scheduler = new ResourceReloadScheduler(deps, { reloadMs: 50, settleWaitMs: 20 });
  return { scheduler, state };
}

describe("ResourceReloadScheduler failures", () => {
  it("reports a failed reload instead of success and still delivers held input", async () => {
    const { scheduler, state } = harness(async () => { throw new Error("extension crashed"); });

    await expect(scheduler.request()).resolves.toBe("failed");

    expect(state.delivered).toEqual(["held follow-up"]);
    expect(state.logs).toContain("plugin reload failed: extension crashed");
    // No retry loop: the app's retry requests a new generation.
    expect(scheduler.pending).toBe(false);
  });

  it("stops holding input when Pi's reload hangs", async () => {
    const { scheduler, state } = harness(() => new Promise(() => {}));

    const settle = await scheduler.finishBeforeInput();
    expect(settle).toBe("unchanged");
    const request = scheduler.request();
    // Input arriving during the reload waits only briefly before the caller moves on.
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(scheduler.reloading).toBe(true);
    await expect(scheduler.finishBeforeInput()).resolves.toBe("deferred");

    await expect(request).resolves.toBe("failed");
    expect(scheduler.reloading).toBe(false);
    expect(state.delivered).toEqual(["held follow-up"]);
  });

  it("delivers held input left behind when a turn started during the reload", async () => {
    const { scheduler, state } = harness(async () => { state.busy = true; return { supported: true }; });

    await expect(scheduler.request()).resolves.toBe("reloaded");
    expect(state.delivered).toEqual([]);

    state.busy = false;
    scheduler.schedule();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(state.delivered).toEqual(["held follow-up"]);
  });
});

describe("ResourceReloadScheduler held input", () => {
  it("does not strand held input behind a reload that timed out and is still running", async () => {
    let calls = 0;
    const { scheduler, state } = harness(() => { calls += 1; return new Promise(() => {}); });
    state.held = [];
    await expect(scheduler.request()).resolves.toBe("failed");

    // A second install arrives while Pi is still stuck in the first reload; the user queues input.
    state.held = ["after second install"];
    await expect(scheduler.request()).resolves.toBe("deferred");

    expect(calls).toBe(1);
    expect(state.delivered).toEqual(["after second install"]);
    expect(scheduler.pending).toBe(true);
  });

  it("delivers input scheduled while a drain is already running", async () => {
    let release!: () => void;
    const { scheduler, state } = harness(() => new Promise((resolve) => { release = () => resolve({ supported: true }); }));
    state.held = [];
    const request = scheduler.request();
    await new Promise((resolve) => setTimeout(resolve, 5));

    state.held = ["queued during drain"];
    scheduler.schedule();
    release();
    await request;
    await vi.waitFor(() => expect(state.delivered).toEqual(["queued during drain"]));
  });
});
