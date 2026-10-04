import { z } from "zod";

/**
 * Wire envelope primitives shared by `protocol.ts` and every `features/<slice>/schema.ts`.
 *
 * Slice schemas extend `CommandBaseSchema`/`EventBaseSchema`, and `protocol.ts`
 * composes the slice schemas back into the single wire union. That composition
 * would be a module cycle if the bases lived in `protocol.ts`, so they live here
 * instead; `protocol.ts` re-exports `PROTOCOL_VERSION` for existing importers.
 */
export const PROTOCOL_VERSION = "2026-08-25";

export const isoTimestamp = z.string().datetime({ offset: true });

export const CommandBaseSchema = z.object({
  id: z.string(),
  protocolVersion: z.literal(PROTOCOL_VERSION),
  caller: z.literal("mainAgent").optional(),
});

export const EventBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION), timestamp: isoTimestamp });
