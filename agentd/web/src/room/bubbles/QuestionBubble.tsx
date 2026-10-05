/**
 * Extension-UI question bubble.
 * Source: Picky/HUD/Conversation/Bubbles/PickyQuestionBubbleView.swift and
 * PickyQuestionOptionsLayoutPolicy.swift.
 *
 * Answered or cancelled questions collapse to one header line and expand on tap,
 * exactly as the HUD does. A failed answer recovers inside the bubble instead of
 * replacing it with an error, because the question is still waiting.
 */
import { useState } from "preact/hooks";
import type { JSX } from "preact";

import type { PickyExtensionUiRequest } from "../../../../src/protocol";
import { ChevronRight } from "../icons";
import { t } from "../i18n";
import {
  CANCELLED_ANSWER,
  OTHER_SENTINEL,
  answerableMethod,
  formAnswerPayload,
  formQuestionKey,
  isFormComplete,
  optionsLayout,
  seedFormState,
  type FormState,
} from "../policy/question";

export interface QuestionBubbleProps {
  request: PickyExtensionUiRequest;
  /** False once the daemon moved on: the bubble collapses into its answered form. */
  active: boolean;
  onAnswer: (value: unknown) => Promise<boolean>;
}

export function QuestionBubble({ request, active, onAnswer }: QuestionBubbleProps): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [failed, setFailed] = useState(false);
  const [lastValue, setLastValue] = useState<unknown>(undefined);
  const [text, setText] = useState(request.text ?? "");
  const [form, setForm] = useState<FormState>(() => seedFormState(request.questions ?? []));
  const method = answerableMethod(request);

  async function send(value: unknown): Promise<void> {
    setSubmitting(true);
    setLastValue(value);
    const ok = await onAnswer(value);
    setSubmitting(false);
    setFailed(!ok);
  }

  if (!active && !expanded) {
    return (
      <div class="q-bubble is-closed">
        <div class="q-header">
          <button class="q-collapse" type="button" aria-expanded="false" onClick={() => setExpanded(true)}>
            <ChevronRight class="q-chevron" />
            <span class="q-status">
              ⌑ <span>{t("hud.question.answered")}</span> · {request.method}
            </span>
            <span class="q-collapsed-title">· {request.title ?? request.prompt ?? ""}</span>
          </button>
        </div>
      </div>
    );
  }

  const questions = request.questions ?? [];
  const options = request.options ?? [];
  const layout = optionsLayout(options);
  const disabled = submitting || !active;

  return (
    <div class={`q-bubble${active ? "" : " is-closed"}`}>
      <div class="q-header">
        <span class="q-status">
          ⌑ <span>{t(active ? "hud.question.needed" : "hud.question.answered")}</span> · {request.method}
        </span>
      </div>
      {request.title ? <div class="q-title">{request.title}</div> : null}
      {request.prompt ? <div class="q-body">{request.prompt}</div> : null}
      {request.description ? <div class="q-description">{request.description}</div> : null}

      {method === "confirm" ? (
        <div class={`q-controls q-row${submitting ? " is-submitting" : ""}`}>
          <button class="q-btn" type="button" disabled={disabled} onClick={() => void send(true)}>
            <span>{t("hud.question.allow")}</span>
          </button>
          <button class="q-btn" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
            <span>{t("common.cancel")}</span>
          </button>
        </div>
      ) : null}

      {method === "select" && layout === "inlineRow" ? (
        <div class={`q-controls q-row${submitting ? " is-submitting" : ""}`}>
          {options.map((option) => (
            <button key={option} class="q-btn" type="button" disabled={disabled} onClick={() => void send(option)}>
              {option}
            </button>
          ))}
          <button class="q-btn" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
            <span>{t("common.cancel")}</span>
          </button>
        </div>
      ) : null}

      {method === "select" && layout === "stacked" ? (
        <div class={`q-controls q-stack${submitting ? " is-submitting" : ""}`}>
          {options.map((option) => (
            <button key={option} class="q-option" type="button" disabled={disabled} onClick={() => void send(option)}>
              {option}
            </button>
          ))}
          <button class="q-stack-cancel" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
            <span>{t("common.cancel")}</span>
          </button>
        </div>
      ) : null}

      {method === "input" || method === "editor" ? (
        <div class={`q-controls q-row q-input-row${submitting ? " is-submitting" : ""}`}>
          <input
            class="q-field"
            type="text"
            value={text}
            aria-label={request.title ?? request.prompt ?? t("hud.question.responsePlaceholder")}
            placeholder={t("hud.question.responsePlaceholder")}
            disabled={disabled}
            onInput={(event: JSX.TargetedEvent<HTMLInputElement>) => setText(event.currentTarget.value)}
          />
          <button
            class="q-btn"
            type="button"
            disabled={disabled || text.trim().length === 0}
            onClick={() => void send(text.trim())}
          >
            <span>{t("hud.question.submit")}</span>
          </button>
          <button class="q-btn" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
            <span>{t("common.cancel")}</span>
          </button>
        </div>
      ) : null}

      {method === "askUserQuestion" ? (
        <div class={`q-form${submitting ? " is-submitting" : ""}`}>
          {questions.map((question, index) => {
            const key = formQuestionKey(question, index);
            return (
              <div class="q-form-question" key={key}>
                {question.prompt || question.label ? (
                  <div class="q-prompt">{question.prompt ?? question.label}</div>
                ) : null}
                {question.type !== "text" ? (
                  <div class="q-form-options">
                    {(question.options ?? []).map((option) => {
                      const selected =
                        question.type === "radio"
                          ? form.radio[key] === option.value
                          : (form.checkbox[key] ?? []).includes(option.value);
                      return (
                        <button
                          key={option.value}
                          class={`q-form-option${selected ? " is-selected" : ""}`}
                          type="button"
                          aria-pressed={selected}
                          disabled={disabled}
                          onClick={() =>
                            setForm((state) =>
                              question.type === "radio"
                                ? { ...state, radio: { ...state.radio, [key]: option.value } }
                                : {
                                    ...state,
                                    checkbox: {
                                      ...state.checkbox,
                                      [key]: toggle(state.checkbox[key] ?? [], option.value),
                                    },
                                  },
                            )
                          }
                        >
                          <span class="q-form-option-label">{option.label}</span>
                          {option.description ? (
                            <span class="q-form-option-desc">{option.description}</span>
                          ) : null}
                        </button>
                      );
                    })}
                    {question.type === "radio" && question.allowOther ? (
                      <button
                        class={`q-form-option${form.radio[key] === OTHER_SENTINEL ? " is-selected" : ""}`}
                        type="button"
                        aria-pressed={form.radio[key] === OTHER_SENTINEL}
                        disabled={disabled}
                        onClick={() => setForm((state) => ({ ...state, radio: { ...state.radio, [key]: OTHER_SENTINEL } }))}
                      >
                        <span class="q-form-option-label">{t("hud.question.other")}</span>
                      </button>
                    ) : null}
                  </div>
                ) : null}
                {question.type === "radio" && question.allowOther ? (
                  <input
                    class={`q-field${form.radio[key] === OTHER_SENTINEL ? "" : " is-disabled"}`}
                    type="text"
                    aria-label={`${question.prompt ?? question.label ?? ""} ${t("hud.question.other")}`.trim()}
                    placeholder={t("hud.question.other")}
                    value={form.other[key] ?? ""}
                    disabled={disabled || form.radio[key] !== OTHER_SENTINEL}
                    onInput={(event: JSX.TargetedEvent<HTMLInputElement>) =>
                      setForm((state) => ({ ...state, other: { ...state.other, [key]: event.currentTarget.value } }))
                    }
                  />
                ) : null}
                {question.type === "text" ? (
                  <input
                    class="q-field"
                    type="text"
                    aria-label={question.prompt ?? question.label ?? question.placeholder ?? t("hud.question.responsePlaceholder")}
                    placeholder={question.placeholder ?? t("hud.question.responsePlaceholder")}
                    value={form.text[key] ?? ""}
                    disabled={disabled}
                    onInput={(event: JSX.TargetedEvent<HTMLInputElement>) =>
                      setForm((state) => ({ ...state, text: { ...state.text, [key]: event.currentTarget.value } }))
                    }
                  />
                ) : null}
              </div>
            );
          })}
          <div class="q-row">
            <button
              class="q-btn"
              type="button"
              disabled={disabled || !isFormComplete(form, questions)}
              onClick={() => void send(formAnswerPayload(form, questions))}
            >
              <span>{t("hud.question.submit")}</span>
            </button>
            <button class="q-btn" type="button" disabled={disabled} onClick={() => void send(CANCELLED_ANSWER)}>
              <span>{t("common.cancel")}</span>
            </button>
          </div>
        </div>
      ) : null}

      {failed ? (
        <div class="q-send-failed">
          <span class="q-send-failed-text">{t("hud.question.sendFailed")}</span>
          <button class="q-link" type="button" onClick={() => void send(lastValue)}>
            <span>{t("hud.error.retry")}</span>
          </button>
        </div>
      ) : null}
    </div>
  );
}

function toggle(values: string[], value: string): string[] {
  return values.includes(value) ? values.filter((entry) => entry !== value) : [...values, value];
}
