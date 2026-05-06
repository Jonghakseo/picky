import { describe, expect, it } from "vitest";
import { createPickyShowPointerTool, makePointerOverlayRequest, type PickyShowPointerRequest } from "./pointer-tool.js";

describe("pointer tool", () => {
  it("normalizes label and emits visual-only screenshot-pixel pointer requests", async () => {
    let received: PickyShowPointerRequest | undefined;
    const tool = createPickyShowPointerTool(async (request) => {
      received = request;
      return {
        request: makePointerOverlayRequest(request, {
          contextId: "context-1",
          screenId: "screen2",
          screenBounds: { x: 100, y: 200, width: 300, height: 400 },
          screenshotSize: { width: 600, height: 800 },
        }),
      };
    });

    const result = await tool.execute("tool-1", { x: 601, y: -5, label: "  Try Eleven v3  " } as never, undefined, undefined, {} as never);

    expect(received).toMatchObject({ x: 601, y: -5, label: "Try Eleven v3" });
    expect(result.details).toMatchObject({ request: { screenId: "screen2", screenshotSize: { width: 600, height: 800 } } });
    const content = result.content[0];
    expect(content?.type).toBe("text");
    if (content?.type !== "text") throw new Error("expected text content");
    expect(content.text).toContain("in screenshot pixels");
    expect(content.text).toContain("No real cursor/input action was performed");
  });

  it("rejects non-finite coordinates before callback execution", async () => {
    const tool = createPickyShowPointerTool(async () => {
      throw new Error("should not execute");
    });

    await expect(tool.execute("tool-1", { x: Number.NaN, y: 1 } as never, undefined, undefined, {} as never)).rejects.toThrow(/finite x and y/);
  });
});
