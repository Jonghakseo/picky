/**
 * Transcript bubbles, ported from Picky/HUD/Conversation/Bubbles/.
 *
 * Hover-only HUD details (send time, open-as-report, elapsed time) appear on
 * tap here: a phone has no hover. The tapped row keeps the HUD's visual, so a
 * capture of either side lines up.
 */
import { useState } from "preact/hooks";
import type { JSX } from "preact";

import type { PickySubagentRun, PickyToolImage } from "../../../../src/protocol";
import { Markdown } from "../markdown/Markdown";
import { fileName } from "../format";
import { t } from "../i18n";
import type { ActivityCategory } from "../policy/message";
import { isTruncated, truncatedMarkdown } from "../policy/message";
import type { Presence } from "../policy/presence";
import { elapsedText, presenceTitleKey } from "../policy/presence";
import {
  ChevronDownSmall,
  ChevronRight,
  ChevronUp,
  Clock,
  ListBullet,
  OpenReport,
  Photo,
  PhotoMissing,
} from "../icons";

export function DateDivider({ title }: { title: string }): JSX.Element {
  return (
    <div class="date-divider">
      <span>{title}</span>
    </div>
  );
}

interface LinkHandlers {
  onOpenExternal?: (url: string) => void;
  onOpenFile?: (path: string) => void;
}

export interface UserBubbleProps extends LinkHandlers {
  text: string;
  /** Send time, shown on tap. `null` keeps the slot empty. */
  time: string | null;
  /** `true` draws the clock pin the HUD shows while a message is still in flight. */
  pending?: boolean;
}

export function UserBubble({ text, time, pending, onOpenExternal, onOpenFile }: UserBubbleProps): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const [tapped, setTapped] = useState(false);
  const foldable = isTruncated(text);
  const body = foldable && !expanded ? truncatedMarkdown(text) : text;
  return (
    <div class={`row row--user${tapped ? " row--tapped" : ""}`}>
      {/* The HUD puts a user bubble's time on its left, so the bubble itself
          stays flush with the right edge (PickyBubbleTimestampAccessory). */}
      {pending ? (
        <div class="sendtime sendtime--pinned">
          <Clock />
          <span class="sr-only">{t("common.sending")}</span>
        </div>
      ) : (
        <div class="sendtime">{time ?? ""}</div>
      )}
      <div class="bubble bubble--user" onClick={() => setTapped((value) => !value)}>
        <Markdown text={body} onOpenExternal={onOpenExternal} onOpenFile={onOpenFile} />
        {foldable ? (
          <button
            class="bubble-expand"
            type="button"
            onClick={(event: MouseEvent) => {
              event.stopPropagation();
              setExpanded((value) => !value);
            }}
          >
            <span>{expanded ? t("common.collapse") : t("common.showMore")}</span>
            {expanded ? <ChevronUp /> : <ChevronDownSmall />}
          </button>
        ) : null}
      </div>
    </div>
  );
}

export interface AgentBubbleProps extends LinkHandlers {
  text: string;
  time: string | null;
  onOpenAsReport?: () => void;
}

export function AgentBubble({ text, time, onOpenAsReport, onOpenExternal, onOpenFile }: AgentBubbleProps): JSX.Element {
  const [tapped, setTapped] = useState(false);
  return (
    <div class={`row row--agent${tapped ? " row--tapped" : ""}`}>
      <div class="bubble bubble--agent" onClick={() => setTapped((value) => !value)}>
        <Markdown text={text} onOpenExternal={onOpenExternal} onOpenFile={onOpenFile} />
        {onOpenAsReport ? (
          <button
            class="open-report"
            type="button"
            onClick={(event: MouseEvent) => {
              event.stopPropagation();
              onOpenAsReport();
            }}
          >
            <OpenReport />
            <span class="sr-only">{t("hud.message.openReport.help")}</span>
          </button>
        ) : null}
      </div>
      <div class="sendtime">{time ?? ""}</div>
    </div>
  );
}

/** A queued steer or follow-up: a dimmed user bubble with its own link row. */
export interface PendingQueueRowProps {
  text: string;
  /** Follow-ups can be edited in the composer, like the HUD. */
  onEdit?: () => void;
  onRemove: () => void;
  onSendNow?: () => void;
}

export function PendingQueueRow({ text, onEdit, onRemove, onSendNow }: PendingQueueRowProps): JSX.Element {
  return (
    <div class="steer">
      <span class="sr-only">{t("hud.queue.pending.steer")}</span>
      <div class="row row--user">
        <div class="sendtime sendtime--pinned" aria-hidden="true">
          <Clock />
        </div>
        <div class="bubble bubble--user">
          <p>{text}</p>
        </div>
      </div>
      <div class="steer-links">
        {onSendNow ? (
          <>
            <button type="button" onClick={onSendNow}>
              {t("hud.scheduled.row.sendNow")}
            </button>
            <span aria-hidden="true">·</span>
          </>
        ) : null}
        {onEdit ? (
          <>
            <button type="button" onClick={onEdit}>
              {t("hud.queue.steer.edit.short")}
            </button>
            <span aria-hidden="true">·</span>
          </>
        ) : null}
        <button type="button" onClick={onRemove}>
          {t("hud.queue.steer.cancel")}
        </button>
      </div>
    </div>
  );
}

export interface ScheduledRowProps {
  text: string;
  /** "5분 후" style title plus the absolute time. */
  when: string;
  onEdit: () => void;
  onCancel: () => void;
  onSendNow: () => void;
}

export function ScheduledRow({ text, when, onEdit, onCancel, onSendNow }: ScheduledRowProps): JSX.Element {
  return (
    <div class="scheduled-row">
      <span class="sr-only">{t("hud.scheduled.accessibilityLabel")}</span>
      <div class="row row--user">
        <div class="sendtime sendtime--pinned" aria-hidden="true">
          <Clock />
        </div>
        <div class="bubble bubble--user">
          <p>{text}</p>
        </div>
      </div>
      <div class="queue-row-links">
        <span class="scheduled-when">{when}</span>
        <span aria-hidden="true">·</span>
        <button type="button" onClick={onSendNow}>
          {t("hud.scheduled.row.sendNow")}
        </button>
        <span aria-hidden="true">·</span>
        <button type="button" onClick={onEdit}>
          {t("hud.scheduled.row.edit")}
        </button>
        <span aria-hidden="true">·</span>
        <button type="button" onClick={onCancel}>
          {t("hud.scheduled.row.delete")}
        </button>
      </div>
    </div>
  );
}

export interface ActivitySummaryProps {
  total: number;
  counts: Array<{ category: ActivityCategory; count: number }>;
}

/** Collapsed by default; a tap expands the per-category grid, as hovering does on the Mac. */
export function ActivitySummary({ total, counts }: ActivitySummaryProps): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  return (
    <div class={`activity${expanded ? " activity--expanded" : ""}`}>
      <button class="activity-head" type="button" onClick={() => setExpanded((value) => !value)}>
        <span class="activity-dot" aria-hidden="true" />
        <ListBullet />
        <span class="activity-title">
          {t(total === 1 ? "hud.activity.summary.toolsUsed.one" : "hud.activity.summary.toolsUsed.many", total)}
        </span>
        <span class="activity-state">
          <span>{t("hud.activity.summary.completed")}</span>
          <ChevronRight size={10} />
        </span>
      </button>
      {expanded ? (
        <div class="activity-grid">
          {counts.map((entry) => (
            <div key={entry.category}>
              <span class="k">{t(`hud.activity.category.${entry.category}`)}</span>
              <span class="v">{entry.count}</span>
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export interface PresenceRowProps {
  presence: Presence;
  now: number;
}

export function PresenceRow({ presence, now }: PresenceRowProps): JSX.Element {
  const [tapped, setTapped] = useState(false);
  const elapsed = elapsedText(presence.startedAt, now);
  const waiting = presence.phase === "waitingForInput";
  return (
    <div
      class={`presence${waiting ? " presence--waiting" : ""}${tapped ? " presence--tapped" : ""}`}
      onClick={() => setTapped((value) => !value)}
    >
      <div class="presence-dots" aria-hidden="true">
        <i />
        <i />
        <i />
      </div>
      <div class="presence-text">
        <span class="presence-title">{t(presenceTitleKey(presence.phase))}</span>
        {presence.detail ? (
          <>
            <span class="presence-sep" aria-hidden="true">
              ·
            </span>
            <span class="presence-detail" title={presence.detailHelp ?? presence.detail}>
              {presence.detail}
            </span>
          </>
        ) : null}
      </div>
      {waiting ? null : <span class="presence-elapsed">{elapsed ?? ""}</span>}
    </div>
  );
}

export interface ToolImageBubbleProps {
  toolImage: PickyToolImage;
  /** Thumbnail URL from the gateway; the journal keeps only the Mac-local path. */
  src: string;
  onOpen: () => void;
}

export function ToolImageBubble({ toolImage, src, onOpen }: ToolImageBubbleProps): JSX.Element {
  const [missing, setMissing] = useState(false);
  const name = fileName(toolImage.path);
  return (
    <div class="row row--agent">
      <div class="tool-image">
        <div class="tool-image-caption">
          <Photo />
          <span class="tool-image-name">{name}</span>
        </div>
        {missing ? (
          <div class="tool-image-missing">
            <PhotoMissing />
            <span>{t("hud.toolImage.missing")}</span>
          </div>
        ) : (
          <button class="tool-image-thumb" type="button" onClick={onOpen}>
            <img src={src} alt="" onError={() => setMissing(true)} />
            <span class="sr-only">{t("hud.toolImage.accessibilityLabel", name)}</span>
          </button>
        )}
      </div>
    </div>
  );
}

export function SubagentRuns({ runs }: { runs: PickySubagentRun[] }): JSX.Element | null {
  if (runs.length === 0) return null;
  const done = runs.filter((run) => run.status !== "running").length;
  return (
    <div class="subagents">
      <div class="subagents-head">
        {runs.length === 1
          ? t("hud.subagent.header.one", done, runs.length)
          : t("hud.subagent.header", runs.length, done, runs.length)}
      </div>
      {runs.map((run) => (
        <div class="subagent-row" key={run.runId}>
          <span class="subagent-name">{run.agent}</span>
          <span class="subagent-task">{run.displayTask ?? run.task}</span>
          <span class={`subagent-status${run.status === "running" ? " is-running" : run.status === "error" ? " is-error" : ""}`}>
            {t(
              run.status === "running"
                ? "hud.subagent.status.running"
                : run.status === "error"
                  ? "hud.subagent.status.error"
                  : "hud.subagent.status.done",
            )}
          </span>
        </div>
      ))}
    </div>
  );
}
