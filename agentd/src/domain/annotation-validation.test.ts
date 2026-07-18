import { describe, expect, it } from "vitest";
import { clampAnnotation } from "./annotation-validation.js";

const screenshotSize = { width: 100, height: 80 };

describe("annotation validation", () => {
  it("clamps every supported shape to the selected screenshot while preserving spotlight", () => {
    expect(clampAnnotation({ id: "rect", shape: "rect", x: 90, y: 70, w: 30, h: 20, spotlight: true }, screenshotSize)).toMatchObject({ x: 90, y: 70, w: 10, h: 10, spotlight: true, clamped: true });
    expect(clampAnnotation({ id: "line", shape: "line", x1: -2, y1: 5, x2: 120, y2: 100, spotlight: false }, screenshotSize)).toMatchObject({ x1: 0, y1: 5, x2: 100, y2: 80, spotlight: false, clamped: true });
    expect(clampAnnotation({ id: "label", shape: "label", x: 1, y: 2, label: "  Save  " }, screenshotSize)).toMatchObject({ x: 1, y: 2, label: "Save" });
  });

  it("requires geometry appropriate to each shape", () => {
    expect(() => clampAnnotation({ id: "label", shape: "label", x: 1, y: 2 }, screenshotSize)).toThrow("label annotations need non-empty label text.");
    expect(() => clampAnnotation({ id: "rect", shape: "rect", x: 1, y: 2, w: -1, h: 3 }, screenshotSize)).toThrow("dimensions must be non-negative");
  });
});
