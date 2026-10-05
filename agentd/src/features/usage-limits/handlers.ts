import type { WebSocket } from "ws";
import type { CommandHandlersFor, EventPayload } from "../slice-contract.js";
import type { UsageLimitsSnapshot } from "./schema.js";

export type UsageLimitsCommandType = "getUsageLimits";

/** Implemented by `application/usage-limits-service.ts`. Absent on child daemons and the mock runtime. */
export interface UsageLimitsPort {
  snapshot(options: { force: boolean }): Promise<UsageLimitsSnapshot>;
}

export interface UsageLimitsFeatureContext {
  socket: WebSocket;
  usageLimits?: UsageLimitsPort;
  send: (socket: WebSocket, event: EventPayload) => void;
}

export const USAGE_LIMITS_UNAVAILABLE = "Usage limits unavailable on this daemon";

export function usageLimitsCommandHandlers(ctx: UsageLimitsFeatureContext): CommandHandlersFor<UsageLimitsCommandType> {
  return {
    getUsageLimits: async (command) => {
      if (!ctx.usageLimits) {
        ctx.send(ctx.socket, { type: "usageLimitsResult", commandId: command.id, ok: false, errorMessage: USAGE_LIMITS_UNAVAILABLE });
        return;
      }
      try {
        const snapshot = await ctx.usageLimits.snapshot({ force: command.force === true });
        ctx.send(ctx.socket, { type: "usageLimitsResult", commandId: command.id, ok: true, errorMessage: null, snapshot });
      } catch (error) {
        ctx.send(ctx.socket, {
          type: "usageLimitsResult", commandId: command.id, ok: false,
          errorMessage: error instanceof Error ? error.message : String(error),
        });
      }
    },
  };
}
