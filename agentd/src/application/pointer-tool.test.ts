import { describe, expect, it } from "vitest";
import { createPickyShowPointerTool, makePointerOverlayRequest, PICKY_SHOW_POINTER_TOOL_NAME } from "./pointer-tool.js";

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

  it("forwards structured screenshot coordinates to the supervisor and reports resolved coordinates", async () => {
    let received: unknown;
    const tool = createPickyShowPointerTool(async (request) => {
      received = request;
      return {
        request: {
          id: "pointer-1",
          contextId: "context-1",
          screenId: "screen2",
          x: 0,
          y: 800,
          label: "Save",
          clamped: true,
          screenBounds: { x: 100, y: 200, width: 300, height: 400 },
          screenshotSize: { width: 600, height: 800 },
        },
      };
    });

    const result = await tool.execute(
      "tool-1",
      { x: -20, y: 900, label: "Save", screenId: "screen2" } as never,
      undefined,
      undefined,
      {} as never,
    );
    const content = result.content[0];

    expect(received).toEqual({ x: -20, y: 900, label: "Save", screenId: "screen2" });
    expect(content).toMatchObject({
      type: "text",
      text: "Pointer shown at screenshot pixel (0, 800) on screen2. Coordinates were clamped to the screenshot bounds.",
    });
    expect(result.details).toMatchObject({ request: { x: 0, y: 800, clamped: true } });
  });

  it("declares structured pointer inputs and returns unavailable screenshot errors", async () => {
    const tool = createPickyShowPointerTool(async () => {
      throw new Error("No captured Picky context is available for pointer overlay validation.");
    });
    const definition = tool as unknown as { name: string; parameters?: unknown; promptGuidelines?: string[] };
    const schema = JSON.stringify(definition.parameters);

    const result = await tool.execute("tool-1", { x: 120, y: 240 } as never, undefined, undefined, {} as never);
    const content = result.content[0];

    expect(definition.name).toBe(PICKY_SHOW_POINTER_TOOL_NAME);
    expect(schema).toContain('"x"');
    expect(schema).toContain('"y"');
    expect(schema).toContain('"label"');
    expect(schema).toContain('"screenId"');
    expect(definition.promptGuidelines?.join("\n")).toContain("Do not use text tags");
    expect(content).toMatchObject({
      type: "text",
      text: "Pointer overlay unavailable: No captured Picky context is available for pointer overlay validation.",
    });
    expect(result.details).toEqual({ error: "No captured Picky context is available for pointer overlay validation." });
  });
});
