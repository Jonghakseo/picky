import persistedManifest from "../../../contracts/projection/session-field-ownership.json" with { type: "json" };
import transientManifest from "../../../contracts/projection/session-transient-ownership.json" with { type: "json" };
import { z } from "zod";

const snapshotSemanticsSchema = z.enum(["replace", "merge", "clear-if-omitted-explicit"]);
const p0OmissionBehaviorSchema = z.enum(["never-omitted", "omitted-empty"]);
const mutationSchema = z.union([z.string().min(1), z.array(z.string().min(1)).min(1)]);

const sessionFieldOwnershipSchema = z.object({
  field: z.string().min(1),
  persistenceOwner: z.string().min(1),
  v1Event: z.string().min(1),
  v2Mutation: mutationSchema,
  swiftStore: z.string().min(1),
  snapshotSemantics: snapshotSemanticsSchema,
  p0OmissionBehavior: p0OmissionBehaviorSchema,
  consumers: z.array(z.string().min(1)).min(1),
}).strict();

const sessionTransientOwnershipSchema = z.object({
  id: z.string().min(1),
  owner: z.string().min(1),
  serializer: z.string().min(1),
  terminalSnapshotSource: z.string().min(1),
  postCommitRule: z.string().min(1),
  saveFailureRule: z.literal("rollback: untouched"),
}).strict();

export type SessionFieldOwnership = z.infer<typeof sessionFieldOwnershipSchema>;
export type SessionTransientOwnership = z.infer<typeof sessionTransientOwnershipSchema>;

function rejectDuplicateValues<T, K extends keyof T>(entries: readonly T[], property: K, label: string): readonly T[] {
  const seen = new Set<string>();
  for (const entry of entries) {
    const value = entry[property];
    if (typeof value !== "string") throw new Error(`${label} key ${String(property)} must be a string`);
    if (seen.has(value)) throw new Error(`Duplicate ${label}: ${value}`);
    seen.add(value);
  }
  return entries;
}

export function parseSessionFieldOwnership(text: string): readonly SessionFieldOwnership[] {
  return rejectDuplicateValues(sessionFieldOwnershipSchema.array().parse(JSON.parse(text)), "field", "session field ownership");
}

export function parseSessionTransientOwnership(text: string): readonly SessionTransientOwnership[] {
  return rejectDuplicateValues(sessionTransientOwnershipSchema.array().parse(JSON.parse(text)), "id", "session transient ownership");
}

export const persistedSessionFieldOwnership = parseSessionFieldOwnership(JSON.stringify(persistedManifest));

export const transientSessionOwnership = parseSessionTransientOwnership(JSON.stringify(transientManifest));

export const requiredTransientOwnershipIds = [
  "SessionMessageBuilder.states",
  "SessionMessageBuilder.operationChains",
  "RuntimeEventHandler.assistantDrafts",
  "RuntimeEventHandler.thinkingDrafts",
  "RuntimeEventHandler.thinkingActive",
  "RuntimeEventHandler.pendingThinkingFlushes",
  "RuntimeEventHandler.processedTerminalRuns",
  "RuntimeEventHandler.seenToolCallIds",
  "RuntimeEventHandler.manualTerminalCompactionStatuses",
  "SessionSupervisor.patchChains",
  "SessionSupervisor.emitChains",
  "SessionSupervisor.sessionSeq",
  "SessionSupervisor.pickleCompletionNotified",
  "SessionSupervisor.pickleCompletionInFlight",
  "SessionSupervisor.pendingPickleCompletions",
] as const;

export function mutationNames(entry: SessionFieldOwnership): readonly string[] {
  return Array.isArray(entry.v2Mutation) ? entry.v2Mutation : [entry.v2Mutation];
}
