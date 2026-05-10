import { describe, expect, it } from "vitest";
import { createPickyOpenPickleResponseTool, type PickyOpenPickleResponseRequest } from "./open-pickle-response-tool.js";

describe("createPickyOpenPickleResponseTool", () => {
  it("forwards the sessionId to the onOpen callback and surfaces the result via details", async () => {
    let received: PickyOpenPickleResponseRequest | undefined;
    const tool = createPickyOpenPickleResponseTool(async (request) => {
      received = request;
      return {
        sessionId: request.sessionId,
        messageId: "final-answer",
        source: "finalAnswer",
        status: "completed",
        charCount: 42,
      };
    });

    const result = await tool.execute("tool-1", { sessionId: "pickle-7" } as never, undefined, undefined, {} as never);

    expect(received).toEqual({ sessionId: "pickle-7" });
    expect(result.details).toEqual({
      sessionId: "pickle-7",
      messageId: "final-answer",
      source: "finalAnswer",
      status: "completed",
      charCount: 42,
    });
    if (result.content[0]?.type !== "text") throw new Error("expected text content");
    expect(result.content[0].text).toContain("Opened Pickle response");
    expect(result.content[0].text).toContain("source=finalAnswer");
  });

  it("surfaces errors thrown by the onOpen callback when the Pickle has no response", async () => {
    const tool = createPickyOpenPickleResponseTool(async () => {
      throw new Error("Pickle has no response yet.");
    });

    await expect(tool.execute("tool-1", { sessionId: "pickle-empty" } as never, undefined, undefined, {} as never)).rejects.toThrow(/no response yet/);
  });

  it("guides the model to call this tool only on explicit user request", () => {
    const tool = createPickyOpenPickleResponseTool(async () => ({ sessionId: "x", messageId: "final-answer", source: "finalAnswer", status: "completed", charCount: 0 }));
    const definition = tool as unknown as { promptGuidelines?: string[] };
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";

    expect(guidelines).toContain("Only call");
    expect(guidelines).toContain("explicitly asks");
    expect(guidelines).toContain("markdown viewer");
  });
});
