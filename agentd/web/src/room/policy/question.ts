/**
 * Extension-UI question policies.
 *
 * Swift sources: `PickyQuestionOptionsLayoutPolicy` (option layout),
 * `PickyQuestionBubbleView` (which control each method draws, what each answer
 * sends) and `PickyAskUserQuestionFormState` (the form's answer object).
 */
import type { PickyExtensionUiRequest, PickyQuestionAnswerRow } from "../../../../src/protocol";

export type QuestionOptionsLayout = "inlineRow" | "stacked";

export const MAX_INLINE_OPTION_COUNT = 3;
export const MAX_INLINE_OPTION_LABEL_CHARACTERS = 8;
export const MAX_INLINE_LABEL_CHARACTERS = 18;

/**
 * Inline controls have to fit beside Cancel in the narrowest bubble. The
 * character heuristic keeps the choice deterministic without measuring a font,
 * exactly as the Mac does.
 */
export function optionsLayout(options: string[]): QuestionOptionsLayout {
  if (options.length > MAX_INLINE_OPTION_COUNT) return "stacked";
  if (options.some((option) => [...option].length > MAX_INLINE_OPTION_LABEL_CHARACTERS)) return "stacked";
  const total = options.reduce((sum, option) => sum + [...option].length, 0);
  if (total > MAX_INLINE_LABEL_CHARACTERS) return "stacked";
  return "inlineRow";
}

/** Methods the room renders as an interactive question. Everything else is a plain bubble. */
export type AnswerableMethod = "confirm" | "select" | "input" | "editor" | "askUserQuestion";

export function answerableMethod(request: PickyExtensionUiRequest): AnswerableMethod | null {
  switch (request.method) {
    case "confirm":
    case "select":
    case "input":
    case "editor":
    case "askUserQuestion":
      return request.method;
    default:
      return null;
  }
}

/**
 * Picks what a question row draws.
 *
 * The journal keeps a copy of the request as it was recorded, and the gateway
 * may trim it on the way to the phone, so the copy can arrive without its
 * `questions`, `options` or `text`. While the daemon still waits, the live
 * `pendingExtensionUiRequest` is the truth; once it is answered or cancelled,
 * the copy is all that is left and the bubble is history anyway.
 */
export interface ResolvedQuestion {
  request: PickyExtensionUiRequest;
  /** The daemon is still waiting for this answer. */
  active: boolean;
}

export function resolveQuestionRequest(
  copy: PickyExtensionUiRequest,
  pending: PickyExtensionUiRequest | undefined,
  cancelledAt?: string,
): ResolvedQuestion {
  const matches = pending !== undefined && pending.id === copy.id;
  const active = matches && !cancelledAt;
  return { request: active && pending ? pending : copy, active };
}

/** Cancelling any question sends this; the daemon reads it as "no answer". */
export const CANCELLED_ANSWER = { cancelled: true } as const;

export const OTHER_SENTINEL = "__picky_other__";

export type FormQuestion = NonNullable<PickyExtensionUiRequest["questions"]>[number];

/** Stable key for one form question: its own id, else `q1`, `q2`, ... */
export function formQuestionKey(question: FormQuestion, index: number): string {
  const trimmed = question.id?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : `q${index + 1}`;
}

export interface FormState {
  radio: Record<string, string>;
  checkbox: Record<string, string[]>;
  text: Record<string, string>;
  other: Record<string, string>;
}

export function emptyFormState(): FormState {
  return { radio: {}, checkbox: {}, text: {}, other: {} };
}

/** A question is required unless it says otherwise (`PickyExtensionUiQuestion.required ?? true`). */
export function isQuestionRequired(question: FormQuestion): boolean {
  return question.required ?? true;
}

/** "Type your own" is offered unless the question turns it off; a text question never needs it. */
export function allowsOther(question: FormQuestion): boolean {
  return question.type !== "text" && (question.allowOther ?? true);
}

/** Two or more questions are answered one at a time (`PickyAskUserQuestionStepper.usesSteps`). */
export function usesSteps(questions: FormQuestion[]): boolean {
  return questions.length > 1;
}

/** Seeds the form with each question's `default`, like the Mac's `seedDefaults`. */
export function seedFormState(questions: FormQuestion[]): FormState {
  const state = emptyFormState();
  questions.forEach((question, index) => {
    const key = formQuestionKey(question, index);
    const fallback = question.default;
    switch (question.type) {
      case "radio":
        if (typeof fallback === "string") state.radio[key] = fallback;
        break;
      case "checkbox":
        state.checkbox[key] = Array.isArray(fallback) ? [...fallback] : [];
        break;
      case "text":
        if (typeof fallback === "string") state.text[key] = fallback;
        break;
    }
  });
  return state;
}

export function isOptionSelected(state: FormState, question: FormQuestion, key: string, value: string): boolean {
  return question.type === "radio" ? state.radio[key] === value : (state.checkbox[key] ?? []).includes(value);
}

/**
 * Picking an option, as `PickyAskUserQuestionFormState` does it: a radio replaces
 * the choice, a checkbox toggles it. Unchecking "Type your own" drops its text so
 * it never rides along unseen.
 */
export function selectOption(state: FormState, question: FormQuestion, key: string, value: string): FormState {
  if (question.type === "radio") return { ...state, radio: { ...state.radio, [key]: value } };
  const chosen = state.checkbox[key] ?? [];
  const removing = chosen.includes(value);
  const next = removing ? chosen.filter((entry) => entry !== value) : [...chosen, value];
  const other = removing && value === OTHER_SENTINEL ? { ...state.other, [key]: "" } : state.other;
  return { ...state, checkbox: { ...state.checkbox, [key]: next }, other };
}

export function isOtherSelected(state: FormState, question: FormQuestion, key: string): boolean {
  return question.type === "radio"
    ? state.radio[key] === OTHER_SENTINEL
    : (state.checkbox[key] ?? []).includes(OTHER_SENTINEL);
}

/** A radio question answers with its "Type your own" text once that option is picked. */
export function radioAnswer(state: FormState, key: string): string {
  const selected = state.radio[key] ?? "";
  if (selected !== OTHER_SENTINEL) return selected;
  return (state.other[key] ?? "").trim();
}

/** A checkbox question answers with its picked values, plus its "Type your own" text at the end. */
export function checkboxAnswer(state: FormState, key: string): string[] {
  const chosen = state.checkbox[key] ?? [];
  const values = chosen.filter((value) => value !== OTHER_SENTINEL);
  const other = (state.other[key] ?? "").trim();
  if (chosen.includes(OTHER_SENTINEL) && other.length > 0) values.push(other);
  return values;
}

export type FormAnswerValue = string | string[] | null;

export function formAnswerObject(state: FormState, questions: FormQuestion[]): Record<string, FormAnswerValue> {
  const answer: Record<string, FormAnswerValue> = {};
  questions.forEach((question, index) => {
    const key = formQuestionKey(question, index);
    switch (question.type) {
      case "radio": {
        const value = radioAnswer(state, key);
        answer[key] = value.length > 0 ? value : null;
        break;
      }
      case "checkbox":
        answer[key] = checkboxAnswer(state, key);
        break;
      case "text":
        answer[key] = (state.text[key] ?? "").trim();
        break;
    }
  });
  return answer;
}

/** `askUserQuestion` wraps its answers in `{ value: { ... } }`. */
export function formAnswerPayload(state: FormState, questions: FormQuestion[]): { value: Record<string, FormAnswerValue> } {
  return { value: formAnswerObject(state, questions) };
}

export function isRequiredSatisfied(state: FormState, question: FormQuestion, index: number): boolean {
  if (!isQuestionRequired(question)) return true;
  const key = formQuestionKey(question, index);
  switch (question.type) {
    case "radio":
      return radioAnswer(state, key).length > 0;
    case "checkbox":
      return checkboxAnswer(state, key).length > 0;
    case "text":
      return (state.text[key] ?? "").trim().length > 0;
  }
}

/** Every `required` question must carry an answer before submit is allowed. */
export function isFormComplete(state: FormState, questions: FormQuestion[]): boolean {
  return questions.every((question, index) => isRequiredSatisfied(state, question, index));
}

/**
 * Whether the footer's primary action is allowed: mid-way it only needs the
 * current question, on the last (or only) one it needs the whole form
 * (`PickyAskUserQuestionStepper.isPrimaryEnabled`).
 */
export function isPrimaryEnabled(state: FormState, questions: FormQuestion[], step: number): boolean {
  const current = questions[step];
  if (!usesSteps(questions) || step >= questions.length - 1 || !current) return isFormComplete(state, questions);
  return isRequiredSatisfied(state, current, step);
}

/** Short answer for a finished step's chip: the first chosen label and how many more. */
export interface DisplayAnswer {
  first: string;
  more: number;
}

export function displayAnswer(state: FormState, question: FormQuestion, index: number): DisplayAnswer | null {
  const key = formQuestionKey(question, index);
  const options = question.options ?? [];
  const label = (value: string): string => options.find((option) => option.value === value)?.label ?? value;
  const labels =
    question.type === "radio"
      ? [label(radioAnswer(state, key))]
      : question.type === "checkbox"
        ? checkboxAnswer(state, key).map(label)
        : [(state.text[key] ?? "").trim()];
  const chosen = labels.filter((entry) => entry.length > 0);
  const first = chosen[0];
  return first === undefined ? null : { first, more: chosen.length - 1 };
}

/**
 * One line of what the user answered, for the collapsed bubble. The rows come
 * from the daemon (`extensionUiAnswerRows`), so the phone shows the same answer
 * text the HUD does.
 */
export function answerSummary(rows: PickyQuestionAnswerRow[] | undefined): string | null {
  const values = (rows ?? []).map((row) => row.value.trim()).filter((value) => value.length > 0);
  return values.length > 0 ? values.join(" · ") : null;
}
