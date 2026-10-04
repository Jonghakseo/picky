import { z } from "zod";

export const ASYNC_TASK_CONTRACT = "pi.async-tasks.v1";
const id = z.string().min(1).max(256);
const revision = z.number().int().nonnegative().safe();
const timestamp = z.string().datetime({ offset: true });
const boundedText = z.string().max(4_096);

export const AsyncTaskOwnerSchema = z.object({
  sessionId: id, piSessionId: id, runtimeInstanceId: id, providerId: id, providerInstanceId: id,
}).strict();
export const ExecutionStateSchema = z.enum(["queued", "running", "cancelling", "succeeded", "failed", "cancelled", "interrupted"]);
export const ExecutionPresenceSchema = z.enum(["active", "settled", "unknown"]);
export const CompletionStateSchema = z.enum(["pending", "submitted", "observed", "processing", "handled", "suppressed", "failed", "unknown"]);
export const RegistrationStateSchema = z.enum(["reserved", "approved", "starting", "spawned", "abandoned"]);
export const AdmissionStateSchema = z.enum(["open", "closing", "closed"]);
export const AsyncOperationOutcomeSchema = z.enum(["accepted", "settled", "rejected", "unsupported", "stale", "blocked_delivery", "blocked_cleanup"]);

export const AgentCycleSchema = z.object({
  cycleId: id, runtimeInstanceId: id,
  phase: z.enum(["idle", "responding", "compacting", "settled"]),
  outcome: z.enum(["completed", "failed", "cancelled"]).optional(),
  controlGeneration: revision,
}).strict();
export const AsyncWorkSummarySchema = z.object({
  tracking: z.enum(["ready", "reconciling", "unsupported"]),
  activeRootCount: revision, pendingCompletionCount: revision, uncertainExecutionCount: revision,
  attentionCount: revision, workRevision: revision, canReleaseRuntime: z.boolean(),
  episode: z.object({
    id, settled: z.boolean(), finalizedCycleId: id.optional(),
    outcome: z.enum(["completed", "failed", "cancelled"]).optional(),
  }).strict().refine((episode) => !episode.settled || !!episode.finalizedCycleId && !!episode.outcome, "Settled episode requires its finalized response").optional(),
}).strict();

// Kind is deliberately open; future providers retain their opaque bounded details.
export const AsyncTaskSchema = AsyncTaskOwnerSchema.extend({
  taskId: id, rootTaskId: id, parentTaskId: id.optional(), invocationId: id.optional(),
  kind: id, title: z.string().min(1).max(500), progress: boundedText.optional(),
  execution: ExecutionStateSchema, presence: ExecutionPresenceSchema,
  registration: RegistrationStateSchema, grantId: id.optional(),
  providerRevision: revision, controlGeneration: revision,
  createdAt: timestamp, updatedAt: timestamp,
  details: z.record(z.string(), z.unknown()).refine((value) => {
    try { return Buffer.byteLength(JSON.stringify(value), "utf8") <= 16_384; } catch { return false; }
  }, "Task details exceed 16384 bytes").optional(),
}).strict();
export const CompletionTicketSchema = AsyncTaskOwnerSchema.extend({
  completionId: id, rootTaskId: id, target: z.enum(["model", "human"]),
  state: CompletionStateSchema, controlGeneration: revision,
  deliveryId: id.optional(), cycleId: id.optional(), failureReason: boundedText.optional(),
}).strict().superRefine((ticket, ctx) => {
  if ((ticket.state === "processing" || ticket.state === "handled") && !ticket.cycleId) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Processing/handled tickets require a cycleId" });
  }
});

export const AsyncTaskDetailSchema = z.object({
  tasks: z.array(AsyncTaskSchema), tickets: z.array(CompletionTicketSchema),
}).strict().superRefine((value, ctx) => {
  const tasks = new Map<string, z.infer<typeof AsyncTaskSchema>>();
  const key = (task: z.infer<typeof AsyncTaskOwnerSchema>, taskId: string) =>
    JSON.stringify([task.sessionId, task.piSessionId, task.runtimeInstanceId, task.providerId, task.providerInstanceId, taskId]);
  for (const task of value.tasks) {
    const identity = key(task, task.taskId);
    if (tasks.has(identity)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Duplicate task identity" });
    tasks.set(identity, task);
  }
  for (const task of value.tasks) {
    const root = tasks.get(key(task, task.rootTaskId));
    if (!root || root.taskId !== root.rootTaskId || (task.parentTaskId && !tasks.has(key(task, task.parentTaskId)))) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Task requires a root and parent in the same owner" });
    }
  }
  const tickets = new Set<string>();
  for (const ticket of value.tickets) {
    const identity = key(ticket, ticket.completionId);
    if (tickets.has(identity)) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Duplicate completion identity" });
    tickets.add(identity);
    const root = tasks.get(key(ticket, ticket.rootTaskId));
    if (!root || root.taskId !== root.rootTaskId) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Completion requires a root in the same owner" });
  }
});

export const ReleaseApprovalSchema = z.object({
  operationId: id, releaseToken: id, sessionId: id, daemonInstanceId: id, runtimeInstanceId: id,
  childGeneration: revision, archiveIntentId: id, workRevision: revision, controlGeneration: revision,
}).strict();
export const AsyncControlOperationSchema = z.object({
  requestId: id, operationId: id, outcome: AsyncOperationOutcomeSchema,
  controlGeneration: revision, reason: boundedText.optional(),
}).strict();
export const AsyncControlStateSchema = z.object({
  controlGeneration: revision, admissionState: AdmissionStateSchema,
  operations: z.array(AsyncControlOperationSchema), releasePrepared: ReleaseApprovalSchema.optional(),
}).strict();

const messageBase = AsyncTaskOwnerSchema.extend({
  contract: z.literal(ASYNC_TASK_CONTRACT), requestId: id, providerRevision: revision, controlGeneration: revision,
});
const capabilities = z.object({ registration: z.boolean(), snapshot: z.boolean(), cancel: z.boolean(), detail: z.boolean(), closeAdmission: z.boolean(), suppressDelivery: z.boolean() }).strict();
export const AsyncTaskHostMessageSchema = z.discriminatedUnion("type", [
  // Discovery has no host identity yet. Null is explicit, not a wildcard accepted
  // on any lifecycle message; the host-state reply binds the session/runtime.
  messageBase.extend({ type: z.literal("host-query"), sessionId: id.nullable(), runtimeInstanceId: id.nullable() }),
  messageBase.extend({ type: z.literal("host-state"), supported: z.boolean(), admissionState: AdmissionStateSchema, capabilities }),
  messageBase.extend({ type: z.literal("provider-ready"), providerVersion: id, contractVersion: z.literal(1), snapshotReady: z.boolean(), capabilities }),
  messageBase.extend({ type: z.literal("task-register"), task: AsyncTaskSchema }),
  messageBase.extend({ type: z.literal("task-register-result"), taskId: id, registration: RegistrationStateSchema, grantId: id.optional(), outcome: AsyncOperationOutcomeSchema }),
  messageBase.extend({ type: z.literal("registration-query"), taskId: id }),
  messageBase.extend({ type: z.literal("registration-abandon"), taskId: id, neverSpawned: z.literal(true) }),
  messageBase.extend({ type: z.literal("task-update"), detail: AsyncTaskDetailSchema }),
  messageBase.extend({ type: z.literal("snapshot-request") }),
  messageBase.extend({ type: z.literal("snapshot"), watermark: revision, detail: AsyncTaskDetailSchema }),
  messageBase.extend({ type: z.literal("control-request"), action: z.enum(["cancel", "detail", "closeAdmission", "suppressDelivery"]), taskId: id.optional(), deliveryIds: z.array(id) }),
  messageBase.extend({ type: z.literal("control-result"), outcome: AsyncOperationOutcomeSchema, admissionClosed: z.boolean(), submittedDeliveryIds: z.array(id), reason: boundedText.optional(), detail: boundedText.optional() }),
  messageBase.extend({ type: z.literal("completion-observed"), deliveryId: id, completionIds: z.array(id).min(1) }),
]).superRefine((message, ctx) => {
  const children = "detail" in message && typeof message.detail === "object"
    ? [...message.detail.tasks, ...message.detail.tickets] : "task" in message ? [message.task] : [];
  for (const child of children) {
    if (["sessionId", "piSessionId", "runtimeInstanceId", "providerId", "providerInstanceId"].some((field) => child[field as keyof typeof child] !== message[field as keyof typeof message])) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Message and task owner must match" });
    }
  }
});
export const AsyncCompletionDeliverySchema = AsyncTaskOwnerSchema.extend({
  deliveryId: id, completionIds: z.array(id).min(1), taskIds: z.array(id).min(1), controlGeneration: revision,
}).strict();

// The app transport wraps this fixed payload in asyncTaskCommand; provider wire is independent.
const commandBase = z.object({ requestId: id, sessionId: id, daemonInstanceId: id, runtimeInstanceId: id, workRevision: revision, controlGeneration: revision }).strict();
export const AsyncTaskCommandSchema = z.discriminatedUnion("type", [
  commandBase.extend({ type: z.literal("asyncTaskDetail"), owner: AsyncTaskOwnerSchema, taskId: id, cursor: id.optional(), limit: z.number().int().min(1).max(100) }),
  commandBase.extend({ type: z.literal("cancelAsyncTask"), owner: AsyncTaskOwnerSchema, taskId: id }),
  commandBase.extend({ type: z.literal("prepareSessionArchive"), archiveIntentId: id, requireQuiescence: z.boolean().optional() }),
  commandBase.extend({ type: z.literal("executeSessionArchive"), archiveIntentId: id, mode: z.enum(["continue", "stopThenArchive"]), preparationId: id, requireQuiescence: z.boolean().optional() }),
  commandBase.extend({ type: z.literal("prepareRuntimeRelease"), archiveIntentId: id, childGeneration: revision }),
  commandBase.extend({ type: z.literal("cancelRuntimeRelease"), releaseToken: id }),
]);
export const AsyncTaskCommandResultSchema = commandBase.extend({
  type: z.literal("asyncTaskCommandResult"), operationId: id, outcome: AsyncOperationOutcomeSchema,
  reason: boundedText.optional(), preparationId: id.optional(), releaseApproval: ReleaseApprovalSchema.optional(),
  detail: AsyncTaskDetailSchema.optional(), nextCursor: id.optional(),
}).strict();

export type AsyncTaskOwner = z.infer<typeof AsyncTaskOwnerSchema>;
export type AsyncTask = z.infer<typeof AsyncTaskSchema>;
export type CompletionTicket = z.infer<typeof CompletionTicketSchema>;
export type AgentCycle = z.infer<typeof AgentCycleSchema>;
export type AsyncWorkSummary = z.infer<typeof AsyncWorkSummarySchema>;
export type AsyncTaskDetail = z.infer<typeof AsyncTaskDetailSchema>;
export type AsyncControlState = z.infer<typeof AsyncControlStateSchema>;
export type AsyncTaskHostMessage = z.infer<typeof AsyncTaskHostMessageSchema>;
export type AsyncCompletionDelivery = z.infer<typeof AsyncCompletionDeliverySchema>;
export type AsyncTaskCommand = z.infer<typeof AsyncTaskCommandSchema>;
export type AsyncTaskCommandResult = z.infer<typeof AsyncTaskCommandResultSchema>;
export type ReleaseApproval = z.infer<typeof ReleaseApprovalSchema>;
