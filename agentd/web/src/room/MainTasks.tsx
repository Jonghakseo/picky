/**
 * The Picky room's Tasks section, above the composer.
 *
 * A Pickle room shows `BackgroundWorkFooter`; the main conversation shows this
 * instead, because its background work is Tasks and delegation decisions
 * (docs/picky-task-routing-plan.md 9). An unanswered decision is drawn as a
 * card: it blocks the work and is the one thing here the user must act on.
 * Everything else sits behind one summary line.
 */
import type { JSX } from "preact";
import { useState } from "preact/hooks";

import type { RemoteCommand, RemoteMainDelegation, RemoteMainState, RemoteMainTask } from "../../../src/remote/protocol";
import { ChevronDown, ChevronUp, NotifyError, QuestionCircle } from "./icons";
import { t } from "./i18n";
import {
  TASK_STATUS_KEY,
  decisionNeedsUser,
  mainTasksModel,
  taskDetailLines,
  taskTone,
} from "./policy/main-tasks";

export interface MainTasksProps {
  main?: RemoteMainState;
  /** The room's own sender: it reports failures and haptics like every other control. */
  send: (command: RemoteCommand) => Promise<boolean>;
}

export function MainTasks({ main, send }: MainTasksProps): JSX.Element | null {
  const [expanded, setExpanded] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const model = mainTasksModel(main);
  if (!model) return null;

  async function run(id: string, command: RemoteCommand): Promise<void> {
    if (busyId) return;
    setBusyId(id);
    await send(command);
    setBusyId(null);
  }

  return (
    <section class="main-tasks" aria-label={t("remote.room.tasks.title")}>
      {model.decisions.map((decision) => (
        <DecisionCard
          key={decision.id}
          decision={decision}
          busy={busyId === decision.id}
          disabled={busyId !== null && busyId !== decision.id}
          onChoose={(choice) => void run(decision.id, { type: "main.delegation.resolve", decisionId: decision.id, choice })}
        />
      ))}
      {model.tasks.length > 0 ? (
        <>
          <button
            class="main-tasks-bar"
            type="button"
            aria-expanded={expanded}
            onClick={() => setExpanded((value) => !value)}
          >
            <span class="main-tasks-label">{t("remote.room.tasks.title")}</span>
            <span class="main-tasks-summary">· {t(model.summary.key, model.summary.count)}</span>
            <span class="main-tasks-chevron" aria-hidden="true">{expanded ? <ChevronUp /> : <ChevronDown />}</span>
          </button>
          {expanded ? (
            <div class="main-tasks-list">
              {model.tasks.map((task) => (
                <TaskRow
                  key={task.id}
                  task={task}
                  busy={busyId === task.id}
                  disabled={busyId !== null && busyId !== task.id}
                  onControl={(action) => void run(task.id, { type: "main.task.control", taskId: task.id, action })}
                />
              ))}
            </div>
          ) : null}
        </>
      ) : null}
    </section>
  );
}

function TaskRow({
  task,
  busy,
  disabled,
  onControl,
}: {
  task: RemoteMainTask;
  busy: boolean;
  disabled: boolean;
  onControl: (action: "stop" | "resume") => void;
}): JSX.Element {
  const [open, setOpen] = useState(false);
  const details = taskDetailLines(task);
  const blockers = task.report?.blockers ?? [];
  const expandable = details.length > 0 || blockers.length > 0 || task.handoffSessionId !== undefined;
  return (
    <div class="main-task">
      <div class="main-task-head">
        <button
          class="main-task-name"
          type="button"
          disabled={!expandable}
          aria-expanded={expandable ? open : undefined}
          onClick={() => setOpen((value) => !value)}
        >
          <span class="main-task-title">{task.title}</span>
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
            disabled={busy || disabled}
            aria-label={t("remote.room.tasks.stop.accessibility", task.title)}
            onClick={() => onControl("stop")}
          >
            {t("remote.room.tasks.stop")}
          </button>
        ) : null}
        {task.canResume ? (
          <button
            class="main-task-action is-primary"
            type="button"
            disabled={busy || disabled}
            aria-label={t("remote.room.tasks.resume.accessibility", task.title)}
            onClick={() => onControl("resume")}
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

function DecisionCard({
  decision,
  busy,
  disabled,
  onChoose,
}: {
  decision: RemoteMainDelegation;
  busy: boolean;
  disabled: boolean;
  onChoose: (choice: "pickle" | "task" | "cancel") => void;
}): JSX.Element {
  const pending = decisionNeedsUser(decision);
  const failure = decision.pickle?.state === "failed" ? decision.pickle.error : undefined;
  return (
    <div class={`main-decision${pending ? " is-pending" : ""}`}>
      <div class="main-decision-head">
        {pending ? <QuestionCircle class="main-decision-icon" /> : <NotifyError class="main-decision-icon is-failed" />}
        <span class="main-decision-question">
          {pending ? decision.question ?? t("remote.room.delegation.title") : t("remote.room.delegation.pickleFailed")}
        </span>
      </div>
      <p class="main-decision-work">{decision.title}</p>
      {failure ? <p class="main-decision-error">{failure}</p> : null}
      <div class="main-decision-actions">
        {pending ? (
          <>
            <button class="q-btn is-ghost" type="button" disabled={busy || disabled} onClick={() => onChoose("cancel")}>
              {t("remote.room.delegation.cancel")}
            </button>
            <button class="q-btn is-secondary" type="button" disabled={busy || disabled} onClick={() => onChoose("task")}>
              {t("remote.room.delegation.task")}
            </button>
            <button class="q-btn is-primary" type="button" disabled={busy || disabled} onClick={() => onChoose("pickle")}>
              {t("remote.room.delegation.pickle")}
            </button>
          </>
        ) : (
          <button class="q-btn is-primary" type="button" disabled={busy || disabled} onClick={() => onChoose("pickle")}>
            {t("remote.room.delegation.retry")}
          </button>
        )}
      </div>
    </div>
  );
}
