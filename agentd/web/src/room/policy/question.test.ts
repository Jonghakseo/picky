import { describe, expect, it } from "vitest";

import type { PickyExtensionUiRequest } from "../../../../src/protocol";
import { optionsLayout, resolveQuestionRequest } from "./question";

function request(partial: Partial<PickyExtensionUiRequest> & Pick<PickyExtensionUiRequest, "id">): PickyExtensionUiRequest {
  return {
    sessionId: "s1",
    method: "askUserQuestion",
    createdAt: "2026-10-05T05:00:00.000Z",
    ...partial,
  };
}

describe("option layout", () => {
  it("keeps two short options on one row", () => {
    expect(optionsLayout(["켜기", "나중에"])).toBe("inlineRow");
  });

  it("stacks more than three options, a long label, or labels that add up too long", () => {
    expect(optionsLayout(["하나", "둘", "셋", "넷"])).toBe("stacked");
    expect(optionsLayout(["claude-sonnet-4-6", "짧음"])).toBe("stacked");
    expect(optionsLayout(["여덟글자짜리라벨", "여덟글자짜리라벨", "세글자"])).toBe("stacked");
  });
});

describe("which request a question row draws", () => {
  const copy = request({ id: "q1", title: "재시도 정책" });
  const pending = request({
    id: "q1",
    title: "재시도 정책",
    questions: [{ id: "interval", type: "radio", options: [{ value: "exp", label: "지수 백오프" }] }],
  });

  it("draws the live request while the daemon waits, so the form keeps its questions", () => {
    const resolved = resolveQuestionRequest(copy, pending);
    expect(resolved.active).toBe(true);
    expect(resolved.request.questions).toHaveLength(1);
  });

  it("falls back to the journal copy once the question is answered", () => {
    const resolved = resolveQuestionRequest(copy, undefined);
    expect(resolved.active).toBe(false);
    expect(resolved.request).toBe(copy);
  });

  it("does not borrow a different pending question", () => {
    const other = request({ id: "q2", questions: [{ id: "x", type: "text" }] });
    const resolved = resolveQuestionRequest(copy, other);
    expect(resolved.active).toBe(false);
    expect(resolved.request).toBe(copy);
  });

  it("treats a cancelled question as history even while the id still matches", () => {
    const resolved = resolveQuestionRequest(copy, pending, "2026-10-05T05:01:00.000Z");
    expect(resolved.active).toBe(false);
    expect(resolved.request).toBe(copy);
  });
});
