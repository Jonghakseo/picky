import type { PickyAgentSessionSchema } from "./protocol.js";

/**
 * Single source of truth for how every persisted `PickyAgentSession` field
 * reaches clients. `contracts/projection/session-field-ownership.json` and the
 * Swift meta-patch decoder are generated from this table
 * (`pnpm run gen:contracts`), and the v2 `metaPatch` schema, the daemon's patch
 * diff, and the TypeScript reference reducer derive their field lists from it.
 *
 * Adding a session field therefore starts here: the `satisfies` clause rejects a
 * schema field without a row, and a `metaPatch` row must say whether `null`
 * clears it and how the Swift client applies it. `clearable` is the wire
 * contract and is deliberately independent of `snapshotSemantics`, which only
 * describes P0 snapshot omission.
 */
export type SessionField = keyof typeof PickyAgentSessionSchema.shape;

export type SessionSnapshotSemantics = "replace" | "merge" | "clear-if-omitted-explicit";
export type SessionP0OmissionBehavior = "never-omitted" | "omitted-empty" | "omitted-unavailable";

/**
 * Wire and client contract of a `metaPatch` field. `clearable` decides whether
 * `null` is accepted to clear the value (zod `nullable`, Swift `allowsClear`).
 * `swiftApply`: `metadata` assigns `PickySessionMetadata.<field>`, `custom` routes
 * through a generated protocol requirement (the owning store differs), and
 * `ignored` decodes for validation only. `swiftType` is the Swift value type.
 */
export interface MetaPatchFieldContract {
  readonly clearable: boolean;
  readonly swiftType: string;
  readonly swiftApply: "metadata" | "custom" | "ignored";
}

export interface SessionFieldSpec {
  readonly persistenceOwner: string;
  readonly v1Event: string;
  readonly v2Mutation: string | readonly string[];
  readonly swiftStore: string;
  readonly snapshotSemantics: SessionSnapshotSemantics;
  readonly p0OmissionBehavior: SessionP0OmissionBehavior;
  readonly consumers: readonly string[];
  readonly metaPatch?: MetaPatchFieldContract;
}

export const sessionFieldSpecs = {
  id: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["session-list"], metaPatch: { clearable: false, swiftType: "String", swiftApply: "ignored" } },
  revision: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "transactionEnvelope", swiftStore: "PickySessionRevisionCursor", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["session-projection-recovery"] },
  title: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["dock-icon", "conversation-header"], metaPatch: { clearable: false, swiftType: "String", swiftApply: "metadata" } },
  status: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["dock-icon", "conversation-header"], metaPatch: { clearable: false, swiftType: "PickySessionStatus", swiftApply: "metadata" } },
  cwd: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-context"], metaPatch: { clearable: true, swiftType: "String", swiftApply: "metadata" } },
  piSessionFilePath: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["terminal-overlay"], metaPatch: { clearable: true, swiftType: "String", swiftApply: "metadata" } },
  createdAt: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["session-list"], metaPatch: { clearable: false, swiftType: "Date", swiftApply: "metadata" } },
  updatedAt: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["session-list", "dock-icon"], metaPatch: { clearable: false, swiftType: "Date", swiftApply: "metadata" } },
  lastSummary: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-header"], metaPatch: { clearable: true, swiftType: "String", swiftApply: "metadata" } },
  thinkingPreview: { persistenceOwner: "runtime-event-handler", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-list"], metaPatch: { clearable: true, swiftType: "String", swiftApply: "metadata" } },
  finalAnswer: { persistenceOwner: "runtime-event-handler", v1Event: "sessionMetaUpdated", v2Mutation: "finalAnswerSet", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list", "report-viewer"] },
  logs: { persistenceOwner: "session-supervisor.appendLog", v1Event: "sessionLogAppended", v2Mutation: ["logAppend", "logsSet"], swiftStore: "PickySessionLogStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list"] },
  tools: { persistenceOwner: "runtime-event-handler", v1Event: "toolActivityUpdated", v2Mutation: ["toolUpsert", "toolsSet"], swiftStore: "PickySessionToolStore", snapshotSemantics: "merge", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list", "dock-icon"] },
  todoState: { persistenceOwner: "runtime-event-handler", v1Event: "sessionTodoStateUpdated", v2Mutation: "todoSet", swiftStore: "PickySessionTodoStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list"] },
  subagentRuns: { persistenceOwner: "session-supervisor.updateSubagentRuns", v1Event: "sessionSubagentRunsUpdated", v2Mutation: "subagentRunsSet", swiftStore: "PickySessionSubagentStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list", "dock-icon"] },
  artifacts: { persistenceOwner: "artifact-materializer", v1Event: "artifactUpdated", v2Mutation: ["artifactUpsert", "artifactsSet"], swiftStore: "PickySessionArtifactStore", snapshotSemantics: "merge", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list", "report-viewer"] },
  changedFiles: { persistenceOwner: "artifact-materializer", v1Event: "sessionMetaUpdated", v2Mutation: "changedFilesSet", swiftStore: "PickySessionArtifactStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list", "report-viewer"] },
  messages: { persistenceOwner: "session-message-builder", v1Event: "sessionMessage*", v2Mutation: ["messageAppend", "messageReplace", "messageRemove", "messagesImport"], swiftStore: "PickySessionMessageStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list"] },
  messageJournalAvailable: { persistenceOwner: "session-message-builder", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMessageStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-list"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "custom" } },
  queuedSteers: { persistenceOwner: "session-supervisor.queue", v1Event: "sessionQueueUpdated", v2Mutation: "queueSet", swiftStore: "PickySessionQueueStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list"] },
  queuedFollowUps: { persistenceOwner: "session-supervisor.queue", v1Event: "sessionQueueUpdated", v2Mutation: "queueSet", swiftStore: "PickySessionQueueStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-list"] },
  scheduledMessages: { persistenceOwner: "session-supervisor.queue", v1Event: "sessionQueueUpdated", v2Mutation: "queueSet", swiftStore: "PickySessionQueueStore", snapshotSemantics: "replace", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-composer"] },
  steeringMode: { persistenceOwner: "session-supervisor.queue", v1Event: "sessionQueueUpdated", v2Mutation: "queueSet", swiftStore: "PickySessionQueueStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["conversation-composer"] },
  followUpMode: { persistenceOwner: "session-supervisor.queue", v1Event: "sessionQueueUpdated", v2Mutation: "queueSet", swiftStore: "PickySessionQueueStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["conversation-composer"] },
  activitySummary: { persistenceOwner: "session-supervisor.activity", v1Event: "sessionActivityUpdated", v2Mutation: "activitySet", swiftStore: "PickySessionActivityStore", snapshotSemantics: "replace", p0OmissionBehavior: "never-omitted", consumers: ["dock-icon", "conversation-list"] },
  contextUsage: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-header"], metaPatch: { clearable: true, swiftType: "PickyContextUsage", swiftApply: "metadata" } },
  currentAssistantRun: { persistenceOwner: "runtime-event-handler", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-list"], metaPatch: { clearable: true, swiftType: "PickyAssistantRunMetadata", swiftApply: "metadata" } },
  pendingExtensionUiRequest: { persistenceOwner: "runtime-event-handler", v1Event: "extensionUiRequest", v2Mutation: "extensionUiRequestSet", swiftStore: "PickySessionExtensionUiStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-empty", consumers: ["conversation-composer"] },
  notifyMainOnCompletion: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-menu"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "metadata" } },
  notifyMacOSOnCompletion: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-menu"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "metadata" } },
  archived: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionArchivedAuthoritative", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["dock-icon", "session-list"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "metadata" } },
  archivedAt: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["session-list"], metaPatch: { clearable: true, swiftType: "Date", swiftApply: "metadata" } },
  pinned: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["dock-icon", "session-list"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "metadata" } },
  lastRequest: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-card", "session-list"], metaPatch: { clearable: true, swiftType: "PickySessionLastRequest", swiftApply: "metadata" } },
  agentCycle: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["async-task-projection"], metaPatch: { clearable: true, swiftType: "PickyAgentCycle", swiftApply: "metadata" } },
  asyncWorkSummary: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["async-task-projection"], metaPatch: { clearable: true, swiftType: "PickyAsyncWorkSummary", swiftApply: "metadata" } },
  fastMode: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-composer"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "metadata" } },
  fastModeSupported: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionMetaUpdated", v2Mutation: "metaPatch", swiftStore: "PickySessionMetaStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "never-omitted", consumers: ["conversation-composer"], metaPatch: { clearable: true, swiftType: "Bool", swiftApply: "metadata" } },
  asyncTasks: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "asyncTaskDetailSet", swiftStore: "PickySessionAsyncTaskStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-unavailable", consumers: ["async-task-projection"] },
  completionTickets: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "asyncTaskDetailSet", swiftStore: "PickySessionAsyncTaskStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-unavailable", consumers: ["async-task-projection"] },
  asyncControl: { persistenceOwner: "session-supervisor.commit", v1Event: "sessionUpdated", v2Mutation: "asyncControlSet", swiftStore: "PickySessionAsyncTaskStore", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-unavailable", consumers: ["async-task-projection"] },
  asyncArchiveIntentId: { persistenceOwner: "async-control-coordinator", v1Event: "sessionUpdated", v2Mutation: "snapshotOnly", swiftStore: "not-projected", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-unavailable", consumers: ["async-control-recovery"] },
  asyncControlJournal: { persistenceOwner: "async-control-coordinator", v1Event: "sessionUpdated", v2Mutation: "snapshotOnly", swiftStore: "not-projected", snapshotSemantics: "clear-if-omitted-explicit", p0OmissionBehavior: "omitted-unavailable", consumers: ["async-control-recovery"] },
} as const satisfies Record<SessionField, SessionFieldSpec>;

type Specs = typeof sessionFieldSpecs;

/** Fields carried by the v2 `metaPatch` mutation. */
export type MetaPatchField = { [K in SessionField]: Specs[K]["v2Mutation"] extends "metaPatch" ? K : never }[SessionField];

/** `metaPatch` fields that accept `null` to clear the client's value. */
export type ClearableMetaPatchField = { [K in MetaPatchField]: Specs[K] extends { metaPatch: { clearable: true } } ? K : never }[MetaPatchField];

/** `metaPatch` fields owned by another client section (see each row's `metaPatch.swiftApply`). */
export type CustomMetaPatchField = { [K in MetaPatchField]: Specs[K] extends { metaPatch: { swiftApply: "custom" } } ? K : never }[MetaPatchField];

/** `metaPatch` fields stored in the scalar metadata section on both clients. */
export type MetadataMetaPatchField = { [K in MetaPatchField]: Specs[K] extends { metaPatch: { swiftApply: "metadata" } } ? K : never }[MetaPatchField];

const sessionFields = Object.keys(sessionFieldSpecs) as SessionField[];

function isMetaPatchField(field: SessionField): field is MetaPatchField {
  return sessionFieldSpecs[field].v2Mutation === "metaPatch";
}

export const metaPatchFields: readonly MetaPatchField[] = sessionFields.filter(isMetaPatchField);

export function isClearableMetaPatchField(field: MetaPatchField): field is ClearableMetaPatchField {
  return sessionFieldSpecs[field].metaPatch.clearable;
}

export const metadataMetaPatchFields = metaPatchFields.filter(
  (field): field is MetadataMetaPatchField => sessionFieldSpecs[field].metaPatch.swiftApply === "metadata",
);

export const customMetaPatchFields = metaPatchFields.filter(
  (field): field is CustomMetaPatchField => sessionFieldSpecs[field].metaPatch.swiftApply === "custom",
);
