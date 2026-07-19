import { describe, expect, it } from "vitest";
import type { PickyAnnotationOverlayRequest, PickyContextPacket } from "../protocol.js";
import { PickleVisualDslCoordinator } from "./pickle-visual-dsl-coordinator.js";

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

describe("PickleVisualDslCoordinator", () => {
  it("passes assistant text through when no visual lease is active", () => {
    const emitted: PickyAnnotationOverlayRequest[] = [];
    const coordinator = new PickleVisualDslCoordinator((request) => emitted.push(request));

    expect(coordinator.consumeAssistantDelta("pickle-1", "plain reply")).toBe("plain reply");
    expect(emitted).toEqual([]);
  });

  it("strips split DSL tags and emits annotations grounded in the armed context", () => {
    const emitted: PickyAnnotationOverlayRequest[] = [];
    const coordinator = new PickleVisualDslCoordinator((request) => emitted.push(request));
    const lease = coordinator.createLease("pickle-1", context());
    coordinator.activate(lease);

    expect(coordinator.consumeAssistantDelta("pickle-1", "먼저 [SCREEN: id=screen-main] [RECT:")).toBe("먼저 ");
    expect(coordinator.consumeAssistantDelta("pickle-1", " x=10 y=20 w=30 h=40 label=\"영역\"] 보세요.")).toBe(" 보세요.");

    expect(emitted).toHaveLength(1);
    expect(emitted[0]).toMatchObject({
      mode: "append",
      contextId: "context-armed-pickle",
      contextGeneration: 0,
      screenId: "screen-main",
      revealImmediately: true,
      annotations: [{ shape: "rect", x: 10, y: 20, w: 30, h: 40, label: "영역" }],
    });
    expect(emitted[0]?.annotations[0]?.id).toContain(lease.id);
  });

  it("sanitizes explicit final answers without emitting duplicate overlays", () => {
    const emitted: PickyAnnotationOverlayRequest[] = [];
    const coordinator = new PickleVisualDslCoordinator((request) => emitted.push(request));
    coordinator.activate(coordinator.createLease("pickle-1", context()));

    expect(coordinator.consumeAssistantDelta("pickle-1", "[LINE: x1=1 y1=2 x2=3 y2=4] 설명")).toBe(" 설명");
    const sanitized = coordinator.sanitizeCompleteText("pickle-1", "[LINE: x1=1 y1=2 x2=3 y2=4] 설명");

    expect(sanitized).toBe(" 설명");
    expect(emitted).toHaveLength(1);
  });

  it("drops an unfinished tag when the assistant message ends", () => {
    const emitted: PickyAnnotationOverlayRequest[] = [];
    const coordinator = new PickleVisualDslCoordinator((request) => emitted.push(request));
    coordinator.activate(coordinator.createLease("pickle-1", context()));

    expect(coordinator.consumeAssistantDelta("pickle-1", "응답 [PATH:")).toBe("응답 ");
    coordinator.finishAssistantMessage("pickle-1");
    expect(coordinator.consumeAssistantDelta("pickle-1", "일반 텍스트")).toBe("일반 텍스트");
    expect(emitted).toEqual([]);
  });
});
