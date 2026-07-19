import { describe, expect, it } from "vitest";
import type { PickyContextPacket } from "../protocol.js";
import { PickleVisualDslCoordinator, type PickleVisualDslEvent } from "./pickle-visual-dsl-coordinator.js";

function context(): PickyContextPacket {
  return {
    id: "context-armed-pickle",
    source: "text-follow-up",
    capturedAt: "2026-07-19T00:00:00.000Z",
    transcript: "show me",
    screenshots: [{
      id: "shot-main",
      label: "Main",
      path: "/tmp/armed.png",
      screenId: "screen-main",
      bounds: { x: 0, y: 0, width: 800, height: 600 },
      screenshotWidthInPixels: 1600,
      screenshotHeightInPixels: 1200,
      isCursorScreen: true,
    }],
    inkMarks: [],
    warnings: [],
  };
}

function coordinatorEvents(): { coordinator: PickleVisualDslCoordinator; events: PickleVisualDslEvent[] } {
  const events: PickleVisualDslEvent[] = [];
  return {
    coordinator: new PickleVisualDslCoordinator((event) => events.push(event)),
    events,
  };
}

describe("PickleVisualDslCoordinator", () => {
  it("passes assistant text through when no visual lease is active", () => {
    const { coordinator, events } = coordinatorEvents();

    expect(coordinator.consumeAssistantDelta("pickle-1", "plain reply")).toBe("plain reply");
    expect(events).toEqual([]);
  });

  it("emits source-ordered narration and visual segment events grounded in the armed context", () => {
    const { coordinator, events } = coordinatorEvents();
    const lease = coordinator.createLease("pickle-1", context());
    coordinator.activate(lease);

    expect(coordinator.consumeAssistantDelta("pickle-1", "먼저. [SCREEN: id=screen-main] [RECT:")).toBe("먼저. ");
    expect(coordinator.consumeAssistantDelta("pickle-1", " x=10 y=20 w=30 h=40 label=\"영역\"] 보세요.")).toBe(" 보세요.");
    coordinator.finishAssistantMessage("pickle-1");

    expect(events.map((event) => event.type)).toEqual([
      "mainNarrationChunk",
      "mainVisualNarrationSegmentPrepared",
      "mainVisualNarrationSegmentSentence",
      "mainVisualNarrationSegmentCommitted",
    ]);
    expect(events[0]).toMatchObject({
      type: "mainNarrationChunk",
      contextId: "context-armed-pickle",
      text: "먼저.",
      originSource: "textFollowUp",
      replyKind: "main",
      sessionId: "pickle-1",
    });
    expect(events[1]).toMatchObject({
      type: "mainVisualNarrationSegmentPrepared",
      identity: {
        contextId: "context-armed-pickle",
        contextGeneration: 0,
        turnToken: lease.id,
        ordinal: 0,
      },
      visual: {
        kind: "annotations",
        request: {
          mode: "append",
          contextId: "context-armed-pickle",
          contextGeneration: 0,
          screenId: "screen-main",
          annotations: [{ shape: "rect", x: 10, y: 20, w: 30, h: 40, label: "영역" }],
        },
      },
    });
    expect(events[2]).toMatchObject({
      type: "mainVisualNarrationSegmentSentence",
      index: 0,
      text: "보세요.",
      originSource: "textFollowUp",
      replyKind: "main",
      sessionId: "pickle-1",
    });
    expect(events[3]).toMatchObject({
      type: "mainVisualNarrationSegmentCommitted",
      text: "보세요.",
      sentenceCount: 1,
      originSource: "textFollowUp",
      replyKind: "main",
      sessionId: "pickle-1",
    });
    expect(JSON.stringify(events[1])).toContain(lease.id);
  });

  it("emits one clean final reply for provider fallback without duplicating overlays", () => {
    const { coordinator, events } = coordinatorEvents();
    coordinator.activate(coordinator.createLease("pickle-1", context()));

    expect(coordinator.consumeAssistantDelta("pickle-1", "[LINE: x1=1 y1=2 x2=3 y2=4] 설명입니다.")).toBe(" 설명입니다.");
    coordinator.finishAssistantMessage("pickle-1");
    coordinator.completeAssistantRun("pickle-1", "[LINE: x1=1 y1=2 x2=3 y2=4] 설명입니다.");

    expect(events.filter((event) => event.type === "mainVisualNarrationSegmentPrepared")).toHaveLength(1);
    expect(events.at(-1)).toMatchObject({
      type: "quickReply",
      contextId: "context-armed-pickle",
      text: "설명입니다.",
      originSource: "textFollowUp",
      replyKind: "main",
      sessionId: "pickle-1",
      didStreamNarration: true,
    });
  });

  it("drops an unfinished tag when the assistant message ends", () => {
    const { coordinator, events } = coordinatorEvents();
    coordinator.activate(coordinator.createLease("pickle-1", context()));

    expect(coordinator.consumeAssistantDelta("pickle-1", "응답 [PATH:")).toBe("응답 ");
    coordinator.finishAssistantMessage("pickle-1");
    expect(coordinator.consumeAssistantDelta("pickle-1", "일반 텍스트")).toBe("일반 텍스트");
    expect(events).toEqual([
      expect.objectContaining({ type: "mainNarrationChunk", text: "응답" }),
    ]);
  });
});
