/**
 * Status presentation shared by the gateway (room list, push) and the PWA.
 *
 * TypeScript port of `Picky/HUD/PickySessionStatusPresentation.swift`. Keep the
 * two in step: `status-presentation.test.ts` pins the same table the Swift
 * extension encodes, so a change on one side fails until the other follows.
 */
import type { SessionStatus } from "../protocol.js";
import type { RemoteRoomStatus } from "./protocol.js";

export type HudStatusTone = "inProgress" | "error" | "completed" | "other";

export function hudStatusTone(status: RemoteRoomStatus): HudStatusTone {
  switch (status) {
    case "running":
      return "inProgress";
    case "blocked":
    case "failed":
      return "error";
    case "completed":
      return "completed";
    case "queued":
    case "waiting_for_input":
    case "cancelled":
    case "idle":
      return "other";
  }
}

export function isTerminalStatus(status: RemoteRoomStatus): boolean {
  return status === "completed" || status === "failed" || status === "cancelled";
}

/** Lower sorts first. Matches `PickySessionStatus.hudPriority`; `idle` (main room only) sorts last. */
export function hudStatusPriority(status: RemoteRoomStatus): number {
  const priorities: Record<SessionStatus, number> = {
    waiting_for_input: 0,
    running: 1,
    queued: 2,
    blocked: 3,
    failed: 4,
    completed: 5,
    cancelled: 6,
  };
  return status === "idle" ? 7 : priorities[status];
}
