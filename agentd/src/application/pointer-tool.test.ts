import { describe, expect, it } from "vitest";
import { createPickyShowPointerTool, makePointerOverlayRequest, type PickyShowPointerRequest } from "./pointer-tool.js";

describe("pointer tool", () => {
  it("normalizes defaults and emits visual-only pointer requests", async () => {
    let received: PickyShowPointerRequest | undefined;
    const tool = createPickyShowPointerTool(async (request) => {
      received = request;
      return {
        emitted: request.dryRun !== true,
        request: makePointerOverlayRequest(request, {
          contextId: "context-1",
          screenId: "screen2",
          screenIndex: 2,
          screenBounds: { x: 100, y: 200, width: 300, height: 400 },
          screenshotSize: { width: 600, height: 800 },
        }),
      };
    });

    const result = await tool.execute("tool-1", { x: 601, y: -5, label: "  Try Eleven v3  ", durationMs: 99_999, confidence: 1.5 } as never, undefined, undefined, {} as never);

    expect(received).toMatchObject({ x: 601, y: -5, coordinateSpace: "screenshotPixel", label: "Try Eleven v3", durationMs: 10_000, confidence: 1, dryRun: false });
    expect(result.details).toMatchObject({ emitted: true, request: { coordinateSpace: "screenshotPixel", screenId: "screen2", durationMs: 10_000, confidence: 1 } });
    const content = result.content[0];
    expect(content?.type).toBe("text");
    if (content?.type !== "text") throw new Error("expected text content");
    expect(content.text).toContain("No real cursor/input action was performed");
  });

  it("supports dry-run validation without emitting", async () => {
    const tool = createPickyShowPointerTool(async (request) => ({
      emitted: request.dryRun !== true,
      request: makePointerOverlayRequest(request, {
        contextId: "context-1",
        screenId: "screen1",
        screenIndex: 1,
        screenBounds: { x: 0, y: 0, width: 100, height: 100 },
      }),
    }));

    const result = await tool.execute("tool-1", { x: 20, y: 30, coordinateSpace: "displayPoint", dryRun: true } as never, undefined, undefined, {} as never);

    expect(result.details).toMatchObject({ emitted: false, request: { dryRun: true, coordinateSpace: "displayPoint" } });
  });

  it("rejects non-finite coordinates before callback execution", async () => {
    const tool = createPickyShowPointerTool(async () => {
      throw new Error("should not execute");
    });

    await expect(tool.execute("tool-1", { x: Number.NaN, y: 1 } as never, undefined, undefined, {} as never)).rejects.toThrow(/finite x and y/);
  });
});
