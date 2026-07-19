import { describe, expect, it } from "vitest";
import { parseAnnotationSvgPath } from "./annotation-svg-path.js";

describe("annotation SVG path", () => {
  it("parses the canonical absolute M L C subset", () => {
    expect(parseAnnotationSvgPath("M 10 20 L 30 40 C 50 60 70 80 90 100")).toEqual({
      commands: [
        { type: "move", x: 10, y: 20 },
        { type: "line", x: 30, y: 40 },
        { type: "cubic", c1x: 50, c1y: 60, c2x: 70, c2y: 80, x: 90, y: 100 },
      ],
      normalized: false,
      rounded: false,
    });
  });

  it("normalizes relative, axis, shorthand, quadratic, close, and repeated commands", () => {
    const parsed = parseAnnotationSvgPath("m 10 10 10 0 h 10 v 10 q 10 10 20 0 t 20 0 s 10 -10 20 0 z");

    expect(parsed).toMatchObject({ normalized: true, rounded: false });
    expect(parsed?.commands.map((command) => command.type)).toEqual(["move", "line", "line", "line", "cubic", "cubic", "cubic", "line"]);
    expect(parsed?.commands.slice(0, 4)).toEqual([
      { type: "move", x: 10, y: 10 },
      { type: "line", x: 20, y: 10 },
      { type: "line", x: 30, y: 10 },
      { type: "line", x: 30, y: 20 },
    ]);
    const firstQuadratic = parsed?.commands[4];
    expect(firstQuadratic).toMatchObject({ type: "cubic", x: 50, y: 20 });
    if (firstQuadratic?.type === "cubic") {
      expect(firstQuadratic.c1x).toBeCloseTo(36.6667, 4);
      expect(firstQuadratic.c1y).toBeCloseTo(26.6667, 4);
      expect(firstQuadratic.c2x).toBeCloseTo(43.3333, 4);
      expect(firstQuadratic.c2y).toBeCloseTo(26.6667, 4);
    }
    expect(parsed?.commands.slice(6)).toEqual([
      { type: "cubic", c1x: 70, c1y: 20, c2x: 80, c2y: 10, x: 90, y: 20 },
      { type: "line", x: 10, y: 10 },
    ]);
  });

  it("reflects prior controls for cubic and quadratic shorthand", () => {
    const parsed = parseAnnotationSvgPath("M 0 0 C 10 0 20 10 30 10 S 50 20 60 10 Q 70 0 80 10 T 100 10");

    expect(parsed?.commands[2]).toEqual({
      type: "cubic",
      c1x: 40, c1y: 10,
      c2x: 50, c2y: 20,
      x: 60, y: 10,
    });
    const smoothQuadratic = parsed?.commands[4];
    expect(smoothQuadratic).toMatchObject({ type: "cubic", x: 100, y: 10 });
    if (smoothQuadratic?.type === "cubic") {
      expect(smoothQuadratic.c1x).toBeCloseTo(86.6667, 4);
      expect(smoothQuadratic.c1y).toBeCloseTo(16.6667, 4);
      expect(smoothQuadratic.c2x).toBeCloseTo(93.3333, 4);
      expect(smoothQuadratic.c2y).toBeCloseTo(16.6667, 4);
    }
  });

  it("rounds authored fractional coordinates consistently with the annotation DSL", () => {
    expect(parseAnnotationSvgPath("M 10.4 20.5 L 30.6 40.2")).toEqual({
      commands: [
        { type: "move", x: 10, y: 21 },
        { type: "line", x: 31, y: 40 },
      ],
      normalized: false,
      rounded: true,
    });
  });

  it("rejects arcs, malformed paths, degenerate paths, and oversized command lists", () => {
    expect(parseAnnotationSvgPath("M 0 0 A 10 10 0 0 1 20 20")).toBeUndefined();
    expect(parseAnnotationSvgPath("M 0 0 C 1 2 3 4")).toBeUndefined();
    expect(parseAnnotationSvgPath("L 1 1")).toBeUndefined();
    expect(parseAnnotationSvgPath("M 1 1 L 1 1")).toBeUndefined();

    const oversized = `M 0 0 ${Array.from({ length: 32 }, (_, index) => `L ${index + 1} ${index + 1}`).join(" ")}`;
    expect(parseAnnotationSvgPath(oversized)).toBeUndefined();
  });
});
