import type { WebSocket } from "ws";
import type { CommandHandlersFor, EventPayload } from "../slice-contract.js";
import type { SettingsControlBroker } from "./settings-control-broker.js";

export type SettingsCommandType =
  | "listPickySettings"
  | "getPickySettings"
  | "setPickySettings"
  | "completePickySettingsRequest";

/**
 * What the settings slice needs from the server: the requesting socket, the
 * broker that round-trips to the Picky app, and a way to answer that socket.
 * Nothing here reaches the session supervisor.
 */
export interface SettingsFeatureContext {
  socket: WebSocket;
  settingsControl: Pick<SettingsControlBroker, "request" | "complete">;
  send: (socket: WebSocket, event: EventPayload) => void;
}

export function settingsCommandHandlers(ctx: SettingsFeatureContext): CommandHandlersFor<SettingsCommandType> {
  const ack = (commandId: string, result: Record<string, unknown>) => {
    ctx.send(ctx.socket, { type: "pickySettingsAck", commandId, result });
  };
  return {
    listPickySettings: async (command) => {
      ack(command.id, await ctx.settingsControl.request({ action: "list", caller: command.caller }));
    },
    getPickySettings: async (command) => {
      ack(command.id, await ctx.settingsControl.request({ action: "get", key: command.key, caller: command.caller }));
    },
    setPickySettings: async (command) => {
      ack(command.id, await ctx.settingsControl.request({
        action: "set",
        key: command.key,
        value: command.value,
        ...(command.toggle !== undefined ? { toggle: command.toggle } : {}),
        ...(command.displayId !== undefined ? { displayId: command.displayId } : {}),
        caller: command.caller,
      }));
    },
    completePickySettingsRequest: (command) => ctx.settingsControl.complete(ctx.socket, command),
  };
}
