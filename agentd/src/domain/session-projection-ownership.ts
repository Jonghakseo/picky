import transientManifest from "../../../contracts/projection/session-transient-ownership.json" with { type: "json" };
import { z } from "zod";
import { sessionFieldSpecs, type SessionField, type SessionFieldSpec } from "../protocol-session-fields.js";

const sessionTransientOwnershipSchema = z.object({
  id: z.string().min(1),
  owner: z.string().min(1),
  serializer: z.string().min(1),
  terminalSnapshotSource: z.string().min(1),
  postCommitRule: z.string().min(1),
  saveFailureRule: z.literal("rollback: untouched"),
}).strict();

/** One row of `contracts/projection/session-field-ownership.json`, which is generated from the field table. */
export type SessionFieldOwnership = { readonly field: SessionField } & Omit<SessionFieldSpec, "metaPatch">;
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

export function parseSessionTransientOwnership(text: string): readonly SessionTransientOwnership[] {
  return rejectDuplicateValues(sessionTransientOwnershipSchema.array().parse(JSON.parse(text)), "id", "session transient ownership");
}

export const persistedSessionFieldOwnership: readonly SessionFieldOwnership[] = (Object.keys(sessionFieldSpecs) as SessionField[])
  .map((field) => {
    const { metaPatch: _metaPatch, ...ownership } = sessionFieldSpecs[field] as SessionFieldSpec;
    return { field, ...ownership };
  });

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
  "AsyncTaskHostBridge.providers",
  "AsyncTaskModelFence.cycle",
  "SubagentInvocationTracker.trackedInvocations",
] as const;

export function mutationNames(entry: SessionFieldOwnership): readonly string[] {
  return typeof entry.v2Mutation === "string" ? [entry.v2Mutation] : entry.v2Mutation;
}
