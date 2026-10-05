/**
 * One paired phone on `/api/ws`.
 *
 * Every inbound frame is parsed with `RemoteClientMessageSchema` before it can
 * reach the daemons: this socket is the only place where a message from outside
 * the Mac turns into a daemon command.
 */
import type { WebSocket } from "ws";
import { REMOTE_PROTOCOL_VERSION, MAIN_ROOM_ID } from "../remote/constants.js";
import {
  RemoteClientMessageSchema,
  type RemoteClientMessage,
  type RemoteCommand,
  type RemoteError,
  type RemoteQuery,
  type RemoteServerMessage,
} from "../remote/protocol.js";
import { executeCommand, executeQuery, RemoteCommandError } from "./command-executor.js";
import type { ClientHandle, GatewayCore } from "./core.js";
import { errorMessage, logGateway } from "./log.js";

export class ClientConnection implements ClientHandle {
  visible = true;
  locale?: string;
  readonly openRooms = new Set<string>();

  constructor(
    private readonly socket: WebSocket,
    readonly deviceId: string,
    readonly deviceName: string,
    private readonly core: GatewayCore,
  ) {
    socket.on("message", (data) => this.handleMessage(data.toString()));
    socket.on("close", () => {
      this.core.removeClient(this);
      this.core.publishDevices();
    });
    socket.on("error", (error) => logGateway("client socket error", { deviceId, error: errorMessage(error) }));

    core.addClient(this);
    this.send({
      type: "welcome",
      protocolVersion: REMOTE_PROTOCOL_VERSION,
      device: { id: deviceId, name: deviceName },
      mac: core.macState(),
      serverTime: new Date().toISOString(),
      ...(core.push.publicKey ? { vapidPublicKey: core.push.publicKey } : {}),
    });
    core.publishDevices();
  }

  send(message: RemoteServerMessage): void {
    if (this.socket.readyState !== this.socket.OPEN) return;
    this.socket.send(JSON.stringify(message));
  }

  close(code: number, reason: string): void {
    this.socket.close(code, reason);
  }

  private handleMessage(raw: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      this.send({ type: "error", error: { code: "invalid", message: "Message is not JSON." } });
      return;
    }
    const result = RemoteClientMessageSchema.safeParse(parsed);
    if (!result.success) {
      this.send({ type: "error", error: { code: "invalid", message: "Message does not match the remote protocol." } });
      return;
    }
    void this.dispatch(result.data);
  }

  private async dispatch(message: RemoteClientMessage): Promise<void> {
    switch (message.type) {
      case "hello":
        this.visible = message.visible;
        if (message.locale) this.locale = message.locale;
        await this.core.devices.touch(this.deviceId, message.locale);
        this.send({ type: "mac", mac: this.core.macState() });
        this.send({ type: "rooms", ...this.core.rooms() });
        return;
      case "visibility":
        this.visible = message.visible;
        if (message.visible) this.core.markViewedRoomsRead();
        return;
      case "room.open":
        await this.openRoom(message.roomId, false);
        return;
      case "room.close":
        this.openRooms.delete(message.roomId);
        return;
      case "room.resync":
        await this.openRoom(message.roomId, true);
        return;
      case "command":
        await this.runCommand(message.commandId, message.command);
        return;
      case "query":
        await this.runQuery(message.queryId, message.query);
        return;
      case "ping":
        this.send({ type: "pong", t: message.t });
        return;
    }
  }

  private async openRoom(roomId: string, resync: boolean): Promise<void> {
    this.core.markRoomViewed(this.deviceId, roomId);
    if (roomId === MAIN_ROOM_ID) {
      this.openRooms.add(roomId);
      this.send({ type: "main.state", state: this.core.main.state() });
      return;
    }
    await this.core.openRoom(this, roomId, resync);
  }

  private async runCommand(commandId: string, command: RemoteCommand): Promise<void> {
    try {
      const data = await this.core.dedupe.run(this.deviceId, commandId, () =>
        executeCommand(this.core.commandContext(), this.deviceId, command));
      this.send({ type: "command.result", commandId, ok: true, ...(data !== undefined ? { data } : {}) });
    } catch (error) {
      this.send({ type: "command.result", commandId, ok: false, error: toRemoteError(error) });
    }
  }

  private async runQuery(queryId: string, query: RemoteQuery): Promise<void> {
    try {
      const data = await executeQuery(this.core.commandContext(), query);
      this.send({ type: "query.result", queryId, ok: true, data });
    } catch (error) {
      this.send({ type: "query.result", queryId, ok: false, error: toRemoteError(error) });
    }
  }
}

function toRemoteError(error: unknown): RemoteError {
  if (error instanceof RemoteCommandError) return error.toRemoteError();
  return { code: "internal", message: errorMessage(error) };
}
