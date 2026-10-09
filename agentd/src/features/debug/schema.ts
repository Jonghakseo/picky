import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema, isoTimestamp } from "../../protocol-base.js";

/**
 * Picky debug instrumentation: a bounded, metadata-only view of how an input
 * travels through Picky, plus a narrow app-control surface for reproducing one.
 *
 * Two deliberate limits keep this safe to leave always on:
 *
 * - Trace records carry an allowlisted set of correlation ids and short labels.
 *   `.strict()` rejects any extra field, so a future "details" blob cannot be
 *   smuggled in; user text, tool arguments, paths, and tokens never appear.
 *   The only size signal is `textLength`.
 * - `debugApp` drives the app through its production input paths (text entry,
 *   push-to-talk) rather than setting state directly. The app answers with
 *   `completeDebugApp`; a snapshot is read-only.
 *
 * `protocol.ts` spreads these into the wire unions, so the message names and
 * fields are unchanged by living here.
 */

/** Each app action maps to one production entry point the app already owns. */
export const DebugAppActionSchema = z.enum(["snapshot", "text", "pttPress", "pttRelease"]);
export type DebugAppAction = z.infer<typeof DebugAppActionSchema>;

/** Matches the composer's practical ceiling; longer input is a CLI mistake, not a debug case. */
export const DEBUG_APP_TEXT_MAX_LENGTH = 32_000;
/** One publish carries at most this many records so a burst cannot block the event loop. */
export const DEBUG_TRACE_PUBLISH_MAX_RECORDS = 100;
export const DEBUG_TRACE_READ_MAX_LIMIT = 500;
export const DEBUG_TRACE_READ_DEFAULT_LIMIT = 200;
/** Correlation ids are app/daemon generated; the bound only stops an unbounded wire value. */
export const DEBUG_TRACE_ID_MAX_LENGTH = 160;
/** Labels are enum-like transition names, not sentences. */
export const DEBUG_TRACE_LABEL_MAX_LENGTH = 96;

const TraceId = z.string().min(1).max(DEBUG_TRACE_ID_MAX_LENGTH);
const TraceLabel = z.string().min(1).max(DEBUG_TRACE_LABEL_MAX_LENGTH);

/**
 * One semantic transition. `timestamp`/`monotonicMs` are the *source* process
 * clocks: the app and the daemon are separate processes, so their monotonic
 * values are not comparable to each other. Cross-process ordering comes from
 * the daemon's `sequence`/`receivedAt` stamped on arrival.
 */
export const DebugTraceRecordSchema = z.object({
  source: z.enum(["app", "daemon"]),
  name: TraceLabel,
  timestamp: isoTimestamp,
  monotonicMs: z.number().finite().nonnegative(),
  inputId: TraceId.optional(),
  contextId: TraceId.optional(),
  sessionId: TraceId.optional(),
  commandId: TraceId.optional(),
  state: TraceLabel.optional(),
  previousState: TraceLabel.optional(),
  outcome: TraceLabel.optional(),
  event: TraceLabel.optional(),
  target: TraceLabel.optional(),
  modality: z.enum(["audio", "text"]).optional(),
  textLength: z.number().int().nonnegative().optional(),
}).strict();
export type DebugTraceRecord = z.infer<typeof DebugTraceRecordSchema>;

/** A record as retained by the daemon ring: source clocks plus daemon receipt order. */
export const StoredDebugTraceRecordSchema = DebugTraceRecordSchema.extend({
  sequence: z.number().int().positive(),
  receivedAt: isoTimestamp,
});
export type StoredDebugTraceRecord = z.infer<typeof StoredDebugTraceRecordSchema>;

/** The daemon stamps `source: "daemon"` itself, so a client can only publish app records. */
const PublishedDebugTraceRecordSchema = DebugTraceRecordSchema.extend({ source: z.literal("app") });

export const debugCommandSchemas = [
  CommandBaseSchema.extend({
    type: z.literal("debugApp"),
    action: DebugAppActionSchema,
    text: z.string().min(1).max(DEBUG_APP_TEXT_MAX_LENGTH).optional(),
  }),
  CommandBaseSchema.extend({
    type: z.literal("completeDebugApp"),
    requestId: z.string().min(1),
    result: z.record(z.string(), z.unknown()).optional(),
    errorCode: z.string().min(1).optional(),
    errorMessage: z.string().min(1).optional(),
  }),
  CommandBaseSchema.extend({
    type: z.literal("publishDebugTrace"),
    records: z.array(PublishedDebugTraceRecordSchema).min(1).max(DEBUG_TRACE_PUBLISH_MAX_RECORDS),
  }),
  CommandBaseSchema.extend({
    type: z.literal("readDebugTrace"),
    afterSequence: z.number().int().nonnegative().optional(),
    limit: z.number().int().min(1).max(DEBUG_TRACE_READ_MAX_LIMIT).optional(),
  }),
] as const;

/**
 * Cross-field rules for `debugApp`. The wire union is a discriminated union, so a
 * per-member refinement is not expressible there; `protocol.ts` calls this from
 * the envelope-level `superRefine` and the rule still lives with its slice.
 */
export function refineDebugCommand(
  command: { type: string; action?: string; text?: string },
  context: { addIssue: (issue: { code: "custom"; path: (string | number)[]; message: string }) => void },
): void {
  if (command.type !== "debugApp") return;
  const hasText = (command.text ?? "").trim().length > 0;
  if (command.action === "text" && !hasText) {
    context.addIssue({ code: "custom", path: ["text"], message: "debugApp text action requires non-blank text" });
  }
  if (command.action !== "text" && command.text !== undefined) {
    context.addIssue({ code: "custom", path: ["text"], message: "debugApp text is only valid for the text action" });
  }
}

export const debugEventSchemas = [
  EventBaseSchema.extend({
    type: z.literal("debugAppRequested"),
    requestId: z.string().min(1),
    /** The originating `debugApp` command id: the correlation root for everything this input causes. */
    commandId: z.string().min(1),
    action: DebugAppActionSchema,
    text: z.string().min(1).max(DEBUG_APP_TEXT_MAX_LENGTH).optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("debugAppResult"),
    commandId: z.string().min(1),
    requestId: z.string().min(1),
    result: z.record(z.string(), z.unknown()),
  }),
  EventBaseSchema.extend({
    type: z.literal("debugTrace"),
    commandId: z.string().min(1),
    /** Changes on daemon restart; a reader that sees a new value must reset its cursor. */
    instanceId: z.string().min(1),
    /** Lowest sequence still retained, or 0 when nothing has been recorded. */
    oldestSequence: z.number().int().nonnegative(),
    /** Last returned sequence, or the current latest when this page is empty. Feed back as `afterSequence`. */
    nextSequence: z.number().int().nonnegative(),
    /** The requested cursor predates evicted records: some transitions are permanently gone. */
    truncated: z.boolean(),
    records: z.array(StoredDebugTraceRecordSchema),
  }),
] as const;
