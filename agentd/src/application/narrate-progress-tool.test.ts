import { describe, expect, it } from "vitest";
import { createPickyNarrateProgressTool, type PickyNarrateProgressRequest } from "./narrate-progress-tool.js";

describe("createPickyNarrateProgressTool", () => {
  it("dispatches trimmed narration text to the callback", async () => {
    let received: PickyNarrateProgressRequest | undefined;
    const tool = createPickyNarrateProgressTool(async (request) => {
      received = request;
    });

    const result = await tool.execute("tool-1", { text: "  지금 파일을 살펴보고 있어요  " } as never, undefined, undefined, {} as never);

    expect(received).toEqual({ text: "지금 파일을 살펴보고 있어요" });
    if (result.content[0]?.type !== "text") throw new Error("expected text content");
    expect(result.content[0].text).toContain("Narration dispatched");
  });

  it("truncates overly long narration lines so they stay short on TTS", async () => {
    let received: PickyNarrateProgressRequest | undefined;
    const tool = createPickyNarrateProgressTool(async (request) => {
      received = request;
    });
    const longText = "가나다라마바사아자차카타파하".repeat(20);

    await tool.execute("tool-1", { text: longText } as never, undefined, undefined, {} as never);

    expect(received?.text.length).toBeLessThanOrEqual(80);
    expect(received?.text.endsWith("…")).toBe(true);
  });

  it("rejects empty narration so the agent does not waste a turn on silence", async () => {
    const tool = createPickyNarrateProgressTool(() => {});

    await expect(
      tool.execute("tool-1", { text: "   " } as never, undefined, undefined, {} as never),
    ).rejects.toThrow(/text must not be empty/);
  });

  it("warns the agent to skip duplicate narration when the setting may be off", () => {
    const tool = createPickyNarrateProgressTool(() => {});
    const definition = tool as unknown as { name: string; promptGuidelines?: string[] };

    expect(definition.name).toBe("picky_narrate_progress");
    const guidelines = definition.promptGuidelines?.join("\n") ?? "";
    expect(guidelines).toContain("disabled");
    expect(guidelines).toContain("do not retry");
    expect(guidelines).toContain("One narration per long step");
  });
});
