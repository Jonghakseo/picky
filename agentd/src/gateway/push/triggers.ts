/**
 * When a push is worth sending (docs/remote-pwa-implementation.md 2.8).
 *
 * Pure transitions, not level checks: a room that is already failed must not
 * re-notify on every unrelated projection update. The throttle is the second
 * guard, for a session that flaps between states inside ten seconds.
 */
import type { RemoteRoom, RemoteRoomStatus } from "../../remote/protocol.js";
import type { PushKind } from "./push-copy.js";

export const PUSH_THROTTLE_MS = 10_000;
/** A main reply only notifies when the user asked recently from that device. */
export const MAIN_REPLY_WINDOW_MS = 30 * 60 * 1000;

export interface RoomPushState {
  id: string;
  title: string;
  status: RemoteRoomStatus;
  pendingQuestion: boolean;
}

export interface PushEvent {
  roomId: string;
  roomTitle: string;
  kind: PushKind;
}

export function roomPushState(room: RemoteRoom): RoomPushState {
  return { id: room.id, title: room.title, status: room.status, pendingQuestion: room.pendingQuestion };
}

export function diffRoomPushEvents(
  previous: ReadonlyMap<string, RoomPushState>,
  next: readonly RoomPushState[],
): PushEvent[] {
  const events: PushEvent[] = [];
  for (const room of next) {
    const before = previous.get(room.id);
    if (!before) continue; // A room the gateway is seeing for the first time is history, not news.
    if (room.pendingQuestion && !before.pendingQuestion) {
      events.push({ roomId: room.id, roomTitle: room.title, kind: "question" });
      continue;
    }
    if (room.status === before.status) continue;
    if (room.status === "completed") events.push({ roomId: room.id, roomTitle: room.title, kind: "completed" });
    else if (room.status === "failed" || room.status === "blocked") events.push({ roomId: room.id, roomTitle: room.title, kind: "failed" });
  }
  return events;
}

export function badgeCount(rooms: readonly RoomPushState[]): number {
  return rooms.filter((room) => room.pendingQuestion).length;
}

/** One notification per room per 10 s, shared by every device. */
export class PushThrottle {
  private readonly lastSentMs = new Map<string, number>();

  allow(roomId: string, nowMs = Date.now()): boolean {
    const last = this.lastSentMs.get(roomId);
    if (last !== undefined && nowMs - last < PUSH_THROTTLE_MS) return false;
    this.lastSentMs.set(roomId, nowMs);
    return true;
  }
}

/**
 * A device that is looking at the room already sees the change, so pushing to
 * it would only duplicate what is on screen.
 */
export function shouldNotifyDevice(options: {
  viewingRoomId?: string;
  visible: boolean;
  roomId: string;
}): boolean {
  return !(options.visible && options.viewingRoomId === options.roomId);
}

export function isWithinMainReplyWindow(lastMainSendAtMs: number | undefined, nowMs = Date.now()): boolean {
  return lastMainSendAtMs !== undefined && nowMs - lastMainSendAtMs <= MAIN_REPLY_WINDOW_MS;
}
