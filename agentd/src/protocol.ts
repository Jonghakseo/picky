import { z } from "zod";

export const PROTOCOL_VERSION = "2026-05-01";

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

export const ScreenshotSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  path: z.string().min(1),
  screenId: z.string().optional(),
  bounds: z
    .object({ x: z.number(), y: z.number(), width: z.number(), height: z.number() })
    .optional(),
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
  warnings: z.array(z.string()).default([]),
});

export type PickyContextPacket = z.infer<typeof PickyContextPacketSchema>;

export const PickyChangedFileSchema = z.object({ path: z.string(), status: z.string(), summary: z.string().optional() });
export const PickyArtifactSchema = z.object({ id: z.string(), kind: z.string(), title: z.string(), path: z.string().optional(), url: z.string().url().optional(), updatedAt: isoTimestamp });
export type PickyArtifact = z.infer<typeof PickyArtifactSchema>;
export const PickyToolActivitySchema = z.object({ toolCallId: z.string(), name: z.string(), status: z.enum(["running", "succeeded", "failed"]), preview: z.string().optional(), startedAt: isoTimestamp.optional(), endedAt: isoTimestamp.optional() });
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
  createdAt: isoTimestamp,
});
export type PickyExtensionUiRequest = z.infer<typeof PickyExtensionUiRequestSchema>;

export const PickyAgentSessionSchema = z.object({
  id: z.string(),
  title: z.string(),
  status: SessionStatusSchema,
  cwd: z.string().optional(),
  createdAt: isoTimestamp,
  updatedAt: isoTimestamp,
  lastSummary: z.string().optional(),
  finalAnswer: z.string().optional(),
  logs: z.array(z.string()).default([]),
  tools: z.array(PickyToolActivitySchema).default([]),
  artifacts: z.array(PickyArtifactSchema).default([]),
  changedFiles: z.array(PickyChangedFileSchema).default([]),
  pendingExtensionUiRequest: PickyExtensionUiRequestSchema.optional(),
  notifyMainOnCompletion: z.boolean().optional(),
});

export type PickyAgentSession = z.infer<typeof PickyAgentSessionSchema>;

const CommandBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION) });
export const CommandEnvelopeSchema = z.discriminatedUnion("type", [
  CommandBaseSchema.extend({ type: z.literal("routeTask"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("createTask"), context: PickyContextPacketSchema }),
  CommandBaseSchema.extend({ type: z.literal("pinSideSession"), context: PickyContextPacketSchema, title: z.string().min(1).optional() }),
  CommandBaseSchema.extend({ type: z.literal("setNotifyMainOnCompletion"), sessionId: z.string(), enabled: z.boolean() }),
  CommandBaseSchema.extend({ type: z.literal("followUp"), sessionId: z.string(), text: z.string().min(1), context: PickyContextPacketSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("steer"), sessionId: z.string(), text: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("abort"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("listSessions") }),
  CommandBaseSchema.extend({ type: z.literal("getSession"), sessionId: z.string() }),
  CommandBaseSchema.extend({ type: z.literal("answerExtensionUi"), sessionId: z.string(), requestId: z.string(), value: z.unknown().optional() }),
  CommandBaseSchema.extend({ type: z.literal("openArtifact"), sessionId: z.string(), artifactId: z.string() }),
]);

export type CommandEnvelope = z.infer<typeof CommandEnvelopeSchema>;

const EventBaseSchema = z.object({ id: z.string(), protocolVersion: z.literal(PROTOCOL_VERSION), timestamp: isoTimestamp });
export const EventEnvelopeSchema = z.discriminatedUnion("type", [
  EventBaseSchema.extend({ type: z.literal("hello"), serverName: z.literal("picky-agentd"), supportedProtocolVersions: z.array(z.string()) }),
  EventBaseSchema.extend({ type: z.literal("quickReply"), contextId: z.string(), text: z.string().min(1) }),
  EventBaseSchema.extend({ type: z.literal("sessionSnapshot"), sessions: z.array(PickyAgentSessionSchema) }),
  EventBaseSchema.extend({ type: z.literal("sessionUpdated"), session: PickyAgentSessionSchema }),
  EventBaseSchema.extend({ type: z.literal("sessionLogAppended"), sessionId: z.string(), line: z.string() }),
  EventBaseSchema.extend({ type: z.literal("toolActivityUpdated"), sessionId: z.string(), tool: PickyToolActivitySchema }),
  EventBaseSchema.extend({ type: z.literal("extensionUiRequest"), request: PickyExtensionUiRequestSchema }),
  EventBaseSchema.extend({ type: z.literal("artifactUpdated"), sessionId: z.string(), artifact: PickyArtifactSchema }),
  EventBaseSchema.extend({ type: z.literal("artifactOpened"), sessionId: z.string(), artifactId: z.string(), path: z.string() }),
  EventBaseSchema.extend({ type: z.literal("error"), code: z.string(), message: z.string(), commandId: z.string().optional() }),
]);

export type EventEnvelope = z.infer<typeof EventEnvelopeSchema>;

export function parseCommand(input: unknown): CommandEnvelope {
  return CommandEnvelopeSchema.parse(input);
}

export function parseEvent(input: unknown): EventEnvelope {
  return EventEnvelopeSchema.parse(input);
}
