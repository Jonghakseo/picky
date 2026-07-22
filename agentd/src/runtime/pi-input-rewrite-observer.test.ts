import { describe, expect, it, vi } from "vitest";
import { expectedInputDeliveryIndex, PiInputRewriteObserver } from "./pi-input-rewrite-observer.js";

describe("PiInputRewriteObserver", () => {
  it("records only final RPC input in the active delivery context", async () => {
    const onAlias = vi.fn();
    const observer = new PiInputRewriteObserver(onAlias);
    let inputHandler: ((event: { type: "input"; text: string; source: "rpc" | "extension" }) => unknown) | undefined;
    const inline = observer.inlineExtension;
    const factory = typeof inline === "function" ? inline : inline.factory;
    await factory({
      on: (event: string, handler: typeof inputHandler) => {
        if (event === "input") inputHandler = handler;
      },
    } as never);

    await observer.runWithDelivery("delivery-1", async () => {
      await inputHandler?.({ type: "input", text: "delegate subagent:worker now", source: "rpc" });
      await inputHandler?.({ type: "input", text: "extension injected follow-up", source: "extension" });
    });
    await inputHandler?.({ type: "input", text: "outside context", source: "rpc" });

    expect(onAlias).toHaveBeenCalledTimes(1);
    expect(onAlias).toHaveBeenCalledWith("delivery-1", "delegate subagent:worker now");
  });
});

describe("expectedInputDeliveryIndex", () => {
  it("does not consume an unmatched extension event before a known rewritten echo", () => {
    const deliveries = [{
      text: "delegate >worker now",
      aliases: new Set(["delegate subagent:worker now"]),
    }];

    expect(expectedInputDeliveryIndex(deliveries, "extension injected follow-up", (text) => text)).toBe(-1);
    expect(expectedInputDeliveryIndex(deliveries, "delegate subagent:worker now", (text) => text)).toBe(0);
  });

  it("matches a queue-derived reverse expansion without FIFO fallback", () => {
    const deliveries = [{ text: "/skill:test" }];

    expect(expectedInputDeliveryIndex(
      deliveries,
      "expanded skill body",
      (text) => text === "expanded skill body" ? "/skill:test" : text,
    )).toBe(0);
  });
});
