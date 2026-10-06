/**
 * Room list sections: the gateway's dock-ordered rooms folded into rows and
 * collapsible groups. A group sits where its first member sits in the dock
 * order, and lists its members in that same order, so neither a reply nor a
 * collapse moves anything else on the screen.
 */
import type { RemoteDockGroup, RemoteRoom } from "../../../src/remote/protocol";

export type RoomListEntry =
  | { kind: "room"; room: RemoteRoom }
  | { kind: "group"; group: RemoteDockGroup; rooms: RemoteRoom[] };

export function buildRoomSections(rooms: readonly RemoteRoom[], groups: readonly RemoteDockGroup[]): RoomListEntry[] {
  const groupsById = new Map(groups.map((group) => [group.id, group]));
  const entries: RoomListEntry[] = [];
  const sections = new Map<string, Extract<RoomListEntry, { kind: "group" }>>();
  for (const room of rooms) {
    // The HUD allows one group per Pickle; an unknown group id means the overlay
    // dropped it, so the room falls back to a plain row instead of vanishing.
    const group = room.groupIds.map((id) => groupsById.get(id)).find((item) => item !== undefined);
    if (!group) {
      entries.push({ kind: "room", room });
      continue;
    }
    const section = sections.get(group.id);
    if (section) {
      section.rooms.push(room);
      continue;
    }
    const created = { kind: "group" as const, group, rooms: [room] };
    sections.set(group.id, created);
    entries.push(created);
  }
  return entries;
}

const COLLAPSED_KEY = "picky.roomList.collapsedGroups";

/** Phone-only: collapsing a group here never folds it on the Mac. */
export function loadCollapsedGroups(storage: Pick<Storage, "getItem"> | undefined): Set<string> {
  try {
    const parsed: unknown = JSON.parse(storage?.getItem(COLLAPSED_KEY) ?? "[]");
    return new Set(Array.isArray(parsed) ? parsed.filter((id): id is string => typeof id === "string") : []);
  } catch {
    return new Set();
  }
}

export function saveCollapsedGroups(storage: Pick<Storage, "setItem" | "removeItem"> | undefined, ids: ReadonlySet<string>): void {
  try {
    if (ids.size === 0) storage?.removeItem(COLLAPSED_KEY);
    else storage?.setItem(COLLAPSED_KEY, JSON.stringify([...ids]));
  } catch {
    // Private mode or a full quota: the group just opens expanded next time.
  }
}
