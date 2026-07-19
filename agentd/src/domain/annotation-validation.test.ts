import { describe, expect, it } from "vitest";
import { clampAnnotation } from "./annotation-validation.js";

const screenshotSize = { width: 100, height: 80 };

describe("annotation validation", () => {
  it("clamps every supported shape to the selected screenshot while preserving spotlight", () => {
    expect(clampAnnotation({ id: "rect", shape: "rect", x: 90, y: 70, w: 30, h: 20, spotlight: true, label: "  Save  " }, screenshotSize)).toMatchObject({ x: 90, y: 70, w: 10, h: 10, spotlight: true, label: "Save", clamped: true });
    expect(clampAnnotation({ id: "line", shape: "line", x1: -2, y1: 5, x2: 120, y2: 100, spotlight: false }, screenshotSize)).toMatchObject({ x1: 0, y1: 5, x2: 100, y2: 80, spotlight: false, clamped: true });
  });

  it("clamps every PATH endpoint and control point", () => {
    expect(clampAnnotation({
      id: "path",
      shape: "path",
      commands: [
        { type: "move", x: -10, y: 10 },
        { type: "cubic", c1x: 20, c1y: -20, c2x: 120, c2y: 40, x: 110, y: 90 },
      ],
    }, screenshotSize)).toMatchObject({
      commands: [
        { type: "move", x: 0, y: 10 },
        { type: "cubic", c1x: 20, c1y: 0, c2x: 100, c2y: 40, x: 100, y: 80 },
      ],
      clamped: true,
    });
  });

  it("requires geometry appropriate to each shape", () => {
    expect(() => clampAnnotation({ id: "line", shape: "line", x1: 1, y1: 2, x2: 3 }, screenshotSize)).toThrow("y2 must be a finite number");
    expect(() => clampAnnotation({ id: "rect", shape: "rect", x: 1, y: 2, w: -1, h: 3 }, screenshotSize)).toThrow("dimensions must be non-negative");
    expect(() => clampAnnotation({ id: "path", shape: "path", commands: [{ type: "move", x: 1, y: 1 }] }, screenshotSize)).toThrow("2 to 32 commands");
    expect(() => clampAnnotation({ id: "path", shape: "path", commands: [{ type: "move", x: 1, y: 1 }, { type: "line", x: 2, y: 2 }], spotlight: true }, screenshotSize)).toThrow("does not support spotlight");
  });
});
