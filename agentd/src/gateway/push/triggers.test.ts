/**
 * When a push is worth sending. These are the rules that decide whether a
 * phone buzzes, so the cases that matter are the ones that must stay quiet.
 */
import { describe, expect, it } from "vitest";
import type { RemoteRoom } from "../../remote/protocol.js";
import {
  badgeCount,
  diffRoomPushEvents,
  isWithinMainReplyWindow,
  MAIN_REPLY_WINDOW_MS,
  PushThrottle,
  PUSH_THROTTLE_MS,
  roomPushState,
  shouldNotifyDevice,
  type RoomPushState,
} from "./triggers.js";

function state(overrides: Partial<RoomPushState> & { id: string }): RoomPushState {
  return { title: overrides.id, status: "running", pendingQuestion: false, ...overrides };
}

function previous(...rooms: RoomPushState[]): Map<string, RoomPushState> {
  return new Map(rooms.map((room) => [room.id, room]));
}

describe("room push events", () => {
  it("notifies when a room starts waiting for an answer", () => {
    const events = diffRoomPushEvents(previous(state({ id: "s1" })), [state({ id: "s1", pendingQuestion: true })]);
    expect(events).toEqual([{ roomId: "s1", roomTitle: "s1", kind: "question" }]);
  });

  it("stays quiet while the same question is still pending", () => {
    const waiting = state({ id: "s1", pendingQuestion: true });
    expect(diffRoomPushEvents(previous(waiting), [waiting])).toEqual([]);
  });

  it("notifies on the transition into completed, failed and blocked", () => {
    const running = state({ id: "s1" });
    expect(diffRoomPushEvents(previous(running), [state({ id: "s1", status: "completed" })])).toEqual([
      { roomId: "s1", roomTitle: "s1", kind: "completed" },
    ]);
    expect(diffRoomPushEvents(previous(running), [state({ id: "s1", status: "failed" })])).toEqual([
      { roomId: "s1", roomTitle: "s1", kind: "failed" },
    ]);
    expect(diffRoomPushEvents(previous(running), [state({ id: "s1", status: "blocked" })])).toEqual([
      { roomId: "s1", roomTitle: "s1", kind: "failed" },
    ]);
  });

  it("does not re-notify a room that is already failed", () => {
    const failed = state({ id: "s1", status: "failed" });
    expect(diffRoomPushEvents(previous(failed), [failed])).toEqual([]);
  });

  it("treats a room it has never seen as history, not news", () => {
    expect(diffRoomPushEvents(previous(), [state({ id: "s1", status: "completed", pendingQuestion: true })])).toEqual([]);
  });

  it("prefers the question over a status change in the same update", () => {
    const events = diffRoomPushEvents(
      previous(state({ id: "s1" })),
      [state({ id: "s1", status: "blocked", pendingQuestion: true })],
    );
    expect(events).toEqual([{ roomId: "s1", roomTitle: "s1", kind: "question" }]);
  });

  it("reads its state straight off the room projection", () => {
    const room: RemoteRoom = {
      id: "s1",
      kind: "pickle",
      title: "리팩터링",
      status: "waiting_for_input",
      unread: true,
      pinned: false,
      archived: false,
      groupIds: [],
      pendingQuestion: true,
      backgroundTasks: 0,
    };
    expect(roomPushState(room)).toEqual({ id: "s1", title: "리팩터링", status: "waiting_for_input", pendingQuestion: true });
  });
});

describe("badge and throttle", () => {
  it("counts only the rooms waiting for the user", () => {
    expect(badgeCount([
      state({ id: "s1", pendingQuestion: true }),
      state({ id: "s2" }),
      state({ id: "s3", pendingQuestion: true }),
    ])).toBe(2);
  });

  it("allows one notification per room per ten seconds", () => {
    const throttle = new PushThrottle();
    expect(throttle.allow("s1", 0)).toBe(true);
    expect(throttle.allow("s1", PUSH_THROTTLE_MS - 1)).toBe(false);
    // A different room is unaffected by the first one's cooldown.
    expect(throttle.allow("s2", 1)).toBe(true);
    expect(throttle.allow("s1", PUSH_THROTTLE_MS)).toBe(true);
  });
});

describe("which devices hear about it", () => {
  it("skips the device that is looking at that very room", () => {
    expect(shouldNotifyDevice({ viewingRoomId: "s1", visible: true, roomId: "s1" })).toBe(false);
  });

  it("still notifies a device in another room, or with the app in the background", () => {
    expect(shouldNotifyDevice({ viewingRoomId: "s2", visible: true, roomId: "s1" })).toBe(true);
    expect(shouldNotifyDevice({ viewingRoomId: "s1", visible: false, roomId: "s1" })).toBe(true);
    expect(shouldNotifyDevice({ visible: true, roomId: "s1" })).toBe(true);
  });

  it("only announces a main reply to a device that asked recently", () => {
    const now = 10 * MAIN_REPLY_WINDOW_MS;
    expect(isWithinMainReplyWindow(undefined, now)).toBe(false);
    expect(isWithinMainReplyWindow(now - MAIN_REPLY_WINDOW_MS - 1, now)).toBe(false);
    expect(isWithinMainReplyWindow(now - MAIN_REPLY_WINDOW_MS, now)).toBe(true);
    expect(isWithinMainReplyWindow(now - 1000, now)).toBe(true);
  });
});
