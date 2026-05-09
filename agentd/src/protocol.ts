import { z } from "zod";

export const PROTOCOL_VERSION = "2026-05-09";

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

export const ScreenshotSchema = z.object({
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
  source: z.enum(["voice", "text", "voice-follow-up", "text-follow-up", "system"]),
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
export const PickyMainAgentContextUsageSchema = z.object({
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

export const ThinkingLevelSchema = z.enum(["off", "minimal", "low", "medium", "high", "xhigh"]);
export type ThinkingLevel = z.infer<typeof ThinkingLevelSchema>;
export const MainAgentRuntimeModeSchema = z.enum(["pi", "openai-realtime"]);
export type MainAgentRuntimeMode = z.infer<typeof MainAgentRuntimeModeSchema>;
export const OpenAIRealtimeProviderSchema = z.enum(["openai", "azure_openai"]);
export type OpenAIRealtimeProvider = z.infer<typeof OpenAIRealtimeProviderSchema>;
export const OpenAIRealtimeReasoningEffortSchema = z.enum(["low", "medium", "high"]);
export const AzureOpenAIRealtimeAPIShapeSchema = z.enum(["ga", "preview"]);
const OpenAIRealtimeAuthConfigShape = {
  provider: OpenAIRealtimeProviderSchema,
  apiKey: z.string().min(1),
  modelOrDeployment: z.string().min(1),
  voice: z.string().min(1),
  reasoningEffort: OpenAIRealtimeReasoningEffortSchema.optional(),
  transcriptionLanguage: z.string().optional(),
  azure: z.object({
    resourceEndpoint: z.string().min(1),
    apiVersion: z.string().optional(),
    apiShape: AzureOpenAIRealtimeAPIShapeSchema,
  }).optional(),
} satisfies z.ZodRawShape;
const OpenAIRealtimeAuthConfigObjectSchema = z.object(OpenAIRealtimeAuthConfigShape);
export const OpenAIRealtimeAuthConfigSchema = OpenAIRealtimeAuthConfigObjectSchema.superRefine((value, ctx) => {
  if (value.provider === "azure_openai" && !value.azure) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["azure"], message: "Azure OpenAI realtime config is required for azure_openai provider" });
  }
  if (value.provider === "openai" && value.azure) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["azure"], message: "Azure OpenAI realtime config must be omitted for openai provider" });
  }
  if (value.azure?.apiShape === "preview" && !value.azure.apiVersion?.trim()) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["azure", "apiVersion"], message: "Azure OpenAI preview realtime API requires apiVersion" });
  }
});
export type OpenAIRealtimeAuthConfig = z.infer<typeof OpenAIRealtimeAuthConfigSchema>;
export const ModelCycleDirectionSchema = z.enum(["forward", "backward"]);
export type ModelCycleDirection = z.infer<typeof ModelCycleDirectionSchema>;
export const PickySlashCommandSourceSchema = z.enum(["extension", "prompt", "skill", "builtin"]);
export const PickySlashCommandSchema = z.object({
  name: z.string().min(1),
  description: z.string().optional(),
  source: PickySlashCommandSourceSchema,
});
export type PickySlashCommand = z.infer<typeof PickySlashCommandSchema>;

export const PickyChangedFileSchema = z.object({ path: z.string(), status: z.string(), summary: z.string().optional() });
export const PickyArtifactSchema = z.object({ id: z.string(), kind: z.string(), title: z.string(), path: z.string().optional(), url: z.string().url().optional(), updatedAt: isoTimestamp });
export type PickyArtifact = z.infer<typeof PickyArtifactSchema>;
export const PickyToolActivitySchema = z.object({ toolCallId: z.string(), name: z.string(), status: z.enum(["running", "succeeded", "failed"]), preview: z.string().optional(), argsPreview: z.string().optional(), resultPreview: z.string().optional(), startedAt: isoTimestamp.optional(), endedAt: isoTimestamp.optional() });
export type PickyToolActivity = z.infer<typeof PickyToolActivitySchema>;
export const PickyExtensionUiQuestionOptionSchema = z.preprocess(
  (option) => typeof option === "string" ? { value: option, label: option } : option,
  z.object({ value: z.string(), label: z.string(), description: z.string().optional() }),
);
export const PickyExtensionUiQuestionSchema = z.object({
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
export type PickyExtensionUiQuestion = z.infer<typeof PickyExtensionUiQuestionSchema>;
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
  createdAt: isoTimestamp,
});
export type PickyExtensionUiRequest = z.infer<typeof PickyExtensionUiRequestSchema>;

export const PickyQueueModeSchema = z.enum(["one-at-a-time", "all"]);
export type PickyQueueMode = z.infer<typeof PickyQueueModeSchema>;
export const PickyQueueItemSchema = z.object({ text: z.string(), enqueuedAt: isoTimestamp });
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
export const PickyMainAgentModelOptionSchema = z.object({
  provider: z.string().min(1),
  modelId: z.string().min(1),
  displayName: z.string().min(1),
  pattern: z.string().min(1),
});
export type PickyMainAgentModelOption = z.infer<typeof PickyMainAgentModelOptionSchema>;
export const PickySessionMessageSchema = z.object({
  id: z.string(),
  kind: z.enum(["user_text", "agent_text", "agent_thinking", "agent_question", "agent_error", "agent_activity", "system"]),
  createdAt: isoTimestamp,
  originatedBy: z.enum(["user", "main_agent", "pi_extension"]).optional(),
  text: z.string().optional(),
  question: PickyExtensionUiRequestSchema.optional(),
  cancelledAt: isoTimestamp.optional(),
  activitySnapshot: PickyActivitySummarySchema.optional(),
  assistantRun: PickyAssistantRunMetadataSchema.optional(),
  errorContext: z.string().optional(),
  errorMessage: z.string().optional(),
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
  pinned: z.boolean().optional(),
});

export type PickyAgentSessionParsed = z.infer<typeof PickyAgentSessionSchema>;
export type PickyAgentSession = Omit<PickyAgentSessionParsed, "messages" | "queuedSteers" | "queuedFollowUps" | "steeringMode" | "followUpMode" | "activitySummary"> & Partial<Pick<PickyAgentSessionParsed, "messages" | "queuedSteers" | "queuedFollowUps" | "steeringMode" | "followUpMode" | "activitySummary">>;

export const PickyPointerOverlayRequestSchema = z.object({
  id: z.string().min(1),
  contextId: z.string().optional(),
  screenId: z.string().optional(),
  x: z.number().finite(),
  y: z.number().finite(),
  label: z.string().optional(),
  clamped: z.boolean().optional(),
  screenBounds: BoundsSchema,
  screenshotSize: z.object({ width: z.number().positive(), height: z.number().positive() }),
});
export type PickyPointerOverlayRequest = z.infer<typeof PickyPointerOverlayRequestSchema>;

const CommandBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION) });
export const CommandEnvelopeSchema = z.discriminatedUnion("type", [
  CommandBaseSchema.extend({ type: z.literal("routeTask"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("createTask"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("createEmptyPickleSession"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("duplicatePickleSession"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("pinPickleSession"), context: PickyContextPacketSchema, title: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("setNotifyMainOnCompletion"), sessionId: z.string(), enabled: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("setSessionArchived"), sessionId: z.string(), archived: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("cycleSessionThinkingLevel"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("cycleSessionModel"), sessionId: z.string(), direction: ModelCycleDirectionSchema.default("forward") }),
  CommandBaseSchema.extend({ type: z.literal("clearQueue"), sessionId: z.string(), kind: z.enum(["steering", "followUp", "all"]) }),
  CommandBaseSchema.extend({ type: z.literal("syncTerminalSession"), sessionId: z.string(), baselinePiMessageId: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("followUp"), sessionId: z.string(), text: z.string().min(1), context: PickyContextPacketSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("steer"), sessionId: z.string(), text: z.string().min(1), context: PickyContextPacketSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("abort"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("listSessions") }),
  CommandBaseSchema.extend({ type: z.literal("listMainMessages") }),
  CommandBaseSchema.extend({ type: z.literal("listMainAgentModels") }),
  CommandBaseSchema.extend({ type: z.literal("setDefaultCwd"), defaultCwd: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentModel"), mainAgentModelPattern: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentRuntimeMode"), mode: MainAgentRuntimeModeSchema }),
  CommandBaseSchema.extend({ type: z.literal("configureMainRealtimeAuth"), ...OpenAIRealtimeAuthConfigShape }),
  CommandBaseSchema.extend({ type: z.literal("beginMainRealtimeVoiceTurn"), inputId: z.string().min(1), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("appendMainRealtimeInputAudio"), inputId: z.string().min(1), audioBase64: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("commitMainRealtimeVoiceTurn"), inputId: z.string().min(1), context: PickyContextPacketSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("cancelMainRealtimeVoiceTurn"), inputId: z.string().min(1).optional(), playedAudioMs: z.number().nonnegative().optional() }),
  CommandBaseSchema.extend({ type: z.literal("resetMainAgent") }),
  CommandBaseSchema.extend({ type: z.literal("abortMainAgent") }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentThinkingLevel"), mainAgentThinkingLevel: ThinkingLevelSchema }),
  CommandBaseSchema.extend({ type: z.literal("setMainAgentExtraInstructions"), mainAgentExtraInstructions: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("listSlashCommands"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("getSession"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("answerExtensionUi"), sessionId: z.string(), requestId: z.string(), value: z.unknown().optional() }),
]);

export type CommandEnvelope = z.infer<typeof CommandEnvelopeSchema>;

const EventBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION), timestamp: isoTimestamp });
const MainRealtimeStateSchema = z.enum(["connecting", "ready", "listening", "thinking", "speaking", "failed"]);
const MainRealtimeTurnStatusSchema = z.enum(["completed", "cancelled", "failed", "incomplete"]);
const QuickReplyOriginSourceSchema = z.enum(["voice", "text", "voiceFollowUp", "textFollowUp", "system", "unknown"]);
const QuickReplyKindSchema = z.preprocess((value) => {
  if (typeof value !== "string") return value;
  const normalized = value.trim().toLowerCase();
  if (["picklecompletion", "pickle-completion", "pickle_completion"].includes(normalized)) return "pickleCompletion";
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
  }),
  EventBaseSchema.extend({ type: z.literal("mainMessagesSnapshot"), messages: z.array(PickyMainAgentMessageSchema) }),
  EventBaseSchema.extend({ type: z.literal("mainMessageAppended"), message: PickyMainAgentMessageSchema }),
  EventBaseSchema.extend({ type: z.literal("mainAgentModelsSnapshot"), models: z.array(PickyMainAgentModelOptionSchema) }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeStateChanged"), state: MainRealtimeStateSchema, message: z.string().optional() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeInputTranscriptDelta"), inputId: z.string(), delta: z.string() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeInputTranscriptCompleted"), inputId: z.string(), transcript: z.string() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeOutputAudioDelta"), inputId: z.string().optional(), audioBase64: z.string() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeOutputAudioDone"), inputId: z.string().optional() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeOutputTranscriptDelta"), inputId: z.string().optional(), delta: z.string() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeOutputTranscriptCompleted"), inputId: z.string().optional(), transcript: z.string() }),
  EventBaseSchema.extend({ type: z.literal("mainRealtimeTurnDone"), inputId: z.string().optional(), status: MainRealtimeTurnStatusSchema, finalTranscript: z.string().optional() }),
  EventBaseSchema.extend({ type: z.literal("sessionSnapshot"), sessions: z.array(PickyAgentSessionSchema) }),
  EventBaseSchema.extend({ type: z.literal("sessionUpdated"), session: PickyAgentSessionSchema }),
  EventBaseSchema.extend({ type: z.literal("sessionLogAppended"), sessionId: z.string(), line: z.string() }),
  EventBaseSchema.extend({ type: z.literal("toolActivityUpdated"), sessionId: z.string(), tool: PickyToolActivitySchema }),
  EventBaseSchema.extend({ type: z.literal("extensionUiRequest"), request: PickyExtensionUiRequestSchema }),
  EventBaseSchema.extend({ type: z.literal("artifactUpdated"), sessionId: z.string(), artifact: PickyArtifactSchema }),
  EventBaseSchema.extend({ type: z.literal("pointerOverlayRequested"), request: PickyPointerOverlayRequestSchema }),
  EventBaseSchema.extend({ type: z.literal("slashCommandsSnapshot"), sessionId: z.string(), commands: z.array(PickySlashCommandSchema) }),
  EventBaseSchema.extend({ type: z.literal("sessionMessageAppended"), sessionId: z.string(), message: PickySessionMessageSchema, seq: z.number().int() }),
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

export function parseEvent(input: unknown): EventEnvelope {
  return EventEnvelopeSchema.parse(input);
}
