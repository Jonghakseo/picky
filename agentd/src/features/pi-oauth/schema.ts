import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema } from "../../protocol-base.js";

export const PiOAuthProviderIdSchema = z.enum(["openai-codex", "anthropic"]);
export type PiOAuthProviderId = z.infer<typeof PiOAuthProviderIdSchema>;
export const PiOAuthPromptTypeSchema = z.enum(["text", "secret", "select", "manual_code"]);
export type PiOAuthPromptType = z.infer<typeof PiOAuthPromptTypeSchema>;
export const PiOAuthPromptOptionSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  description: z.string().optional(),
});
export type PiOAuthPromptOption = z.infer<typeof PiOAuthPromptOptionSchema>;

/**
 * Provider sign-in for the Hub. Primary-only: a child daemon has no OAuth
 * coordinator and rejects these commands. `reloadPiAuthentication` is the one
 * command with a session-wide effect; it refreshes credentials on live runtime
 * handles through a narrow supervisor port (see handlers.ts).
 */
export const piOAuthCommandSchemas = [
  CommandBaseSchema.extend({ type: z.literal("getPiOAuthStatus"), providerId: PiOAuthProviderIdSchema }),
  CommandBaseSchema.extend({ type: z.literal("signInPiOAuth"), providerId: PiOAuthProviderIdSchema }),
  CommandBaseSchema.extend({ type: z.literal("signOutPiOAuth"), providerId: PiOAuthProviderIdSchema }),
  CommandBaseSchema.extend({
    type: z.literal("answerPiOAuthPrompt"),
    requestId: z.string().min(1),
    promptId: z.string().min(1),
    value: z.string().optional(),
    cancelled: z.boolean().optional(),
  }),
  CommandBaseSchema.extend({ type: z.literal("cancelPiOAuth"), requestId: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("reloadPiAuthentication") }),
] as const;

export const piOAuthEventSchemas = [
  EventBaseSchema.extend({
    type: z.literal("piOAuthStatus"),
    requestId: z.string().min(1),
    providerId: PiOAuthProviderIdSchema,
    configured: z.boolean(),
    source: z.string().optional(),
    label: z.string().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("piOAuthUrlRequested"),
    requestId: z.string().min(1),
    providerId: PiOAuthProviderIdSchema,
    url: z.string().url(),
    instructions: z.string().optional(),
    userCode: z.string().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("piOAuthPromptRequested"),
    requestId: z.string().min(1),
    providerId: PiOAuthProviderIdSchema,
    promptId: z.string().min(1),
    promptType: PiOAuthPromptTypeSchema,
    message: z.string().min(1),
    placeholder: z.string().optional(),
    options: z.array(PiOAuthPromptOptionSchema).optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("piAuthenticationReloaded"),
    requestId: z.string().min(1),
    reloadedHandleCount: z.number().int().nonnegative(),
  }),
] as const;
