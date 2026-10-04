import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema } from "../../protocol-base.js";

/**
 * Picky settings control: the CLI and the main agent read/write the app's
 * `settings.json` through the connected Picky app, which owns that file.
 * `protocol.ts` spreads these into the wire unions, so the message names and
 * fields are unchanged by living here.
 */
export const settingsCommandSchemas = [
  CommandBaseSchema.extend({ type: z.literal("listPickySettings") }),
  CommandBaseSchema.extend({ type: z.literal("getPickySettings"), key: z.string().min(1) }),
  CommandBaseSchema.extend({
    type: z.literal("setPickySettings"),
    key: z.string().min(1),
    value: z.any().refine((value) => value !== undefined, "value is required"),
    toggle: z.boolean().optional(),
    displayId: z.string().min(1).optional(),
  }),
  CommandBaseSchema.extend({
    type: z.literal("completePickySettingsRequest"),
    requestId: z.string().min(1),
    result: z.unknown().optional(),
    errorCode: z.string().min(1).optional(),
    errorMessage: z.string().min(1).optional(),
  }),
] as const;

export const settingsEventSchemas = [
  EventBaseSchema.extend({
    type: z.literal("pickySettingsRequested"),
    requestId: z.string().min(1),
    action: z.enum(["list", "get", "set"]),
    key: z.string().min(1).optional(),
    value: z.any().optional(),
    toggle: z.boolean().optional(),
    displayId: z.string().min(1).optional(),
    caller: z.literal("mainAgent").optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("pickySettingsAck"),
    commandId: z.string().min(1),
    result: z.unknown().refine((value) => value !== undefined, "result is required"),
  }),
] as const;
