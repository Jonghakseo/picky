import { describe, expect, it } from "vitest";
import { titleFromContext } from "../domain/session-title.js";
import { compactSessionsForSnapshot } from "../server.js";
import { RuntimeEventHandler } from "../application/runtime-event-handler.js";
import type { PickyAgentSession, PickyContextPacket } from "../protocol.js";

describe("picky agentd known bugs (failing reproductions)", () => {
  it("[BUG 1] titleFromContext slices at UTF-16 boundary and produces a lone surrogate when the input contains emoji that crosses the truncation point", () => {
    // The truncation does `text.slice(0, 57) + "..."`. If a non-BMP character (e.g. 🎉) sits
    // exactly at code-unit boundary 56–57, the slice cuts the surrogate pair in half,
    // producing a string with a stray high-surrogate (and the second half permanently lost).
    const emojiTask = "🎉".repeat(31); // 62 UTF-16 code units > 60 → triggers truncation.
    const title = titleFromContext({ transcript: emojiTask } as PickyContextPacket);

    for (let i = 0; i < title.length; i += 1) {
      const code = title.charCodeAt(i);
      const isHigh = code >= 0xd800 && code <= 0xdbff;
      const isLow = code >= 0xdc00 && code <= 0xdfff;
      if (isHigh) {
        const next = title.charCodeAt(i + 1);
        expect(
          next >= 0xdc00 && next <= 0xdfff,
          `lone high surrogate at index ${i} of ${JSON.stringify(title)}`,
        ).toBe(true);
        i += 1;
        continue;
      }
      expect(isLow, `lone low surrogate at index ${i} of ${JSON.stringify(title)}`).toBe(false);
    }
  });

  it("[BUG 2] RuntimeEventHandler.applyStatusEvent resurrects a cancelled session when a stray 'running' status arrives after abort", async () => {
    // Only terminal->terminal transitions are guarded. A `running` (or `waiting_for_input`,
    // `blocked`) status event after abort flips the session out of `cancelled`, losing the
    // user's cancellation and re-opening the loading state in the HUD.
    const session: PickyAgentSession = {
      id: "s-cancel",
      title: "Cancelled session",
      status: "cancelled",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:00.000Z",
      lastSummary: "Cancelled",
      logs: [],
      tools: [],
      artifacts: [],
      changedFiles: [],
    };

    const handler = new RuntimeEventHandler({
      getSession: () => session,
      patchSession: async (_id, patch) => {
        Object.assign(session, patch);
      },
      emitToolActivityUpdated: () => {},
      appendLog: async () => {},
      materializeTerminalArtifacts: async () => {},
      applyQueueUpdate: async () => {},
      incrementActivity: async () => {},
      commitTurnActivity: async () => {},
      notifyPickleCompletion: async () => {},
      isPickleSession: () => false,
      emitExtensionUiRequest: () => {},
      messageBuilder: {
        recordExtensionQuestion: async () => {},
        recordExtensionNotification: async () => {},
        cancelExtensionQuestion: async () => {},
        recordError: async () => {},
        recordSystemMessage: async () => {},
        recordUserText: async () => {},
        appendAssistantDelta: () => {},
        flushAssistantText: async () => {},
        appendThinkingDelta: async () => {},
        flushThinking: async () => {},
        clearAllThinking: async () => {},
        recordActivitySnapshot: async () => {},
      },
    });

    await handler.handle("s-cancel", { type: "status", status: "running", summary: "stray turn" });

    expect(session.status).toBe("cancelled");
  });

  it("[BUG 3] compactSessionsForSnapshot reorders 'important' logs to the front, breaking the HUD timeline's chronological order", () => {
    // compactSnapshotLogs builds [...important, ...recent] then dedupes. When an important
    // log appears mid-transcript, it gets pulled to the start of the snapshot and ends up
    // before older non-important entries that originally preceded it.
    const logs = [
      ...Array.from({ length: 20 }, (_, index) => `noisy log ${index}`),
      "steer: keep this important log",
      ...Array.from({ length: 5 }, (_, index) => `tail log ${index}`),
    ];
    const session: PickyAgentSession = {
      id: "session-order",
      title: "Order check",
      status: "running",
      cwd: "/tmp",
      createdAt: "2026-05-03T00:00:00.000Z",
      updatedAt: "2026-05-03T00:00:01.000Z",
      logs,
      tools: [],
      artifacts: [],
      changedFiles: [],
    };

    const [compact] = compactSessionsForSnapshot([session]);
    const steerIndex = compact.logs.indexOf("steer: keep this important log");
    const earlierEntryIndex = compact.logs.indexOf("noisy log 15");

    expect(steerIndex).toBeGreaterThan(-1);
    expect(earlierEntryIndex).toBeGreaterThan(-1);
    // 'noisy log 5' chronologically came BEFORE the steer line, so it should also come
    // before in the snapshot. The compactor reorders them.
    expect(earlierEntryIndex).toBeLessThan(steerIndex);
  });
});
