import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema } from "../../protocol-base.js";

/**
 * Pi package management: install/remove/update user-scope packages and report
 * the conflicts and progress the Hub shows. The operations themselves run in
 * `runtime/package-operations.ts` because they drive the Pi SDK package manager.
 */
export const packageCommandSchemas = [
  CommandBaseSchema.extend({ type: z.literal("installPackage"), source: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("setupPackage"), source: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("removePackage"), source: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("checkPackageUpdates") }),
  CommandBaseSchema.extend({ type: z.literal("inspectPackageConflicts"), sources: z.array(z.string().min(1)).max(100) }),
  CommandBaseSchema.extend({ type: z.literal("updatePackage"), source: z.string().min(1) }),
] as const;

export const packageEventSchemas = [
  EventBaseSchema.extend({
    type: z.literal("packageUpdatesAvailable"),
    commandId: z.string().min(1),
    sources: z.array(z.string().min(1)),
    /** Registry version each source would update to, when agentd could resolve it. */
    latestVersions: z.record(z.string().min(1), z.string().min(1)).optional(),
    failed: z.boolean().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("packageConflicts"),
    commandId: z.string().min(1),
    conflicts: z.array(z.object({
      source: z.string().min(1),
      kind: z.enum(["tool", "skill"]),
      name: z.string().min(1),
      ownerPath: z.string().min(1),
      removal: z.discriminatedUnion("kind", [
        z.object({ kind: z.literal("package"), source: z.string().min(1) }),
        z.object({ kind: z.literal("trash"), path: z.string().min(1) }),
        z.object({ kind: z.literal("manual") }),
      ]).optional(),
    })),
    failed: z.boolean().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("packageOperationProgress"),
    requestId: z.string().min(1),
    operation: z.enum(["install", "remove", "update"]),
    source: z.string().min(1),
    message: z.string().min(1),
  }),
  EventBaseSchema.extend({
    type: z.literal("packageOperationCompleted"),
    requestId: z.string().min(1),
    operation: z.enum(["install", "remove", "update", "setup"]),
    source: z.string().min(1),
    ok: z.boolean(),
    errorCode: z.enum(["duplicate", "held", "timeout"]).optional(),
    errorMessage: z.string().min(1).optional(),
    packageChanged: z.boolean().optional(),
  }),
] as const;
