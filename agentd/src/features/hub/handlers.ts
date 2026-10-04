import type { WebSocket } from "ws";
import { logAgentd } from "../../local-log.js";
import type { CommandHandlersFor, EventPayload } from "../slice-contract.js";
import type { HubStatisticsBroker } from "./hub-statistics-broker.js";
import type { PickyMcpScope } from "./schema.js";

export type HubCommandType =
  | "listMcpServers"
  | "addMcpServer"
  | "updateMcpServer"
  | "removeMcpServer"
  | "signInMcpServer"
  | "signOutMcpServer"
  | "getHubStatistics"
  | "resetHubStatistics"
  | "configureHubStatistics";

export type McpServerOperation = "add" | "update" | "remove" | "signIn" | "signOut";
export type McpServerOperationErrorCode = "duplicate" | "invalid" | "notFound";

export interface McpServerListing {
  configPath: string;
  servers: readonly {
    name: string;
    pickyScope: PickyMcpScope;
    enabled: boolean;
    exposure: string;
    transport: string;
    state: "disabled" | "connecting" | "connected" | "disconnected" | "needs-auth" | "failed" | "closed";
    tools: string[];
    error?: string;
    usesOAuth: boolean;
  }[];
  configErrors: string[];
}

/**
 * Pi's global `mcp.json` administration. Implemented by
 * `runtime/mcp-server-admin.ts`, which owns the Pi SDK MCP internals.
 */
export interface McpServerAdminPort {
  list(): Promise<McpServerListing>;
  add(name: string, configJson: string, pickyScope: PickyMcpScope): Promise<void>;
  update(name: string, patch: { enabled?: boolean; pickyScope?: PickyMcpScope }): Promise<void>;
  remove(name: string): Promise<void>;
  signIn(name: string): Promise<void>;
  signOut(name: string): Promise<void>;
  /** The wire error code for a failure this adapter raised, when it has one. */
  operationErrorCode(error: unknown): McpServerOperationErrorCode | undefined;
}

export interface HubFeatureContext {
  socket: WebSocket;
  mcpServers: McpServerAdminPort;
  statistics: Pick<HubStatisticsBroker, "sendSnapshot" | "configure">;
  send: (socket: WebSocket, event: EventPayload) => void;
}

export function hubCommandHandlers(ctx: HubFeatureContext): CommandHandlersFor<HubCommandType> {
  const runMcpOperation = async (requestId: string, operation: McpServerOperation, name: string, run: () => Promise<void>) => {
    try {
      await run();
      ctx.send(ctx.socket, { type: "mcpServerOperationCompleted", requestId, operation, name, ok: true });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logAgentd("mcp server operation failed", { operation, name, error: message });
      const errorCode = ctx.mcpServers.operationErrorCode(error);
      ctx.send(ctx.socket, {
        type: "mcpServerOperationCompleted", requestId, operation, name, ok: false, errorMessage: message,
        ...(errorCode ? { errorCode } : {}),
      });
    }
  };

  return {
    listMcpServers: async (command) => {
      try {
        const listing = await ctx.mcpServers.list();
        ctx.send(ctx.socket, { type: "mcpServerList", commandId: command.id, ok: true, ...listing, servers: [...listing.servers] });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logAgentd("mcp server list failed", { error: message });
        ctx.send(ctx.socket, { type: "mcpServerList", commandId: command.id, ok: false, servers: [], configErrors: [], errorMessage: message });
      }
    },
    addMcpServer: (command) => runMcpOperation(command.id, "add", command.name, () => ctx.mcpServers.add(command.name, command.configJson, command.pickyScope)),
    updateMcpServer: (command) => runMcpOperation(command.id, "update", command.name, () => ctx.mcpServers.update(command.name, {
      ...(command.enabled === undefined ? {} : { enabled: command.enabled }),
      ...(command.pickyScope === undefined ? {} : { pickyScope: command.pickyScope }),
    })),
    removeMcpServer: (command) => runMcpOperation(command.id, "remove", command.name, () => ctx.mcpServers.remove(command.name)),
    signInMcpServer: (command) => runMcpOperation(command.id, "signIn", command.name, () => ctx.mcpServers.signIn(command.name)),
    signOutMcpServer: (command) => runMcpOperation(command.id, "signOut", command.name, () => ctx.mcpServers.signOut(command.name)),
    getHubStatistics: (command) => ctx.statistics.sendSnapshot(ctx.socket, command.id, false),
    resetHubStatistics: (command) => ctx.statistics.sendSnapshot(ctx.socket, command.id, true),
    configureHubStatistics: (command) => ctx.statistics.configure(ctx.socket, command.id, command.classificationEnabled),
  };
}
