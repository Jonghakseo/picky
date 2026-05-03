import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { normalizePiEvent } from "./domain/pi-event-normalizer.js";

const contractsRoot = join(process.cwd(), "..", "contracts", "pi-events");

async function fixture(name: string): Promise<unknown> {
  return JSON.parse(await readFile(join(contractsRoot, name), "utf8"));
}

describe("normalizePiEvent", () => {
  it("maps agent lifecycle events to Picky status", async () => {
    expect(normalizePiEvent(await fixture("agent-start.json"))).toMatchObject({ kind: "status", status: "running" });
    expect(normalizePiEvent(await fixture("agent-end.json"))).toMatchObject({ kind: "status", status: "completed" });
    expect(normalizePiEvent(await fixture("agent-end.json"), { hasQueuedFollowUp: true })).toMatchObject({ kind: "status", status: "running" });
    expect(normalizePiEvent(await fixture("abort-error.json"))).toMatchObject({ kind: "status", status: "failed" });
  });

  it("maps message deltas to assistant answer fragments", async () => {
    expect(normalizePiEvent(await fixture("message-text-delta.json"))).toEqual({ kind: "assistantDelta", delta: "Hello" });
  });

  it("maps thinking deltas to current-work thinking previews", async () => {
    expect(normalizePiEvent(await fixture("message-thinking-delta.json"))).toEqual({
      kind: "thinkingDelta",
      delta: "I need to inspect the HUD current work state.",
    });
  });

  it("correlates tool events by toolCallId", async () => {
    expect(normalizePiEvent(await fixture("tool-start.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "running" } });
    expect(normalizePiEvent(await fixture("tool-update.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "running" } });
    expect(normalizePiEvent(await fixture("tool-end-success.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-1", status: "succeeded" } });
    expect(normalizePiEvent(await fixture("tool-end-error.json"))).toMatchObject({ kind: "tool", tool: { toolCallId: "call-2", status: "failed" } });
  });

  it("marks dialog extension UI as waiting for input", async () => {
    expect(normalizePiEvent(await fixture("extension-ui-request-confirm.json"))).toMatchObject({ kind: "extensionUi", waitsForInput: true });
    expect(normalizePiEvent({ type: "extension_ui_request", id: "ui-form", method: "askUserQuestion", questions: [] })).toMatchObject({ kind: "extensionUi", waitsForInput: true });
  });

  it("logs queue updates without routing policy", async () => {
    expect(normalizePiEvent(await fixture("queue-update.json"))).toEqual({ kind: "log", line: "queue update: steering=1 followUp=1" });
  });
});
