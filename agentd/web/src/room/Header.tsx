/**
 * Room header: the HUD conversation header on the phone.
 *
 * Source: Picky/HUD/Conversation/PickyConversationHeaderView.swift
 * (single-row layout, pi badge with its status corner, status label,
 * context usage control, archive and menu buttons). The back control is
 * phone-only: the HUD card is always the one open Pickle.
 */
import type { JSX } from "preact";

import type { RemoteRoomStatus } from "../../../src/remote/protocol";
import { ArchiveBox, ChevronLeft, Ellipsis, ListBullet, PickleGlyph } from "./icons";
import { t } from "./i18n";

export interface ContextUsage {
  /** `null` right after compaction, until the next model response. */
  percent: number | null;
}

export interface HeaderProps {
  title: string;
  status: RemoteRoomStatus;
  contextUsage?: ContextUsage;
  /** Hidden for the main room, which cannot be archived from here. */
  showArchive: boolean;
  /** An archived room's archive button restores it instead. */
  archived?: boolean;
  /** True while an archive or restore request is in flight. */
  archiveBusy?: boolean;
  /** Hidden for the main room, which produces no artifacts or diffs of its own. */
  showWork: boolean;
  showMenu: boolean;
  /** Hidden in the wide layout, where the room list is already on screen. */
  showBack?: boolean;
  onBack: () => void;
  onArchive?: () => void;
  onWork?: () => void;
  onMenu?: () => void;
}

const STATUS_CLASS: Record<RemoteRoomStatus, string> = {
  running: "is-running",
  queued: "is-queued",
  waiting_for_input: "is-waiting",
  blocked: "is-blocked",
  failed: "is-failed",
  completed: "is-completed",
  cancelled: "is-cancelled",
  idle: "is-queued",
};

const STATUS_LABEL_KEY: Record<RemoteRoomStatus, string> = {
  running: "hud.conversation.status.running",
  queued: "hud.conversation.status.queued",
  waiting_for_input: "hud.conversation.status.waiting",
  blocked: "hud.conversation.status.blocked",
  failed: "hud.conversation.status.failed",
  completed: "hud.conversation.status.completed",
  cancelled: "hud.conversation.status.cancelled",
  idle: "hud.conversation.status.completed",
};

/**
 * Since 8361c7b8d a running session shows no corner mark; only waiting and
 * blocked ("!") and failed ("x") do.
 */
export function statusCornerMark(status: RemoteRoomStatus): string | null {
  if (status === "waiting_for_input" || status === "blocked") return "!";
  if (status === "failed") return "\u00d7";
  return null;
}

/** Band thresholds from `PickyHeaderContextUsageDisplay`. */
export function contextBandClass(percent: number | null | undefined): string {
  if (percent === null || percent === undefined) return "band-low";
  const clamped = Math.max(0, Math.min(100, percent));
  if (clamped >= 90) return "band-critical";
  if (clamped >= 70) return "band-warning";
  if (clamped >= 50) return "band-caution";
  return "band-low";
}

export function contextLabel(percent: number | null | undefined): string {
  if (percent === null || percent === undefined) return "?%";
  return `${Math.round(Math.max(0, Math.min(100, percent)))}%`;
}

export function Header(props: HeaderProps): JSX.Element {
  const { title, status, contextUsage } = props;
  const corner = statusCornerMark(status);
  const statusLabel = t(STATUS_LABEL_KEY[status]);
  const percent = contextUsage?.percent;
  const label = contextLabel(percent);
  return (
    <header class={`room-header ${STATUS_CLASS[status]}${props.showBack === false ? " no-back" : ""}`}>
      {props.showBack === false ? null : (
        <button class="hdr-back" type="button" onClick={props.onBack}>
          <ChevronLeft />
          <span class="sr-only">{t("remote.room.back")}</span>
        </button>
      )}
      <span class="pi-badge">
        <span class="pi-badge-tile">
          <PickleGlyph class="pi-glyph" />
        </span>
        {corner ? <span class="pi-badge-corner attention">{corner}</span> : null}
        {status === "idle" ? null : <span class="sr-only">{t("hud.header.target.accessibilityLabel", statusLabel)}</span>}
      </span>
      <h1 class="hdr-title">{title}</h1>
      {/* An idle Picky room shows no status: "done" would claim a turn that never ran. */}
      {status === "idle" ? null : <span class="hdr-status">{statusLabel}</span>}
      {contextUsage ? (
        <span class={`ctx ${contextBandClass(percent)}`}>
          <span class="ctx-bar">
            <span
              class="ctx-fill"
              style={{ "--ctx": percent === null || percent === undefined ? "0%" : label } as JSX.CSSProperties}
            />
          </span>
          <span class="ctx-label">{label}</span>
          <span class="sr-only">{t("hud.conversation.meta.context", label)}</span>
        </span>
      ) : null}
      {props.showWork ? (
        <button class="hdr-icon hdr-work" type="button" onClick={props.onWork}>
          <ListBullet />
          <span class="sr-only">{t("hud.utilityPanel.accessibilityLabel")}</span>
        </button>
      ) : null}
      {props.showArchive ? (
        <button class="hdr-icon hdr-archive" type="button" onClick={props.onArchive} disabled={props.archiveBusy} aria-busy={props.archiveBusy}>
          <ArchiveBox />
          <span class="sr-only">{t(props.archived ? "hud.archive.restore.accessibility" : "hud.header.archive.accessibilityLabel")}</span>
        </button>
      ) : null}
      {props.showMenu ? (
        <button class="hdr-icon hdr-menu" type="button" onClick={props.onMenu}>
          <Ellipsis />
          <span class="sr-only">{t("hud.header.menu.accessibilityLabel")}</span>
        </button>
      ) : null}
    </header>
  );
}
