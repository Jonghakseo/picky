import { describe, expect, it, vi } from "vitest";
import { CommandRegistry, newCommandId } from "./commands";
import type { RemoteCommand } from "../../../src/remote/protocol";

const followUp: RemoteCommand = { type: "session.send", sessionId: "s1", text: "계속해 줘", kind: "followUp" };

describe("newCommandId", () => {
  it("is `c_` plus 16 characters", () => {
    expect(newCommandId()).toMatch(/^c_[a-z0-9]{16}$/);
  });

  it("does not repeat", () => {
    const ids = new Set(Array.from({ length: 200 }, () => newCommandId()));
    expect(ids.size).toBe(200);
  });
});

describe("CommandRegistry", () => {
  it("resolves the caller when the result for its id arrives", async () => {
    const registry = new CommandRegistry(() => {});
    const pending = registry.send(followUp, "c_fixed0000000000");
    registry.resolve("c_fixed0000000000", { ok: true, data: { queued: true } });
    await expect(pending).resolves.toEqual({ ok: true, data: { queued: true } });
    expect(registry.pendingCount).toBe(0);
  });

  it("resends an unresolved command with the same id, so the gateway can dedupe it", async () => {
    const sent: string[] = [];
    const registry = new CommandRegistry((id) => sent.push(id));
    const pending = registry.send(followUp, "c_keepsameid00000");
    registry.resend();
    registry.resend();
    expect(sent).toEqual(["c_keepsameid00000", "c_keepsameid00000", "c_keepsameid00000"]);
    registry.resolve("c_keepsameid00000", { ok: true });
    await pending;
  });

  it("does not resend a command that already produced a result", async () => {
    const sent: string[] = [];
    const registry = new CommandRegistry((id) => sent.push(id));
    const pending = registry.send(followUp, "c_done00000000000");
    registry.resolve("c_done00000000000", { ok: true });
    await pending;
    registry.resend();
    expect(sent).toHaveLength(1);
  });

  it("fails the caller when nothing answers in time", async () => {
    vi.useFakeTimers();
    try {
      const registry = new CommandRegistry(() => {}, 1_000);
      const pending = registry.send(followUp, "c_timeout00000000");
      vi.advanceTimersByTime(1_000);
      await expect(pending).resolves.toEqual({ ok: false, error: { code: "timeout", message: "command timed out" } });
    } finally {
      vi.useRealTimers();
    }
  });

  it("fails every pending command when the device is revoked", async () => {
    const registry = new CommandRegistry(() => {});
    const first = registry.send(followUp, "c_a0000000000000a");
    const second = registry.send(followUp, "c_b0000000000000b");
    registry.failAll({ code: "unauthorized", message: "device revoked" });
    expect((await first).ok).toBe(false);
    expect((await second).ok).toBe(false);
    expect(registry.pendingCount).toBe(0);
  });
});
