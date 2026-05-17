import { AgentdServer, APP_PICKLE_HANDOFF_UNAVAILABLE, type AppPickleBridgeRequest, type AppPickleBridgeResult, type AppPickleHandoffRequest, type AppPickleHandoffResult } from "./server.js";
import { defaultAppSupportRoot } from "./artifact-store.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { PiSdkRuntime } from "./runtime/pi-sdk-runtime.js";
import { ConservativeMockTaskRouter } from "./task-router.js";
import { createPickyAbortPickleTool, createPickyPickleSessionsTool, createPickyStartPickleTool, createPickySteerPickleTool, type PickyHandoffRequest, type PickyPickleAbortRequest, type PickyPickleSteerRequest } from "./application/handoff-tool.js";
import { createPickyAskUserQuestionTool } from "./application/ask-user-question-tool.js";
import { createReadPickyUserGuideTool, readPickyUserGuide } from "./application/user-guide-tool.js";
import { stabilizeProcessCwd, type ProcessCwdStabilizerResult } from "./process-cwd.js";
import { ThinkingLevelSchema, type ThinkingLevel } from "./protocol.js";
import type { AgentRuntime } from "./runtime/types.js";
import { logAgentd } from "./local-log.js";

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
  sessionId?: string;
  sessionCwd?: string;
  primaryUrl?: string;
}

interface ComposeOverrides {
  runtimeFactory?: (config: AgentdConfig) => AgentRuntime;
  mainRuntimeFactory?: (config: AgentdConfig, supervisorRef: { current?: SessionSupervisor }, currentDefaultCwd: { value: string }) => AgentRuntime | undefined;
  stabilizeCwd?: (targetDir: string) => ProcessCwdStabilizerResult;
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
}

export function parseAgentdConfig(env: NodeJS.ProcessEnv): AgentdConfig {
  const token = env.PICKY_AGENTD_TOKEN;
  if (!token) throw new Error("PICKY_AGENTD_TOKEN is required");

  const rawMode = env.PICKY_AGENTD_MODE?.trim();
  let mode: AgentdMode;
  if (rawMode === undefined || rawMode === "" || rawMode === "primary") mode = "primary";
  else if (rawMode === "child") mode = "child";
  else throw new Error(`Unknown PICKY_AGENTD_MODE: ${JSON.stringify(rawMode)} (expected "primary" | "child")`);

  if (mode === "child") {
    if (!env.PICKY_AGENTD_SESSION_ID?.trim()) throw new Error("PICKY_AGENTD_SESSION_ID is required in child mode");
    if (!env.PICKY_AGENTD_SESSION_CWD?.trim()) throw new Error("PICKY_AGENTD_SESSION_CWD is required in child mode");
  }

  const appSupportDir = env.PICKY_APP_SUPPORT_DIR ?? defaultAppSupportRoot();
  const initialDefaultCwd = mode === "child"
    ? env.PICKY_AGENTD_SESSION_CWD!.trim()
    : (env.PICKY_DEFAULT_CWD ?? process.cwd());

  // Child daemons bind to an OS-assigned port; the parent reads the bound port from the
  // `picky-agentd listening on …` stdout line. Primary keeps the historical default. We ignore
  // an inherited PICKY_AGENTD_PORT in child mode so children spawned by a primary that still has
  // that env exported do not race for the primary's pinned port. An empty string in primary mode
  // falls back to the default (matches the legacy `Number("") === 0` permissive behaviour from
  // before bootstrap split).
  const defaultPort = mode === "child" ? 0 : 17631;
  const portEnvRaw = mode === "child" ? undefined : env.PICKY_AGENTD_PORT?.trim();
  const portEnv = portEnvRaw === undefined || portEnvRaw === "" ? undefined : portEnvRaw;
  if (portEnv !== undefined && (!/^[0-9]+$/.test(portEnv) || Number(portEnv) > 65535)) {
    throw new Error(`Invalid PICKY_AGENTD_PORT: ${JSON.stringify(portEnv)}`);
  }
  const port = portEnv === undefined ? defaultPort : Number(portEnv);

  return {
    mode,
    port,
    token,
    appSupportDir,
    defaultCwd: initialDefaultCwd,
    mainAgentCwd: env.PICKY_MAIN_AGENT_CWD ?? initialDefaultCwd,
    mainAgentThinkingLevel: parseThinkingLevel(env.PICKY_MAIN_AGENT_THINKING_LEVEL, { fallback: "medium", label: "main" }) ?? "medium",
    mainAgentModelPattern: env.PICKY_MAIN_AGENT_MODEL?.trim() || undefined,
    pickleThinkingLevel: parseThinkingLevel(env.PICKY_PICKLE_THINKING_LEVEL, { label: "pickle" }),
    pickleModelPattern: env.PICKY_PICKLE_MODEL?.trim() || undefined,
    useMockRuntime: env.PICKY_AGENTD_RUNTIME === "mock",
    sessionId: env.PICKY_AGENTD_SESSION_ID?.trim() || undefined,
    sessionCwd: env.PICKY_AGENTD_SESSION_CWD?.trim() || undefined,
    primaryUrl: env.PICKY_AGENTD_PRIMARY_URL?.trim() || undefined,
  };
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

export function composeAgentdServices(config: AgentdConfig, overrides: ComposeOverrides = {}): ComposeResult {
  let cwdStabilization: ProcessCwdStabilizerResult | undefined;
  if (config.mode === "child" && config.sessionCwd) {
    const stabilize = overrides.stabilizeCwd ?? stabilizeProcessCwd;
    cwdStabilization = stabilize(config.sessionCwd);
    logAgentd("child cwd stabilized", { sessionId: config.sessionId, cwd: cwdStabilization.cwd, ok: cwdStabilization.ok ? 1 : 0 });
    if (!cwdStabilization.ok) {
      throw new Error(`Failed to stabilize child cwd ${config.sessionCwd}: ${describeStabilizationError(cwdStabilization.error)}`);
    }
  }

  const currentDefaultCwd = { value: config.defaultCwd };
  const supervisorRef: { current?: SessionSupervisor } = {};
  const appPickleHandoffRef: { current?: (request: AppPickleHandoffRequest) => Promise<AppPickleHandoffResult>; bridge?: (request: AppPickleBridgeRequest) => Promise<AppPickleBridgeResult> } = {};

  const runtime = overrides.runtimeFactory
    ? overrides.runtimeFactory(config)
    : config.useMockRuntime
      ? new MockRuntime()
      : new PiSdkRuntime({
          thinkingLevel: config.pickleThinkingLevel,
          modelPattern: config.pickleModelPattern,
          customTools: [createPickyAskUserQuestionTool()],
        });

  // Picky main-agent runtime + delegation tools (`picky_start_pickle`, `picky_pickle_sessions`,
  // `picky_steer_pickle`, `picky_open_pickle_response`) are primary-only. Child daemons run a
  // single Pickle session and must not register them — they would call back into the primary
  // supervisor that lives in a different process.
  const primaryMain = config.mode === "primary"
    ? buildPrimaryMainRuntime(config, supervisorRef, currentDefaultCwd, appPickleHandoffRef, overrides)
    : undefined;
  const mainRuntime = primaryMain?.runtime;
  const mainCustomToolsBuilder = primaryMain?.toolsBuilder;

  const store = new SessionStore(config.appSupportDir, config.mode === "child" ? { scopeSessionId: config.sessionId } : undefined);

  const sessionIdFactory = config.mode === "child" && config.sessionId
    ? createSingleUseSessionIdFactory(config.sessionId)
    : undefined;
  // Child daemons cannot followUp the main Picky agent themselves (mainRuntime is undefined per
  // `8aa986f Make per-Pickle runtime the only Pickle path`). When a per-Pickle bell toggle is on
  // and that Pickle completes, the supervisor falls back to this forwarder, which routes the
  // prebuilt prompt through the Picky app to the primary daemon's main agent. Primary daemons
  // never need the bridge (they own the main runtime in-process) and leave it undefined.
  const forwardPickleCompletionToPrimary = config.mode === "child"
    ? async (request: { sessionId: string; prompt: string; cwd?: string }) => {
        if (!appPickleHandoffRef.bridge) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
        await appPickleHandoffRef.bridge({ operation: "notifyMainOfPickleCompletion", ...request });
      }
    : undefined;
  const supervisor = new SessionSupervisor(runtime, store, {
    taskRouter: config.useMockRuntime ? new ConservativeMockTaskRouter() : undefined,
    mainRuntime,
    sessionIdFactory,
    forwardPickleCompletionToPrimary,
    mainCustomToolsBuilder,
  });
  supervisorRef.current = supervisor;

  // Picky agentd extension bridge. Pi extensions loaded from the workspace's
  // `.pi/extensions/` (notably `picky-tell-plan`) run in this Node process
  // and reach Picky's companion voice through this stable globalThis
  // interface. Keep the shape narrow and additive so seeded extensions can
  // depend on it.
  installPickyAgentdBridge(supervisor);

  const server = new AgentdServer({
    port: config.port,
    token: config.token,
    supervisor,
    setDefaultCwd: (cwd) => {
      currentDefaultCwd.value = cwd;
      logAgentd("default cwd updated", { defaultCwd: cwd });
    },
  });
  appPickleHandoffRef.current = (request) => server.requestPickleHandoffFromApp(request);
  appPickleHandoffRef.bridge = (request) => server.requestPickleBridgeFromApp(request);

  return {
    config,
    supervisor,
    server,
    runtime,
    mainRuntime,
    cwdStabilization,
    currentDefaultCwd,
    sessionIdFactory,
  };
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
  toolsBuilder: (disabled: ReadonlySet<string>) => import("@mariozechner/pi-coding-agent").ToolDefinition[];
}

function buildPrimaryMainRuntime(
  config: AgentdConfig,
  supervisorRef: { current?: SessionSupervisor },
  currentDefaultCwd: { value: string },
  appPickleHandoffRef: { current?: (request: AppPickleHandoffRequest) => Promise<AppPickleHandoffResult>; bridge?: (request: AppPickleBridgeRequest) => Promise<AppPickleBridgeResult> },
  overrides: ComposeOverrides,
): PrimaryMainRuntimeBundle | undefined {
  if (config.useMockRuntime) return undefined;
  if (overrides.mainRuntimeFactory) {
    const overridden = overrides.mainRuntimeFactory(config, supervisorRef, currentDefaultCwd);
    if (!overridden) return undefined;
    return { runtime: overridden, toolsBuilder: () => [] };
  }

  const requireSupervisor = (): SessionSupervisor => {
    if (!supervisorRef.current) throw new Error("Supervisor not constructed yet");
    return supervisorRef.current;
  };

  const startPickleFromMainContext = async (request: PickyHandoffRequest) => {
    const supervisor = requireSupervisor();
    const context = supervisor.currentMainContext();
    if (!context) throw new Error("No active Picky context to hand off.");
    const cwd = request.cwd?.trim() || currentDefaultCwd.value;
    logAgentd("pickle start requested", { contextId: context.id, titleChars: request.title.length, instructionChars: request.instructions.length, cwd });
    supervisor.announceMainHandoff(
      context.id,
      request.userMessage?.trim() || "이건 피클에 맡길게요. 진행 상황은 Picky dock에서 확인할 수 있어요.",
    );
    if (!appPickleHandoffRef.current) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    const session = await appPickleHandoffRef.current({ context, title: request.title, instructions: request.instructions, cwd });
    logAgentd("pickle started via app handoff", { contextId: context.id, sessionId: session.sessionId, titleChars: session.title.length, cwd: session.cwd });
    return session;
  };

  const listPickleSessions = async () => {
    if (!appPickleHandoffRef.bridge) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    const result = await appPickleHandoffRef.bridge({ operation: "listSessions" });
    return result.sessions ?? [];
  };

  const steerPickleSession = async (request: PickyPickleSteerRequest) => {
    if (!appPickleHandoffRef.bridge) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    logAgentd("pickle steer requested", { sessionId: request.sessionId, textChars: request.message.length });
    const result = await appPickleHandoffRef.bridge({ operation: "steer", sessionId: request.sessionId, text: request.message });
    if (!result.session) throw new Error(`No Pickle session returned for steer: ${request.sessionId}`);
    logAgentd("pickle steer sent", { sessionId: result.session.id, status: result.session.status });
    return result.session;
  };

  const abortPickleSession = async (request: PickyPickleAbortRequest) => {
    if (!appPickleHandoffRef.bridge) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
    logAgentd("pickle abort requested", { sessionId: request.sessionId });
    const result = await appPickleHandoffRef.bridge({ operation: "abort", sessionId: request.sessionId });
    if (!result.session) throw new Error(`No Pickle session returned for abort: ${request.sessionId}`);
    logAgentd("pickle abort sent", { sessionId: result.session.id, status: result.session.status });
    return result.session;
  };

  // Picky built-in tools registered to the main agent. ask_user_question is
  // intentionally excluded — disableBlockingDialogs prevents it from working
  // on the main runtime and it is registered separately on Pickle child
  // runtimes. The plan narration (`picky_tell_plan`) used to live here, but
  // is now provided by a Pi extension seeded into the workspace's
  // `.pi/extensions/picky-tell-plan.ts`, so it is scoped to the main agent's
  // cwd and enforces its own "announce the plan before any other tool" rule.
  // The user can disable individual entries from the settings UI; `toolsBuilder`
  // returns the subset that should be active given the current disabled set.
  const allBuiltinTools: import("@mariozechner/pi-coding-agent").ToolDefinition[] = [
    createPickyStartPickleTool(startPickleFromMainContext),
    createPickyPickleSessionsTool(listPickleSessions),
    createPickySteerPickleTool(steerPickleSession),
    createPickyAbortPickleTool(abortPickleSession),
    createReadPickyUserGuideTool(readPickyUserGuide),
  ];
  const toolsBuilder = (disabled: ReadonlySet<string>) => allBuiltinTools.filter((tool) => !disabled.has(tool.name));

  const piMainRuntime = new PiSdkRuntime({
    thinkingLevel: config.mainAgentThinkingLevel,
    modelPattern: config.mainAgentModelPattern,
    // Picky has no UI surface for blocking dialogs (ask_user_question/confirm/input/...).
    // Without this flag, any extension or tool that calls `ctx.ui.<dialog>` would hang the Picky
    // session forever (`applyMainRuntimeEvent` ignores `extension_ui` events). Reject blocking
    // calls eagerly so the LLM gets a usable error and can fall back to picky_start_pickle.
    disableBlockingDialogs: true,
    customTools: toolsBuilder(new Set()),
  });

  return { runtime: piMainRuntime, toolsBuilder };
}

/**
 * Stable in-process bridge that Pi extensions seeded into the workspace can
 * call to reach Picky's companion voice. Exposed on `globalThis.__pickyAgentd`
 * so the seeded `picky-tell-plan` extension (and any future extensions) can
 * depend on a narrow, documented surface without importing agentd internals.
 */
export interface PickyAgentdBridge {
  /** Speak a short filler line via Picky's companion voice. No-op if blank. */
  narrate(text: string): void;
  /**
   * Current value of the Picky narrationEnabled toggle. The extension reads
   * this at `session_start` to decide whether to register `picky_tell_plan`
   * via `pi.setActiveTools` and whether to enforce the "announce the plan
   * before any other tool" gate.
   */
  getNarrationEnabled(): boolean;
  /**
   * Subscribe to narration-toggle transitions. Returns an unsubscribe
   * function the extension calls on `session_shutdown`. Listeners only fire
   * on real value changes — idempotent settings rebroadcasts do not retrigger.
   */
  onNarrationEnabledChange(listener: (enabled: boolean) => void): () => void;
}

function installPickyAgentdBridge(supervisor: SessionSupervisor): void {
  const bridge: PickyAgentdBridge = {
    narrate(text: string): void {
      const trimmed = (text ?? "").trim();
      if (!trimmed) return;
      logAgentd("narrate progress requested", { textChars: trimmed.length, via: "extension-bridge" });
      supervisor.requestNarrateProgress({ text: trimmed });
    },
    getNarrationEnabled(): boolean {
      return supervisor.getNarrationEnabled();
    },
    onNarrationEnabledChange(listener: (enabled: boolean) => void): () => void {
      return supervisor.onNarrationEnabledChange(listener);
    },
  };
  (globalThis as unknown as { __pickyAgentd?: PickyAgentdBridge }).__pickyAgentd = bridge;
}
