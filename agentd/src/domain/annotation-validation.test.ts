import { describe, expect, it } from "vitest";
import { clampAnnotation } from "./annotation-validation.js";

const screenshotSize = { width: 100, height: 80 };

describe("annotation validation", () => {
  it("clamps every supported shape to the selected screenshot while preserving spotlight", () => {
    expect(clampAnnotation({ id: "rect", shape: "rect", x: 90, y: 70, w: 30, h: 20, spotlight: true, label: "  Save  " }, screenshotSize)).toMatchObject({ x: 90, y: 70, w: 10, h: 10, spotlight: true, label: "Save", clamped: true });
    expect(clampAnnotation({ id: "line", shape: "line", x1: -2, y1: 5, x2: 120, y2: 100, spotlight: false }, screenshotSize)).toMatchObject({ x1: 0, y1: 5, x2: 100, y2: 80, spotlight: false, clamped: true });
  });

  it("requires geometry appropriate to each shape", () => {
    expect(() => clampAnnotation({ id: "line", shape: "line", x1: 1, y1: 2, x2: 3 }, screenshotSize)).toThrow("y2 must be a finite number");
    expect(() => clampAnnotation({ id: "rect", shape: "rect", x: 1, y: 2, w: -1, h: 3 }, screenshotSize)).toThrow("dimensions must be non-negative");
  });
});
