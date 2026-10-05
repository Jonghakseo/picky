/**
 * Every daemon link, plus the ownership rule that decides whose frames count
 * (docs/remote-pwa-implementation.md 2.5, docs/per-pickle-daemon-topology.md).
 *
 * All daemons share one session store, so the primary also projects sessions a
 * child hosts. The child the hub lists for a session is authoritative for it;
 * frames for that session from any other link are dropped rather than folded,
 * because two writers into one reduced state would interleave revisions.
 */
import {
  applySessionProjectionSnapshot,
  applySessionProjectionTransaction,
  materializeSessionProjection,
  type SessionProjectionState,
} from "../domain/session-projection-reducer.js";
import type { PickyAgentSession } from "../protocol.js";
import { DaemonLink, type DaemonEvent, type DaemonSnapshotFrame, type DaemonTransactionFrame } from "./daemon-link.js";
import { errorMessage, logGateway } from "./log.js";

export interface DaemonTopology {
  token: string;
  primaryUrl?: string;
  children: Array<{ sessionId: string; url: string }>;
}

export interface SessionProjectionEntry {
  state: SessionProjectionState;
  epoch: string;
  revision: number;
  /** False while the newest snapshot omitted fields: a room open must refresh first. */
  complete: boolean;
  ownerUrl: string;
}

export interface DaemonPoolListener {
  /** A session's folded state was replaced; open rooms need a fresh snapshot. */
  onSessionReset: (sessionId: string) => void;
  /** A transaction the gateway accepted, ready to forward verbatim. */
  onSessionTransaction: (frame: DaemonTransactionFrame) => void;
  /** Projection content changed in a way the room list may care about. */
  onSessionsChanged: () => void;
  onMainEvent: (event: DaemonEvent) => void;
  onPrimaryConnected: () => void;
  onConnectionChange: () => void;
}

const MAIN_EVENT_TYPES = new Set([
  "mainMessagesSnapshot",
  "mainMessageAppended",
  "mainActivityUpdated",
  "mainExtensionUiRequested",
  "mainExtensionUiCancelled",
  "mainTurnSettled",
]);

export class DaemonPool {
  private readonly links = new Map<string, DaemonLink>();
  private readonly projections = new Map<string, SessionProjectionEntry>();
  private topology: DaemonTopology = { token: "", children: [] };
  private primaryUrl?: string;

  constructor(private readonly listener: DaemonPoolListener) {}

  setTopology(topology: DaemonTopology): void {
    this.topology = topology;
    this.primaryUrl = topology.primaryUrl;
    const wanted = new Set<string>([...(topology.primaryUrl ? [topology.primaryUrl] : []), ...topology.children.map((child) => child.url)]);

    const orphaned: string[] = [];
    for (const [url, link] of this.links) {
      if (wanted.has(url)) {
        link.updateToken(topology.token);
        continue;
      }
      link.stop();
      this.links.delete(url);
      orphaned.push(...this.dropProjectionsOwnedBy(url));
    }

    for (const url of wanted) {
      if (this.links.has(url)) continue;
      const link = new DaemonLink(url, topology.token, {
        onSnapshot: (frame) => this.handleSnapshot(url, frame),
        onTransaction: (frame) => this.handleTransaction(url, frame),
        onEvent: (event) => this.handleEvent(url, event),
        onConnectionChange: (connected) => this.handleConnectionChange(url, connected),
      }, url === topology.primaryUrl ? "primary" : "child");
      this.links.set(url, link);
      link.start();
    }

    // Releasing a child daemon does not end its sessions: they stay in the
    // shared store and the primary still projects them. Without re-seeding, the
    // room list skips an id with no projection and the Pickle disappears from
    // the phone. A primary that is not connected yet re-bootstraps everything
    // on its own, so there is nothing to ask for in that case.
    const primary = this.primaryUrl ? this.links.get(this.primaryUrl) : undefined;
    if (primary?.connected) {
      for (const sessionId of orphaned) void this.recoverFrom(sessionId, "owner-released");
    }

    this.listener.onConnectionChange();
    this.listener.onSessionsChanged();
  }

  stop(): void {
    for (const link of this.links.values()) link.stop();
    this.links.clear();
    this.projections.clear();
  }

  get primaryConnected(): boolean {
    return this.primaryUrl ? this.links.get(this.primaryUrl)?.connected === true : false;
  }

  primary(): DaemonLink | undefined {
    const link = this.primaryUrl ? this.links.get(this.primaryUrl) : undefined;
    return link?.connected ? link : undefined;
  }

  /** The child that hosts this session when it is connected, else the primary. */
  ownerFor(sessionId: string): DaemonLink | undefined {
    const childUrl = this.topology.children.find((child) => child.sessionId === sessionId)?.url;
    const child = childUrl ? this.links.get(childUrl) : undefined;
    if (child?.connected) return child;
    return this.primary();
  }

  sessionIds(): string[] {
    return [...this.projections.keys()];
  }

  projection(sessionId: string): PickyAgentSession | undefined {
    const entry = this.projections.get(sessionId);
    return entry ? materializeSessionProjection(entry.state) : undefined;
  }

  entry(sessionId: string): SessionProjectionEntry | undefined {
    return this.projections.get(sessionId);
  }

  entries(): ReadonlyMap<string, SessionProjectionEntry> {
    return this.projections;
  }

  /** Asks the owning daemon for a complete snapshot (room open, resync, gap). */
  async refreshSnapshot(sessionId: string): Promise<void> {
    const owner = this.ownerFor(sessionId);
    if (!owner) throw new Error("No daemon owns this session");
    await owner.request(
      (commandId) => ({ type: "getSessionProjectionSnapshot", requestId: commandId, sessionId }),
      (event) => event.type === "sessionProjectionSnapshot" && event.sessionId === sessionId,
    );
  }

  private ownerUrlFor(sessionId: string): string | undefined {
    const childUrl = this.topology.children.find((child) => child.sessionId === sessionId)?.url;
    if (childUrl && this.links.get(childUrl)?.connected) return childUrl;
    return this.primaryUrl;
  }

  private handleSnapshot(url: string, frame: DaemonSnapshotFrame): void {
    if (this.ownerUrlFor(frame.sessionId) !== url) return;
    const previous = this.projections.get(frame.sessionId);
    const continues = previous?.ownerUrl === url && previous.epoch === frame.epoch;
    const state = applySessionProjectionSnapshot(continues ? previous.state : undefined, {
      sessionId: frame.sessionId,
      revision: frame.revision,
      omittedFields: frame.omittedFields,
      projection: frame.projection,
    });
    this.projections.set(frame.sessionId, {
      state,
      epoch: frame.epoch,
      revision: frame.revision,
      // Completeness is sticky within an epoch: a later partial snapshot layers
      // onto state a complete one already filled in.
      complete: frame.complete || (continues ? previous.complete : false),
      ownerUrl: url,
    });
    this.listener.onSessionReset(frame.sessionId);
    this.listener.onSessionsChanged();
  }

  private handleTransaction(url: string, frame: DaemonTransactionFrame): void {
    if (this.ownerUrlFor(frame.sessionId) !== url) return;
    const previous = this.projections.get(frame.sessionId);
    if (!previous || previous.ownerUrl !== url || previous.epoch !== frame.epoch || previous.revision !== frame.baseRevision) {
      // A gap or an epoch change: the folded state would silently diverge, so
      // discard this transaction and let a fresh snapshot re-seed the session.
      void this.recoverFrom(frame.sessionId, previous ? "gap" : "unknown-session");
      return;
    }
    const state = applySessionProjectionTransaction(previous.state, {
      sessionId: frame.sessionId,
      revision: frame.revision,
      mutations: frame.mutations,
    });
    if (!state) return;
    this.projections.set(frame.sessionId, { ...previous, state, revision: frame.revision });
    this.listener.onSessionTransaction(frame);
    this.listener.onSessionsChanged();
  }

  private async recoverFrom(sessionId: string, reason: string): Promise<void> {
    try {
      await this.refreshSnapshot(sessionId);
    } catch (error) {
      logGateway("projection recovery failed", { sessionId, reason, error: errorMessage(error) });
    }
  }

  private handleEvent(url: string, event: DaemonEvent): void {
    if (url !== this.primaryUrl) return;
    if (MAIN_EVENT_TYPES.has(event.type)) this.listener.onMainEvent(event);
  }

  private handleConnectionChange(url: string, connected: boolean): void {
    logGateway("daemon connection", { url, connected });
    if (!connected) this.dropProjectionsOwnedBy(url);
    // A child that just connected takes ownership of its session back from the
    // primary; its bootstrap snapshot arrives next and resets that session.
    if (connected && url === this.primaryUrl) this.listener.onPrimaryConnected();
    this.listener.onConnectionChange();
    this.listener.onSessionsChanged();
  }

  /** Returns the ids of the sessions that just lost their folded projection. */
  private dropProjectionsOwnedBy(url: string): string[] {
    const dropped: string[] = [];
    for (const [sessionId, entry] of this.projections) {
      if (entry.ownerUrl !== url) continue;
      this.projections.delete(sessionId);
      dropped.push(sessionId);
      this.listener.onSessionReset(sessionId);
    }
    return dropped;
  }
}
