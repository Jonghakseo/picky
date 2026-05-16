import { describe, expect, it } from "vitest";
import { makePointerOverlayRequest } from "./pointer-tool.js";

describe("makePointerOverlayRequest", () => {
  it("trims label/screenId and falls back to default screenId when input is empty", () => {
    const overlay = makePointerOverlayRequest(
      { x: 12, y: 34, label: "  Try Eleven v3  ", screenId: "  " },
      {
        contextId: "context-1",
        screenId: "screen2",
        screenBounds: { x: 100, y: 200, width: 300, height: 400 },
        screenshotSize: { width: 600, height: 800 },
      },
    );

    expect(overlay).toMatchObject({
      contextId: "context-1",
      screenId: "screen2",
      x: 12,
      y: 34,
      label: "Try Eleven v3",
      screenshotSize: { width: 600, height: 800 },
    });
    expect(overlay.id).toMatch(/^pointer-/);
  });

  it("prefers an explicit input screenId over the default", () => {
    const overlay = makePointerOverlayRequest(
      { x: 1, y: 2, screenId: "screen5" },
      {
        screenId: "screen2",
        screenBounds: { x: 0, y: 0, width: 10, height: 10 },
        screenshotSize: { width: 10, height: 10 },
      },
    );

    expect(overlay.screenId).toBe("screen5");
    expect(overlay.label).toBeUndefined();
  });
});
