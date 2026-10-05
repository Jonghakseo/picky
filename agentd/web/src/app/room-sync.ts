/**
 * Decides what to do with a projection frame for an open room.
 *
 * The gateway streams `session.snapshot` then `session.transaction`, each with
 * an epoch (the owning daemon's bootstrap) and a revision chain. A transaction
 * whose `baseRevision` is not the revision we hold, or whose epoch differs,
 * means we missed a frame: ask for a fresh snapshot with `room.resync` and drop
 * frames until it lands, so the reducer never folds a gap.
 */
export interface HeldRevision {
  epoch: string;
  revision: number;
}

export interface IncomingTransaction {
  epoch: string;
  baseRevision: number;
  revision: number;
}

export type FrameDecision = "apply" | "resync" | "ignore";

export function decideTransaction(
  held: HeldRevision | undefined,
  incoming: IncomingTransaction,
  awaitingSnapshot: boolean,
): FrameDecision {
  // A resync is already in flight: everything before its snapshot is noise.
  if (awaitingSnapshot) return "ignore";
  if (!held) return "resync";
  if (held.epoch !== incoming.epoch) return "resync";
  if (held.revision !== incoming.baseRevision) {
    // A replayed frame we already folded is not a gap; drop it quietly.
    return incoming.revision <= held.revision ? "ignore" : "resync";
  }
  return "apply";
}

export interface IncomingSnapshot {
  epoch: string;
  revision: number;
}

/** A snapshot always replaces what we hold: it is authoritative for its epoch. */
export function decideSnapshot(held: HeldRevision | undefined, incoming: IncomingSnapshot): FrameDecision {
  if (held && held.epoch === incoming.epoch && incoming.revision < held.revision) return "ignore";
  return "apply";
}
