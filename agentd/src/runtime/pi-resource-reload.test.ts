import { describe, expect, it, vi } from "vitest";
import { ResourceReloadScheduler, type ResourceReloadSchedulerDeps } from "./pi-resource-reload.js";

// Failure paths of the plugin reload scheduler. The happy paths and queue ordering run against
// real Pi sessions in plugin-reload.integration.test.ts.

function harness(reload: () => Promise<{ supported: boolean }>) {
  const state = { busy: false, held: ["held follow-up"], delivered: [] as string[], logs: [] as string[], fenceReleases: 0 };
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
    emitReplacementFenceReleased: () => { state.fenceReleases += 1; },
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

// The async replacement fence closes model admission; only this signal lets idle sessions reopen it
// for prompts that bypass Picky input (e.g. scheduled extension deliveries).
describe("ResourceReloadScheduler replacement fence release", () => {
  it("releases the fence after a reload that failed without hanging", async () => {
    const { scheduler, state } = harness(async () => { throw new Error("extension crashed"); });

    await expect(scheduler.request()).resolves.toBe("failed");

    expect(state.fenceReleases).toBe(1);
  });

  it("keeps the fence while a timed-out reload is still running inside Pi", async () => {
    const { scheduler, state } = harness(() => new Promise(() => {}));

    await expect(scheduler.request()).resolves.toBe("failed");

    expect(state.fenceReleases).toBe(0);
  });

  it("does not release between reloads while the next one waits for a busy turn", async () => {
    let calls = 0;
    const { scheduler, state } = harness(async () => {
      calls += 1;
      if (calls === 1) { state.busy = true; void scheduler.request(); }
      return { supported: true };
    });

    await expect(scheduler.request()).resolves.toBe("deferred");
    expect(state.fenceReleases).toBe(0);

    state.busy = false;
    scheduler.schedule();
    await vi.waitFor(() => expect(state.fenceReleases).toBe(1));
    expect(calls).toBe(2);
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
