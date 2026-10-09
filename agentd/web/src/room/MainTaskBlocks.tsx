/**
 * Blocks for the Picky room's Tasks and "hand this to a Pickle?" questions,
 * drawn inside the conversation where each one started
 * (`policy/main-tasks.ts`, docs/picky-task-routing-plan.md 9).
 *
 * A Pickle room shows `BackgroundWorkFooter`; the main conversation has no
 * section above the composer: its background work reads as part of the
 * conversation, like the Mac's Recent Conversation. A question the user has
 * not answered is a card; an answered one stays as one line.
 */
import type { JSX } from "preact";
import { useState } from "preact/hooks";

import type { RemoteCommand, RemoteMainDelegation, RemoteMainTask } from "../../../src/remote/protocol";
import type { RoomActions } from "./contract";
import { ChevronDown, ChevronUp, NotifyError, QuestionCircle } from "./icons";
import { t } from "./i18n";
import {
  TASK_STATUS_KEY,
  TASK_TIER_KEY,
  decisionCreatingPickle,
  decisionFailed,
  decisionNeedsUser,
  taskDetailLines,
  taskTone,
  type MainTimelineBlock,
} from "./policy/main-tasks";

/** The room's own sender: it reports failures and haptics like every other control. */
type Send = (command: RemoteCommand) => Promise<boolean>;

export function MainBlock({ block, send, actions }: { block: MainTimelineBlock; send: Send; actions: RoomActions }): JSX.Element {
  if (block.kind === "task") return <TaskBlock task={block.task} send={send} />;
  const decision = block.decision;
  if (decisionNeedsUser(decision) || decisionFailed(decision)) return <DecisionCard decision={decision} send={send} />;
  return <DecisionRecord decision={decision} onOpenPickle={(sessionId) => actions.openRoom(sessionId)} />;
}

/** One request at a time per block; the daemon's next broadcast is the answer. */
function useCommand(send: Send): { busy: boolean; run: (command: RemoteCommand) => void } {
  const [busy, setBusy] = useState(false);
  return {
    busy,
    run: (command) => {
      if (busy) return;
      setBusy(true);
      void send(command).finally(() => setBusy(false));
    },
  };
}

function TaskBlock({ task, send }: { task: RemoteMainTask; send: Send }): JSX.Element {
  const [open, setOpen] = useState(false);
  const { busy, run } = useCommand(send);
  const details = taskDetailLines(task);
  const blockers = task.report?.blockers ?? [];
  const expandable = details.length > 0 || blockers.length > 0 || task.handoffSessionId !== undefined;
  const control = (action: "stop" | "resume") => run({ type: "main.task.control", taskId: task.id, action });
  return (
    <div class="main-task main-block">
      <div class="main-task-head">
        <button
          class="main-task-name"
          type="button"
          disabled={!expandable}
          aria-expanded={expandable ? open : undefined}
          onClick={() => setOpen((value) => !value)}
        >
          <span class="main-task-title">{task.title}</span>
          {task.tier ? <span class="main-task-tier">{t(TASK_TIER_KEY[task.tier])}</span> : null}
          {/* The state is named, not only colored. */}
          <span class={`main-task-state is-${taskTone(task)}`}>{t(TASK_STATUS_KEY[task.status])}</span>
          {expandable ? (
            <span class="main-task-chevron" aria-hidden="true">{open ? <ChevronUp /> : <ChevronDown />}</span>
          ) : null}
        </button>
        {task.canStop ? (
          <button
            class="main-task-action"
            type="button"
            disabled={busy}
            aria-label={t("remote.room.tasks.stop.accessibility", task.title)}
            onClick={() => control("stop")}
          >
            {t("remote.room.tasks.stop")}
          </button>
        ) : null}
        {task.canResume ? (
          <button
            class="main-task-action is-primary"
            type="button"
            disabled={busy}
            aria-label={t("remote.room.tasks.resume.accessibility", task.title)}
            onClick={() => control("resume")}
          >
            {t("remote.room.tasks.resume")}
          </button>
        ) : null}
      </div>
      {open && expandable ? (
        <div class="main-task-detail">
          {details.map((line) => (
            <p key={line} class="main-task-line">{line}</p>
          ))}
          {blockers.length > 0 ? (
            <>
              <p class="main-task-caption">{t("remote.room.tasks.blockers")}</p>
              <ul class="main-task-blockers">
                {blockers.map((blocker) => (
                  <li key={blocker}>{blocker}</li>
                ))}
              </ul>
            </>
          ) : null}
          {task.handoffSessionId ? (
            <p class="main-task-caption">{t("remote.room.tasks.handoff")}</p>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/**
 * A question still waiting on the user, or one whose Pickle could not be made.
 * Same buttons and order as the Mac: cancel leads, the primary answer ends the
 * row. `data-question-id` lets the pinned bar above the composer find it.
 */
function DecisionCard({ decision, send }: { decision: RemoteMainDelegation; send: Send }): JSX.Element {
  const { busy, run } = useCommand(send);
  const pending = decisionNeedsUser(decision);
  const failure = decision.pickle?.state === "failed" ? decision.pickle.error : undefined;
  const choose = (choice: "pickle" | "task" | "cancel") => run({ type: "main.delegation.resolve", decisionId: decision.id, choice });
  return (
    <div class={`main-decision main-block${pending ? " is-pending" : ""}`} data-question-id={decision.id} tabIndex={-1}>
      <div class="main-decision-head">
        {pending ? <QuestionCircle class="main-decision-icon" /> : <NotifyError class="main-decision-icon is-failed" />}
        <span class="main-decision-question">
          {pending ? decision.question ?? t("remote.room.delegation.title") : t("remote.room.delegation.pickleFailed")}
        </span>
      </div>
      <p class="main-decision-work">{decision.title}</p>
      {failure ? <p class="main-decision-error">{failure}</p> : null}
      <div class="main-decision-actions">
        <button class="q-btn is-ghost" type="button" disabled={busy} onClick={() => choose("cancel")}>
          {t("remote.room.delegation.cancel")}
        </button>
        <button class="q-btn is-secondary" type="button" disabled={busy} onClick={() => choose("task")}>
          {t("remote.room.delegation.task")}
        </button>
        <button class="q-btn is-primary" type="button" disabled={busy} onClick={() => choose("pickle")}>
          {pending ? t("remote.room.delegation.pickle") : t("remote.room.delegation.retry")}
        </button>
      </div>
    </div>
  );
}

/** An answered question as one line, so the conversation keeps what was decided. */
function DecisionRecord({ decision, onOpenPickle }: { decision: RemoteMainDelegation; onOpenPickle: (sessionId: string) => void }): JSX.Element {
  const sessionId = decision.state === "pickle" && decision.pickle?.state === "created" ? decision.pickle.sessionId : undefined;
  return (
    <div class="main-record">
      <span class="main-record-title">{decision.title}</span>
      <span class="main-record-dot" aria-hidden="true">·</span>
      <span class="main-record-outcome">{t(recordKey(decision))}</span>
      {sessionId ? (
        <button class="main-record-link" type="button" onClick={() => onOpenPickle(sessionId)}>
          {t("hub.tasks.decision.openPickle")}
        </button>
      ) : null}
    </div>
  );
}

/** The Mac's record wording; a Pickle still being made says so for the few seconds it takes. */
function recordKey(decision: RemoteMainDelegation): string {
  if (decisionCreatingPickle(decision)) return "hub.tasks.decision.creating";
  if (decision.state === "pickle") return "hub.tasks.decision.record.pickle";
  if (decision.state === "task") return "hub.tasks.decision.record.task";
  return "hub.tasks.decision.record.cancelled";
}
