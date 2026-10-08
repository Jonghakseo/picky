/**
 * Extension-UI question bubble.
 * Source: docs/prototypes/picky-ask-question (P1-P4) and the Mac form policy in
 * Picky/PickyAskUserQuestionForm.swift, so the phone and the HUD ask the same way.
 *
 * A waiting question is the next thing to do, not a warning: neutral surface,
 * accent border, one primary action. Two or more questions are answered one at
 * a time. Answered or skipped questions collapse to one line that carries the
 * answer summary and expand on tap, with no controls redrawn.
 */
import { Fragment } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { JSX } from "preact";

import type { PickyExtensionUiRequest, PickyQuestionAnswerRow } from "../../../../src/protocol";
import { CheckCircle, Checkmark, ChevronDown, ChevronRight, MinusCircle, QuestionCircle } from "../icons";
import { t } from "../i18n";
import {
  CANCELLED_ANSWER,
  OTHER_SENTINEL,
  allowsOther,
  answerSummary,
  answerableMethod,
  displayAnswer,
  formAnswerPayload,
  formQuestionKey,
  isOptionSelected,
  isOtherSelected,
  isPrimaryEnabled,
  isQuestionRequired,
  optionsLayout,
  seedFormState,
  selectOption,
  usesSteps,
  type FormQuestion,
  type FormState,
} from "../policy/question";

export interface QuestionBubbleProps {
  request: PickyExtensionUiRequest;
  /** False once the daemon moved on: the bubble collapses into its answered form. */
  active: boolean;
  /** What the user answered, for the collapsed summary. Absent on skipped questions. */
  answerRows?: PickyQuestionAnswerRow[];
  /** The question was closed without an answer. */
  cancelled?: boolean;
  onAnswer: (value: unknown) => Promise<boolean>;
}

export function QuestionBubble({ request, active, answerRows, cancelled, onAnswer }: QuestionBubbleProps): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [failed, setFailed] = useState(false);
  const [lastValue, setLastValue] = useState<unknown>(undefined);
  const [text, setText] = useState(request.text ?? "");
  const [form, setForm] = useState<FormState>(() => seedFormState(request.questions ?? []));
  const [step, setStep] = useState(0);
  const otherField = useRef<HTMLInputElement | null>(null);
  const method = answerableMethod(request);

  async function send(value: unknown): Promise<void> {
    setSubmitting(true);
    setLastValue(value);
    const ok = await onAnswer(value);
    setSubmitting(false);
    setFailed(!ok);
  }

  if (!active) {
    return (
      <ClosedQuestion
        request={request}
        answerRows={answerRows}
        cancelled={cancelled === true}
        expanded={expanded}
        onToggle={() => setExpanded(!expanded)}
      />
    );
  }

  const questions = request.questions ?? [];
  const options = request.options ?? [];
  const layout = optionsLayout(options);
  const disabled = submitting;
  const stepped = method === "askUserQuestion" && usesSteps(questions);
  const stepIndex = Math.min(step, Math.max(questions.length - 1, 0));
  const current = method === "askUserQuestion" ? questions[stepIndex] : undefined;
  const isLastStep = stepIndex >= questions.length - 1;
  const primaryEnabled = isPrimaryEnabled(form, questions, stepIndex);
  // A single question needs no second heading: its prompt is the title.
  const heading = request.title ?? (stepped || !current ? undefined : current.prompt ?? current.label);
  const promptIsHeading = request.title === undefined && !stepped;

  const failure = failed ? (
    <div class="q-failed">
      <span class="q-failed-text">{t("hud.question.sendFailed")}</span>
      <button class="q-link" type="button" onClick={() => void send(lastValue)}>
        {t("hud.error.retry")}
      </button>
    </div>
  ) : null;

  function skipButton(): JSX.Element {
    return (
      <button class="q-btn is-ghost" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
        {t("hud.question.skip")}
      </button>
    );
  }

  function primaryLabel(label: string): JSX.Element {
    return (
      <Fragment>
        {submitting ? <span class="q-spinner" aria-hidden="true" /> : null}
        <span>{label}</span>
      </Fragment>
    );
  }

  return (
    <div
      class={`q-bubble${submitting ? " is-sending" : ""}`}
      data-question-id={request.id}
    >
      <div class="q-header">
        <QuestionCircle class="q-head-icon" />
        <span class="q-status">{t("hud.question.needed")}</span>
        {stepped ? (
          <span class="q-step" aria-label={t("hud.question.step", stepIndex + 1, questions.length)}>
            {`${stepIndex + 1} / ${questions.length}`}
          </span>
        ) : null}
      </div>
      {heading ? <div class="q-title">{heading}</div> : null}
      {request.prompt && request.prompt !== heading ? <div class="q-body">{request.prompt}</div> : null}
      {request.description ? <div class="q-description">{request.description}</div> : null}

      {method === "confirm" ? (
        <div class="q-foot">
          <button class="q-btn is-ghost" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
            {t("common.cancel")}
          </button>
          <button class="q-btn is-primary" type="button" disabled={disabled} onClick={() => void send(true)}>
            {primaryLabel(t("hud.question.allow"))}
          </button>
        </div>
      ) : null}

      {method === "select" && layout === "inlineRow" ? (
        <div class="q-chips">
          {options.map((option) => (
            <button key={option} class="q-chip-btn" type="button" disabled={disabled} onClick={() => void send(option)}>
              {option}
            </button>
          ))}
          {skipButton()}
        </div>
      ) : null}

      {method === "select" && layout === "stacked" ? (
        <Fragment>
          <div class="q-opts" role="radiogroup">
            {options.map((option) => (
              <button
                key={option}
                class="q-opt"
                type="button"
                role="radio"
                aria-checked={false}
                disabled={disabled}
                onClick={() => void send(option)}
              >
                <span class="q-ind is-radio" aria-hidden="true" />
                <span class="q-opt-text">
                  <span class="q-opt-label">{option}</span>
                </span>
              </button>
            ))}
          </div>
          <div class="q-foot">{skipButton()}</div>
        </Fragment>
      ) : null}

      {method === "input" || method === "editor" ? (
        <Fragment>
          <input
            class="q-field"
            type="text"
            value={text}
            aria-label={request.title ?? request.prompt ?? t("hud.question.responsePlaceholder")}
            placeholder={t("hud.question.responsePlaceholder")}
            disabled={disabled}
            onInput={(event: JSX.TargetedEvent<HTMLInputElement>) => setText(event.currentTarget.value)}
          />
          <div class="q-foot">
            {skipButton()}
            <button
              class="q-btn is-primary"
              type="button"
              disabled={disabled || text.trim().length === 0}
              onClick={() => void send(text.trim())}
            >
              {primaryLabel(t("hud.question.submit"))}
            </button>
          </div>
        </Fragment>
      ) : null}

      {method === "askUserQuestion" ? (
        <Fragment>
          {stepped ? (
            <Fragment>
              <div class="q-progress" aria-hidden="true">
                {questions.map((question, index) => (
                  <span
                    key={formQuestionKey(question, index)}
                    class={index < stepIndex ? "is-done" : index === stepIndex ? "is-current" : ""}
                  />
                ))}
              </div>
              {stepIndex > 0 ? (
                <div class="q-prev">
                  {questions.slice(0, stepIndex).map((question, index) => {
                    const answer = displayAnswer(form, question, index);
                    if (!answer) return null;
                    const label = question.label ?? question.prompt ?? "";
                    const value = answer.more > 0 ? t("hud.question.answerMore", answer.first, answer.more) : answer.first;
                    return (
                      <button
                        key={formQuestionKey(question, index)}
                        class="q-chip"
                        type="button"
                        disabled={disabled}
                        onClick={() => setStep(index)}
                      >
                        {label ? <span class="q-chip-label">{label}</span> : null}
                        <span class="q-chip-value">{value}</span>
                      </button>
                    );
                  })}
                </div>
              ) : null}
            </Fragment>
          ) : null}

          {current ? (
            <QuestionFields
              question={current}
              index={stepIndex}
              form={form}
              disabled={disabled}
              hidePrompt={promptIsHeading}
              otherField={otherField}
              onChange={setForm}
            />
          ) : (
            <div class="q-description">{t("hud.question.empty")}</div>
          )}

          <div class="q-foot">
            {!primaryEnabled ? <span class="q-foot-hint">{t("hud.question.required")}</span> : null}
            {stepped && stepIndex > 0 ? (
              <button class="q-btn is-secondary" type="button" disabled={disabled} onClick={() => setStep(stepIndex - 1)}>
                {t("hud.question.previous")}
              </button>
            ) : null}
            {stepped ? null : skipButton()}
            {stepped && !isLastStep ? (
              <button
                class="q-btn is-primary"
                type="button"
                disabled={disabled || !primaryEnabled}
                onClick={() => setStep(stepIndex + 1)}
              >
                {t("hud.question.next")}
              </button>
            ) : (
              <button
                class="q-btn is-primary"
                type="button"
                disabled={disabled || !primaryEnabled}
                onClick={() => void send(formAnswerPayload(form, questions))}
              >
                {primaryLabel(t("hud.question.submit"))}
              </button>
            )}
          </div>
        </Fragment>
      ) : null}

      {failure}
    </div>
  );
}

interface QuestionFieldsProps {
  question: FormQuestion;
  index: number;
  form: FormState;
  disabled: boolean;
  /** The bubble already shows this question's prompt as its title. */
  hidePrompt: boolean;
  otherField: { current: HTMLInputElement | null };
  onChange: (next: (state: FormState) => FormState) => void;
}

/** One askUserQuestion question: its prompt line, its hint, and its control. */
function QuestionFields({ question, index, form, disabled, hidePrompt, otherField, onChange }: QuestionFieldsProps): JSX.Element {
  const key = formQuestionKey(question, index);
  const prompt = hidePrompt ? undefined : question.prompt ?? question.label;
  const hint =
    question.type === "checkbox"
      ? { text: t("hud.question.hint.multiple"), required: false }
      : question.type === "text" && isQuestionRequired(question)
        ? { text: t("hud.question.hint.required"), required: true }
        : undefined;
  const otherSelected = isOtherSelected(form, question, key);
  const role = question.type === "radio" ? "radio" : "checkbox";

  // The field opens inside the row it belongs to, so typing starts there.
  useEffect(() => {
    if (otherSelected) otherField.current?.focus();
  }, [otherSelected, key, otherField]);

  function indicator(selected: boolean): JSX.Element {
    return (
      <span class={`q-ind ${question.type === "radio" ? "is-radio" : "is-check"}`} aria-hidden="true">
        {question.type === "checkbox" && selected ? <Checkmark size={9} /> : null}
      </span>
    );
  }

  return (
    <div class="q-q">
      {prompt || hint ? (
        <div class="q-prompt-row">
          {prompt ? <span class="q-prompt">{prompt}</span> : null}
          {hint ? <span class={`q-hint${hint.required ? " is-required" : ""}`}>{hint.text}</span> : null}
        </div>
      ) : null}

      {question.type === "text" ? (
        <input
          class="q-field"
          type="text"
          aria-label={question.prompt ?? question.label ?? question.placeholder ?? t("hud.question.responsePlaceholder")}
          placeholder={question.placeholder ?? t("hud.question.responsePlaceholder")}
          value={form.text[key] ?? ""}
          disabled={disabled}
          onInput={(event: JSX.TargetedEvent<HTMLInputElement>) => {
            const value = event.currentTarget.value;
            onChange((state) => ({ ...state, text: { ...state.text, [key]: value } }));
          }}
        />
      ) : (
        <div class="q-opts" role={question.type === "radio" ? "radiogroup" : "group"}>
          {(question.options ?? []).map((option) => {
            const selected = isOptionSelected(form, question, key, option.value);
            return (
              <button
                key={option.value}
                class={`q-opt${selected ? " is-selected" : ""}`}
                type="button"
                role={role}
                aria-checked={selected}
                disabled={disabled}
                onClick={() => onChange((state) => selectOption(state, question, key, option.value))}
              >
                {indicator(selected)}
                <span class="q-opt-text">
                  <span class="q-opt-label">{option.label}</span>
                  {option.description ? <span class="q-opt-desc">{option.description}</span> : null}
                </span>
              </button>
            );
          })}
          {allowsOther(question) ? (
            <div class={`q-other${otherSelected ? " is-selected" : ""}`}>
              <button
                class={`q-opt is-other${otherSelected ? " is-selected" : ""}`}
                type="button"
                role={role}
                aria-checked={otherSelected}
                disabled={disabled}
                onClick={() => onChange((state) => selectOption(state, question, key, OTHER_SENTINEL))}
              >
                {indicator(otherSelected)}
                <span class="q-opt-text">
                  <span class="q-opt-label">{t("hud.question.other")}</span>
                </span>
              </button>
              {otherSelected ? (
                <input
                  class="q-field q-other-field"
                  type="text"
                  ref={otherField}
                  aria-label={`${question.prompt ?? question.label ?? ""} ${t("hud.question.other")}`.trim()}
                  placeholder={t("hud.question.responsePlaceholder")}
                  value={form.other[key] ?? ""}
                  disabled={disabled}
                  onInput={(event: JSX.TargetedEvent<HTMLInputElement>) => {
                    const value = event.currentTarget.value;
                    onChange((state) => ({ ...state, other: { ...state.other, [key]: value } }));
                  }}
                />
              ) : null}
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}

interface ClosedQuestionProps {
  request: PickyExtensionUiRequest;
  answerRows?: PickyQuestionAnswerRow[];
  cancelled: boolean;
  expanded: boolean;
  onToggle: () => void;
}

/**
 * History: what was asked and what was answered. Expanding shows the recorded
 * answer rows, never the controls again, so an old question can't be re-answered.
 */
function ClosedQuestion({ request, answerRows, cancelled, expanded, onToggle }: ClosedQuestionProps): JSX.Element {
  const rows = cancelled ? [] : answerRows ?? [];
  const title = request.title ?? request.prompt ?? "";
  const summary = (cancelled ? null : answerSummary(rows)) ?? title;
  const detail = [request.prompt === title ? undefined : request.prompt, request.description].filter(
    (line): line is string => (line ?? "").length > 0,
  );
  // The collapsed line already carries the title whenever there is no answer to show.
  const repeatsTitle = summary === title && detail.length > 0;
  return (
    <div class={`q-bubble is-closed${cancelled ? " is-skipped" : ""}`}>
      <button
        class="q-collapse"
        type="button"
        aria-expanded={expanded}
        aria-label={t(expanded ? "hud.question.collapse" : "hud.question.expand")}
        onClick={onToggle}
      >
        {cancelled ? <MinusCircle class="q-head-icon" /> : <CheckCircle class="q-head-icon" size={13} />}
        <span class="q-status">{t(cancelled ? "hud.question.cancelled" : "hud.question.answered")}</span>
        {summary ? <span class="q-collapsed-title">· {summary}</span> : null}
        {expanded ? <ChevronDown class="q-chevron" /> : <ChevronRight class="q-chevron" />}
      </button>
      {expanded ? (
        rows.length > 0 ? (
          <dl class="q-answers">
            {rows.map((row, index) => (
              <Fragment key={`${row.label}-${index}`}>
                {row.label ? <dt>{row.label}</dt> : null}
                <dd class={row.label ? undefined : "is-wide"}>{row.value}</dd>
              </Fragment>
            ))}
          </dl>
        ) : (
          <div class="q-closed-body">
            {title && !repeatsTitle ? <div class="q-closed-title">{title}</div> : null}
            {detail.map((line) => (
              <div class="q-closed-text" key={line}>
                {line}
              </div>
            ))}
          </div>
        )
      ) : null}
    </div>
  );
}
