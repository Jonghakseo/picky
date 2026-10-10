import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { LoadExtensionsResult, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { AgentdServer, APP_PICKLE_HANDOFF_UNAVAILABLE, type AppPickleBridgeRequest, type AppPickleBridgeResult, type AppPickleHandoffRequest, type AppPickleHandoffResult } from "./server.js";
import { defaultAppSupportRoot } from "./artifact-store.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { PiSdkRuntime, type PiSdkRuntimeOptions } from "./runtime/pi-sdk-runtime.js";
import { qualifyAsyncProviders } from "./runtime/qualified-async-providers.js";
import { ConservativeMockTaskRouter } from "./task-router.js";
import { createPickyAskUserQuestionTool } from "./runtime/ask-user-question-tool.js";
import { createReadPickyUserGuideTool, readPickyUserGuide } from "./runtime/user-guide-tool.js";
import { stabilizeProcessCwd, type ProcessCwdStabilizerResult } from "./process-cwd.js";
import { ThinkingLevelSchema, type ThinkingLevel } from "./protocol.js";
import type { AgentRuntime, RuntimeTextCompleter } from "./runtime/types.js";
import { logAgentd } from "./local-log.js";
import { buildPickyRuntimeContract } from "./domain/picky-runtime-contract.js";
import { createPickyRuntimeContractExtension } from "./runtime/picky-runtime-contract-extension.js";
import { EdgeTTSService } from "./edge-tts-service.js";
import { PiOAuthService } from "./runtime/pi-oauth-service.js";
import { PiSubscriptionCredentials } from "./runtime/pi-subscription-credentials.js";
import { UsageLimitsService } from "./application/usage-limits-service.js";
import { PiTextCompleter } from "./runtime/pi-text-completer.js";
import { HubStatisticsService } from "./application/hub-statistics-service.js";
import { PickleClassifier } from "./application/pickle-classifier.js";
import { MainTaskService } from "./application/main-task-service.js";
import { MAIN_TASK_MAX_CONCURRENCY } from "./domain/main-task-policy.js";
import { createPickyTaskWorkerFactory, MainTaskEvaluationContext } from "./runtime/task/picky-task-runtime.js";
import { createMainTaskTool, createPickleDelegationTool } from "./runtime/main-task-tools.js";
import type { PickyContextPacket } from "./protocol.js";

/** Primary-only, and real provider endpoints only: the mock runtime has no Pi credentials to check. */
function createUsageLimitsService(config: Pick<AgentdConfig, "mode" | "useMockRuntime">): UsageLimitsService | undefined {
  return config.mode === "primary" && !config.useMockRuntime
    ? new UsageLimitsService({ credentials: new PiSubscriptionCredentials() })
    : undefined;
}

export type AgentdMode = "primary" | "child";

export interface AgentdConfig {
  mode: AgentdMode;
  port: number;
  token: string;
  appSupportDir: string;
  defaultCwd: string;
  mainAgentCwd: string;
  mainAgentThinkingLevel: ThinkingLevel;
  mainAgentModelPattern?: string;
  pickleThinkingLevel?: ThinkingLevel;
  pickleModelPattern?: string;
  useMockRuntime: boolean;
  asyncTaskRollout?: "on" | "drain";
  /** Auto-delete archived Pickles past the retention window on load. Off only when the app sends "0". */
  purgeStaleArchivedSessions?: boolean;
  sessionId?: string;
  sessionCwd?: string;
  primaryUrl?: string;
}

interface ComposeOverrides {
  runtimeFactory?: (config: AgentdConfig) => AgentRuntime;
  mainRuntimeFactory?: (config: AgentdConfig, supervisorRef: { current?: SessionSupervisor }, currentDefaultCwd: { value: string }) => AgentRuntime | undefined;
  stabilizeCwd?: (targetDir: string) => ProcessCwdStabilizerResult;
  asyncProviderCapsule?: { root: string; lockPath: string };
  /** Builds every Pi SDK runtime (Pickle and main). Tests wrap it to observe the composed options. */
  createPiSdkRuntime?: (options: PiSdkRuntimeOptions) => PiSdkRuntime;
}

interface ComposeResult {
  config: AgentdConfig;
  supervisor: SessionSupervisor;
  server: AgentdServer;
  runtime: AgentRuntime;
  mainRuntime?: AgentRuntime;
  cwdStabilization?: ProcessCwdStabilizerResult;
  currentDefaultCwd: { value: string };
  // Child mode only: exposed so the caller (index.ts) can consume the single-use issuance
  // after `supervisor.load()` rehydrates the scoped session, preventing a replayed `createTask`
  // from minting the same id again and silently overwriting persisted state.
  sessionIdFactory?: () => string;
  pickleClassifier?: PickleClassifier;
  /** Primary daemon with a real main runtime only. Closed on shutdown so workers stop with the daemon. */
  mainTasks?: MainTaskService;
}

export function parseAgentdConfig(env: NodeJS.ProcessEnv): AgentdConfig {
  const token = env.PICKY_AGENTD_TOKEN;
  if (!token) throw new Error("PICKY_AGENTD_TOKEN is required");

  const mode = parseAgentdMode(env.PICKY_AGENTD_MODE);
  const sessionId = env.PICKY_AGENTD_SESSION_ID?.trim() || undefined;
  const sessionCwd = env.PICKY_AGENTD_SESSION_CWD?.trim() || undefined;
  assertChildAgentdConfig(mode, sessionId, sessionCwd);

  const initialDefaultCwd = mode === "child"
    ? sessionCwd!
    : (env.PICKY_DEFAULT_CWD ?? process.cwd());

  return {
    mode,
    port: parseAgentdPort(mode, env.PICKY_AGENTD_PORT),
    token,
    appSupportDir: env.PICKY_APP_SUPPORT_DIR ?? defaultAppSupportRoot(),
    defaultCwd: initialDefaultCwd,
    mainAgentCwd: env.PICKY_MAIN_AGENT_CWD ?? initialDefaultCwd,
    mainAgentThinkingLevel: parseThinkingLevel(env.PICKY_MAIN_AGENT_THINKING_LEVEL, { fallback: "medium", label: "main" }) ?? "medium",
    mainAgentModelPattern: env.PICKY_MAIN_AGENT_MODEL?.trim() || undefined,
    pickleThinkingLevel: parseThinkingLevel(env.PICKY_PICKLE_THINKING_LEVEL, { label: "pickle" }),
    pickleModelPattern: env.PICKY_PICKLE_MODEL?.trim() || undefined,
    useMockRuntime: env.PICKY_AGENTD_RUNTIME === "mock",
    asyncTaskRollout: parseAsyncTaskRollout(env.PICKY_ASYNC_TASK_ROLLOUT),
    purgeStaleArchivedSessions: env.PICKY_ARCHIVED_PICKLE_AUTO_DELETE !== "0",
    sessionId,
    sessionCwd,
    primaryUrl: env.PICKY_AGENTD_PRIMARY_URL?.trim() || undefined,
  };
}

function parseAsyncTaskRollout(value: string | undefined): "on" | "drain" {
  if (!value || value === "on") return "on";
  if (value === "drain") return value;
  throw new Error(`Invalid PICKY_ASYNC_TASK_ROLLOUT: ${JSON.stringify(value)}`);
}

function parseAgentdMode(value: string | undefined): AgentdMode {
  const mode = value?.trim();
  if (mode === undefined || mode === "" || mode === "primary") return "primary";
  if (mode === "child") return "child";
  throw new Error(`Unknown PICKY_AGENTD_MODE: ${JSON.stringify(mode)} (expected "primary" | "child")`);
}

function assertChildAgentdConfig(mode: AgentdMode, sessionId: string | undefined, sessionCwd: string | undefined): void {
  if (mode !== "child") return;
  if (!sessionId) throw new Error("PICKY_AGENTD_SESSION_ID is required in child mode");
  if (!sessionCwd) throw new Error("PICKY_AGENTD_SESSION_CWD is required in child mode");
}

function parseAgentdPort(mode: AgentdMode, value: string | undefined): number {
  // Child daemons bind to an OS-assigned port; the parent reads the bound port from the
  // `picky-agentd listening on …` stdout line. Ignore inherited primary ports in child mode.
  if (mode === "child") return 0;
  const port = value?.trim();
  if (port === undefined || port === "") return 17631;
  if (!/^[0-9]+$/.test(port) || Number(port) > 65535) {
    throw new Error(`Invalid PICKY_AGENTD_PORT: ${JSON.stringify(port)}`);
  }
  return Number(port);
}

function describeStabilizationError(error: unknown): string {
  if (!error) return "unknown error";
  if (error instanceof Error) return error.message;
  return String(error);
}

// Child daemons host exactly one session whose id is set by the parent through
// PICKY_AGENTD_SESSION_ID. The first call returns that id; the second call throws so the daemon
// fails loudly if anything tries to create more than one session inside a single child process
// (e.g. an attempt to fan a primary's main-agent tools out from inside a child).
export function createSingleUseSessionIdFactory(sessionId: string): () => string {
  let issued = false;
  return () => {
    if (issued) throw new Error(`Child daemon already issued its single session id ${sessionId}`);
    issued = true;
    return sessionId;
  };
}

function parseThinkingLevel(value: string | undefined, options: { label: string; fallback?: ThinkingLevel }): ThinkingLevel | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return options.fallback;
  const parsed = ThinkingLevelSchema.safeParse(trimmed);
  if (parsed.success) return parsed.data;
  logAgentd(`invalid ${options.label} thinking level`, { value: trimmed, fallback: options.fallback ?? "global" });
  return options.fallback;
}

function stabilizeChildCwd(config: AgentdConfig, override?: (targetDir: string) => ProcessCwdStabilizerResult): ProcessCwdStabilizerResult | undefined {
  if (config.mode !== "child" || !config.sessionCwd) return undefined;
  const cwdStabilization = (override ?? stabilizeProcessCwd)(config.sessionCwd);
  logAgentd("child cwd stabilized", { sessionId: config.sessionId, cwd: cwdStabilization.cwd, ok: cwdStabilization.ok ? 1 : 0 });
  if (!cwdStabilization.ok) {
    throw new Error(`Failed to stabilize child cwd ${config.sessionCwd}: ${describeStabilizationError(cwdStabilization.error)}`);
  }
  return cwdStabilization;
}

export function composeAgentdServices(config: AgentdConfig, overrides: ComposeOverrides = {}): ComposeResult {
  const cwdStabilization = stabilizeChildCwd(config, overrides.stabilizeCwd);

  const currentDefaultCwd = { value: config.defaultCwd };
  const supervisorRef: { current?: SessionSupervisor } = {};
  const appPickleBridgeRef: { current?: (request: AppPickleBridgeRequest) => Promise<AppPickleBridgeResult> } = {};
  const appPickleHandoffRef: { current?: (request: AppPickleHandoffRequest) => Promise<AppPickleHandoffResult> } = {};
  const { runtime, hostedAsync } = createPickleRuntime(config, overrides);

  // The primary main agent delegates through the real `picky` CLI using its existing bash tool.
  // Child daemons run one Pickle session and never receive that primary-only CLI environment.
  const mainTaskBundle = createMainTaskBundle(config, overrides, currentDefaultCwd, appPickleHandoffRef);
  const mainTaskOptions = mainTaskBundle ? { mainTasks: mainTaskBundle.service } : {};
  const primaryMain = config.mode === "primary"
    ? buildPrimaryMainRuntime(config, supervisorRef, currentDefaultCwd, overrides, mainTaskBundle)
    : undefined;
  const mainRuntime = primaryMain?.runtime;
  const mainCustomToolsBuilder = primaryMain?.toolsBuilder;
  const onDisabledBuiltinToolsChanged = primaryMain?.onDisabledBuiltinToolsChanged;

  const store = new SessionStore(config.appSupportDir, config.mode === "child" ? { scopeSessionId: config.sessionId } : undefined);

  const sessionIdFactory = config.mode === "child" && config.sessionId
    ? createSingleUseSessionIdFactory(config.sessionId)
    : undefined;
  // Every Pickle completion goes through the app-owned coordinator so its
  // Main Picky/macOS/Both destination is honored. This includes external CLI
  // Pickles hosted by the primary daemon as well as per-Pickle child daemons.
  const forwardPickleCompletionToPrimary = async (request: {
    sessionId: string;
    prompt: string;
    cwd?: string;
    completionId: string;
    title: string;
    status: "completed";
    summary?: string;
    notifyMainOnCompletion: boolean;
    notifyMacOSOnCompletion: boolean;
  }) => {
    if (!appPickleBridgeRef.current) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    await appPickleBridgeRef.current({ operation: "notifyMainOfPickleCompletion", ...request });
  };
  const supervisor = new SessionSupervisor(runtime, store, {
    taskRouter: config.useMockRuntime ? new ConservativeMockTaskRouter() : undefined,
    mainRuntime,
    sessionIdFactory,
    purgeStaleArchivedSessions: config.purgeStaleArchivedSessions,
    enableAsyncTasksForSession: (id) => canHostAsyncTasks(config, supervisorRef, hostedAsync, id),
    forwardPickleCompletionToPrimary,
    mainCustomToolsBuilder,
    onDisabledBuiltinToolsChanged,
    ...mainTaskOptions,
  });
  supervisorRef.current = supervisor;

  const hubStatistics = config.mode === "primary" ? new HubStatisticsService(config.appSupportDir) : undefined;
  const pickleClassifier = hubStatistics
    ? new PickleClassifier({
        statistics: hubStatistics,
        completer: config.useMockRuntime ? (hasTextCompletion(runtime) ? runtime : new MockRuntime()) : new PiTextCompleter({ cwd: config.mainAgentCwd }),
      })
    : undefined;
  void pickleClassifier?.start();

  const server = new AgentdServer({
    port: config.port,
    token: config.token,
    supervisor,
    setDefaultCwd: (cwd) => {
      currentDefaultCwd.value = cwd;
      logAgentd("default cwd updated", { defaultCwd: cwd });
    },
    getDefaultCwd: () => currentDefaultCwd.value,
    // Edge Read Aloud is a primary-only opt-in adapter. A child daemon must
    // never expose this route because it is not the app-owned daemon whose
    // connection token is published to the Settings client.
    edgeTTS: config.mode === "primary" ? new EdgeTTSService() : undefined,
    piOAuth: config.mode === "primary" ? new PiOAuthService() : undefined,
    hubStatistics,
    pickleClassifier,
    usageLimits: createUsageLimitsService(config),
    ...mainTaskServerOptions(mainTaskBundle),
  });
  appPickleBridgeRef.current = (request) => server.requestPickleBridgeFromApp(request);
  // Creating the Pickle may spawn its daemon; allow longer than a CLI round-trip.
  appPickleHandoffRef.current = (request) => server.requestPickleHandoffFromApp(request, 20_000);

  return {
    config,
    supervisor,
    server,
    runtime,
    mainRuntime,
    cwdStabilization,
    currentDefaultCwd,
    sessionIdFactory,
    pickleClassifier,
    ...mainTaskOptions,
  };
}

interface MainTaskBundle {
  service: MainTaskService;
  evaluation: MainTaskEvaluationContext;
}

/** What the wire needs from the Task bundle: the service, and the per-level model settings. */
function mainTaskServerOptions(bundle: MainTaskBundle | undefined): { mainTasks?: MainTaskService; mainTaskModels?: MainTaskEvaluationContext } {
  return bundle ? { mainTasks: bundle.service, mainTaskModels: bundle.evaluation } : {};
}

/**
 * The main agent's Task service: Picky-owned workers, decisions, and the Pickle handoff route.
 * Primary daemon with the real main runtime only; the mock runtime has no Pi to run workers with.
 */
function createMainTaskBundle(
  config: AgentdConfig,
  overrides: ComposeOverrides,
  currentDefaultCwd: { value: string },
  appPickleHandoffRef: { current?: (request: AppPickleHandoffRequest) => Promise<AppPickleHandoffResult> },
): MainTaskBundle | undefined {
  if (config.mode !== "primary" || config.useMockRuntime || overrides.mainRuntimeFactory) return undefined;
  const evaluation = new MainTaskEvaluationContext();
  const service = new MainTaskService({
    directory: join(config.appSupportDir, "main-tasks"),
    maxConcurrency: MAIN_TASK_MAX_CONCURRENCY,
    createWorker: createPickyTaskWorkerFactory({ internalBinDir: join(config.appSupportDir, "bin") }),
    evaluate: (record, snapshot, signal) => evaluation.evaluate(record, snapshot, signal),
    createPickle: async (request) => {
      if (!appPickleHandoffRef.current) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
      const cwd = request.cwd ?? currentDefaultCwd.value;
      const result = await appPickleHandoffRef.current({
        context: request.context ?? neutralHandoffContext(cwd),
        title: request.title,
        instructions: request.instructions,
        cwd,
      });
      return { sessionId: result.sessionId };
    },
    // The configured Pickle folder is often a product repository; an everyday Task must not load
    // its project rules. The main agent's workspace would load Picky's own persona instead.
    defaultCwd: () => homedir(),
    log: (message, fields) => logAgentd(message, fields ?? {}),
  });
  return { service, evaluation };
}

function neutralHandoffContext(cwd: string): PickyContextPacket {
  return { id: `context-task-${randomUUID()}`, source: "system", capturedAt: new Date().toISOString(), cwd, screenshots: [], inkMarks: [], warnings: [] };
}

/** A separately installed Task extension must not shadow Picky's built-in `Task` tool. */
function withoutExtensionTaskTools(base: LoadExtensionsResult): LoadExtensionsResult {
  return {
    ...base,
    extensions: base.extensions.map((extension) => {
      if (!extension.tools.has("Task")) return extension;
      return { ...extension, tools: new Map([...extension.tools].filter(([name]) => name !== "Task")) };
    }),
  };
}

function hasTextCompletion(runtime: AgentRuntime): runtime is AgentRuntime & RuntimeTextCompleter {
  return "complete" in runtime && typeof runtime.complete === "function";
}

function canHostAsyncTasks(config: AgentdConfig, supervisorRef: { current?: SessionSupervisor }, hostedAsync: boolean, id: string): boolean {
  if (config.mode === "child" && id !== config.sessionId) return false;
  return hostedAsync || supervisorRef.current?.get(id)?.asyncWorkSummary !== undefined;
}

function asyncAdmissionDraining(config: AgentdConfig): boolean {
  try {
    // This local file is an immediate, reversible gate for already-live handles.
    // Invalid content or I/O failure must never reopen new work by accident.
    return readFileSync(join(config.appSupportDir, "async-task-rollout"), "utf8").trim() !== "on";
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return true;
    return config.asyncTaskRollout === "drain";
  }
}

function createPickleRuntime(config: AgentdConfig, overrides: ComposeOverrides): { runtime: AgentRuntime; hostedAsync: boolean } {
  const capsule = config.useMockRuntime ? undefined : qualifyAsyncProviders(overrides.asyncProviderCapsule?.root, overrides.asyncProviderCapsule?.lockPath);
  const hostedAsync = capsule !== undefined;
  logAgentd("async task rollout", { requested: config.asyncTaskRollout ?? "on", capsuleQualified: hostedAsync });
  if (overrides.runtimeFactory) return { runtime: overrides.runtimeFactory(config), hostedAsync };
  if (config.useMockRuntime) return { runtime: new MockRuntime(), hostedAsync };
  const createPiSdkRuntime = overrides.createPiSdkRuntime ?? ((options: PiSdkRuntimeOptions) => new PiSdkRuntime(options));
  return { runtime: createPiSdkRuntime({
    thinkingLevel: config.pickleThinkingLevel,
    modelPattern: config.pickleModelPattern,
    customTools: [createPickyAskUserQuestionTool()],
    // Even without a qualified capsule, Pickles must reject legacy async tools.
    // An empty allowlist keeps unrelated global extensions available.
    asyncProviderPaths: capsule?.paths ?? [],
    asyncAdmissionDrain: () => asyncAdmissionDraining(config),
    asyncProvidersQualified: hostedAsync,
    mcpTarget: "pickle",
  }), hostedAsync };
}

// Called by index.ts after `supervisor.load()` in child mode. If a scoped session for the
// configured PICKY_AGENTD_SESSION_ID is already persisted (i.e. the child is resuming after a
// crash/restart), consume the single-use factory's first issuance so that a stray createTask
// from the client cannot reuse the same id and overwrite the hydrated session.
export function primeSessionIdFactoryForResume(result: ComposeResult): "consumed" | "fresh" | "not-applicable" {
  if (result.config.mode !== "child" || !result.sessionIdFactory || !result.config.sessionId) return "not-applicable";
  if (result.supervisor.get(result.config.sessionId)) {
    result.sessionIdFactory();
    logAgentd("child session resumed; sessionIdFactory pre-consumed", { sessionId: result.config.sessionId });
    return "consumed";
  }
  return "fresh";
}

interface PrimaryMainRuntimeBundle {
  runtime: AgentRuntime;
  toolsBuilder: (disabled: ReadonlySet<string>) => ToolDefinition[];
  /** Lets the supervisor publish toggle changes into the runtime's system-prompt contract. */
  onDisabledBuiltinToolsChanged: (disabled: ReadonlySet<string>) => void;
}

function buildPrimaryMainRuntime(
  config: AgentdConfig,
  supervisorRef: { current?: SessionSupervisor },
  currentDefaultCwd: { value: string },
  overrides: ComposeOverrides,
  mainTasks?: MainTaskBundle,
): PrimaryMainRuntimeBundle | undefined {
  if (config.useMockRuntime) return undefined;
  if (overrides.mainRuntimeFactory) {
    const overridden = overrides.mainRuntimeFactory(config, supervisorRef, currentDefaultCwd);
    if (!overridden) return undefined;
    return { runtime: overridden, toolsBuilder: () => [], onDisabledBuiltinToolsChanged: () => {} };
  }

  // Picky-specific main-agent tools that are not CLI operations. Pickle delegation itself
  // intentionally uses the real `picky` command through Pi's existing bash tool.
  const allBuiltinTools: ToolDefinition[] = [
    createPickyAskUserQuestionTool(),
    createReadPickyUserGuideTool(readPickyUserGuide),
    ...(mainTasks ? [createMainTaskTool(mainTasks.service, mainTasks.evaluation), createPickleDelegationTool(mainTasks.service)] : []),
  ];
  const toolsBuilder = (disabled: ReadonlySet<string>) => allBuiltinTools.filter((tool) => !disabled.has(tool.name));

  // Read at turn time by the contract extension, so a settings toggle reaches the next system
  // prompt without recreating the main handle.
  let disabledMainBuiltinTools: ReadonlySet<string> = new Set();

  const createPiSdkRuntime = overrides.createPiSdkRuntime ?? ((options: PiSdkRuntimeOptions) => new PiSdkRuntime(options));
  const piMainRuntime = createPiSdkRuntime({
    thinkingLevel: config.mainAgentThinkingLevel,
    modelPattern: config.mainAgentModelPattern,
    // The main overlay can answer ask_user_question, but has no surface for other
    // blocking dialogs. Keep those rejected so an unsupported extension call cannot hang.
    disableBlockingDialogs: true,
    allowedBlockingDialogMethods: ["askUserQuestion"],
    customTools: toolsBuilder(new Set()),
    mcpTarget: "main",
    // Standing rules ride the system prompt instead of a transcript message, so compaction,
    // resume, and stale session files cannot drop them. Pi appends inline extensions after
    // discovered user extensions, so this runs as a late `before_agent_start` modifier.
    resourceLoaderOptions: {
      extensionFactories: [
        createPickyRuntimeContractExtension(() => buildPickyRuntimeContract(disabledMainBuiltinTools)),
        ...(mainTasks ? [mainTasks.evaluation.extension()] : []),
      ],
      ...(mainTasks ? { extensionsOverride: withoutExtensionTaskTools } : {}),
    },
  });

  return {
    runtime: piMainRuntime,
    toolsBuilder,
    onDisabledBuiltinToolsChanged: (disabled) => {
      disabledMainBuiltinTools = disabled;
    },
  };
}
