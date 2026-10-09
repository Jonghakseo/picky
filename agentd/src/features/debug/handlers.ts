import type { WebSocket } from "ws";
import { recordDaemonTrace, type DebugTraceRing } from "../../domain/debug-trace-ring.js";
import { logAgentd } from "../../local-log.js";
import type { CommandHandlersFor, EventPayload } from "../slice-contract.js";
import { DebugControlError, type DebugControlBroker } from "./debug-control-broker.js";

export type DebugCommandType = "debugApp" | "completeDebugApp" | "publishDebugTrace" | "readDebugTrace";

/**
 * What the debug slice needs from the server: the requesting socket, the broker
 * that round-trips to the Picky app, the process-wide trace ring, and whether
 * this socket is the registered `debugControl` app.
 */
export interface DebugFeatureContext {
  socket: WebSocket;
  debugControl: Pick<DebugControlBroker, "request" | "complete">;
  traceRing: DebugTraceRing;
  hasCapability: (socket: WebSocket, capability: string) => boolean;
  send: (socket: WebSocket, event: EventPayload) => void;
}

export function debugCommandHandlers(ctx: DebugFeatureContext): CommandHandlersFor<DebugCommandType> {
  return {
    debugApp: async (command) => {
      // The command id is the correlation root: the app stamps it on every trace
      // record the injected input produces, so a CLI run can be followed end to end.
      recordDaemonTrace("debug.app.request.sent", { commandId: command.id, target: command.action, event: "debugApp" });
      try {
        const outcome = await ctx.debugControl.request({
          action: command.action,
          commandId: command.id,
          ...(command.text !== undefined ? { text: command.text } : {}),
        });
        recordDaemonTrace("debug.app.request.completed", { commandId: command.id, target: command.action, outcome: "ok" });
        ctx.send(ctx.socket, { type: "debugAppResult", commandId: command.id, requestId: outcome.requestId, result: outcome.result });
      } catch (error) {
        recordDaemonTrace("debug.app.request.completed", {
          commandId: command.id,
          target: command.action,
          outcome: error instanceof DebugControlError ? error.code : "failed",
        });
        throw error;
      }
    },
    completeDebugApp: (command) => ctx.debugControl.complete(ctx.socket, command),
    publishDebugTrace: (command) => {
      // Only the app that registered `debugControl` may add records; otherwise any
      // authenticated socket could forge app-side transitions into the ring.
      if (!ctx.hasCapability(ctx.socket, "debugControl")) {
        throw new DebugControlError("DEBUG_TRACE_PUBLISH_FORBIDDEN", "Publishing debug trace records requires the Picky app debug control connection");
      }
      const receivedAt = new Date().toISOString();
      for (const record of command.records) ctx.traceRing.record(record, receivedAt);
      logAgentd("debug trace published", { records: command.records.length, size: ctx.traceRing.size });
    },
    readDebugTrace: (command) => {
      const page = ctx.traceRing.read({
        ...(command.afterSequence !== undefined ? { afterSequence: command.afterSequence } : {}),
        ...(command.limit !== undefined ? { limit: command.limit } : {}),
      });
      ctx.send(ctx.socket, {
        type: "debugTrace",
        commandId: command.id,
        instanceId: page.instanceId,
        oldestSequence: page.oldestSequence,
        nextSequence: page.nextSequence,
        truncated: page.truncated,
        records: page.records,
      });
    },
  };
}
