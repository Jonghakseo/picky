import { describe, expect, it } from "vitest";
import { createPickyShowAnnotationsTool, PICKY_SHOW_ANNOTATIONS_TOOL_NAME } from "./annotation-tool.js";

const request = {
  id: "annotations-1",
  mode: "replace" as const,
  contextId: "context-1",
  screenId: "screen-1",
  screenBounds: { x: 0, y: 0, width: 200, height: 100 },
  screenshotSize: { width: 400, height: 200 },
  annotations: [{ id: "save", shape: "target" as const, x: 400, y: 0, r: 24, clamped: true }],
};

describe("picky_show_annotations", () => {
  it("forwards structured annotation requests and reports clamping", async () => {
    let received: unknown;
    const tool = createPickyShowAnnotationsTool(async (input) => {
      received = input;
      return { request };
    });

    const result = await tool.execute("tool-1", {
      mode: "replace",
      screenId: "screen-1",
      annotations: [{ id: "save", shape: "target", x: 410, y: -2, r: 24 }],
    } as never, undefined, undefined, {} as never);

    expect(received).toEqual({
      mode: "replace",
      screenId: "screen-1",
      annotations: [{ id: "save", shape: "target", x: 410, y: -2, r: 24 }],
    });
    expect(result.content[0]).toMatchObject({
      type: "text",
      text: "1 screen annotation shown at screenshot-pixel coordinates. 1 coordinate set was clamped to screenshot bounds.",
    });
    expect(result.details).toEqual({ request });
  });

  it("declares structured inputs and accepts an empty clear request", async () => {
    let received: unknown;
    const tool = createPickyShowAnnotationsTool(async (input) => {
      received = input;
      return { request: { ...request, mode: "clear", annotations: [] } };
    });
    const definition = tool as unknown as { name: string; parameters?: unknown; promptGuidelines?: string[] };

    const result = await tool.execute("tool-1", { mode: "clear", annotations: [] } as never, undefined, undefined, {} as never);

    expect(definition.name).toBe(PICKY_SHOW_ANNOTATIONS_TOOL_NAME);
    const parameters = JSON.stringify(definition.parameters);
    expect(parameters).toContain('"spotlight"');
    expect(parameters).toContain('"maxItems":24');
    expect(parameters).not.toContain('"zOrder"');
    expect(parameters).not.toContain('"Optional captured screen ID. It must match the request screen when supplied."');
    expect(definition.promptGuidelines?.join("\n")).toContain("one captured screen");
    expect(definition.promptGuidelines?.join("\n")).toContain("Do not use text tags");
    expect(received).toEqual({ mode: "clear", screenId: undefined, annotations: [] });
    expect(result.content[0]).toMatchObject({ type: "text", text: "Screen annotations cleared." });
  });

  it("returns a clear error when a non-clear call has no annotations", async () => {
    const tool = createPickyShowAnnotationsTool(async () => {
      throw new Error("should not run");
    });
    const result = await tool.execute("tool-1", { mode: "append", annotations: [] } as never, undefined, undefined, {} as never);

    expect(result.content[0]).toMatchObject({ type: "text", text: "Screen annotations unavailable: Annotations are required unless mode is clear." });
  });
});
