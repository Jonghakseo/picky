import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema, isoTimestamp, ThinkingLevelSchema } from "../../protocol-base.js";

/**
 * Wire shape of the main Picky agent's Tasks and Pickle delegation decisions.
 *
 * A Task belongs to the main conversation and runs in a Picky-owned worker; a delegation decision is
 * the user's answer to "hand this to a Pickle?". `pending` means the user has not decided: nothing
 * runs until they pick Pickle or Task, and closing the form keeps it pending.
 */
export const MainTaskStatusSchema = z.enum([
  "queued",
  "evaluating",
  "running",
  "waiting",
  "stopping",
  "completed",
  "failed",
  "blocked",
  "cancelled",
  "interrupted",
]);

export const MainTaskReportSchema = z.object({
  status: z.enum(["success", "failed", "blocked"]),
  summary: z.string(),
  artifacts: z.array(z.string()),
  verification: z.array(z.string()),
  blockers: z.array(z.string()),
  escalation: z.literal("production_code").optional(),
}).strict();

export const MainTaskTierSchema = z.enum(["fast", "balanced", "powerful"]);

/** The model and thinking level a Task revision runs with. */
export const MainTaskModelSelectionSchema = z.object({
  provider: z.string().min(1),
  model: z.string().min(1),
  thinking: ThinkingLevelSchema,
}).strict();

export const MainTaskSchema = z.object({
  id: z.string().min(1),
  revision: z.number().int().positive(),
  title: z.string(),
  status: MainTaskStatusSchema,
  cwd: z.string(),
  readonly: z.boolean(),
  instructions: z.array(z.string()).min(1),
  createdAt: isoTimestamp,
  updatedAt: isoTimestamp,
  revisionStartedAt: isoTimestamp.optional(),
  tier: MainTaskTierSchema.optional(),
  /** Chosen with the tier when the revision starts; absent while it is still being chosen. */
  selection: MainTaskModelSelectionSchema.optional(),
  report: MainTaskReportSchema.optional(),
  error: z.string().optional(),
  /** Set on `cancelled`: whether the worker process was confirmed to have exited. */
  cleanup: z.enum(["confirmed", "uncertain"]).optional(),
  /** The declined delegation decision this Task runs for, when the user chose Task over Pickle. */
  decisionId: z.string().optional(),
  /** The Pickle that took this Task over. The Task's own result stays as it was. */
  handoff: z.object({ decisionId: z.string(), pickleSessionId: z.string().optional() }).strict().optional(),
  canStop: z.boolean(),
  canResume: z.boolean(),
}).strict();

export const MainDelegationPickleSchema = z.object({
  state: z.enum(["creating", "created", "failed"]),
  sessionId: z.string().optional(),
  error: z.string().optional(),
}).strict();

export const MainDelegationDecisionSchema = z.object({
  id: z.string().min(1),
  state: z.enum(["pending", "pickle", "task", "cancelled"]),
  title: z.string(),
  instructions: z.string(),
  cwd: z.string().optional(),
  /** The question the main agent asked, in the user's language. */
  question: z.string().optional(),
  createdAt: isoTimestamp,
  updatedAt: isoTimestamp,
  /** The Task whose scope grew into production code work, for a Task-to-Pickle handoff. */
  fromTaskId: z.string().optional(),
  /** The Task that runs this scope after the user chose Task. */
  taskId: z.string().optional(),
  pickle: MainDelegationPickleSchema.optional(),
}).strict();

export const MainTasksSnapshotSchema = z.object({
  tasks: z.array(MainTaskSchema),
  decisions: z.array(MainDelegationDecisionSchema),
}).strict();

/**
 * The user's choice for one tier in Picky's settings. An absent field follows the automatic preset,
 * so `{}` and a missing tier both mean automatic.
 */
export const MainTaskModelPresetSchema = z.object({
  model: z.object({ provider: z.string().min(1), id: z.string().min(1) }).strict().optional(),
  thinking: ThinkingLevelSchema.optional(),
}).strict();

export const MainTaskModelPresetsSchema = z.object({
  fast: MainTaskModelPresetSchema.optional(),
  balanced: MainTaskModelPresetSchema.optional(),
  powerful: MainTaskModelPresetSchema.optional(),
}).strict();

/** What each tier uses on automatic. Follows the main model's provider. */
export const MainTaskAutomaticModelsSchema = z.object({
  fast: MainTaskModelSelectionSchema,
  balanced: MainTaskModelSelectionSchema,
  powerful: MainTaskModelSelectionSchema,
}).strict();

export type MainTaskStatus = z.infer<typeof MainTaskStatusSchema>;
export type MainTaskModelPresets = z.infer<typeof MainTaskModelPresetsSchema>;
export type MainTaskAutomaticModels = z.infer<typeof MainTaskAutomaticModelsSchema>;
export type MainTask = z.infer<typeof MainTaskSchema>;
export type MainDelegationDecision = z.infer<typeof MainDelegationDecisionSchema>;
export type MainTasksSnapshot = z.infer<typeof MainTasksSnapshotSchema>;

export const mainTasksCommandSchemas = [
  /** User control from the app or a paired device. `resume` continues the same child session. */
  CommandBaseSchema.extend({ type: z.literal("controlMainTask"), taskId: z.string().min(1), action: z.enum(["stop", "resume"]) }),
  /** A user's answer to a delegation decision, typically for one left pending. */
  CommandBaseSchema.extend({ type: z.literal("resolveMainDelegation"), decisionId: z.string().min(1), choice: z.enum(["pickle", "task", "cancel"]) }),
  /** The app's saved per-tier choices. Sent on connect and after every settings save; replaces the previous set. */
  CommandBaseSchema.extend({ type: z.literal("setMainTaskModelPresets"), taskModelPresets: MainTaskModelPresetsSchema }),
  /** Asks what automatic means right now, for the settings screen. Answered with `mainTaskModelPresets`. */
  CommandBaseSchema.extend({ type: z.literal("getMainTaskModelPresets") }),
] as const;

export const mainTasksEventSchemas = [
  EventBaseSchema.extend({ type: z.literal("mainTasksUpdated"), ...MainTasksSnapshotSchema.shape }),
  /** `automatic` is absent until the main agent has started, or on a daemon that runs no Tasks. */
  EventBaseSchema.extend({
    type: z.literal("mainTaskModelPresets"),
    commandId: z.string(),
    automatic: MainTaskAutomaticModelsSchema.optional(),
  }),
] as const;
