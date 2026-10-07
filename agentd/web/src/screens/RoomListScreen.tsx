/**
 * Room list: the Picky room pinned on top, then Pickles in Mac Dock order with
 * dock groups as collapsible sections, and the archive at the bottom. Rows never
 * move because a Pickle replied; only the dock order places them. Ported from the reviewed prototype
 * (docs/prototypes/picky-remote-pwa/room-list.html).
 */
import { useComputed, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { JSX } from "preact";
import { MAIN_ROOM_ID } from "../../../src/remote/constants";
import type { RemoteDockGroup, RemoteRoom } from "../../../src/remote/protocol";
import { formatRoomTime, type RoomTimeLabels } from "../app/format";
import { t } from "../app/i18n";
import { navigate } from "../app/navigation";
import { buildRoomSections } from "../app/room-sections";
import type { AppStore } from "../app/store";
import {
  ArchiveIcon,
  ChevronRightIcon,
  GearIcon,
  MacOfflineIcon,
  PickleGlyph,
  PlusIcon,
  StatusGlyph,
  statusClass,
  statusLabelKey,
} from "../ui/icons";
import { NewPickleSheet } from "./NewPickleSheet";

/** Mac dock group colors are `PickyDockGroupColor` raw values; room-list.css has one class each. */
function groupClass(color: string): string {
  const known = ["teal", "amber", "blue", "purple", "red", "pink", "gray"];
  return known.includes(color) ? `group-${color}` : "";
}

export function RoomListScreen({
  store,
  selectedRoomId,
  sidebar = false,
}: {
  store: AppStore;
  selectedRoomId?: string;
  /** Rendered as the wide layout's list column next to another page. */
  sidebar?: boolean;
}): JSX.Element {
  const archiveOpen = useSignal(false);
  const sheetOpen = useSignal(false);
  // Relative times ("3분 전") go stale while the list sits open; one tick a minute keeps them honest.
  const now = useSignal(new Date());
  useEffect(() => {
    const timer = setInterval(() => (now.value = new Date()), 60_000);
    return () => clearInterval(timer);
  }, []);

  const visible = useComputed(() => keepMainFirst(store.rooms.value));
  const rooms = visible.value.filter((room) => !room.archived);
  const archived = visible.value.filter((room) => room.archived);
  const pickles = rooms.filter((room) => room.id !== MAIN_ROOM_ID);
  const sections = buildRoomSections(rooms, store.groups.value);
  const collapsed = store.collapsedGroups.value;
  const times = roomTimeLabels();
  const rowProps = { now: now.value, locale: store.locale, times };

  return (
    <div class="app-shell">
      <div class="app-topbar app-side-inset">
        {/* Beside an open room the list is a sidebar: the room's title is the page's h1. */}
        {!sidebar ? (
          <h1 class="app-topbar-title">{t("messages.title")}</h1>
        ) : (
          <h2 class="app-topbar-title">{t("messages.title")}</h2>
        )}
        <button class="icon-button" type="button" aria-label={t("remote.settings.title")} onClick={() => navigate({ name: "settings" })}>
          <GearIcon size={17} />
        </button>
        <button class="list-new" type="button" onClick={() => (sheetOpen.value = true)}>
          <PlusIcon size={12} />
          <span>{t("remote.roomList.newPickle")}</span>
        </button>
      </div>

      <div class="app-scroll app-side-inset">
        {!store.mac.value.connected && <MacOfflineBanner />}

        <div class="list-rows">
          {sections.map((entry) =>
            entry.kind === "room" ? (
              <RoomRow key={entry.room.id} room={entry.room} selected={entry.room.id === selectedRoomId} {...rowProps} />
            ) : (
              <GroupSection
                key={entry.group.id}
                group={entry.group}
                rooms={entry.rooms}
                collapsed={collapsed.has(entry.group.id)}
                onToggle={() => store.toggleGroupCollapsed(entry.group.id)}
                selectedRoomId={selectedRoomId}
                rowProps={rowProps}
              />
            ),
          )}

          {store.roomsLoaded.value && pickles.length === 0 && (
            <div class="list-empty">
              <span class="list-empty-title">{t("remote.roomList.empty.title")}</span>
              <button class="list-new" type="button" onClick={() => (sheetOpen.value = true)}>
                <PlusIcon size={12} />
                <span>{t("remote.roomList.newPickle")}</span>
              </button>
            </div>
          )}

          {archived.length > 0 && (
            <>
              <button class="archived-row" type="button" onClick={() => (archiveOpen.value = !archiveOpen.value)} aria-expanded={archiveOpen.value}>
                <span class="archived-icon">
                  <ArchiveIcon size={15} />
                </span>
                <span class="archived-label">{t("hud.archivedList.title")}</span>
                <span class="archived-count">{archived.length}</span>
                <span class="archived-chevron" style={archiveOpen.value ? "transform:rotate(90deg)" : undefined}>
                  <ChevronRightIcon size={13} />
                </span>
              </button>
              {archiveOpen.value &&
                archived.map((room) => (
                  <RoomRow key={room.id} room={room} selected={room.id === selectedRoomId} {...rowProps} />
                ))}
            </>
          )}
        </div>
      </div>

      {sheetOpen.value && <NewPickleSheet store={store} onClose={() => (sheetOpen.value = false)} />}
    </div>
  );
}

type RowProps = { now: Date; locale: "ko" | "en"; times: RoomTimeLabels };

/**
 * One thin header for both states: chevron, group color swatch, name, member count, and
 * the unread dot when any member is unread. Collapsing only hides the rows.
 */
function GroupSection({
  group,
  rooms,
  collapsed,
  onToggle,
  selectedRoomId,
  rowProps,
}: {
  group: RemoteDockGroup;
  rooms: RemoteRoom[];
  collapsed: boolean;
  onToggle: () => void;
  selectedRoomId?: string;
  rowProps: RowProps;
}): JSX.Element {
  const unread = rooms.some((room) => room.unread);
  const membersId = `group-members-${group.id}`;
  return (
    <div class={`group-section ${groupClass(group.color)}`}>
      <button
        class="group-header"
        type="button"
        aria-expanded={!collapsed}
        aria-controls={membersId}
        aria-label={t("remote.roomList.group.label", group.name, rooms.length) + (unread ? `, ${t("dock.unread")}` : "")}
        onClick={onToggle}
      >
        <span class="group-chevron" style={collapsed ? undefined : "transform:rotate(90deg)"}>
          <ChevronRightIcon size={12} />
        </span>
        <span class="group-swatch" aria-hidden="true" />
        <span class="group-name">{group.name}</span>
        <span class="group-count">{rooms.length}</span>
        {unread && <span class="group-unread" aria-hidden="true" />}
      </button>
      {!collapsed && (
        <div class="group-members" id={membersId}>
          {rooms.map((room) => (
            <RoomRow key={room.id} room={room} selected={room.id === selectedRoomId} {...rowProps} />
          ))}
        </div>
      )}
    </div>
  );
}

function roomTimeLabels(): RoomTimeLabels {
  return {
    justNow: t("remote.time.justNow"),
    minutes: (count) => t("remote.time.minutesAgo", count),
    hours: (count) => t("remote.time.hoursAgo", count),
    yesterday: t("remote.time.yesterday"),
  };
}

function MacOfflineBanner(): JSX.Element {
  return (
    <div class="notice warning" role="status">
      <span class="notice-icon">
        <MacOfflineIcon size={14} />
      </span>
      <span class="notice-text">
        <span class="notice-title">{t("remote.mac.offline.title")}</span>
        <span class="notice-body">{t("remote.mac.offline.body")}</span>
      </span>
    </div>
  );
}

function RoomRow({ room, now, locale, times, selected }: RowProps & { room: RemoteRoom; selected: boolean }): JSX.Element {
  const isMain = room.id === MAIN_ROOM_ID;
  const classes = ["room-row", statusClass(room.status)];
  if (selected) classes.push("is-selected");
  if (room.pinned || isMain) classes.push("pinned");
  if (room.unread) classes.push("unread");

  return (
    <a
      class={classes.join(" ")}
      href={`/room/${encodeURIComponent(room.id)}`}
      data-room-id={room.id}
      aria-current={selected ? "page" : undefined}
      onClick={(event) => {
        event.preventDefault();
        navigate({ name: "room", roomId: room.id });
      }}
    >
      <span class={`avatar${isMain ? " picky" : ""}${room.status === "running" && !isMain ? " is-running" : ""}`}>
        {room.status === "running" && !isMain && <span class="avatar-ring" />}
        <PickleGlyph class="avatar-glyph" />
        {room.unread && (
          <>
            <span class="avatar-unread" />
            <span class="sr-only">{t("dock.unread")}</span>
          </>
        )}
      </span>
      <span class="row-main">
        <span class="row-top">
          <span class="row-title">{room.title}</span>
          {(room.pinned || isMain) && (
            <>
              <svg class="row-pin" width="10" height="10" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
                <path d="M9.6 1.6l4.8 4.8-1.4 1.4-1-.2-3 3 .3 2.1-1.2 1.2-3-3-3 3-.8-.8 3-3-3-3L2.5 5.9l2.1.3 3-3-.2-1z" />
              </svg>
              <span class="sr-only">{t("remote.roomList.pinned")}</span>
            </>
          )}
          <span class="row-time">{formatRoomTime(room.updatedAt, now, locale, times)}</span>
        </span>
        <span class="row-bottom">
          {room.status === "idle" ? null : (
            // An idle Picky room has nothing to report; "queued" or "done" would both mislead.
            <span class="row-status">
              <StatusGlyph status={room.status} />
              <span>{t(statusLabelKey(room.status))}</span>
            </span>
          )}
          {room.preview && <span class="row-summary">{room.preview}</span>}
        </span>
      </span>
    </a>
  );
}

/** The gateway owns the dock order; the phone only guarantees the Picky room stays on top. */
function keepMainFirst(rooms: readonly RemoteRoom[]): RemoteRoom[] {
  const main = rooms.filter((room) => room.id === MAIN_ROOM_ID);
  return [...main, ...rooms.filter((room) => room.id !== MAIN_ROOM_ID)];
}
