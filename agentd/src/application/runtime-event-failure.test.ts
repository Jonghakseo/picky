import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import type { PickyContextPacket } from "../protocol.js";
import type { BuiltPrompt } from "../prompt-builder.js";
import { MockRuntime, type MockRuntimeSession } from "../runtime/mock-runtime.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";

class CapturingRuntime extends MockRuntime {
  readonly handles: MockRuntimeSession[] = [];
  override async create(prompt: BuiltPrompt): Promise<RuntimeSessionHandle> {
    const handle = await super.create(prompt);
    this.handles.push(handle as MockRuntimeSession);
    return handle;
  }
}

const context = (text: string): PickyContextPacket => ({
  id: `context-${text}`,
  source: "text",
  capturedAt: "2026-05-01T00:00:00.000Z",
  transcript: text,
  cwd: "/tmp/project",
  screenshots: [],
  inkMarks: [],
  warnings: [],
});

describe("runtime event failures", () => {
  // The daemon's extension crash guard rethrows unhandled rejections and exits the process,
  // so a failed picky.json write while handling a main-agent event must not escape.
  it("does not raise an unhandled rejection when saving main state fails during an event", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-main-event-failure-"));
    const store = new SessionStore(dir);
    const mainRuntime = new CapturingRuntime();
    const supervisor = new SessionSupervisor(new MockRuntime(), store, { mainRuntime });
    await supervisor.load();
    await supervisor.route(context("hello"));
    const handle = mainRuntime.handles.at(-1);
    expect(handle).toBeDefined();

    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    const saveFailure = vi.spyOn(store, "saveMainAgentState").mockRejectedValue(new Error("disk full"));
    try {
      handle!.emit({ type: "assistant_delta", delta: "reply" });
      handle!.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "reply" });
      await vi.waitFor(() => expect(saveFailure).toHaveBeenCalled());
      // Let any rejection reach the process-level handler.
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(unhandled).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  it("does not raise an unhandled rejection when saving a Pickle fails during a runtime event", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-pickle-event-failure-"));
    const store = new SessionStore(dir);
    const runtime = new CapturingRuntime();
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();
    await supervisor.create(context("pickle"));
    const handle = runtime.handles.at(-1);
    expect(handle).toBeDefined();

    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    const saveFailure = vi.spyOn(store, "save").mockRejectedValue(new Error("disk full"));
    try {
      handle!.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "reply" });
      await vi.waitFor(() => expect(saveFailure).toHaveBeenCalled());
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(unhandled).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });
});
