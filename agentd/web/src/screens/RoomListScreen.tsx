/**
 * Room list: the Picky room pinned on top, then Pickles by recent activity,
 * with the archive at the bottom. Ported from the reviewed prototype
 * (docs/prototypes/picky-remote-pwa/room-list.html).
 */
import { useComputed, useSignal } from "@preact/signals";
import type { JSX } from "preact";
import { MAIN_ROOM_ID } from "../../../src/remote/constants";
import type { RemoteDockGroup, RemoteRoom } from "../../../src/remote/protocol";
import { formatRoomTime } from "../app/format";
import { t } from "../app/i18n";
import { navigate } from "../app/navigation";
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

export function RoomListScreen({ store, selectedRoomId }: { store: AppStore; selectedRoomId?: string }): JSX.Element {
  const groupFilter = store.roomListGroup;
  const archiveOpen = useSignal(false);
  const sheetOpen = useSignal(false);

  const groups = store.groups.value;
  // A filter whose group disappeared would hide everything; fall back to all.
  const activeGroup = groups.some((group) => group.id === groupFilter.value) ? groupFilter.value : undefined;

  const visible = useComputed(() => sortRooms(store.rooms.value));
  const rooms = visible.value.filter((room) => !room.archived && matchesGroup(room, activeGroup));
  const archived = visible.value.filter((room) => room.archived);
  const pickles = rooms.filter((room) => room.id !== MAIN_ROOM_ID);
  const now = new Date();

  return (
    <div class="app-shell">
      <div class="app-topbar app-side-inset">
        <span class="app-topbar-title">{t("messages.title")}</span>
        <button class="icon-button" type="button" aria-label={t("remote.settings.title")} onClick={() => navigate({ name: "settings" })}>
          <GearIcon size={17} />
        </button>
        <button class="list-new" type="button" onClick={() => (sheetOpen.value = true)}>
          <PlusIcon size={12} />
          <span>{t("remote.roomList.newPickle")}</span>
        </button>
      </div>

      {groups.length > 0 && (
        <div class="list-filters app-side-inset">
          <button
            class={`filter-chip${activeGroup === undefined ? " selected" : ""}`}
            type="button"
            onClick={() => (groupFilter.value = undefined)}
          >
            <span>{t("remote.roomList.filter.all")}</span>
          </button>
          {groups.map((group) => (
            <GroupChip key={group.id} group={group} selected={group.id === activeGroup} onSelect={() => (groupFilter.value = group.id)} />
          ))}
        </div>
      )}

      <div class="app-scroll app-side-inset">
        {!store.mac.value.connected && <MacOfflineBanner />}

        <div class="list-rows">
          {rooms.map((room) => (
            <RoomRow key={room.id} room={room} now={now} locale={store.locale} selected={room.id === selectedRoomId} />
          ))}

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
                  <RoomRow key={room.id} room={room} now={now} locale={store.locale} selected={room.id === selectedRoomId} />
                ))}
            </>
          )}
        </div>
      </div>

      {sheetOpen.value && <NewPickleSheet store={store} onClose={() => (sheetOpen.value = false)} />}
    </div>
  );
}

function GroupChip({ group, selected, onSelect }: { group: RemoteDockGroup; selected: boolean; onSelect: () => void }): JSX.Element {
  return (
    <button class={`filter-chip ${groupClass(group.color)}${selected ? " selected" : ""}`} type="button" onClick={onSelect}>
      <span class="filter-dot" />
      {group.name}
    </button>
  );
}

function MacOfflineBanner(): JSX.Element {
  return (
    <div class="notice warning">
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

function RoomRow({ room, now, locale, selected }: { room: RemoteRoom; now: Date; locale: "ko" | "en"; selected: boolean }): JSX.Element {
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
          <span class="row-time">{formatRoomTime(room.updatedAt, now, locale, t("remote.time.yesterday"))}</span>
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

function matchesGroup(room: RemoteRoom, groupId: string | undefined): boolean {
  // The Picky room is not in any dock group but stays pinned on top of every filter.
  if (!groupId || room.id === MAIN_ROOM_ID) return true;
  return room.groupIds.includes(groupId);
}

/** The gateway already orders rooms; sorting again keeps the list stable if it ever does not. */
function sortRooms(rooms: readonly RemoteRoom[]): RemoteRoom[] {
  return [...rooms].sort((left, right) => {
    if (left.id === MAIN_ROOM_ID) return -1;
    if (right.id === MAIN_ROOM_ID) return 1;
    if (left.pinned !== right.pinned) return left.pinned ? -1 : 1;
    return (right.updatedAt ?? "").localeCompare(left.updatedAt ?? "");
  });
}
