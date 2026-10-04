import type { WebSocket } from "ws";
import type { CommandHandlersFor } from "../slice-contract.js";

export type PackageCommandType =
  | "installPackage"
  | "setupPackage"
  | "removePackage"
  | "checkPackageUpdates"
  | "inspectPackageConflicts"
  | "updatePackage";

/**
 * The package work this slice delegates. `runtime/package-operations.ts`
 * implements it; the Pi SDK package manager may not be imported outside
 * `runtime/`, so the slice depends on this port instead of that module.
 */
export interface PackageOperationsPort {
  runOperation(socket: WebSocket, requestId: string, operation: "install" | "remove" | "update", source: string): Promise<void>;
  runSetup(socket: WebSocket, requestId: string, source: string): Promise<void>;
  runUpdateCheck(socket: WebSocket, commandId: string): Promise<void>;
  runConflictInspection(socket: WebSocket, commandId: string, sources: readonly string[]): Promise<void>;
}

export interface PackageFeatureContext {
  socket: WebSocket;
  operations: PackageOperationsPort;
}

export function packageCommandHandlers(ctx: PackageFeatureContext): CommandHandlersFor<PackageCommandType> {
  return {
    installPackage: (command) => ctx.operations.runOperation(ctx.socket, command.id, "install", command.source),
    setupPackage: (command) => ctx.operations.runSetup(ctx.socket, command.id, command.source),
    removePackage: (command) => ctx.operations.runOperation(ctx.socket, command.id, "remove", command.source),
    checkPackageUpdates: (command) => ctx.operations.runUpdateCheck(ctx.socket, command.id),
    inspectPackageConflicts: (command) => ctx.operations.runConflictInspection(ctx.socket, command.id, command.sources),
    updatePackage: (command) => ctx.operations.runOperation(ctx.socket, command.id, "update", command.source),
  };
}
