import { describe, expect, it } from "vitest";
import type { PickyContextPacket } from "../protocol.js";
import { clampPointerCoordinates, selectPointerScreenshot, screenshotSizeFromMetadata } from "./pointer-validation.js";

type ScreenshotContext = PickyContextPacket["screenshots"][number];

function screenshot(overrides: Partial<ScreenshotContext> = {}): ScreenshotContext {
  return {
    id: "shot-1",
    label: "Screen 1",
    path: "/tmp/shot-1.jpg",
    ...overrides,
  };
}

describe("pointer validation", () => {
  it("rejects empty screenshot snapshots", () => {
    expect(() => selectPointerScreenshot([], {})).toThrow("No screenshots are available for pointer overlay validation.");
  });

  it("selects an explicit screenId match", () => {
    const selected = selectPointerScreenshot([
      screenshot({ id: "shot-a", screenId: "screen-a" }),
      screenshot({ id: "shot-b", screenId: "screen-b" }),
    ], { screenId: " screen-b " });

    expect(selected.id).toBe("shot-b");
  });

  it("selects an explicit screenshot id match", () => {
    const selected = selectPointerScreenshot([
      screenshot({ id: "shot-a", screenId: "screen-a" }),
      screenshot({ id: "shot-b", screenId: "screen-b" }),
    ], { screenId: "shot-b" });

    expect(selected.screenId).toBe("screen-b");
  });

  it("rejects unknown explicit screen ids", () => {
    expect(() => selectPointerScreenshot([screenshot({ screenId: "screen-a" })], { screenId: "missing" })).toThrow("Unknown pointer overlay screenId: missing");
  });

  it("preserves first-match behavior when a screenshot id collides with a later screenId", () => {
    const selected = selectPointerScreenshot([
      screenshot({ id: "target", screenId: "screen-a" }),
      screenshot({ id: "shot-b", screenId: "target" }),
    ], { screenId: "target" });

    expect(selected.id).toBe("target");
  });

  it("selects the first screenshot explicitly marked as the cursor screen when earlier screenshots have no cursor hint", () => {
    const selected = selectPointerScreenshot([
      screenshot({ id: "shot-a", label: "Secondary display" }),
      screenshot({ id: "shot-b", label: "External", isCursorScreen: true }),
    ], {});

    expect(selected.id).toBe("shot-b");
  });

  it("falls back to cursor/primary/focus labels before the first screenshot", () => {
    const selected = selectPointerScreenshot([
      screenshot({ id: "shot-a", label: "Secondary display" }),
      screenshot({ id: "shot-b", label: "Focus screen" }),
    ], {});

    expect(selected.id).toBe("shot-b");
  });

  it("falls back to the first screenshot when no cursor hint exists", () => {
    const selected = selectPointerScreenshot([
      screenshot({ id: "shot-a", label: "Secondary display" }),
      screenshot({ id: "shot-b", label: "Other display" }),
    ], {});

    expect(selected.id).toBe("shot-a");
  });

  it("returns screenshot dimensions only when both metadata fields are present", () => {
    expect(screenshotSizeFromMetadata(screenshot({ screenshotWidthInPixels: 600, screenshotHeightInPixels: 800 }))).toEqual({ width: 600, height: 800 });
    expect(screenshotSizeFromMetadata(screenshot({ screenshotWidthInPixels: 600 }))).toBeUndefined();
    expect(screenshotSizeFromMetadata(screenshot({ screenshotHeightInPixels: 800 }))).toBeUndefined();
  });

  it("clamps pointer coordinates to screenshot dimensions and reports whether it clamped", () => {
    expect(clampPointerCoordinates({ x: -1, y: 101 }, { width: 100, height: 100 })).toEqual({ x: 0, y: 100, clamped: true });
    expect(clampPointerCoordinates({ x: 25, y: 75 }, { width: 100, height: 100 })).toEqual({ x: 25, y: 75, clamped: undefined });
  });

  it("clamps an optional highlight radius like screenshot coordinates", () => {
    expect(clampPointerCoordinates({ x: 25, y: 75, r: 120 }, { width: 100, height: 80 })).toEqual({ x: 25, y: 75, r: 100, clamped: true });
    expect(clampPointerCoordinates({ x: 25, y: 75, r: 12 }, { width: 100, height: 80 })).toEqual({ x: 25, y: 75, r: 12 });
    expect(() => clampPointerCoordinates({ x: 25, y: 75, r: -1 }, { width: 100, height: 80 })).toThrow("r must be a non-negative finite number.");
  });

  it("treats screenshot width and height as inclusive max-edge coordinates", () => {
    expect(clampPointerCoordinates({ x: 100, y: 100 }, { width: 100, height: 100 })).toEqual({ x: 100, y: 100, clamped: undefined });
  });
});
