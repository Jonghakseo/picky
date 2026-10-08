import { describe, expect, it } from "vitest";

import type { PickyExtensionUiRequest } from "../../../../src/protocol";
import {
  OTHER_SENTINEL,
  answerSummary,
  displayAnswer,
  formAnswerPayload,
  isFormComplete,
  isPrimaryEnabled,
  optionsLayout,
  resolveQuestionRequest,
  seedFormState,
  selectOption,
  type FormQuestion,
} from "./question";

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

const alerts: FormQuestion = {
  id: "alerts",
  type: "checkbox",
  prompt: "어디로 알릴까요?",
  options: [
    { value: "slack", label: "Slack" },
    { value: "email", label: "이메일" },
  ],
};

describe("answering a checkbox question with its own text", () => {
  it("sends the picked values plus the typed text, never the sentinel", () => {
    let form = seedFormState([alerts]);
    form = selectOption(form, alerts, "alerts", "slack");
    form = selectOption(form, alerts, "alerts", OTHER_SENTINEL);
    form = { ...form, other: { alerts: "  PagerDuty 당직  " } };

    expect(formAnswerPayload(form, [alerts])).toEqual({ value: { alerts: ["slack", "PagerDuty 당직"] } });
  });

  it("drops the typed text when the row is unchecked again", () => {
    let form = seedFormState([alerts]);
    form = selectOption(form, alerts, "alerts", OTHER_SENTINEL);
    form = { ...form, other: { alerts: "PagerDuty" } };
    form = selectOption(form, alerts, "alerts", OTHER_SENTINEL);

    expect(formAnswerPayload(form, [alerts])).toEqual({ value: { alerts: [] } });
  });

  it("does not count an empty own-text row as an answer", () => {
    let form = seedFormState([alerts]);
    form = selectOption(form, alerts, "alerts", OTHER_SENTINEL);

    expect(isFormComplete(form, [alerts])).toBe(false);
  });
});

describe("when submit is allowed", () => {
  const note: FormQuestion = { id: "note", type: "text", prompt: "덧붙일 조건이 있나요?" };

  it("treats a question without `required` as required, like the Mac form", () => {
    expect(isFormComplete(seedFormState([note]), [note])).toBe(false);
    expect(isFormComplete({ ...seedFormState([note]), text: { note: "결제 실패만" } }, [note])).toBe(true);
  });

  it("lets an explicitly optional question through", () => {
    const optional: FormQuestion = { ...note, required: false };
    expect(isFormComplete(seedFormState([optional]), [optional])).toBe(true);
  });

  it("gates `next` on the current step and `submit` on the whole form", () => {
    const questions = [alerts, note];
    const empty = seedFormState(questions);
    expect(isPrimaryEnabled(empty, questions, 0)).toBe(false);

    const answeredFirst = selectOption(empty, alerts, "alerts", "slack");
    expect(isPrimaryEnabled(answeredFirst, questions, 0)).toBe(true);
    expect(isPrimaryEnabled(answeredFirst, questions, 1)).toBe(false);

    const answeredBoth = { ...answeredFirst, text: { note: "결제 실패만" } };
    expect(isPrimaryEnabled(answeredBoth, questions, 1)).toBe(true);
  });
});

describe("what a finished step shows on its chip", () => {
  it("shows the option label, not the value, and how many more were picked", () => {
    let form = seedFormState([alerts]);
    form = selectOption(form, alerts, "alerts", "slack");
    expect(displayAnswer(form, alerts, 0)).toEqual({ first: "Slack", more: 0 });

    form = selectOption(form, alerts, "alerts", "email");
    expect(displayAnswer(form, alerts, 0)).toEqual({ first: "Slack", more: 1 });
  });

  it("has nothing to show before the question is answered", () => {
    expect(displayAnswer(seedFormState([alerts]), alerts, 0)).toBeNull();
  });
});

describe("collapsed answer summary", () => {
  it("joins the recorded answers into one line", () => {
    const rows = [
      { label: "버전", value: "0.9.3-beta.2" },
      { label: "노트", value: "HUD 렉 수정" },
    ];
    expect(answerSummary(rows)).toBe("0.9.3-beta.2 · HUD 렉 수정");
  });

  it("has no summary without recorded answers", () => {
    expect(answerSummary(undefined)).toBeNull();
    expect(answerSummary([{ label: "버전", value: "   " }])).toBeNull();
  });
});
