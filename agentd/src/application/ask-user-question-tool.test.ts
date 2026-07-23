import { describe, expect, it } from "vitest";
import { createPickyAskUserQuestionTool } from "./ask-user-question-tool.js";

describe("picky ask_user_question tool", () => {
  it("routes form requests through the Picky extension UI bridge", async () => {
    const tool = createPickyAskUserQuestionTool();
    const calls: unknown[] = [];

    const result = await tool.execute(
      "tool-1",
      {
        title: "복합 폼",
        description: "테스트",
        questions: [
          { id: "priority", type: "radio", prompt: "우선순위", options: ["P0", "P1"], allowOther: true },
          { id: "scope", type: "checkbox", prompt: "영향 범위", options: [{ value: "api", label: "API" }] },
          { id: "memo", type: "text", prompt: "메모", required: false },
        ],
      },
      undefined,
      undefined,
      {
        hasUI: true,
        ui: {
          askUserQuestion: async (request: unknown) => {
            calls.push(request);
            return { priority: "P1", scope: ["api"], memo: "확인" };
          },
        },
      } as never,
    );

    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ title: "복합 폼" });
    expect((calls[0] as { questions: Array<{ id: string }> }).questions[0]).toMatchObject({ id: "priority" });
    const text = textContent(result);
    expect(text).toContain("| priority | P1 |");
    expect(text).toContain("| scope | api |");
    expect(result.details).toEqual({ value: { priority: "P1", scope: ["api"], memo: "확인" }, cancelled: false });
  });

  it("returns a cancellation result when the bridge resolves without an answer", async () => {
    const tool = createPickyAskUserQuestionTool();

    const result = await tool.execute(
      "tool-1",
      { questions: [{ id: "q1", type: "text" }] },
      undefined,
      undefined,
      { hasUI: true, ui: { askUserQuestion: async () => undefined } } as never,
    );

    expect(textContent(result)).toContain("dismissed without a submitted answer");
    expect(textContent(result)).toContain("treat it as the answer");
    expect(result.details).toEqual({ cancelled: true });
  });
});

function textContent(result: Awaited<ReturnType<ReturnType<typeof createPickyAskUserQuestionTool>["execute"]>>): string {
  const first = result.content[0];
  if (first?.type !== "text") throw new Error("Expected text content");
  return first.text;
}
