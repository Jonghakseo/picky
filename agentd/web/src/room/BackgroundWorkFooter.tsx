/**
 * Background work above the composer.
 *
 * Source: Picky/HUD/Conversation/PickyRunningTaskFooterView.swift. One line
 * names the state of all unfinished work; tapping it lists each command or
 * subagent with its state and elapsed time. Decisions live in
 * `policy/background-work.ts`.
 */
import type { JSX } from "preact";
import { useState } from "preact/hooks";

import type { PickyAgentSession } from "../../../src/protocol";
import { CheckCircle, ChevronDown, ChevronUp, Clock, NotifyError, NotifyInfo, StopFill, Warning, Xmark } from "./icons";
import { t } from "./i18n";
import type { BackgroundWorkGroup, BackgroundWorkResult, BackgroundWorkRow, BackgroundWorkState, BackgroundWorkTiming } from "./policy/background-work";
import {
  NOTE_KEY,
  RESULT_LABEL_KEY,
  STATE_LABEL_KEY,
  backgroundWorkModel,
  durationText,
  groupCounts,
  resultNeedsAttention,
  rootIssue,
} from "./policy/background-work";

export function BackgroundWorkFooter({ session, now }: { session?: PickyAgentSession; now: number }): JSX.Element | null {
  const [expanded, setExpanded] = useState(false);
  const model = backgroundWorkModel(session, now);
  if (!model) return null;
  return (
    <div class="bg-work">
      <button
        class="bg-work-bar"
        type="button"
        aria-expanded={expanded}
        aria-label={t("hud.backgroundWork.accessibility", model.status.text)}
        onClick={() => setExpanded((value) => !value)}
      >
        <StateGlyph state={model.status.state} />
        <span class="bg-work-title">{t("hud.backgroundWork.title")}</span>
        <span class="bg-work-status">· {model.status.text}</span>
        <span class="bg-work-chevron" aria-hidden="true">
          {expanded ? <ChevronUp /> : <ChevronDown />}
        </span>
      </button>
      {expanded ? (
        <div class="bg-work-list">
          {model.groups.map((group) => (
            <Group key={group.id} group={group} now={now} />
          ))}
          {model.note ? (
            <div class={`bg-work-note${model.note === "attention" ? " is-warning" : ""}`}>
              {model.note === "attention" ? <Warning /> : <NotifyInfo />}
              <span>{t(NOTE_KEY[model.note])}</span>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function Group({ group, now }: { group: BackgroundWorkGroup; now: number }): JSX.Element {
  const issue = rootIssue(group);
  return (
    <>
      {group.children.length > 0 ? (
        <div class="bg-work-group">
          <span class="bg-work-name">{group.title}</span>
          <span class="bg-work-counts">
            {groupCounts(group).map(({ state, count }) => t("hud.backgroundWork.stateCount", t(STATE_LABEL_KEY[state]), count)).join(" · ")}
          </span>
          {issue ? (
            <span class={`bg-work-state is-${issue}`}>
              <StateGlyph state={issue} />
              {t(STATE_LABEL_KEY[issue])}
            </span>
          ) : null}
        </div>
      ) : null}
      {group.children.length > 0
        ? group.children.map((child) => <Row key={child.id} row={child} indented now={now} />)
        : <Row row={group} indented={false} now={now} />}
      {group.result ? <ResultRow result={group.result} indented={group.children.length > 0} /> : null}
    </>
  );
}

function Row({ row, indented, now }: { row: BackgroundWorkRow; indented: boolean; now: number }): JSX.Element {
  return (
    <div class={`bg-work-row${indented ? " is-indented" : ""}`}>
      <span class="bg-work-name">{row.title}</span>
      {/* The state is named, not only colored. */}
      <span class={`bg-work-state is-${row.state}`}>
        <StateGlyph state={row.state} />
        {t(STATE_LABEL_KEY[row.state])}
      </span>
      <Timing timing={row.timing} now={now} />
    </div>
  );
}

function ResultRow({ result, indented }: { result: BackgroundWorkResult; indented: boolean }): JSX.Element {
  const tone = result === "failed" ? " is-failed" : result === "unverified" ? " is-unknown" : "";
  return (
    <div class={`bg-work-row bg-work-result${indented ? " is-indented" : ""}${tone}`}>
      {resultNeedsAttention(result) ? <Warning /> : <Clock />}
      <span class="bg-work-name">{t(RESULT_LABEL_KEY[result])}</span>
    </div>
  );
}

function Timing({ timing, now }: { timing: BackgroundWorkTiming; now: number }): JSX.Element | null {
  if (timing.kind === "none") return null;
  const seconds = timing.kind === "elapsed" ? Math.max(0, (now - timing.since) / 1000) : timing.seconds;
  return <span class="bg-work-time">{durationText(seconds)}</span>;
}

/** `PickyBackgroundWorkState.symbol`, drawn with the room's own icon set. */
function StateGlyph({ state }: { state: BackgroundWorkState }): JSX.Element {
  switch (state) {
    case "running":
      return (
        <svg class="bg-work-glyph is-running" width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-dasharray="2.2 2.2" aria-hidden="true">
          <circle cx="8" cy="8" r="6" />
        </svg>
      );
    case "queued":
      return <Clock class="bg-work-glyph is-queued" />;
    case "stopping":
      return <StopFill class="bg-work-glyph is-stopping" />;
    case "completed":
      return <CheckCircle class="bg-work-glyph is-completed" />;
    case "failed":
      return <NotifyError class="bg-work-glyph is-failed" />;
    case "cancelled":
      return <Xmark class="bg-work-glyph is-cancelled" />;
    case "interrupted":
    case "unknown":
      return <Warning class="bg-work-glyph is-unknown" />;
  }
}
