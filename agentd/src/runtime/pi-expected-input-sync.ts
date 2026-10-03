/**
 * Keeps Picky's expected-input bookkeeping in step with per-item queue edits.
 *
 * Every prompt Picky hands to Pi registers an expectation so the matching Pi echo is
 * attributed to Picky instead of surfacing as an extension message. When Picky later
 * removes, rewrites, or moves a queued entry, its expectation has to follow; a stale one
 * swallows the next identical text from elsewhere (for example a delayed-action message
 * with the same wording), hiding it from the transcript.
 */
export interface ExpectedInputDelivery {
  id: string;
  text: string;
  originatedBy: "user" | "main_agent" | "internal" | "pi_extension";
  suppress: boolean;
  queueKind?: "steering" | "followUp";
  aliases?: Set<string>;
}

type QueueKind = "steering" | "followUp";

function indexFor(deliveries: readonly ExpectedInputDelivery[], text: string, kind: QueueKind): number {
  const sameKind = deliveries.findIndex((delivery) => delivery.text === text && delivery.queueKind === kind);
  return sameKind >= 0 ? sameKind : deliveries.findIndex((delivery) => delivery.text === text);
}

/** Drops one expectation per removed queue text. */
export function dropExpectedInputs(deliveries: ExpectedInputDelivery[], texts: readonly string[], kind: QueueKind): void {
  for (const text of texts) {
    const index = indexFor(deliveries, text, kind);
    if (index >= 0) deliveries.splice(index, 1);
  }
}

/** Points the expectation for a rewritten or moved entry at its new text or queue. */
export function retargetExpectedInput(
  deliveries: ExpectedInputDelivery[],
  text: string,
  kind: QueueKind,
  next: { text?: string; queueKind?: QueueKind },
): void {
  const index = indexFor(deliveries, text, kind);
  if (index < 0) return;
  const current = deliveries[index]!;
  deliveries[index] = { ...current, ...(next.text === undefined ? {} : { text: next.text, aliases: undefined }), ...(next.queueKind ? { queueKind: next.queueKind } : {}) };
}

/** Runs a queue edit and, only if it applied, brings the edited entry's expectation along. */
export function syncedQueueEdit(
  deliveries: ExpectedInputDelivery[],
  editedText: string | undefined,
  edit: () => boolean,
  sync: (deliveries: ExpectedInputDelivery[], text: string) => void,
): boolean {
  const applied = edit();
  if (applied && editedText !== undefined) sync(deliveries, editedText);
  return applied;
}
