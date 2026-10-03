import type { PickyQueueItem, PickyScheduledMessage } from "../protocol.js";
import { visibleQueueEntryIndices, type MaterializedQueueDeliveryIdentity } from "./queue-policy.js";

/**
 * Failures the app can act on: a lost race against the agent draining the queue, and a
 * missing delayed-action extension. Anything else stays a generic command error.
 */
export type SessionQueueCommandErrorCode = "queueItemNotFound" | "delayedActionUnavailable";

export class SessionQueueCommandError extends Error {
  constructor(readonly code: SessionQueueCommandErrorCode, message: string) {
    super(message);
    this.name = "SessionQueueCommandError";
  }
}

export interface QueueItemLocation {
  kind: "steering" | "followUp";
  /** Position in the runtime queue, which is what per-item edits address. */
  index: number;
  item: PickyQueueItem;
}

/**
 * A per-item queue edit Picky itself is about to perform, announced before it reaches the
 * runtime.
 *
 * Pi republishes its queues as plain text, so the queue update a Picky edit triggers looks
 * exactly like the agent consuming a message. Matching the two by text breaks as soon as two
 * queued messages read the same ("continue", "ok"): the wrong entry is treated as delivered
 * and journaled as a user bubble while it is still waiting. The supervisor therefore derives
 * the expected queue from the projection plus this descriptor instead of guessing.
 */
export type SelfQueueMutation =
  | { action: "remove"; itemId: string }
  | { action: "rewrite"; itemId: string; text: string }
  | { action: "promote"; itemId: string };

export interface ProjectedQueues {
  steering: PickyQueueItem[];
  followUp: PickyQueueItem[];
}

/**
 * The queue the projection should hold once `mutation` lands, with every surviving entry
 * keeping its own delivery id. Returns undefined when the item is not in the projection, in
 * which case the caller falls back to ordinary text reconciliation.
 */
export function applySelfQueueMutation(
  projected: { steering: readonly PickyQueueItem[]; followUp: readonly PickyQueueItem[] },
  mutation: SelfQueueMutation,
): ProjectedQueues | undefined {
  const steering = [...projected.steering];
  const followUp = [...projected.followUp];
  const followUpIndex = followUp.findIndex((item) => item.id === mutation.itemId);
  if (mutation.action === "remove") {
    const steeringIndex = steering.findIndex((item) => item.id === mutation.itemId);
    if (steeringIndex >= 0) {
      steering.splice(steeringIndex, 1);
      return { steering, followUp };
    }
    if (followUpIndex < 0) return undefined;
    followUp.splice(followUpIndex, 1);
    return { steering, followUp };
  }
  if (followUpIndex < 0) return undefined;
  const item = followUp[followUpIndex]!;
  if (mutation.action === "rewrite") {
    // The rewritten entry carries text only, so an image count from the original submission
    // must not survive into the row or the user bubble Pi eventually journals. The rewrite text
    // comes straight from the composer, so it is already the user-facing instruction.
    followUp[followUpIndex] = { id: item.id, text: mutation.text, displayText: mutation.text, enqueuedAt: item.enqueuedAt };
    return { steering, followUp };
  }
  followUp.splice(followUpIndex, 1);
  steering.push(item);
  return { steering, followUp };
}

/** True when `items` describes exactly the texts the runtime just published, in order. */
function queueItemsMatchTexts(items: readonly PickyQueueItem[], texts: readonly string[]): boolean {
  return items.length === texts.length && items.every((item, index) => item.text === texts[index]);
}

/**
 * Queue items for an update caused by Picky's own per-item edit. The announced mutation is
 * only trusted when the runtime published exactly the queue it predicts; anything else (the
 * agent drained an entry in the same window) falls back to ordinary text reconciliation.
 */
export function selfMutatedQueueItems(
  mutation: SelfQueueMutation | undefined,
  projected: { steering?: readonly PickyQueueItem[]; followUp?: readonly PickyQueueItem[] },
  runtimeQueues: { steering: readonly string[]; followUp: readonly string[] },
): ProjectedQueues | undefined {
  if (!mutation) return undefined;
  const expected = applySelfQueueMutation({ steering: projected.steering ?? [], followUp: projected.followUp ?? [] }, mutation);
  if (!expected) return undefined;
  if (!queueItemsMatchTexts(expected.steering, runtimeQueues.steering)) return undefined;
  if (!queueItemsMatchTexts(expected.followUp, runtimeQueues.followUp)) return undefined;
  return expected;
}

/**
 * Resolves a projected queue item id to its position in the runtime queue.
 *
 * Positions are matched by text occurrence rather than by projected index: the projection
 * can hide entries the agent already materialized, and the runtime snapshot can carry
 * adapter-held prompts, so the two lists are not guaranteed to be index-aligned. Duplicate
 * texts are disambiguated by counting occurrences, which keeps "remove the second identical
 * message" addressing the second one. Occurrences are counted over the runtime positions the
 * projection still shows, so an identical text whose bubble was already journaled cannot
 * shift the target onto a message the user never sees.
 */
export function locateRuntimeQueueItem(
  projected: { steering: readonly PickyQueueItem[]; followUp: readonly PickyQueueItem[] },
  runtime: { steering: readonly string[]; followUp: readonly string[] },
  itemId: string,
  deliveries: {
    pending?: readonly MaterializedQueueDeliveryIdentity[];
    materialized?: readonly MaterializedQueueDeliveryIdentity[];
  } = {},
): QueueItemLocation | undefined {
  const visible = visibleQueueEntryIndices(runtime, deliveries.pending ?? [], deliveries.materialized ?? []);
  for (const kind of ["steering", "followUp"] as const) {
    const items = kind === "steering" ? projected.steering : projected.followUp;
    const projectedIndex = items.findIndex((item) => item.id === itemId);
    if (projectedIndex < 0) continue;
    const item = items[projectedIndex]!;
    const occurrence = items.slice(0, projectedIndex).filter((candidate) => candidate.text === item.text).length;
    const runtimeTexts = kind === "steering" ? runtime.steering : runtime.followUp;
    let seen = 0;
    for (const index of kind === "steering" ? visible.steering : visible.followUp) {
      if (runtimeTexts[index] !== item.text) continue;
      if (seen === occurrence) return { kind, index, item };
      seen += 1;
    }
    return undefined;
  }
  return undefined;
}

export function findScheduledMessage(
  messages: readonly PickyScheduledMessage[] | undefined,
  scheduledId: string,
): PickyScheduledMessage | undefined {
  return messages?.find((message) => message.id === scheduledId);
}

/**
 * What the delayed-action extension answered when Picky cancelled one of its tasks.
 *
 * The extension reports the outcome only through `ctx.ui.notify` ("✓ <id> 예약을 취소했어요."
 * versus "예약을 찾을 수 없어요: <id>"), which Picky suppresses and captures. Without that
 * answer a task that fired a moment before the cancel is indistinguishable from one the
 * cancel removed, and re-scheduling or sending it would deliver the message twice.
 */
export type DelayedActionCancelOutcome = "cancelled" | "missing" | "unknown";

export function delayedActionCancelOutcome(notifications: readonly string[]): DelayedActionCancelOutcome {
  const answers = notifications.map((entry) => entry.trim()).filter((entry) => entry.length > 0);
  const answer = answers[answers.length - 1];
  if (!answer) return "unknown";
  return answer.startsWith("✓") ? "cancelled" : "missing";
}

/**
 * Remaining time for a scheduled message whose text is being edited. The due time is kept,
 * so an edit never silently postpones delivery; a message that is already due is pushed out
 * by the one-second floor the extension's timer needs.
 */
export function remainingDelayMs(dueAt: string, now: number): number {
  const due = Date.parse(dueAt);
  if (!Number.isFinite(due)) return 1_000;
  return Math.max(1_000, due - now);
}
