/**
 * How long the gateway waits for the Mac.
 *
 * The gateway's timer starts when the request is sent; the Mac's dictation
 * budget starts after it decodes the audio. With both at 120 s the phone always
 * got `timeout` just before the transcript arrived.
 */
import type { WebSocket } from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HubLink, type HubLinkListener } from "./hub-link.js";

function quietListener(): HubLinkListener {
  return {
    onHello: () => {},
    onDaemons: () => {},
    onOverlay: () => {},
    onConfig: () => {},
    onPairingStart: () => {},
    onPairingCancel: () => {},
    onLocalOpen: () => {},
    onRevoke: () => {},
    onRename: () => {},
    onConnectionChange: () => {},
  };
}

/** A socket that swallows everything: the Mac that never answers. */
function silentSocket(): WebSocket {
  return { on: () => {}, send: () => {}, close: () => {} } as unknown as WebSocket;
}

function attachedHub(): HubLink {
  const hub = new HubLink(quietListener());
  hub.attach(silentSocket());
  return hub;
}

/** Records settlement as it happens; advanceTimersByTimeAsync flushes it. */
function track(promise: Promise<unknown>): { done: boolean; error: unknown } {
  const state: { done: boolean; error: unknown } = { done: false, error: undefined };
  promise.then(
    () => {
      state.done = true;
    },
    (error: unknown) => {
      state.done = true;
      state.error = error;
    },
  );
  return state;
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe("hub request timeouts", () => {
  it("gives dictation more room than the Mac's own 120 s budget", async () => {
    const hub = attachedHub();
    const state = track(hub.request("device-1", { type: "dictation.transcribe", filePath: "/tmp/a.m4a", mime: "audio/mp4" }));

    await vi.advanceTimersByTimeAsync(130_000);
    expect(state.done).toBe(false);

    await vi.advanceTimersByTimeAsync(25_000);
    expect(state.error).toMatchObject({ code: "timeout" });
  });

  it("keeps every other request on the short timeout", async () => {
    const hub = attachedHub();
    const state = track(hub.request("device-1", { type: "pickle.create", cwd: "/tmp" }));

    await vi.advanceTimersByTimeAsync(19_000);
    expect(state.done).toBe(false);

    await vi.advanceTimersByTimeAsync(2_000);
    expect(state.error).toMatchObject({ code: "timeout" });
  });
});
