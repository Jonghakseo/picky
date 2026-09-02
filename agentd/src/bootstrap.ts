import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { AgentdServer, APP_PICKLE_HANDOFF_UNAVAILABLE, type AppPickleBridgeRequest, type AppPickleBridgeResult } from "./server.js";
import { defaultAppSupportRoot } from "./artifact-store.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { PiSdkRuntime } from "./runtime/pi-sdk-runtime.js";
import { ConservativeMockTaskRouter } from "./task-router.js";
import { createPickyAskUserQuestionTool } from "./application/ask-user-question-tool.js";
import { createReadPickyUserGuideTool, readPickyUserGuide } from "./application/user-guide-tool.js";
import { stabilizeProcessCwd, type ProcessCwdStabilizerResult } from "./process-cwd.js";
import { ThinkingLevelSchema, type ThinkingLevel } from "./protocol.js";
import type { AgentRuntime } from "./runtime/types.js";
import { logAgentd } from "./local-log.js";
import { buildPickyRuntimeContract } from "./domain/picky-runtime-contract.js";
import { createPickyRuntimeContractExtension } from "./runtime/picky-runtime-contract-extension.js";
import { EdgeTTSService } from "./edge-tts-service.js";
import { PiOAuthService } from "./application/pi-oauth-service.js";

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
    sessionId,
    sessionCwd,
    primaryUrl: env.PICKY_AGENTD_PRIMARY_URL?.trim() || undefined,
  };
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

  const runtime = overrides.runtimeFactory
    ? overrides.runtimeFactory(config)
    : config.useMockRuntime
      ? new MockRuntime()
      : new PiSdkRuntime({
          thinkingLevel: config.pickleThinkingLevel,
          modelPattern: config.pickleModelPattern,
          customTools: [createPickyAskUserQuestionTool()],
        });

  // The primary main agent delegates through the real `picky` CLI using its existing bash tool.
  // Child daemons run one Pickle session and never receive that primary-only CLI environment.
  const primaryMain = config.mode === "primary"
    ? buildPrimaryMainRuntime(config, supervisorRef, currentDefaultCwd, overrides)
    : undefined;
  const mainRuntime = primaryMain?.runtime;
  const mainCustomToolsBuilder = primaryMain?.toolsBuilder;
  const onDisabledBuiltinToolsChanged = primaryMain?.onDisabledBuiltinToolsChanged;

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
        if (!appPickleBridgeRef.current) throw new Error(APP_PICKLE_HANDOFF_UNAVAILABLE);
        await appPickleBridgeRef.current({ operation: "notifyMainOfPickleCompletion", ...request });
      }
    : undefined;
  const supervisor = new SessionSupervisor(runtime, store, {
    taskRouter: config.useMockRuntime ? new ConservativeMockTaskRouter() : undefined,
    mainRuntime,
    sessionIdFactory,
    forwardPickleCompletionToPrimary,
    mainCustomToolsBuilder,
    onDisabledBuiltinToolsChanged,
  });
  supervisorRef.current = supervisor;

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
  });
  appPickleBridgeRef.current = (request) => server.requestPickleBridgeFromApp(request);

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
  toolsBuilder: (disabled: ReadonlySet<string>) => ToolDefinition[];
  /** Lets the supervisor publish toggle changes into the runtime's system-prompt contract. */
  onDisabledBuiltinToolsChanged: (disabled: ReadonlySet<string>) => void;
}

function buildPrimaryMainRuntime(
  config: AgentdConfig,
  supervisorRef: { current?: SessionSupervisor },
  currentDefaultCwd: { value: string },
  overrides: ComposeOverrides,
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
  ];
  const toolsBuilder = (disabled: ReadonlySet<string>) => allBuiltinTools.filter((tool) => !disabled.has(tool.name));

  // Read at turn time by the contract extension, so a settings toggle reaches the next system
  // prompt without recreating the main handle.
  let disabledMainBuiltinTools: ReadonlySet<string> = new Set();

  const piMainRuntime = new PiSdkRuntime({
    thinkingLevel: config.mainAgentThinkingLevel,
    modelPattern: config.mainAgentModelPattern,
    // The main overlay can answer ask_user_question, but has no surface for other
    // blocking dialogs. Keep those rejected so an unsupported extension call cannot hang.
    disableBlockingDialogs: true,
    allowedBlockingDialogMethods: ["askUserQuestion"],
    customTools: toolsBuilder(new Set()),
    // Standing rules ride the system prompt instead of a transcript message, so compaction,
    // resume, and stale session files cannot drop them. Pi appends inline extensions after
    // discovered user extensions, so this runs as a late `before_agent_start` modifier.
    resourceLoaderOptions: {
      extensionFactories: [createPickyRuntimeContractExtension(() => buildPickyRuntimeContract(disabledMainBuiltinTools))],
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
