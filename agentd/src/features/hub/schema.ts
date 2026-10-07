import { z } from "zod";
import { CommandBaseSchema, EventBaseSchema, isoTimestamp } from "../../protocol-base.js";

/** `all`: the main agent and every Pickle connect to the server. `main`: the main agent only. */
export const PickyMcpScopeSchema = z.enum(["all", "main"]);
export type PickyMcpScope = z.infer<typeof PickyMcpScopeSchema>;

export const PickyMcpServerSchema = z.object({
  name: z.string().min(1),
  pickyScope: PickyMcpScopeSchema,
  enabled: z.boolean(),
  exposure: z.string(),
  transport: z.string(),
  state: z.enum(["disabled", "connecting", "connected", "disconnected", "needs-auth", "failed", "closed"]),
  tools: z.array(z.string()),
  error: z.string().optional(),
  usesOAuth: z.boolean(),
});

const PickyHubWorkCategorySchema = z.enum(["fix", "research", "create", "review", "unclassified"]);
const PickyHubPickleRecordSchema = z.object({
  id: z.string(),
  title: z.string(),
  project: z.string(),
  cwd: z.string().nullable().optional(),
  createdAt: isoTimestamp,
  lastActivityAt: isoTimestamp,
  followUpCount: z.number().int().nonnegative(),
  delegationCount: z.number().int().nonnegative(),
  reviewCount: z.number().int().nonnegative(),
  category: PickyHubWorkCategorySchema,
  // Added after the first Hub statistics release; older payloads omit them.
  changedFileCount: z.number().int().nonnegative().default(0),
  artifactCount: z.number().int().nonnegative().default(0),
  toolCallCount: z.number().int().nonnegative().default(0),
  subagentCount: z.number().int().nonnegative().default(0),
  activeDurationMs: z.number().int().nonnegative().default(0),
  totalTokens: z.number().int().nonnegative().default(0),
});
const PickyHubUsageSampleSchema = z.object({
  day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  provider: z.string(),
  model: z.string(),
  project: z.string().nullable().optional(),
  inputTokens: z.number().int().nonnegative(),
  outputTokens: z.number().int().nonnegative(),
  cacheTokens: z.number().int().nonnegative(),
});
export const PickyHubStatisticsSnapshotSchema = z.object({
  generatedAt: isoTimestamp,
  records: z.array(PickyHubPickleRecordSchema),
  usageSamples: z.array(PickyHubUsageSampleSchema),
  pendingClassificationCount: z.number().int().nonnegative(),
  // Legacy snapshots predate the consent field. Treat omission as disabled.
  classificationEnabled: z.boolean().default(false),
});
export type PickyHubStatisticsSnapshot = z.infer<typeof PickyHubStatisticsSnapshotSchema>;

/**
 * The Hub tab: MCP server administration plus local Pickle statistics.
 *
 * `reloadPlugins` deliberately stays in `server.ts`. It reaches into live
 * sessions (queued `/reload` follow-ups, session logs), so it is not a
 * session-state-free Hub command and would blur what this slice measures.
 */
export const hubCommandSchemas = [
  CommandBaseSchema.extend({ type: z.literal("listMcpServers") }),
  CommandBaseSchema.extend({ type: z.literal("addMcpServer"), name: z.string().min(1), configJson: z.string().min(1), pickyScope: PickyMcpScopeSchema }),
  CommandBaseSchema.extend({ type: z.literal("updateMcpServer"), name: z.string().min(1), enabled: z.boolean().optional(), pickyScope: PickyMcpScopeSchema.optional() }),
  CommandBaseSchema.extend({ type: z.literal("removeMcpServer"), name: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("signInMcpServer"), name: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("signOutMcpServer"), name: z.string().min(1) }),
  CommandBaseSchema.extend({ type: z.literal("getHubStatistics") }),
  CommandBaseSchema.extend({ type: z.literal("resetHubStatistics") }),
  CommandBaseSchema.extend({ type: z.literal("configureHubStatistics"), classificationEnabled: z.boolean() }),
] as const;

export const hubEventSchemas = [
  EventBaseSchema.extend({
    type: z.literal("hubStatisticsResult"),
    commandId: z.string().min(1),
    ok: z.boolean(),
    errorMessage: z.string().nullable().optional(),
    snapshot: PickyHubStatisticsSnapshotSchema.optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("mcpServerList"),
    commandId: z.string().min(1),
    ok: z.boolean(),
    configPath: z.string().optional(),
    servers: z.array(PickyMcpServerSchema),
    configErrors: z.array(z.string()),
    errorMessage: z.string().optional(),
  }),
  EventBaseSchema.extend({
    type: z.literal("mcpServerOperationCompleted"),
    requestId: z.string().min(1),
    operation: z.enum(["add", "update", "remove", "signIn", "signOut"]),
    name: z.string().min(1),
    ok: z.boolean(),
    errorCode: z.enum(["duplicate", "invalid", "notFound"]).optional(),
    errorMessage: z.string().optional(),
  }),
] as const;
