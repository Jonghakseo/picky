import { describe, expect, it } from "vitest";
import type { RemoteDockGroup, RemoteRoom } from "../../../src/remote/protocol";
import { buildRoomSections, loadCollapsedGroups, saveCollapsedGroups } from "./room-sections";

function room(id: string, groupIds: string[] = []): RemoteRoom {
  return { id, kind: "pickle", title: id, status: "running", unread: false, pinned: false, archived: false, groupIds, pendingQuestion: false, backgroundTasks: 0 };
}

const work: RemoteDockGroup = { id: "g1", name: "Work", color: "teal" };

function shape(entries: ReturnType<typeof buildRoomSections>): string[] {
  return entries.map((entry) => (entry.kind === "room" ? entry.room.id : `${entry.group.id}[${entry.rooms.map((item) => item.id).join(",")}]`));
}

describe("buildRoomSections", () => {
  it("places a group where its first member sits and keeps member order", () => {
    const entries = buildRoomSections([room("a"), room("m1", ["g1"]), room("b"), room("m2", ["g1"])], [work]);
    expect(shape(entries)).toEqual(["a", "g1[m1,m2]", "b"]);
  });

  it("shows a room as a plain row when its group is unknown", () => {
    expect(shape(buildRoomSections([room("a", ["gone"])], [work]))).toEqual(["a"]);
  });
});

describe("collapsed groups persistence", () => {
  function memoryStorage() {
    const data = new Map<string, string>();
    return {
      getItem: (key: string) => data.get(key) ?? null,
      setItem: (key: string, value: string) => void data.set(key, value),
      removeItem: (key: string) => void data.delete(key),
    };
  }

  it("survives a reload", () => {
    const storage = memoryStorage();
    saveCollapsedGroups(storage, new Set(["g1", "g2"]));
    expect([...loadCollapsedGroups(storage)].sort()).toEqual(["g1", "g2"]);
  });

  it("opens everything when storage is empty, broken, or unavailable", () => {
    const storage = memoryStorage();
    expect(loadCollapsedGroups(storage).size).toBe(0);
    storage.setItem("picky.roomList.collapsedGroups", "{not json");
    expect(loadCollapsedGroups(storage).size).toBe(0);
    expect(loadCollapsedGroups(undefined).size).toBe(0);
  });
});
