import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema, isoTimestamp } from "../../protocol-base.js";

export const UsageLimitsProviderIdSchema = z.enum(["anthropic", "openai-codex"]);

const UsageLimitWindowSchema = z.object({
  usedPercent: z.number().min(0).max(100),
  resetsAt: isoTimestamp.nullable(),
});

const UsageLimitResetsSchema = z.object({
  available: z.number().int().nonnegative(),
  nextExpiresAt: isoTimestamp.nullable(),
});

/**
 * One subscribed provider. Signed-out and free-plan providers are omitted.
 * `checkedAt` is the last successful check; when the latest check failed,
 * `errorMessage` is set and the windows keep the last known values (or are null).
 */
export const UsageLimitsProviderSchema = z.object({
  provider: UsageLimitsProviderIdSchema,
  plan: z.string().nullable(),
  checkedAt: isoTimestamp.nullable(),
  errorMessage: z.string().nullable(),
  session: UsageLimitWindowSchema.nullable(),
  weekly: UsageLimitWindowSchema.nullable(),
  resets: UsageLimitResetsSchema.nullable(),
});
export type UsageLimitsProvider = z.infer<typeof UsageLimitsProviderSchema>;

export const UsageLimitsSnapshotSchema = z.object({
  checkedAt: isoTimestamp,
  providers: z.array(UsageLimitsProviderSchema),
});
export type UsageLimitsSnapshot = z.infer<typeof UsageLimitsSnapshotSchema>;

/**
 * Subscription plan limits for the providers Picky signs in to. Primary-only.
 * `force` bypasses the daemon's short reuse window (manual refresh).
 */
export const usageLimitsCommandSchemas = [
  CommandBaseSchema.extend({ type: z.literal("getUsageLimits"), force: z.boolean().optional() }),
] as const;

export const usageLimitsEventSchemas = [
  EventBaseSchema.extend({
    type: z.literal("usageLimitsResult"),
    commandId: z.string().min(1),
    ok: z.boolean(),
    errorMessage: z.string().nullable().optional(),
    snapshot: UsageLimitsSnapshotSchema.optional(),
  }),
] as const;
