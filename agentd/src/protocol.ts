import { z } from "zod";

export const PROTOCOL_VERSION = "2026-07-17";

const isoTimestamp = z.string().datetime({ offset: true });

export const SessionStatusSchema = z.enum([
  "queued",
  "running",
  "waiting_for_input",
  "blocked",
  "completed",
  "failed",
  "cancelled",
]);

export type SessionStatus = z.infer<typeof SessionStatusSchema>;

const BoundsSchema = z.object({ x: z.number(), y: z.number(), width: z.number(), height: z.number() });
const PointSchema = z.object({ x: z.number(), y: z.number() });
const CursorContextSchema = z.object({
  globalPoint: PointSchema,
  displayPoint: PointSchema,
  screenshotPixel: PointSchema,
});

const InkMarkSchema = z.object({
  id: z.string().min(1),
  source: z.enum(["voice", "text"]),
  kind: z.string().default("freehand-highlight"),
  screenId: z.string().optional(),
  points: z.array(PointSchema).min(2),
  bounds: BoundsSchema,
  strokeWidth: z.number().positive(),
  opacity: z.number().min(0).max(1),
});

const ScreenshotSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  path: z.string().min(1),
  screenId: z.string().optional(),
  bounds: BoundsSchema.optional(),
  screenshotWidthInPixels: z.number().int().positive().optional(),
  screenshotHeightInPixels: z.number().int().positive().optional(),
  isCursorScreen: z.boolean().optional(),
  cursor: CursorContextSchema.optional(),
});

export const BrowserMetadataSchema = z.object({
  url: z.string().url().optional(),
  title: z.string().optional(),
  selectedText: z.string().optional(),
});

export const PickyContextPacketSchema = z.object({
  id: z.string().min(1),
  source: z.enum(["voice", "text", "voice-follow-up", "text-follow-up", "system", "cli"]),
  capturedAt: isoTimestamp,
  transcript: z.string().optional(),
  selectedText: z.string().optional(),
  cwd: z.string().optional(),
  activeApp: z
    .object({ bundleId: z.string().optional(), name: z.string().optional(), pid: z.number().int().optional() })
    .optional(),
  activeWindow: z
    .object({ title: z.string().optional(), frame: z.object({ x: z.number(), y: z.number(), width: z.number(), height: z.number() }).optional() })
    .optional(),
  browser: BrowserMetadataSchema.optional(),
  screenshots: z.array(ScreenshotSchema).default([]),
  inkMarks: z.array(InkMarkSchema).default([]),
  warnings: z.array(z.string()).default([]),
});

export type PickyContextPacket = z.infer<typeof PickyContextPacketSchema>;

export const PickyMainAgentMessageSchema = z.object({
  role: z.enum(["user", "assistant"]),
  text: z.string(),
  createdAt: isoTimestamp,
});
export type PickyMainAgentMessage = z.infer<typeof PickyMainAgentMessageSchema>;
const PickyMainAgentContextUsageSchema = z.object({
  tokens: z.number().nullable(),
  contextWindow: z.number(),
  percent: z.number().nullable(),
});
export const PickyMainAgentStateSchema = z.object({
  sessionFilePath: z.string().optional(),
  cwd: z.string().optional(),
  messages: z.array(PickyMainAgentMessageSchema).default([]),
  compactSummary: z.string().optional(),
  epochStartedAt: isoTimestamp.optional(),
  epochTurnCount: z.number().int().nonnegative().optional(),
  lastRolloverAt: isoTimestamp.optional(),
  lastRolloverReason: z.string().optional(),
  contextUsage: PickyMainAgentContextUsageSchema.optional(),
});
export type PickyMainAgentState = z.infer<typeof PickyMainAgentStateSchema>;

export const ThinkingLevelSchema = z.enum(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
export type ThinkingLevel = z.infer<typeof ThinkingLevelSchema>;
export const ModelCycleDirectionSchema = z.enum(["forward", "backward"]);
export type ModelCycleDirection = z.infer<typeof ModelCycleDirectionSchema>;
const PickySlashCommandSourceSchema = z.enum(["extension", "prompt", "skill", "builtin"]);
const PickyPushToTalkControlActionSchema = z.enum(["press", "release"]);
export type PickyPushToTalkControlAction = z.infer<typeof PickyPushToTalkControlActionSchema>;
const PickySlashCommandSchema = z.object({
  name: z.string().min(1),
  description: z.string().optional(),
  source: PickySlashCommandSourceSchema,
});
export const PickyAutocompleteItemSchema = z.object({
  value: z.string(),
  label: z.string(),
  description: z.string().optional(),
});
export type PickyAutocompleteItem = z.infer<typeof PickyAutocompleteItemSchema>;
export const PickyRewindTargetSchema = z.object({
  entryId: z.string().min(1),
  text: z.string(),
  createdAt: isoTimestamp.optional(),
});
export type PickyRewindTarget = z.infer<typeof PickyRewindTargetSchema>;
const PickyChangedFileSchema = z.object({ path: z.string(), status: z.string(), summary: z.string().optional() });
export const PickyArtifactSchema = z.object({ id: z.string(), kind: z.string(), title: z.string(), path: z.string().optional(), url: z.string().url().optional(), updatedAt: isoTimestamp });
export type PickyArtifact = z.infer<typeof PickyArtifactSchema>;
export const PickyToolActivitySchema = z.object({ toolCallId: z.string(), name: z.string(), status: z.enum(["running", "succeeded", "failed"]), preview: z.string().optional(), argsPreview: z.string().optional(), resultPreview: z.string().optional(), startedAt: isoTimestamp.optional(), endedAt: isoTimestamp.optional() });
export type PickyToolActivity = z.infer<typeof PickyToolActivitySchema>;
export const PickyTodoTaskSchema = z.object({
  id: z.string(),
  content: z.string(),
  status: z.enum(["pending", "in_progress", "completed"]),
  activeForm: z.string().optional(),
  notes: z.string().optional(),
});
export type PickyTodoTask = z.infer<typeof PickyTodoTaskSchema>;
export const PickyTodoStateSchema = z.object({
  tasks: z.array(PickyTodoTaskSchema),
  updatedAt: isoTimestamp,
});
export type PickyTodoState = z.infer<typeof PickyTodoStateSchema>;
const PickyExtensionUiQuestionOptionSchema = z.preprocess(
  (option) => typeof option === "string" ? { value: option, label: option } : option,
  z.object({ value: z.string(), label: z.string(), description: z.string().optional() }),
);
const PickyExtensionUiQuestionSchema = z.object({
  id: z.string().optional(),
  type: z.enum(["radio", "checkbox", "text"]),
  prompt: z.string().optional(),
  label: z.string().optional(),
  options: z.array(PickyExtensionUiQuestionOptionSchema).optional(),
  allowOther: z.boolean().optional(),
  required: z.boolean().optional(),
  placeholder: z.string().optional(),
  default: z.union([z.string(), z.array(z.string())]).optional(),
});
export const PickyExtensionNotifyTypeSchema = z.enum(["info", "warning", "error"]);
export type PickyExtensionNotifyType = z.infer<typeof PickyExtensionNotifyTypeSchema>;
export const PickyExtensionUiRequestSchema = z.object({
  id: z.string(),
  sessionId: z.string(),
  method: z.enum(["select", "confirm", "input", "editor", "askUserQuestion", "notify", "setStatus", "setWidget", "setTitle", "set_editor_text"]),
  title: z.string().optional(),
  prompt: z.string().optional(),
  description: z.string().optional(),
  options: z.array(z.string()).optional(),
  questions: z.array(PickyExtensionUiQuestionSchema).optional(),
  text: z.string().optional(),
  notifyType: PickyExtensionNotifyTypeSchema.optional(),
  createdAt: isoTimestamp,
});
export type PickyExtensionUiRequest = z.infer<typeof PickyExtensionUiRequestSchema>;

export const PickyQueueModeSchema = z.enum(["one-at-a-time", "all"]);
export type PickyQueueMode = z.infer<typeof PickyQueueModeSchema>;
export const PickyQueueItemSchema = z.object({ id: z.string().optional(), text: z.string(), enqueuedAt: isoTimestamp });
export type PickyQueueItem = z.infer<typeof PickyQueueItemSchema>;
export const PickyActivitySummarySchema = z.object({
  read: z.number().int().default(0),
  bash: z.number().int().default(0),
  edit: z.number().int().default(0),
  write: z.number().int().default(0),
  thinking: z.number().int().default(0),
  other: z.number().int().default(0),
});
export type PickyActivitySummary = z.infer<typeof PickyActivitySummarySchema>;
export const PickyAssistantRunMetadataSchema = z.object({
  model: z.string().optional(),
  thinkingLevel: ThinkingLevelSchema.optional(),
});
export type PickyAssistantRunMetadata = z.infer<typeof PickyAssistantRunMetadataSchema>;
export const PickyCommandReceiptSchema = z.object({
  command: z.string().min(1),
  status: z.enum(["submitted", "failed"]),
  detail: z.string().optional(),
});
export type PickyCommandReceipt = z.infer<typeof PickyCommandReceiptSchema>;
export const PickyMainAgentModelOptionSchema = z.object({
  provider: z.string().min(1),
  modelId: z.string().min(1),
  displayName: z.string().min(1),
  pattern: z.string().min(1),
});
export type PickyMainAgentModelOption = z.infer<typeof PickyMainAgentModelOptionSchema>;
export const PickySessionMessageSchema = z.object({
  id: z.string(),
  kind: z.enum(["user_text", "agent_text", "agent_thinking", "agent_question", "agent_error", "agent_activity", "command_receipt", "system"]),
  createdAt: isoTimestamp,
  originatedBy: z.enum(["user", "main_agent", "pi_extension"]).optional(),
  text: z.string().optional(),
  question: PickyExtensionUiRequestSchema.optional(),
  cancelledAt: isoTimestamp.optional(),
  activitySnapshot: PickyActivitySummarySchema.optional(),
  assistantRun: PickyAssistantRunMetadataSchema.optional(),
  errorContext: z.string().optional(),
  errorMessage: z.string().optional(),
  notifyType: PickyExtensionNotifyTypeSchema.optional(),
  commandReceipt: PickyCommandReceiptSchema.optional(),
  // Count of image attachments that travelled with this user_text via the
  // structured context channel (PTT / QuickInput screenshots). HUD renders a
  // small "\ud83d\uddbc N attached" affordance on the user bubble so the user
  // can tell the model received screenshots even though no path appears in
  // the message body. Absent on messages that have no attachments.
  attachedImagesCount: z.number().int().nonnegative().optional(),
});
export type PickySessionMessage = z.infer<typeof PickySessionMessageSchema>;

export const PickyAgentSessionSchema = z.object({
  id: z.string(),
  title: z.string(),
  status: SessionStatusSchema,
  cwd: z.string().optional(),
  piSessionFilePath: z.string().optional(),
  createdAt: isoTimestamp,
  updatedAt: isoTimestamp,
  lastSummary: z.string().optional(),
  thinkingPreview: z.string().optional(),
  finalAnswer: z.string().optional(),
  logs: z.array(z.string()).default([]),
  tools: z.array(PickyToolActivitySchema).default([]),
  todoState: PickyTodoStateSchema.optional(),
  artifacts: z.array(PickyArtifactSchema).default([]),
  changedFiles: z.array(PickyChangedFileSchema).default([]),
  messages: z.array(PickySessionMessageSchema).default([]),
  queuedSteers: z.array(PickyQueueItemSchema).default([]),
  queuedFollowUps: z.array(PickyQueueItemSchema).default([]),
  steeringMode: PickyQueueModeSchema.default("one-at-a-time"),
  followUpMode: PickyQueueModeSchema.default("one-at-a-time"),
  activitySummary: PickyActivitySummarySchema.default({ read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 }),
  contextUsage: z.object({
    tokens: z.number().nullable(),
    contextWindow: z.number(),
    percent: z.number().nullable(),
  }).optional(),
  currentAssistantRun: PickyAssistantRunMetadataSchema.optional(),
  pendingExtensionUiRequest: PickyExtensionUiRequestSchema.optional(),
  notifyMainOnCompletion: z.boolean().optional(),
  archived: z.boolean().optional(),
  archivedAt: isoTimestamp.optional(),
  pinned: z.boolean().optional(),
});

export type PickyAgentSessionParsed = z.infer<typeof PickyAgentSessionSchema>;
export type PickyAgentSession = Omit<PickyAgentSessionParsed, "messages" | "queuedSteers" | "queuedFollowUps" | "steeringMode" | "followUpMode" | "activitySummary"> & Partial<Pick<PickyAgentSessionParsed, "messages" | "queuedSteers" | "queuedFollowUps" | "steeringMode" | "followUpMode" | "activitySummary">>;

export const PickyPointerOverlayRequestSchema = z.object({
  id: z.string().min(1),
  contextId: z.string().optional(),
  contextGeneration: z.number().int().nonnegative().optional(),
  screenId: z.string().optional(),
  x: z.number().finite(),
  y: z.number().finite(),
  label: z.string().optional(),
  clamped: z.boolean().optional(),
  screenBounds: BoundsSchema,
  screenshotSize: z.object({ width: z.number().positive(), height: z.number().positive() }),
});
export type PickyPointerOverlayRequest = z.infer<typeof PickyPointerOverlayRequestSchema>;

const PickyAnnotationShapeSchema = z.enum(["rect", "line"]);
export const PickyAnnotationOverlayAnnotationSchema = z.object({
  id: z.string().min(1),
  shape: PickyAnnotationShapeSchema,
  x: z.number().finite().optional(),
  y: z.number().finite().optional(),
  w: z.number().nonnegative().finite().optional(),
  h: z.number().nonnegative().finite().optional(),
  x1: z.number().finite().optional(),
  y1: z.number().finite().optional(),
  x2: z.number().finite().optional(),
  y2: z.number().finite().optional(),
  spotlight: z.boolean().optional(),
  label: z.string().optional(),
  clamped: z.boolean().optional(),
});
export type PickyAnnotationOverlayAnnotation = z.infer<typeof PickyAnnotationOverlayAnnotationSchema>;

export const PickyAnnotationOverlayRequestSchema = z.object({
  id: z.string().min(1),
  mode: z.enum(["replace", "append", "clear"]),
  annotations: z.array(PickyAnnotationOverlayAnnotationSchema).max(24),
  contextId: z.string().optional(),
  contextGeneration: z.number().int().nonnegative().optional(),
  screenId: z.string().optional(),
  screenBounds: BoundsSchema.optional(),
  screenshotSize: z.object({ width: z.number().positive(), height: z.number().positive() }).optional(),
});
export type PickyAnnotationOverlayRequest = z.infer<typeof PickyAnnotationOverlayRequestSchema>;

// App-owned Pickle dock group snapshot for CLI commands.
export const DockGroupSchema = z.object({
  id: z.string(),
  name: z.string(),
  color: z.number().int(),
  memberSessionIds: z.array(z.string()),
  collapsed: z.boolean(),
});
export type DockGroup = z.infer<typeof DockGroupSchema>;

const CommandBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION) });
export const CommandEnvelopeSchema = z.discriminatedUnion("type", [
  CommandBaseSchema.extend({ type: z.literal("routeTask"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("createTask"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("createEmptyPickleSession"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("createPickleFromHandoff"), context: PickyContextPacketSchema, title: z.string().min(1), instructions: z.string().min(1), cwd: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("completePickleHandoff"), requestId: z.string().min(1), sessionId: z.string().min(1).optional(), title: z.string().min(1).optional(), cwd: z.string().optional(), errorMessage: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("registerAppCapabilities"), capabilities: z.array(z.enum(["pickleHandoff", "pickleBridge", "externalEntry", "pushToTalkControl"])).min(1) }),
  CommandBaseSchema.extend({ type: z.literal("submitMainFromExternal"), text: z.string().min(1), captureContext: z.boolean().default(true), cwd: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("createPickleFromExternal"), title: z.string().min(1), instructions: z.string().min(1), captureContext: z.boolean().default(true), cwd: z.string().min(1).optional(), group: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("controlPushToTalkFromExternal"), action: PickyPushToTalkControlActionSchema }),
  CommandBaseSchema.extend({ type: z.literal("completePushToTalkControlRequest"), requestId: z.string().min(1), errorMessage: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("completeExternalEntryRequest"), requestId: z.string().min(1), context: PickyContextPacketSchema.optional(), errorMessage: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("listDockGroups") }),
  CommandBaseSchema.extend({ type: z.literal("completeDockGroupsRequest"), requestId: z.string().min(1), groups: z.array(DockGroupSchema).optional(), errorMessage: z.string().min(1).optional() }),
  CommandBaseSchema.extend({
    type: z.literal("completePickleBridgeRequest"),
    requestId: z.string().min(1),
    sessions: z.array(PickyAgentSessionSchema).optional(),
    session: PickyAgentSessionSchema.optional(),
    delivered: z.boolean().optional(),
    errorMessage: z.string().min(1).optional(),
  }),
  CommandBaseSchema.extend({ type: z.literal("notifyMainOfPickleCompletion"), sessionId: z.string().min(1), prompt: z.string().min(1), cwd: z.string().optional() }),
  CommandBaseSchema.extend({ type: z.literal("duplicatePickleSession"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("pinPickleSession"), context: PickyContextPacketSchema, title: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("setNotifyMainOnCompletion"), sessionId: z.string(), enabled: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("setSessionArchived"), sessionId: z.string(), archived: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("deleteSession"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("cycleSessionThinkingLevel"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("cycleSessionModel"), sessionId: z.string(), direction: ModelCycleDirectionSchema.default("forward") }),
  CommandBaseSchema.extend({ type: z.literal("clearQueue"), sessionId: z.string(), kind: z.enum(["steering", "followUp", "all"]) }),
  CommandBaseSchema.extend({ type: z.literal("syncTerminalSession"), sessionId: z.string(), baselinePiMessageId: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("setTerminalSessionTailEnabled"), sessionId: z.string(), enabled: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("followUp"), sessionId: z.string(), text: z.string().min(1), context: PickyContextPacketSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("steer"), sessionId: z.string(), text: z.string().min(1), context: PickyContextPacketSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("abort"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("listSessions") }),
  CommandBaseSchema.extend({ type: z.literal("listMainMessages") }),
  CommandBaseSchema.extend({ type: z.literal("listMainAgentModels") }),
  CommandBaseSchema.extend({ type: z.literal("setDefaultCwd"), defaultCwd: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentModel"), mainAgentModelPattern: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("setDisabledBuiltinTools"), disabledBuiltinTools: z.array(z.string()) }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentTTSEnabled"), enabled: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("resetMainAgent") }),
  CommandBaseSchema.extend({ type: z.literal("abortMainAgent") }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentThinkingLevel"), mainAgentThinkingLevel: ThinkingLevelSchema }),
  CommandBaseSchema.extend({ type: z.literal("listSlashCommands"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("getAutocompleteCapabilities"), sessionId: z.string() }),
  CommandBaseSchema.extend({
    type: z.literal("autocompleteQuery"),
    sessionId: z.string(),
    generation: z.number().int().nonnegative(),
    lines: z.array(z.string()).min(1).max(1_000),
    cursorLine: z.number().int().nonnegative(),
    cursorCol: z.number().int().nonnegative(),
    force: z.boolean().optional(),
    draftRevision: z.number().int().nonnegative(),
    draftFingerprint: z.string().min(1),
  }),
  CommandBaseSchema.extend({
    type: z.literal("autocompleteApply"),
    sessionId: z.string(),
    generation: z.number().int().nonnegative(),
    lines: z.array(z.string()).min(1).max(1_000),
    cursorLine: z.number().int().nonnegative(),
    cursorCol: z.number().int().nonnegative(),
    force: z.boolean().optional(),
    draftRevision: z.number().int().nonnegative(),
    draftFingerprint: z.string().min(1),
    item: PickyAutocompleteItemSchema,
    prefix: z.string(),
  }),
  CommandBaseSchema.extend({ type: z.literal("listRewindTargets"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("rewindSession"), sessionId: z.string(), entryId: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("getSession"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("answerExtensionUi"), sessionId: z.string(), requestId: z.string(), value: z.unknown().optional() }),
  CommandBaseSchema.extend({ type: z.literal("reloadPlugins") }),
]);

type CommandEnvelope = z.infer<typeof CommandEnvelopeSchema>;

const EventBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION), timestamp: isoTimestamp });
const QuickReplyOriginSourceSchema = z.enum(["voice", "text", "voiceFollowUp", "textFollowUp", "system", "cli", "unknown"]);
const QuickReplyKindSchema = z.preprocess((value) => {
  if (typeof value !== "string") return value;
  const normalized = value.trim().toLowerCase();
  if (["picklecompletion", "pickle-completion", "pickle_completion"].includes(normalized)) return "pickleCompletion";
  if (["handoffack", "handoff-ack", "handoff_ack"].includes(normalized)) return "handoffAck";
  return value;
}, z.enum(["main", "pickleCompletion", "router", "handoffAck", "error", "unknown"]));

export const EventEnvelopeSchema = z.discriminatedUnion("type", [
  EventBaseSchema.extend({ type: z.literal("hello"), serverName: z.literal("picky-agentd"), supportedProtocolVersions: z.array(z.string()) }),
  EventBaseSchema.extend({
    type: z.literal("quickReply"),
    contextId: z.string(),
    text: z.string().min(1),
    originSource: QuickReplyOriginSourceSchema.optional(),
    replyKind: QuickReplyKindSchema.optional(),
    sessionId: z.string().optional(),
    inputId: z.string().optional(),
    didStreamNarration: z.boolean().optional(),
  }),
  EventBaseSchema.extend({ type: z.literal("mainTurnSettled"), contextId: z.string() }),
  EventBaseSchema.extend({
    type: z.literal("mainNarrationChunk"),
    contextId: z.string(),
    text: z.string().min(1),
    originSource: QuickReplyOriginSourceSchema.optional(),
    replyKind: QuickReplyKindSchema.optional(),
    sessionId: z.string().optional(),
  }),
  EventBaseSchema.extend({ type: z.literal("mainMessagesSnapshot"), messages: z.array(PickyMainAgentMessageSchema) }),
  EventBaseSchema.extend({ type: z.literal("mainMessageAppended"), message: PickyMainAgentMessageSchema }),
  EventBaseSchema.extend({
    type: z.literal("mainAgentSessionInfoUpdated"),
    sessionFilePath: z.string().optional(),
    cwd: z.string().optional(),
  }),
  EventBaseSchema.extend({ type: z.literal("mainAgentModelsSnapshot"), models: z.array(PickyMainAgentModelOptionSchema) }),
  EventBaseSchema.extend({ type: z.literal("sessionSnapshot"), sessions: z.array(PickyAgentSessionSchema) }),
  EventBaseSchema.extend({ type: z.literal("sessionUpdated"), session: PickyAgentSessionSchema }),
  // Explicit signal that a session's `archived` flag was just (un)set on the
  // daemon side. Picky's session view model trusts THIS event to update its
  // local `manuallyArchivedSessionIDs` UserDefaults; it deliberately ignores
  // the `archived` field on plain `sessionUpdated` to avoid mid-flight
  // unarchive flicker when an unrelated update arrives while the user has
  // just archived/unarchived locally. Fired from `setSessionArchived`
  // regardless of source (client command, picky_unarchive_pickle tool, ...).
  EventBaseSchema.extend({ type: z.literal("sessionArchivedAuthoritative"), sessionId: z.string(), archived: z.boolean() }),
  EventBaseSchema.extend({ type: z.literal("sessionResourcesReloaded"), sessionId: z.string() }),
  EventBaseSchema.extend({
    type: z.literal("pluginsReloaded"),
    requestId: z.string().optional(),
    pickyReloaded: z.boolean(),
    pickleReloadedCount: z.number().int().nonnegative(),
    pickleAbortedCount: z.number().int().nonnegative(),
    pickleDeferredCount: z.number().int().nonnegative(),
  }),
  EventBaseSchema.extend({ type: z.literal("sessionLogAppended"), sessionId: z.string(), line: z.string() }),
  EventBaseSchema.extend({ type: z.literal("toolActivityUpdated"), sessionId: z.string(), tool: PickyToolActivitySchema }),
  EventBaseSchema.extend({ type: z.literal("sessionTodoStateUpdated"), sessionId: z.string(), todoState: PickyTodoStateSchema.nullable(), seq: z.number().int() }),
  EventBaseSchema.extend({ type: z.literal("extensionUiRequest"), request: PickyExtensionUiRequestSchema }),
  EventBaseSchema.extend({ type: z.literal("artifactUpdated"), sessionId: z.string(), artifact: PickyArtifactSchema }),
  EventBaseSchema.extend({ type: z.literal("pointerOverlayRequested"), request: PickyPointerOverlayRequestSchema }),
  EventBaseSchema.extend({ type: z.literal("annotationOverlayRequested"), request: PickyAnnotationOverlayRequestSchema }),
  EventBaseSchema.extend({
    type: z.literal("pickleHandoffRequested"),
    requestId: z.string().min(1),
    context: PickyContextPacketSchema,
    title: z.string().min(1),
    instructions: z.string().min(1),
    cwd: z.string().min(1),
  }),
  EventBaseSchema.extend({
    type: z.literal("pickleBridgeRequested"),
    requestId: z.string().min(1),
    operation: z.enum(["listSessions", "steer", "abort", "notifyMainOfPickleCompletion"]),
    sessionId: z.string().optional(),
    text: z.string().optional(),
    prompt: z.string().optional(),
    cwd: z.string().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("externalEntryRequested"),
    requestId: z.string().min(1),
    kind: z.enum(["submitMain", "createPickle"]),
    text: z.string().optional(),
    title: z.string().optional(),
    instructions: z.string().optional(),
    cwd: z.string().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("externalEntryAck"),
    commandId: z.string().min(1),
    kind: z.enum(["submitMain", "createPickle"]),
    sessionId: z.string().min(1).optional(),
    contextId: z.string().min(1).optional(),
    errorMessage: z.string().min(1).optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("externalEntryAccepted"),
    commandId: z.string().min(1),
    kind: z.enum(["submitMain", "createPickle"]),
    contextId: z.string().min(1),
    sessionId: z.string().min(1).optional(),
    group: z.string().min(1).optional(),
  }),
  EventBaseSchema.extend({ type: z.literal("dockGroupsRequested"), requestId: z.string().min(1) }),
  EventBaseSchema.extend({ type: z.literal("dockGroupsSnapshot"), groups: z.array(DockGroupSchema) }),
  EventBaseSchema.extend({
    type: z.literal("pushToTalkControlRequested"),
    requestId: z.string().min(1),
    action: PickyPushToTalkControlActionSchema,
  }),
  EventBaseSchema.extend({
    type: z.literal("pushToTalkControlAck"),
    commandId: z.string().min(1),
    action: PickyPushToTalkControlActionSchema,
  }),
  EventBaseSchema.extend({ type: z.literal("slashCommandsSnapshot"), sessionId: z.string(), requestId: z.string().optional(), commands: z.array(PickySlashCommandSchema) }),
  EventBaseSchema.extend({
    type: z.literal("autocompleteCapabilitiesSnapshot"),
    sessionId: z.string(),
    requestId: z.string(),
    generation: z.number().int().nonnegative(),
    triggerCharacters: z.array(z.string()),
  }),
  EventBaseSchema.extend({
    type: z.literal("autocompleteSuggestionsSnapshot"),
    sessionId: z.string(),
    requestId: z.string(),
    generation: z.number().int().nonnegative(),
    draftRevision: z.number().int().nonnegative(),
    draftFingerprint: z.string().min(1),
    cursorLine: z.number().int().nonnegative(),
    cursorCol: z.number().int().nonnegative(),
    prefix: z.string().optional(),
    items: z.array(PickyAutocompleteItemSchema),
  }),
  EventBaseSchema.extend({
    type: z.literal("autocompleteCompletionApplied"),
    sessionId: z.string(),
    requestId: z.string(),
    generation: z.number().int().nonnegative(),
    draftRevision: z.number().int().nonnegative(),
    draftFingerprint: z.string().min(1),
    lines: z.array(z.string()).min(1),
    cursorLine: z.number().int().nonnegative(),
    cursorCol: z.number().int().nonnegative(),
  }),
  EventBaseSchema.extend({ type: z.literal("rewindTargetsSnapshot"), sessionId: z.string(), requestId: z.string().optional(), targets: z.array(PickyRewindTargetSchema) }),
  EventBaseSchema.extend({ type: z.literal("sessionRewound"), sessionId: z.string(), editorText: z.string().optional(), removedIds: z.array(z.string()) }),
  EventBaseSchema.extend({ type: z.literal("sessionMessageAppended"), sessionId: z.string(), message: PickySessionMessageSchema, seq: z.number().int() }),
  // Bulk append for terminal-sync / history-restore imports. The whole batch shares one
  // seq so the client applies it as a single incremental update instead of replaying the
  // import message-by-message (which renders like a timelapse).
  EventBaseSchema.extend({ type: z.literal("sessionMessagesImported"), sessionId: z.string(), messages: z.array(PickySessionMessageSchema), seq: z.number().int() }),
  EventBaseSchema.extend({ type: z.literal("sessionMessageReplaced"), sessionId: z.string(), messageId: z.string(), message: PickySessionMessageSchema, seq: z.number().int() }),
  EventBaseSchema.extend({ type: z.literal("sessionMessageRemoved"), sessionId: z.string(), messageId: z.string(), seq: z.number().int() }),
  EventBaseSchema.extend({ type: z.literal("sessionQueueUpdated"), sessionId: z.string(), steering: z.array(PickyQueueItemSchema), followUp: z.array(PickyQueueItemSchema), steeringMode: PickyQueueModeSchema.optional(), followUpMode: PickyQueueModeSchema.optional(), seq: z.number().int() }),
  EventBaseSchema.extend({ type: z.literal("sessionActivityUpdated"), sessionId: z.string(), activitySummary: PickyActivitySummarySchema, seq: z.number().int() }),
  EventBaseSchema.extend({
    type: z.literal("terminalSessionSyncOutcome"),
    sessionId: z.string(),
    baselineFound: z.boolean(),
    importedMessageCount: z.number().int().nonnegative(),
    activeLastMessageId: z.string().optional(),
    baselinePiMessageId: z.string().optional(),
  }),
  EventBaseSchema.extend({ type: z.literal("error"), code: z.string(), message: z.string(), commandId: z.string().optional() }),
]);

export type EventEnvelope = z.infer<typeof EventEnvelopeSchema>;

export function parseCommand(input: unknown): CommandEnvelope {
  return CommandEnvelopeSchema.parse(input);
}

