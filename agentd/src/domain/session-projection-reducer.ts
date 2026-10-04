import type {
  PickyActivitySummary,
  PickyAgentSession,
  PickyArtifact,
  PickyExtensionUiRequest,
  PickyQueueItem,
  PickyQueueMode,
  PickyScheduledMessage,
  PickySessionMessage,
  PickySessionProjectionMutation,
  PickySubagentRun,
  PickyTodoState,
  PickyToolActivity,
} from "../protocol.js";
import type { AsyncControlState, AsyncTaskDetail } from "./async-task-contract.js";
import { customMetaPatchFields, metadataMetaPatchFields, type CustomMetaPatchField, type MetadataMetaPatchField } from "../protocol-session-fields.js";

/**
 * Reference implementation of the client-side projection reducer.
 *
 * The normative definition lives in Swift
 * (`Picky/Sessions/PickyRegistrySessionProjectionStorage+V2.swift` plus the child
 * stores in `Picky/Sessions/Projection/`); this module is the isomorphic second
 * reader so a non-Swift client (web) folds the same snapshot/transaction stream
 * into the same state. Both are pinned by the language-neutral scenarios in
 * `contracts/projection/conformance/`.
 *
 * Deliberate boundaries, matching the Swift reducer:
 * - Ordering is not validated here. `transaction.baseRevision` is ignored and
 *   `revision` is replaced outright; gap detection belongs to the revision
 *   cursor (`Picky/Sessions/PickySessionRevisionCursor.swift`).
 * - Archive intent, selection, notifications and ownership/epoch policy are
 *   client policy layered above this reducer, not part of it.
 * - Locally-owned presentation (log preview, optimistic request timestamp,
 *   terminal-sync banner, "writing reply") has no projection owner. Only the
 *   reset *signal* is modelled here, as `signals.localPresentationResets`.
 */

export type PickyChangedFile = NonNullable<PickyAgentSession["changedFiles"]>[number];

/**
 * A section is `unavailable` until a snapshot or mutation supplies it. This is
 * the distinction a flattened session record cannot carry: "the daemon omitted
 * this" is not "the daemon says it is empty".
 */
export type ProjectionSectionState<Value> =
  | { readonly state: "unavailable" }
  | { readonly state: "loaded"; readonly value: Value };

export const unavailableSection = { state: "unavailable" } as const;

export function loadedSection<Value>(value: Value): ProjectionSectionState<Value> {
  return { state: "loaded", value };
}

/**
 * Scalar session metadata, owned as one section (Swift: `PickySessionMetaStore`):
 * every metadata-owned `metaPatch` field from `protocol-session-fields.ts`, plus
 * the session `id`, the envelope `revision`, and `finalAnswer` (its own mutation).
 */
export type SessionProjectionMeta =
  & Readonly<Pick<PickyAgentSession, MetadataMetaPatchField | "id" | "finalAnswer">>
  & { readonly revision: number };

export interface SessionProjectionQueue {
  readonly steers: readonly PickyQueueItem[];
  readonly followUps: readonly PickyQueueItem[];
  readonly scheduled: readonly PickyScheduledMessage[];
}

/**
 * Delivery modes are scalar metadata that survive an unavailable queue
 * collection, so they are not part of the queue section value.
 */
export interface SessionProjectionQueueModes {
  readonly steeringMode: PickyQueueMode;
  readonly followUpMode: PickyQueueMode;
}

export interface SessionProjectionSections {
  readonly meta: ProjectionSectionState<SessionProjectionMeta>;
  readonly logs: ProjectionSectionState<readonly string[]>;
  readonly tools: ProjectionSectionState<readonly PickyToolActivity[]>;
  readonly todo: ProjectionSectionState<PickyTodoState | null>;
  readonly subagentRuns: ProjectionSectionState<readonly PickySubagentRun[]>;
  readonly asyncTaskDetail: ProjectionSectionState<AsyncTaskDetail>;
  readonly asyncControl: ProjectionSectionState<AsyncControlState>;
  readonly artifacts: ProjectionSectionState<readonly PickyArtifact[]>;
  readonly changedFiles: ProjectionSectionState<readonly PickyChangedFile[]>;
  readonly messages: ProjectionSectionState<readonly PickySessionMessage[]>;
  readonly messageJournalAvailable: ProjectionSectionState<boolean | null>;
  readonly queue: ProjectionSectionState<SessionProjectionQueue>;
  readonly activity: ProjectionSectionState<PickyActivitySummary>;
  readonly extensionUiRequest: ProjectionSectionState<PickyExtensionUiRequest | null>;
}

/**
 * Routing evidence a client needs but that is not stored projection data.
 * Counters rather than booleans so a scenario can assert "exactly once".
 */
export interface SessionProjectionSignals {
  /** Session replacement (`/new`) or a snapshot that swapped the Pi session. */
  readonly localPresentationResets: number;
  /** Transactions eligible for the progress-only path (no card republish). */
  readonly progressOnlyTransactions: number;
  /** Transactions dropped because the session had no loaded metadata. */
  readonly ignoredTransactions: number;
  /** Snapshots dropped because `projection.id` did not match `sessionId`. */
  readonly ignoredSnapshots: number;
}

export interface SessionProjectionState {
  readonly sessionId: string;
  readonly sections: SessionProjectionSections;
  readonly queueModes: SessionProjectionQueueModes;
  readonly signals: SessionProjectionSignals;
}

export interface SessionProjectionSnapshotInput {
  readonly sessionId: string;
  readonly revision: number;
  readonly omittedFields: readonly string[];
  readonly projection: PickyAgentSession;
}

export interface SessionProjectionTransactionInput {
  readonly sessionId: string;
  readonly revision: number;
  readonly mutations: readonly PickySessionProjectionMutation[];
}

const defaultQueueModes: SessionProjectionQueueModes = { steeringMode: "one-at-a-time", followUpMode: "one-at-a-time" };
const zeroActivity: PickyActivitySummary = { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 };
const noSignals: SessionProjectionSignals = {
  localPresentationResets: 0,
  progressOnlyTransactions: 0,
  ignoredTransactions: 0,
  ignoredSnapshots: 0,
};

/** Every section starts unavailable, exactly like a freshly vended Swift store. */
export function emptySessionProjectionState(sessionId: string): SessionProjectionState {
  return {
    sessionId,
    sections: {
      meta: unavailableSection,
      logs: unavailableSection,
      tools: unavailableSection,
      todo: unavailableSection,
      subagentRuns: unavailableSection,
      asyncTaskDetail: unavailableSection,
      asyncControl: unavailableSection,
      artifacts: unavailableSection,
      changedFiles: unavailableSection,
      messages: unavailableSection,
      messageJournalAvailable: unavailableSection,
      queue: unavailableSection,
      activity: unavailableSection,
      extensionUiRequest: unavailableSection,
    },
    queueModes: defaultQueueModes,
    signals: noSignals,
  };
}

/**
 * Snapshot hydration. `omittedFields` decides per section whether the snapshot
 * carries authoritative data or leaves the section unavailable; scalar metadata
 * is always taken from the projection, as in Swift.
 */
export function applySessionProjectionSnapshot(
  previous: SessionProjectionState | undefined,
  snapshot: SessionProjectionSnapshotInput,
): SessionProjectionState {
  const base = previous ?? emptySessionProjectionState(snapshot.sessionId);
  if (snapshot.projection.id !== snapshot.sessionId) {
    return { ...base, signals: { ...base.signals, ignoredSnapshots: base.signals.ignoredSnapshots + 1 } };
  }

  const projection = snapshot.projection;
  const omitted = new Set(snapshot.omittedFields);
  // A correlated recovery snapshot can supersede a lost `/new` transaction.
  // Swift compares the materialized card, whose Pi path may come from a log
  // line; this reference compares metadata only (log-derived presentation is
  // outside the reducer), so conformance scenarios keep Pi paths in metadata.
  const replacesExistingPiSession = base.sections.meta.state === "loaded"
    && base.sections.meta.value.piSessionFilePath !== projection.piSessionFilePath;

  return {
    sessionId: snapshot.sessionId,
    sections: {
      meta: loadedSection(metaFrom(projection, snapshot.revision)),
      ...snapshotLeafSections(projection, omitted),
      ...snapshotAsyncSections(projection, omitted),
      // Artifacts and changed files share one Swift store, so omitting either
      // leaves both unavailable.
      ...artifactSections(
        omitted.has("artifacts") || omitted.has("changedFiles")
          ? undefined
          : { artifacts: projection.artifacts ?? [], changedFiles: projection.changedFiles ?? [] },
      ),
      ...snapshotConversationSections(projection, omitted),
      queue: snapshotQueueSection(projection, omitted),
    },
    // Modes are restated even when the queue collection is omitted.
    queueModes: {
      steeringMode: projection.steeringMode ?? defaultQueueModes.steeringMode,
      followUpMode: projection.followUpMode ?? defaultQueueModes.followUpMode,
    },
    signals: {
      ...base.signals,
      localPresentationResets: base.signals.localPresentationResets + (replacesExistingPiSession ? 1 : 0),
    },
  };
}

type OmittedFields = ReadonlySet<string>;

function snapshotLeafSections(
  projection: PickyAgentSession,
  omitted: OmittedFields,
): Pick<SessionProjectionSections, "logs" | "tools" | "todo" | "subagentRuns" | "activity" | "extensionUiRequest"> {
  return {
    logs: omitted.has("logs") ? unavailableSection : loadedSection(projection.logs ?? []),
    tools: omitted.has("tools") ? unavailableSection : loadedSection(projection.tools ?? []),
    todo: omitted.has("todoState") ? unavailableSection : loadedSection(projection.todoState ?? null),
    subagentRuns: omitted.has("subagentRuns") ? unavailableSection : loadedSection(projection.subagentRuns ?? []),
    activity: omitted.has("activitySummary") ? unavailableSection : loadedSection(projection.activitySummary ?? zeroActivity),
    extensionUiRequest: omitted.has("pendingExtensionUiRequest")
      ? unavailableSection
      : loadedSection(projection.pendingExtensionUiRequest ?? null),
  };
}

function snapshotAsyncSections(
  projection: PickyAgentSession,
  omitted: OmittedFields,
): Pick<SessionProjectionSections, "asyncTaskDetail" | "asyncControl"> {
  // Detail is one section: a half-supplied pair is as unusable as none.
  const detail = omitted.has("asyncTasks") || omitted.has("completionTickets")
    ? undefined
    : asyncDetailFrom(projection.asyncTasks, projection.completionTickets);
  const control = omitted.has("asyncControl") ? undefined : projection.asyncControl;
  return {
    asyncTaskDetail: detail ? loadedSection(detail) : unavailableSection,
    asyncControl: control ? loadedSection(control) : unavailableSection,
  };
}

function snapshotConversationSections(
  projection: PickyAgentSession,
  omitted: OmittedFields,
): Pick<SessionProjectionSections, "messages" | "messageJournalAvailable"> {
  // An omitted journal takes its availability flag with it.
  if (omitted.has("messages")) return { messages: unavailableSection, messageJournalAvailable: unavailableSection };
  return {
    messages: loadedSection(projection.messages ?? []),
    messageJournalAvailable: omitted.has("messageJournalAvailable")
      ? unavailableSection
      : loadedSection(projection.messageJournalAvailable ?? null),
  };
}

function snapshotQueueSection(
  projection: PickyAgentSession,
  omitted: OmittedFields,
): SessionProjectionSections["queue"] {
  if (omitted.has("queuedSteers") || omitted.has("queuedFollowUps")) return unavailableSection;
  return loadedSection({
    steers: projection.queuedSteers ?? [],
    followUps: projection.queuedFollowUps ?? [],
    scheduled: omitted.has("scheduledMessages") ? [] : projection.scheduledMessages ?? [],
  });
}

/**
 * Transaction application. Mutations fold in order, then `revision` is replaced
 * by the transaction's. A transaction for a session without loaded metadata is
 * dropped whole, matching the Swift guard.
 */
export function applySessionProjectionTransaction(
  previous: SessionProjectionState | undefined,
  transaction: SessionProjectionTransactionInput,
): SessionProjectionState | undefined {
  if (!previous || previous.sections.meta.state !== "loaded") {
    if (!previous) return undefined;
    return { ...previous, signals: { ...previous.signals, ignoredTransactions: previous.signals.ignoredTransactions + 1 } };
  }

  let state: SessionProjectionState = previous;
  for (const mutation of transaction.mutations) state = applyMutation(state, mutation);

  const meta = state.sections.meta;
  if (meta.state === "loaded") {
    state = withSections(state, { meta: loadedSection({ ...meta.value, revision: transaction.revision }) });
  }

  const replacement = isSessionReplacementTransaction(transaction);
  const progressOnly = isProgressOnlyProjectionTransaction(transaction);
  return {
    ...state,
    signals: {
      ...state.signals,
      localPresentationResets: state.signals.localPresentationResets + (replacement ? 1 : 0),
      progressOnlyTransactions: state.signals.progressOnlyTransactions + (progressOnly ? 1 : 0),
    },
  };
}

/**
 * `/new` is represented by authoritative empty replacements for every
 * resettable collection at once. Anything less is an ordinary clear.
 */
export function isSessionReplacementTransaction(transaction: SessionProjectionTransactionInput): boolean {
  let clearsLogs = false;
  let clearsTools = false;
  let clearsArtifacts = false;
  for (const mutation of transaction.mutations) {
    if (mutation.type === "logsSet") clearsLogs = mutation.logs.length === 0;
    if (mutation.type === "toolsSet") clearsTools = mutation.tools.length === 0;
    if (mutation.type === "artifactsSet") clearsArtifacts = mutation.artifacts.length === 0;
  }
  return clearsLogs && clearsTools && clearsArtifacts;
}

/**
 * Async progress commits touch only leaf execution state, so a client may apply
 * them without rebuilding the conversation card.
 */
export function isProgressOnlyProjectionTransaction(transaction: SessionProjectionTransactionInput): boolean {
  return transaction.mutations.length > 0
    && transaction.mutations.every((mutation) => mutation.type === "asyncTaskDetailSet" || mutation.type === "asyncControlSet");
}

/**
 * Flattens the reduced sections back into one session record. Unavailable
 * sections contribute their empty/default value, exactly like the Swift
 * materialization, so an omitted section can never revive stale data.
 */
export function materializeSessionProjection(state: SessionProjectionState): PickyAgentSession | undefined {
  const meta = state.sections.meta;
  if (meta.state !== "loaded") return undefined;
  const detail = sectionValue(state.sections.asyncTaskDetail);
  const queue = sectionValue(state.sections.queue);
  return {
    ...materializeMeta(meta.value),
    logs: collection(state.sections.logs),
    tools: collection(state.sections.tools),
    ...optional("todoState", nullableSectionValue(state.sections.todo)),
    subagentRuns: collection(state.sections.subagentRuns),
    ...optional("asyncTasks", detail?.tasks),
    ...optional("completionTickets", detail?.tickets),
    ...optional("asyncControl", sectionValue(state.sections.asyncControl)),
    artifacts: collection(state.sections.artifacts),
    changedFiles: collection(state.sections.changedFiles),
    messages: collection(state.sections.messages),
    ...optional("messageJournalAvailable", nullableSectionValue(state.sections.messageJournalAvailable)),
    queuedSteers: [...(queue?.steers ?? [])],
    queuedFollowUps: [...(queue?.followUps ?? [])],
    scheduledMessages: [...(queue?.scheduled ?? [])],
    steeringMode: state.queueModes.steeringMode,
    followUpMode: state.queueModes.followUpMode,
    activitySummary: sectionValue(state.sections.activity) ?? zeroActivity,
    ...optional("pendingExtensionUiRequest", nullableSectionValue(state.sections.extensionUiRequest)),
  };
}

function materializeMeta(meta: SessionProjectionMeta): SessionProjectionMeta {
  return Object.fromEntries(Object.entries(meta).filter(([, value]) => value !== undefined)) as SessionProjectionMeta;
}

function collection<Value>(section: ProjectionSectionState<readonly Value[]>): Value[] {
  return [...(sectionValue(section) ?? [])];
}

/** A section that loads `null` means "explicitly none", which flattens to absent. */
function nullableSectionValue<Value>(section: ProjectionSectionState<Value | null>): Value | undefined {
  return sectionValue(section) ?? undefined;
}

type MutationOfType<Type extends PickySessionProjectionMutation["type"]> =
  Extract<PickySessionProjectionMutation, { type: Type }>;

/**
 * One applier per mutation variant. The mapped type requires every variant, so
 * a new mutation cannot be added to the protocol without landing here too.
 */
const mutationAppliers: {
  [Type in PickySessionProjectionMutation["type"]]:
  (state: SessionProjectionState, mutation: MutationOfType<Type>) => SessionProjectionState
} = {
  metaPatch: (state, mutation) => applyMetaPatch(state, mutation.patch),
  messageAppend: (state, mutation) => withSections(state, {
    messages: loadedSection(upsertMessage(messagesOf(state), mutation.message)),
  }),
  messageReplace: (state, mutation) => withSections(state, {
    messages: loadedSection(upsertMessage(messagesOf(state), mutation.message)),
  }),
  messageRemove: (state, mutation) => withSections(state, {
    messages: loadedSection(messagesOf(state).filter((message) => message.id !== mutation.messageId)),
  }),
  messagesImport: (state, mutation) => {
    // An empty import is a no-op, so it cannot promote an unavailable journal.
    if (mutation.messages.length === 0) return state;
    let messages = messagesOf(state);
    for (const message of mutation.messages) messages = upsertMessage(messages, message);
    return withSections(state, { messages: loadedSection(messages) });
  },
  logAppend: (state, mutation) => withSections(state, {
    logs: loadedSection([...(sectionValue(state.sections.logs) ?? []), mutation.line]),
  }),
  logsSet: (state, mutation) => withSections(state, { logs: loadedSection(mutation.logs) }),
  toolUpsert: (state, mutation) => withSections(state, {
    tools: loadedSection(upsertBy(sectionValue(state.sections.tools) ?? [], mutation.tool, (tool) => tool.toolCallId)),
  }),
  toolsSet: (state, mutation) => withSections(state, { tools: loadedSection(mutation.tools) }),
  todoSet: (state, mutation) => withSections(state, { todo: loadedSection(mutation.todoState) }),
  subagentRunsSet: (state, mutation) => withSections(state, { subagentRuns: loadedSection(mutation.runs) }),
  asyncTaskDetailSet: (state, mutation) => withSections(state, {
    asyncTaskDetail: mutation.detail ? loadedSection(mutation.detail) : unavailableSection,
  }),
  asyncControlSet: (state, mutation) => withSections(state, {
    asyncControl: mutation.control ? loadedSection(mutation.control) : unavailableSection,
  }),
  artifactUpsert: (state, mutation) => withSections(state, artifactSections({
    artifacts: upsertBy(sectionValue(state.sections.artifacts) ?? [], mutation.artifact, (artifact) => artifact.id),
    changedFiles: sectionValue(state.sections.changedFiles) ?? [],
  })),
  artifactsSet: (state, mutation) => withSections(state, artifactSections({
    artifacts: mutation.artifacts,
    changedFiles: sectionValue(state.sections.changedFiles) ?? [],
  })),
  changedFilesSet: (state, mutation) => withSections(state, artifactSections({
    artifacts: sectionValue(state.sections.artifacts) ?? [],
    changedFiles: mutation.changedFiles,
  })),
  queueSet: (state, mutation) => ({
    ...withSections(state, {
      queue: loadedSection({
        steers: mutation.queuedSteers,
        followUps: mutation.queuedFollowUps,
        scheduled: mutation.scheduledMessages ?? [],
      }),
    }),
    queueModes: { steeringMode: mutation.steeringMode, followUpMode: mutation.followUpMode },
  }),
  activitySet: (state, mutation) => withSections(state, { activity: loadedSection(mutation.activitySummary) }),
  finalAnswerSet: (state, mutation) => withMeta(state, (meta) => ({ ...meta, finalAnswer: mutation.finalAnswer ?? undefined })),
  extensionUiRequestSet: (state, mutation) => withSections(state, { extensionUiRequest: loadedSection(mutation.request) }),
};

function applyMutation(state: SessionProjectionState, mutation: PickySessionProjectionMutation): SessionProjectionState {
  const apply = mutationAppliers[mutation.type] as (
    state: SessionProjectionState,
    mutation: PickySessionProjectionMutation,
  ) => SessionProjectionState;
  return apply(state, mutation);
}

type MetaPatch = Extract<PickySessionProjectionMutation, { type: "metaPatch" }>["patch"];

/**
 * Patch semantics: an absent key is unchanged, `null` clears, any other value
 * sets. `id` is a transaction envelope invariant and never rekeys a store.
 */
function applyMetaPatch(state: SessionProjectionState, patch: MetaPatch): SessionProjectionState {
  const patched = withMeta(state, (meta) => {
    const next: Record<string, unknown> = { ...meta };
    for (const field of metadataMetaPatchFields) {
      const value = patch[field];
      if (value !== undefined) next[field] = value === null ? undefined : value;
    }
    return next as SessionProjectionMeta;
  });
  return customMetaPatchFields.reduce((current, field) => (
    patch[field] === undefined ? current : applyCustomMetaPatch[field](current, patch[field])
  ), patched);
}

/** `metaPatch` fields whose owner is not the metadata section; exhaustive by type. */
const applyCustomMetaPatch: { [K in CustomMetaPatchField]: (state: SessionProjectionState, value: NonNullable<MetaPatch[K]> | null) => SessionProjectionState } = {
  // Journal availability is owned by the conversation section, so a patched
  // `null` loads an explicit "no journal", not an unavailable section.
  messageJournalAvailable: (state, value) => withSections(state, { messageJournalAvailable: loadedSection(value) }),
};

function metaFrom(projection: PickyAgentSession, revision: number): SessionProjectionMeta {
  const meta: Record<string, unknown> = { id: projection.id, revision, finalAnswer: projection.finalAnswer };
  for (const field of metadataMetaPatchFields) meta[field] = projection[field];
  return meta as SessionProjectionMeta;
}

function asyncDetailFrom(
  tasks: PickyAgentSession["asyncTasks"],
  tickets: PickyAgentSession["completionTickets"],
): AsyncTaskDetail | undefined {
  if (!tasks || !tickets) return undefined;
  return { tasks, tickets };
}

function artifactSections(
  value: { artifacts: readonly PickyArtifact[]; changedFiles: readonly PickyChangedFile[] } | undefined,
): Pick<SessionProjectionSections, "artifacts" | "changedFiles"> {
  if (!value) return { artifacts: unavailableSection, changedFiles: unavailableSection };
  return { artifacts: loadedSection(value.artifacts), changedFiles: loadedSection(value.changedFiles) };
}

function messagesOf(state: SessionProjectionState): readonly PickySessionMessage[] {
  return sectionValue(state.sections.messages) ?? [];
}

/** Upsert keeps an existing message at its position; a new id joins the end. */
function upsertMessage(
  messages: readonly PickySessionMessage[],
  message: PickySessionMessage,
): readonly PickySessionMessage[] {
  return upsertBy(messages, message, (candidate) => candidate.id);
}

function upsertBy<Value>(
  values: readonly Value[],
  value: Value,
  identity: (candidate: Value) => string,
): readonly Value[] {
  const id = identity(value);
  const index = values.findIndex((candidate) => identity(candidate) === id);
  if (index < 0) return [...values, value];
  const next = [...values];
  next[index] = value;
  return next;
}

function withSections(
  state: SessionProjectionState,
  sections: Partial<SessionProjectionSections>,
): SessionProjectionState {
  return { ...state, sections: { ...state.sections, ...sections } };
}

function withMeta(
  state: SessionProjectionState,
  update: (meta: SessionProjectionMeta) => SessionProjectionMeta,
): SessionProjectionState {
  const meta = state.sections.meta;
  if (meta.state !== "loaded") return state;
  return withSections(state, { meta: loadedSection(update(meta.value)) });
}

export function sectionValue<Value>(section: ProjectionSectionState<Value>): Value | undefined {
  return section.state === "loaded" ? section.value : undefined;
}

function optional<Key extends string, Value>(key: Key, value: Value | undefined): { [K in Key]?: Value } {
  return (value === undefined ? {} : { [key]: value }) as { [K in Key]?: Value };
}
