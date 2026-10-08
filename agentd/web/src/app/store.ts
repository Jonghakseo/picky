/**
 * Application state. One store instance per page load, fed by a `Transport`.
 *
 * Per-room state lives in its own signal so a streaming Pickle re-renders its
 * room and nothing else; the room list reads the `rooms` signal the gateway
 * rebuilds. Projection frames fold through the same reducer the Mac uses
 * (`agentd/src/domain/session-projection-reducer.ts`), which is what keeps the
 * phone and the HUD showing the same session.
 */
import { signal, type Signal } from "@preact/signals";
import { MAIN_ROOM_ID } from "../../../src/remote/constants";
import {
  applySessionProjectionSnapshot,
  applySessionProjectionTransaction,
  materializeSessionProjection,
  type SessionProjectionState,
} from "../../../src/domain/session-projection-reducer";
import type { PickyAgentSession } from "../../../src/protocol";
import type {
  RemoteCommand,
  RemoteDockGroup,
  RemoteError,
  RemoteFolders,
  RemoteMacState,
  RemoteMainState,
  RemoteQuery,
  RemoteRoom,
  RemoteServerMessage,
} from "../../../src/remote/protocol";
import { CommandRegistry, type CommandResult } from "./commands";
import { currentLocale, type Locale } from "./i18n";
import { decideSnapshot, decideTransaction } from "./room-sync";
import { loadCollapsedGroups, saveCollapsedGroups } from "./room-sections";
import type { ConnectionStatus, Transport } from "./transport";

export type PairingState = "unknown" | "unpaired" | "paired" | "revoked";

export interface RoomRuntime {
  /** No snapshot (or main state) yet. */
  loading: boolean;
  /** A `room.resync` is in flight; frames are dropped until the snapshot lands. */
  awaitingSnapshot: boolean;
  epoch?: string;
  revision?: number;
  projection?: SessionProjectionState;
  session?: PickyAgentSession;
  unavailable?: "notFound" | "macOffline";
}

const emptyRuntime: RoomRuntime = { loading: true, awaitingSnapshot: false };

const emptyMac: RemoteMacState = { connected: false, dictation: { available: true } };

const emptyMain: RemoteMainState = { messages: [], busy: false, tasks: [], decisions: [] };

const DRAFT_PREFIX = "picky.draft.";

export class AppStore {
  readonly connection = signal<ConnectionStatus>("connecting");
  readonly pairing = signal<PairingState>("unknown");
  readonly device = signal<{ id: string; name: string } | undefined>(undefined);
  readonly mac = signal<RemoteMacState>(emptyMac);
  readonly rooms = signal<RemoteRoom[]>([]);
  readonly groups = signal<RemoteDockGroup[]>([]);
  readonly folders = signal<RemoteFolders>({ pinned: [], recent: [] });
  readonly main = signal<RemoteMainState>(emptyMain);
  readonly vapidPublicKey = signal<string | undefined>(undefined);
  readonly insecure = signal(false);
  /** True once a `rooms` message has arrived, so the list can tell empty from not-yet-loaded. */
  readonly roomsLoaded = signal(false);
  /**
   * Room list groups the user folded on this phone. Lives here, not in the list
   * screen, so opening a Pickle and coming back keeps them folded; persisted so
   * a reload does too.
   */
  readonly collapsedGroups = signal<ReadonlySet<string>>(loadCollapsedGroups(globalThis.localStorage));

  readonly locale: Locale = currentLocale();

  private readonly runtimes = new Map<string, Signal<RoomRuntime>>();
  private readonly openRooms = new Set<string>();
  private readonly queries = new Map<string, (result: { ok: true; data: unknown } | { ok: false; error: RemoteError }) => void>();
  private readonly commands: CommandRegistry;
  private queryCounter = 0;

  constructor(readonly transport: Transport) {
    this.commands = new CommandRegistry((id, command) => {
      this.transport.send({ type: "command", commandId: id, command });
    });
  }

  start(): void {
    this.transport.start({
      message: (message) => this.handle(message),
      status: (status) => this.setStatus(status),
    });
  }

  stop(): void {
    this.transport.stop();
  }

  markRevoked(): void {
    this.pairing.value = "revoked";
    this.commands.failAll({ code: "unauthorized", message: "device revoked" });
  }

  /* ---- rooms --------------------------------------------------------- */

  runtime(roomId: string): Signal<RoomRuntime> {
    let held = this.runtimes.get(roomId);
    if (!held) {
      held = signal<RoomRuntime>(emptyRuntime);
      this.runtimes.set(roomId, held);
    }
    return held;
  }

  openRoom(roomId: string): void {
    this.openRooms.add(roomId);
    this.transport.send({ type: "room.open", roomId });
  }

  closeRoom(roomId: string): void {
    this.openRooms.delete(roomId);
    this.transport.send({ type: "room.close", roomId });
  }

  room(roomId: string): RemoteRoom | undefined {
    return this.rooms.value.find((room) => room.id === roomId);
  }

  /* ---- commands and queries ------------------------------------------ */

  command(command: RemoteCommand): Promise<CommandResult> {
    if (this.pairing.value === "revoked") {
      return Promise.resolve({ ok: false, error: { code: "unauthorized", message: "device revoked" } });
    }
    return this.commands.send(command);
  }

  query(query: RemoteQuery): Promise<{ ok: true; data: unknown } | { ok: false; error: RemoteError }> {
    const queryId = `q_${(this.queryCounter += 1)}`;
    return new Promise((resolve) => {
      this.queries.set(queryId, resolve);
      this.transport.send({ type: "query", queryId, query });
      setTimeout(() => {
        if (!this.queries.delete(queryId)) return;
        resolve({ ok: false, error: { code: "timeout", message: "query timed out" } });
      }, 30_000);
    });
  }

  toggleGroupCollapsed(groupId: string): void {
    const next = new Set(this.collapsedGroups.value);
    if (!next.delete(groupId)) next.add(groupId);
    this.collapsedGroups.value = next;
    saveCollapsedGroups(globalThis.localStorage, next);
  }

  /* ---- drafts -------------------------------------------------------- */

  loadDraft(roomId: string): string {
    try {
      return globalThis.localStorage?.getItem(DRAFT_PREFIX + roomId) ?? "";
    } catch {
      return "";
    }
  }

  saveDraft(roomId: string, text: string): void {
    try {
      if (text.length === 0) globalThis.localStorage?.removeItem(DRAFT_PREFIX + roomId);
      else globalThis.localStorage?.setItem(DRAFT_PREFIX + roomId, text);
    } catch {
      // Private mode or a full quota: a lost draft is not worth an error screen.
    }
  }

  /* ---- transport events ---------------------------------------------- */

  private setStatus(status: ConnectionStatus): void {
    this.connection.value = status;
    if (status !== "open") return;
    // Re-subscribe, then resend commands whose result we never saw. The gateway
    // dedupes by command id, so a command that did run is not run twice.
    for (const roomId of this.openRooms) this.transport.send({ type: "room.open", roomId });
    this.commands.resend();
  }

  private handle(message: RemoteServerMessage): void {
    switch (message.type) {
      case "welcome":
        this.pairing.value = "paired";
        this.device.value = message.device;
        this.mac.value = message.mac;
        this.vapidPublicKey.value = message.vapidPublicKey;
        break;
      case "mac":
        this.mac.value = message.mac;
        break;
      case "rooms":
        this.rooms.value = message.rooms;
        this.groups.value = message.groups;
        this.folders.value = message.folders;
        this.roomsLoaded.value = true;
        break;
      case "session.snapshot":
        this.applySnapshot(message);
        break;
      case "session.transaction":
        this.applyTransaction(message);
        break;
      case "session.unavailable": {
        const held = this.runtime(message.sessionId);
        held.value = { ...held.value, loading: false, unavailable: message.reason };
        break;
      }
      case "main.state": {
        this.main.value = message.state;
        const held = this.runtime(MAIN_ROOM_ID);
        held.value = { ...held.value, loading: false, awaitingSnapshot: false };
        break;
      }
      case "main.message": {
        const current = this.main.value;
        if (current.messages.some((held) => held.id === message.message.id)) break;
        this.main.value = { ...current, messages: [...current.messages, message.message] };
        break;
      }
      case "main.activity":
        this.main.value = { ...this.main.value, activity: message.activity, busy: message.busy };
        break;
      case "main.question":
        this.main.value = { ...this.main.value, pendingQuestion: message.request };
        break;
      case "main.tasks":
        this.main.value = { ...this.main.value, tasks: message.tasks, decisions: message.decisions };
        break;
      case "command.result":
        this.commands.resolve(message.commandId, message.ok ? { ok: true, data: message.data } : { ok: false, error: message.error });
        break;
      case "query.result": {
        const resolve = this.queries.get(message.queryId);
        this.queries.delete(message.queryId);
        resolve?.(message.ok ? { ok: true, data: message.data } : { ok: false, error: message.error });
        break;
      }
      case "revoked":
        this.markRevoked();
        break;
      case "pong":
      case "error":
        break;
    }
  }

  private applySnapshot(message: Extract<RemoteServerMessage, { type: "session.snapshot" }>): void {
    const held = this.runtime(message.sessionId);
    const current = held.value;
    const decision = decideSnapshot(
      current.epoch && current.revision !== undefined ? { epoch: current.epoch, revision: current.revision } : undefined,
      { epoch: message.epoch, revision: message.revision },
    );
    if (decision === "ignore") return;
    // A snapshot from a different epoch replaces the state; the same epoch rehydrates it.
    const previous = current.epoch === message.epoch ? current.projection : undefined;
    const projection = applySessionProjectionSnapshot(previous, {
      sessionId: message.sessionId,
      revision: message.revision,
      omittedFields: message.omittedFields,
      projection: message.projection,
    });
    held.value = {
      loading: false,
      awaitingSnapshot: false,
      epoch: message.epoch,
      revision: message.revision,
      projection,
      session: materializeSessionProjection(projection),
    };
  }

  private applyTransaction(message: Extract<RemoteServerMessage, { type: "session.transaction" }>): void {
    const held = this.runtime(message.sessionId);
    const current = held.value;
    const decision = decideTransaction(
      current.epoch && current.revision !== undefined ? { epoch: current.epoch, revision: current.revision } : undefined,
      { epoch: message.epoch, baseRevision: message.baseRevision, revision: message.revision },
      current.awaitingSnapshot,
    );
    if (decision === "ignore") return;
    if (decision === "resync") {
      held.value = { ...current, awaitingSnapshot: true };
      this.transport.send({ type: "room.resync", roomId: message.sessionId });
      return;
    }
    const projection = applySessionProjectionTransaction(current.projection, {
      sessionId: message.sessionId,
      revision: message.revision,
      mutations: message.mutations,
    });
    if (!projection) {
      held.value = { ...current, awaitingSnapshot: true };
      this.transport.send({ type: "room.resync", roomId: message.sessionId });
      return;
    }
    held.value = {
      ...current,
      loading: false,
      revision: message.revision,
      projection,
      session: materializeSessionProjection(projection) ?? current.session,
    };
  }
}
