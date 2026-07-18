import type { PickyQueueItem } from "../protocol.js";

export interface PendingQueueDeliveryIdentity {
  id: string;
  text: string;
}

export interface MaterializedQueueDeliveryIdentity extends PendingQueueDeliveryIdentity {
  kind: "steering" | "followUp";
}

export interface PendingQueueDelivery extends MaterializedQueueDeliveryIdentity {
  originatedBy: "user" | "main_agent";
  attachedImagesCount?: number;
}

export function dropAlreadyMaterializedQueueEntries<T extends MaterializedQueueDeliveryIdentity>(
  queues: { steering: readonly string[]; followUp: readonly string[] },
  pendingDeliveries: readonly T[],
  materializedDeliveries: readonly T[],
): { queues: { steering: string[]; followUp: string[] }; remainingMaterialized: T[] } {
  const pendingCounts = new Map<string, number>();
  for (const delivery of pendingDeliveries) {
    const key = `${delivery.kind}\u0000${delivery.text}`;
    pendingCounts.set(key, (pendingCounts.get(key) ?? 0) + 1);
  }

  const remainingMaterialized = [...materializedDeliveries];
  const dropForKind = (kind: T["kind"], texts: readonly string[]): string[] => {
    const result: string[] = [];
    for (const text of texts) {
      const key = `${kind}\u0000${text}`;
      const pendingCount = pendingCounts.get(key) ?? 0;
      if (pendingCount > 0) {
        pendingCounts.set(key, pendingCount - 1);
        result.push(text);
        continue;
      }

      const materializedIndex = remainingMaterialized.findIndex((entry) => entry.kind === kind && entry.text === text);
      if (materializedIndex >= 0) {
        remainingMaterialized.splice(materializedIndex, 1);
      } else {
        result.push(text);
      }
    }
    return result;
  };

  return {
    queues: {
      steering: dropForKind("steering", queues.steering),
      followUp: dropForKind("followUp", queues.followUp),
    },
    remainingMaterialized,
  };
}

export function matchPreviousQueueItems(
  nextTexts: readonly string[],
  previous: readonly PickyQueueItem[] | undefined = [],
): { matched: Array<PickyQueueItem | undefined>; usedPreviousIndexes: Set<number> } {
  const matched: Array<PickyQueueItem | undefined> = Array(nextTexts.length).fill(undefined);
  const usedPreviousIndexes = new Set<number>();

  if (nextTexts.length > previous.length) {
    let searchStart = 0;
    for (let nextIndex = 0; nextIndex < nextTexts.length; nextIndex += 1) {
      const previousIndex = previous.findIndex((item, index) => index >= searchStart && !usedPreviousIndexes.has(index) && item.text === nextTexts[nextIndex]);
      if (previousIndex < 0) continue;
      matched[nextIndex] = previous[previousIndex];
      usedPreviousIndexes.add(previousIndex);
      searchStart = previousIndex + 1;
    }
  } else {
    let searchEnd = previous.length - 1;
    for (let nextIndex = nextTexts.length - 1; nextIndex >= 0; nextIndex -= 1) {
      let previousIndex = -1;
      for (let index = searchEnd; index >= 0; index -= 1) {
        if (!usedPreviousIndexes.has(index) && previous[index]?.text === nextTexts[nextIndex]) {
          previousIndex = index;
          break;
        }
      }
      if (previousIndex < 0) continue;
      matched[nextIndex] = previous[previousIndex];
      usedPreviousIndexes.add(previousIndex);
      searchEnd = previousIndex - 1;
    }
  }

  return { matched, usedPreviousIndexes };
}

export function queueItems(
  items: readonly string[],
  enqueuedAt: string,
  previous: readonly PickyQueueItem[] | undefined = [],
  pendingDeliveries: readonly PendingQueueDeliveryIdentity[] = [],
  makeId: () => string,
): PickyQueueItem[] {
  const { matched } = matchPreviousQueueItems(items, previous);
  const previousIds = new Set(matched.flatMap((item) => item?.id ? [item.id] : []));
  const pendingByText = new Map<string, PendingQueueDeliveryIdentity[]>();
  for (const delivery of pendingDeliveries) {
    if (previousIds.has(delivery.id)) continue;
    const entries = pendingByText.get(delivery.text) ?? [];
    entries.push(delivery);
    pendingByText.set(delivery.text, entries);
  }
  return items.map((text, index) => {
    const previousItem = matched[index];
    if (previousItem) return previousItem;
    const pending = pendingByText.get(text)?.shift();
    return { id: pending?.id ?? makeId(), text, enqueuedAt };
  });
}

export function sameQueueItems(left: readonly PickyQueueItem[], right: readonly PickyQueueItem[]): boolean {
  return left.length === right.length && left.every((item, index) => item.id === right[index]?.id && item.text === right[index]?.text && item.enqueuedAt === right[index]?.enqueuedAt);
}

/**
 * Compute queue entries that exist in the previous combined queue (steers + follow-ups) but not in
 * the new runtime string snapshot, accounting for duplicate text occurrences. Returning the full
 * previous queue item preserves the Picky delivery id so duplicate texts can be drained one by one.
 */
export function diffQueueRemovedItems(
  previousSteers: readonly PickyQueueItem[],
  previousFollowUps: readonly PickyQueueItem[],
  nextSteers: readonly string[],
  nextFollowUps: readonly string[],
): PickyQueueItem[] {
  const { usedPreviousIndexes: usedSteers } = matchPreviousQueueItems(nextSteers, previousSteers);
  const { usedPreviousIndexes: usedFollowUps } = matchPreviousQueueItems(nextFollowUps, previousFollowUps);
  return [
    ...previousSteers.filter((_, index) => !usedSteers.has(index)),
    ...previousFollowUps.filter((_, index) => !usedFollowUps.has(index)),
  ];
}

export function queueTextMatchesUserText(queueText: string, userText: string): boolean {
  return queueText === userText || extractPickyPromptUserInstruction(queueText) === userText;
}

/**
 * Extract the raw user instruction from a Picky steering/follow-up prompt envelope so queue
 * entries materialized from prompt text can be matched back to the original user input.
 */
export function extractPickyPromptUserInstruction(text: string): string | undefined {
  const envelopes: Array<{ parent: string; userSection: string }> = [
    { parent: "# Picky steering message", userSection: "## User steering instruction" },
    { parent: "# Picky follow-up", userSection: "## User follow-up" },
  ];
  const envelope = envelopes.find((candidate) => text.includes(candidate.parent));
  if (!envelope) return undefined;
  const headingIndex = text.indexOf(envelope.userSection);
  if (headingIndex < 0) return undefined;

  const body = text.slice(headingIndex + envelope.userSection.length);
  const lines = body.split("\n");
  const extracted: string[] = [];
  let hasStarted = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (!hasStarted && trimmed.length === 0) continue;
    if (hasStarted && trimmed.startsWith("## ")) break;
    hasStarted = true;
    extracted.push(line);
  }

  if (extracted[0]?.trim().startsWith("- Source:")) {
    extracted.shift();
    if (extracted[0]?.trim().length === 0) extracted.shift();
  }

  const result = extracted.join("\n").trim();
  return result.length > 0 ? result : undefined;
}
