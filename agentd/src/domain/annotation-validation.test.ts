import { describe, expect, it } from "vitest";
import { clampAnnotation } from "./annotation-validation.js";

const screenshotSize = { width: 100, height: 80 };

describe("annotation validation", () => {
  it("clamps every v1 shape to the selected screenshot", () => {
    expect(clampAnnotation({ id: "target", shape: "target", x: -1, y: 90, r: 8 }, screenshotSize)).toMatchObject({ x: 0, y: 80, r: 8, clamped: true });
    expect(clampAnnotation({ id: "circle", shape: "circle", x: 50, y: 40, rx: 120, ry: 2 }, screenshotSize)).toMatchObject({ x: 50, y: 40, rx: 100, ry: 2, clamped: true });
    expect(clampAnnotation({ id: "rect", shape: "rect", x: 90, y: 70, w: 30, h: 20 }, screenshotSize)).toMatchObject({ x: 90, y: 70, w: 10, h: 10, clamped: true });
    expect(clampAnnotation({ id: "line", shape: "line", x1: -2, y1: 5, x2: 120, y2: 100 }, screenshotSize)).toMatchObject({ x1: 0, y1: 5, x2: 100, y2: 80, clamped: true });
    expect(clampAnnotation({ id: "spotlight", shape: "spotlight", spotlightShape: "circle", x: 1, y: 2, r: 4 }, screenshotSize)).toMatchObject({ x: 1, y: 2, r: 4 });
    expect(clampAnnotation({ id: "label", shape: "label", x: 1, y: 2, label: "  Save  " }, screenshotSize)).toMatchObject({ x: 1, y: 2, label: "Save" });
  });

  it("requires geometry appropriate to each shape", () => {
    expect(() => clampAnnotation({ id: "circle", shape: "circle", x: 1, y: 2 }, screenshotSize)).toThrow("rx must be a finite number.");
    expect(() => clampAnnotation({ id: "spotlight", shape: "spotlight", x: 1, y: 2, r: 3 }, screenshotSize)).toThrow("spotlightShape is required");
    expect(() => clampAnnotation({ id: "label", shape: "label", x: 1, y: 2 }, screenshotSize)).toThrow("label annotations need non-empty label text.");
    expect(() => clampAnnotation({ id: "rect", shape: "rect", x: 1, y: 2, w: -1, h: 3 }, screenshotSize)).toThrow("dimensions must be non-negative");
  });
});
