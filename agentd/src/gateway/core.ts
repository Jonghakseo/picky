/**
 * Gateway state: hub, daemons, rooms, devices, push.
 *
 * The HTTP and WebSocket layers are thin on top of this. Everything that
 * decides *what* a phone may see or do lives here so it is reachable from tests
 * without opening a socket.
 */
import { AuditLog } from "./audit.js";
import { DeviceStore } from "./device-store.js";
import { DaemonPool } from "./daemon-pool.js";
import { HubLink, type HubConfig, type HubDaemons, type HubHello, type HubOverlay } from "./hub-link.js";
import { LockoutTracker } from "./lockout.js";
import { MainConversation } from "./main-conversation.js";
import { PairingSession } from "./pairing.js";
import { PushService } from "./push/push-service.js";
import { PushThrottle, badgeCount, diffRoomPushEvents, isWithinMainReplyWindow, roomPushState, shouldNotifyDevice, type RoomPushState } from "./push/triggers.js";
import { UploadStore } from "./uploads.js";
import { CommandDeduplicator } from "./command-dedupe.js";
import { buildRoomList, MAIN_ROOM_TITLE, type RoomListResult } from "./rooms.js";
import { errorMessage, logGateway } from "./log.js";
import { MAIN_ROOM_ID } from "../remote/constants.js";
import type { PickyAgentSession } from "../protocol.js";
import type { RemoteMacState, RemoteRoom, RemoteServerMessage } from "../remote/protocol.js";
import type { HubRequest } from "../remote/hub-protocol.js";
import type { CommandContext } from "./command-executor.js";
import type { GatewayConfig } from "./config.js";
import type { PushFetch } from "./push/sender.js";

export const ROOM_REBUILD_DEBOUNCE_MS = 150;
const SESSION_WAIT_POLL_MS = 100;

export interface ClientHandle {
  readonly deviceId: string;
  visible: boolean;
  locale?: string;
  readonly openRooms: Set<string>;
  send: (message: RemoteServerMessage) => void;
  close: (code: number, reason: string) => void;
}

export interface GatewayCoreOptions {
  config: GatewayConfig;
  pushFetch?: PushFetch;
}

export class GatewayCore {
  readonly config: GatewayConfig;
  readonly devices: DeviceStore;
  readonly pairing = new PairingSession();
  readonly lockout = new LockoutTracker();
  readonly audit: AuditLog;
  readonly uploads: UploadStore;
  readonly push: PushService;
  readonly hub: HubLink;
  readonly daemons: DaemonPool;
  readonly main: MainConversation;
  readonly clients = new Set<ClientHandle>();
  /** Per-device command history so a retry after a dropped socket is not a resend. */
  readonly dedupe = new CommandDeduplicator<unknown>();

  private rebuildTimer?: NodeJS.Timeout;
  private roomsResult: RoomListResult = { rooms: [], groups: [], folders: { pinned: [], recent: [] } };
  private lastRoomStates = new Map<string, RoomPushState>();
  private readonly throttle = new PushThrottle();
  private readonly lastMainSendAt = new Map<string, number>();
  private readonly mainUnread = new Set<string>();

  constructor(options: GatewayCoreOptions) {
    this.config = options.config;
    this.devices = new DeviceStore(this.config.dataDir);
    this.audit = new AuditLog(this.config.dataDir);
    this.uploads = new UploadStore(this.config.dataDir);
    this.push = new PushService({
      dataDir: this.config.dataDir,
      devices: this.devices,
      ...(options.pushFetch ? { fetchImpl: options.pushFetch } : {}),
    });
    this.main = new MainConversation({
      onMessage: (message) => {
        this.broadcast({ type: "main.message", message });
        if (message.role === "assistant") this.notifyMainReply(message.text);
        this.scheduleRoomRebuild();
      },
      onActivity: (activity, busy) => {
        this.broadcast({ type: "main.activity", ...(activity ? { activity } : {}), busy });
        this.scheduleRoomRebuild();
      },
      onQuestion: (request) => {
        this.broadcast({ type: "main.question", ...(request ? { request } : {}) });
        this.scheduleRoomRebuild();
      },
      onStateReplaced: (state) => {
        this.broadcast({ type: "main.state", state });
        this.scheduleRoomRebuild();
      },
    });
    this.hub = new HubLink(this.hubListener());
    this.daemons = new DaemonPool(this.daemonListener());
  }

  async start(): Promise<void> {
    await this.devices.load();
    await this.push.init();
    await this.uploads.pruneExpired().catch(() => 0);
  }

  stop(): void {
    if (this.rebuildTimer) clearTimeout(this.rebuildTimer);
    this.daemons.stop();
    for (const client of this.clients) client.close(1001, "gateway shutting down");
    this.clients.clear();
  }

  /* --------------------------------------------------------------- */
  /* Clients                                                          */
  /* --------------------------------------------------------------- */

  addClient(client: ClientHandle): void {
    this.clients.add(client);
  }

  removeClient(client: ClientHandle): void {
    this.clients.delete(client);
  }

  broadcast(message: RemoteServerMessage): void {
    for (const client of this.clients) client.send(message);
  }

  clientsFor(deviceId: string): ClientHandle[] {
    return [...this.clients].filter((client) => client.deviceId === deviceId);
  }

  macState(): RemoteMacState {
    const hello = this.hub.hello;
    return {
      connected: this.hub.connected,
      ...(hello?.macName ? { name: hello.macName } : {}),
      ...(hello?.appVersion ? { appVersion: hello.appVersion } : {}),
      dictation: this.hub.config?.dictation ?? { available: false, reason: "macUnavailable" },
    };
  }

  rooms(): RoomListResult {
    return this.roomsResult;
  }

  roomTitle(roomId: string): string {
    if (roomId === MAIN_ROOM_ID) return MAIN_ROOM_TITLE;
    return this.roomsResult.rooms.find((room) => room.id === roomId)?.title ?? roomId;
  }

  session(sessionId: string): PickyAgentSession | undefined {
    return this.daemons.projection(sessionId);
  }

  /* --------------------------------------------------------------- */
  /* Rooms                                                            */
  /* --------------------------------------------------------------- */

  scheduleRoomRebuild(): void {
    if (this.rebuildTimer) return;
    this.rebuildTimer = setTimeout(() => {
      this.rebuildTimer = undefined;
      this.rebuildRooms();
    }, ROOM_REBUILD_DEBOUNCE_MS);
    this.rebuildTimer.unref?.();
  }

  rebuildRooms(): void {
    const sessions = new Map<string, PickyAgentSession>();
    for (const sessionId of this.daemons.sessionIds()) {
      const session = this.daemons.projection(sessionId);
      if (session) sessions.set(sessionId, session);
    }
    const mainState = this.main.state();
    const questionPrompt = mainState.pendingQuestion?.prompt ?? mainState.pendingQuestion?.title;
    const lastAssistantText = this.main.lastAssistantText();
    const mainUpdatedAt = this.main.lastUpdatedAt();
    this.roomsResult = buildRoomList({
      sessions,
      ...(this.hub.overlay ? { overlay: this.hub.overlay } : {}),
      main: {
        busy: this.main.busy,
        pendingQuestion: this.main.hasPendingQuestion,
        ...(questionPrompt ? { questionPrompt } : {}),
        ...(lastAssistantText ? { lastAssistantText } : {}),
        ...(mainUpdatedAt ? { updatedAt: mainUpdatedAt } : {}),
        unread: this.mainUnread.size > 0,
      },
    });
    this.broadcast({ type: "rooms", ...this.roomsResult });
    void this.evaluatePush(this.roomsResult.rooms);
  }

  /* --------------------------------------------------------------- */
  /* Push                                                             */
  /* --------------------------------------------------------------- */

  private async evaluatePush(rooms: readonly RemoteRoom[]): Promise<void> {
    const states = rooms.map(roomPushState);
    const events = diffRoomPushEvents(this.lastRoomStates, states);
    this.lastRoomStates = new Map(states.map((state) => [state.id, state]));
    if (!this.push.enabled || events.length === 0) return;

    const badge = badgeCount(states);
    for (const event of events) {
      if (!this.throttle.allow(event.roomId)) continue;
      const deviceIds = this.devicesToNotify(event.roomId);
      if (deviceIds.length === 0) continue;
      await this.push.notify(deviceIds, { ...event, badge }).catch((error: unknown) => {
        logGateway("push notify failed", { roomId: event.roomId, error: errorMessage(error) });
        return 0;
      });
    }
  }

  private notifyMainReply(text: string): void {
    if (!this.push.enabled) return;
    const badge = badgeCount([...this.lastRoomStates.values()]);
    const deviceIds = this.devicesToNotify(MAIN_ROOM_ID)
      .filter((deviceId) => isWithinMainReplyWindow(this.lastMainSendAt.get(deviceId)));
    for (const deviceId of deviceIds) this.mainUnread.add(deviceId);
    if (deviceIds.length === 0 || !this.throttle.allow(MAIN_ROOM_ID)) return;
    void this.push
      .notify(deviceIds, { roomId: MAIN_ROOM_ID, roomTitle: MAIN_ROOM_TITLE, kind: "reply", badge })
      .catch((error: unknown) => {
        logGateway("push notify failed", { roomId: MAIN_ROOM_ID, error: errorMessage(error), textChars: text.length });
        return 0;
      });
  }

  /** Every paired device except the ones already looking at that room. */
  private devicesToNotify(roomId: string): string[] {
    return this.devices.list()
      .filter((device) => device.pushSubscriptions.length > 0)
      .filter((device) => this.clientsFor(device.id).every((client) => shouldNotifyDevice({
        visible: client.visible,
        ...(client.openRooms.has(roomId) ? { viewingRoomId: roomId } : {}),
        roomId,
      })))
      .map((device) => device.id);
  }

  markRoomViewed(deviceId: string, roomId: string): void {
    if (roomId === MAIN_ROOM_ID) this.mainUnread.delete(deviceId);
  }

  /* --------------------------------------------------------------- */
  /* Commands                                                         */
  /* --------------------------------------------------------------- */

  commandContext(): CommandContext {
    return {
      hubConnected: this.hub.connected,
      hubRequest: (deviceId: string, request: HubRequest) => this.hub.request(deviceId, request),
      ownerFor: (sessionId: string) => this.daemons.ownerFor(sessionId),
      resolveUploads: (uploadIds: readonly string[]) => this.uploads.resolveAll(uploadIds),
      waitForSession: (sessionId: string, timeoutMs: number) => this.waitForSession(sessionId, timeoutMs),
      audit: this.audit,
      onMainSend: (deviceId: string) => {
        this.lastMainSendAt.set(deviceId, Date.now());
        this.main.markTurnStarted();
      },
    };
  }

  private async waitForSession(sessionId: string, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.daemons.entry(sessionId)) return true;
      await new Promise((resolve) => setTimeout(resolve, SESSION_WAIT_POLL_MS));
    }
    return this.daemons.entry(sessionId) !== undefined;
  }

  /* --------------------------------------------------------------- */
  /* Devices                                                          */
  /* --------------------------------------------------------------- */

  async revokeDevice(deviceId: string, by: "hub" | "device"): Promise<boolean> {
    const removed = await this.devices.remove(deviceId);
    if (!removed) return false;
    this.audit.record({ action: "device.revoke", deviceId, by });
    for (const client of this.clientsFor(deviceId)) {
      client.send({ type: "revoked" });
      client.close(4401, "device revoked");
    }
    this.lastMainSendAt.delete(deviceId);
    this.publishDevices();
    return true;
  }

  publishDevices(): void {
    if (!this.hub.connected) return;
    const online = new Set([...this.clients].map((client) => client.deviceId));
    this.hub.send({ type: "gateway.devices", devices: this.devices.hubDevices(online) });
  }

  /* --------------------------------------------------------------- */
  /* Hub and daemon wiring                                            */
  /* --------------------------------------------------------------- */

  private hubListener() {
    return {
      onHello: (hello: HubHello) => {
        logGateway("hub connected", { appVersion: hello.appVersion });
        this.broadcast({ type: "mac", mac: this.macState() });
        this.publishDevices();
      },
      onDaemons: (daemons: HubDaemons) => {
        this.daemons.setTopology({
          token: daemons.token,
          ...(daemons.primary ? { primaryUrl: normalizeDaemonUrl(daemons.primary.url) } : {}),
          children: daemons.children.map((child) => ({ sessionId: child.sessionId, url: normalizeDaemonUrl(child.url) })),
        });
      },
      onOverlay: (_overlay: HubOverlay) => this.scheduleRoomRebuild(),
      onConfig: (config: HubConfig) => {
        this.push.setSubject(config.publicUrl);
        this.broadcast({ type: "mac", mac: this.macState() });
      },
      onPairingStart: () => {
        const code = this.pairing.start();
        this.hub.send({
          type: "gateway.pairing",
          code: code.display,
          expiresAt: code.expiresAt,
          ...(this.hub.config?.publicUrl ? { url: `${this.hub.config.publicUrl}/#pair=${code.code}` } : {}),
        });
      },
      onPairingCancel: () => {
        this.pairing.cancel();
        this.hub.send({ type: "gateway.pairing.ended", reason: "cancelled" });
      },
      onRevoke: (deviceId: string) => void this.revokeDevice(deviceId, "hub"),
      onRename: (deviceId: string, name: string) => void this.devices.rename(deviceId, name).then(() => this.publishDevices()),
      onConnectionChange: (connected: boolean) => {
        this.broadcast({ type: "mac", mac: this.macState() });
        if (connected) this.publishDevices();
        else this.daemons.setTopology({ token: "", children: [] });
      },
    };
  }

  private daemonListener() {
    return {
      onSessionReset: (sessionId: string) => {
        for (const client of this.clients) {
          if (client.openRooms.has(sessionId)) this.sendSessionSnapshot(client, sessionId);
        }
      },
      onSessionTransaction: (frame: { sessionId: string; epoch: string; baseRevision: number; revision: number; mutations: unknown[] }) => {
        for (const client of this.clients) {
          if (!client.openRooms.has(frame.sessionId)) continue;
          // Field by field, not a spread: the daemon frame carries its own
          // `type` (`sessionProjectionTransaction`), which would overwrite the
          // remote message type and leave the phone unable to apply the diff.
          client.send({
            type: "session.transaction",
            sessionId: frame.sessionId,
            epoch: frame.epoch,
            baseRevision: frame.baseRevision,
            revision: frame.revision,
            mutations: frame.mutations,
          } as RemoteServerMessage);
        }
      },
      onSessionsChanged: () => this.scheduleRoomRebuild(),
      onMainEvent: (event: { type: string; [key: string]: unknown }) => {
        this.main.handleEvent(event);
      },
      onPrimaryConnected: () => void this.loadMainMessages(),
      onConnectionChange: () => this.broadcast({ type: "mac", mac: this.macState() }),
    };
  }

  private async loadMainMessages(): Promise<void> {
    const primary = this.daemons.primary();
    if (!primary) return;
    try {
      const event = await primary.request({ type: "listMainMessages" }, (candidate) => candidate.type === "mainMessagesSnapshot");
      this.main.handleEvent(event);
    } catch (error) {
      logGateway("main messages load failed", { error: errorMessage(error) });
    }
  }

  /* --------------------------------------------------------------- */
  /* Room subscription                                                */
  /* --------------------------------------------------------------- */

  /**
   * Opening a room: send the newest snapshot the gateway holds, but ask the
   * owner first when that snapshot was partial, so the phone never renders a
   * section the daemon merely omitted as if it were empty.
   */
  async openRoom(client: ClientHandle, sessionId: string, forceRefresh = false): Promise<void> {
    client.openRooms.add(sessionId);
    const entry = this.daemons.entry(sessionId);
    if (entry && entry.complete && !forceRefresh) {
      this.sendSessionSnapshot(client, sessionId);
      return;
    }
    // A successful refresh re-enters through `onSessionReset`, which sends the
    // snapshot to every client with this room open, including this one.
    const refreshed = await this.daemons.refreshSnapshot(sessionId).then(() => true).catch(() => false);
    if (!refreshed) this.sendSessionSnapshot(client, sessionId);
  }

  sendSessionSnapshot(client: ClientHandle, sessionId: string): void {
    const entry = this.daemons.entry(sessionId);
    const projection = this.daemons.projection(sessionId);
    if (!entry || !projection) {
      client.send({ type: "session.unavailable", sessionId, reason: this.hub.connected ? "notFound" : "macOffline" });
      return;
    }
    client.send({
      type: "session.snapshot",
      sessionId,
      epoch: entry.epoch,
      revision: entry.revision,
      complete: entry.complete,
      omittedFields: [],
      projection,
    });
  }
}

/** The hub may send `ws://127.0.0.1:17631/`; the links are keyed by exact url. */
function normalizeDaemonUrl(url: string): string {
  return url.replace(/\/$/, "");
}
