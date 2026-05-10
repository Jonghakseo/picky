import { AgentdServer } from "./server.js";
import { defaultAppSupportRoot } from "./artifact-store.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { PiSdkRuntime } from "./runtime/pi-sdk-runtime.js";
import { OpenAIRealtimeMainRuntime } from "./runtime/openai-realtime-main-runtime.js";
import { SelectableMainRuntime } from "./runtime/selectable-main-runtime.js";
import { ConservativeMockTaskRouter } from "./task-router.js";
import { createPickyPickleSessionsTool, createPickyStartPickleTool, createPickySteerPickleTool, type PickyHandoffRequest, type PickyPickleSteerRequest } from "./application/handoff-tool.js";
import { createPickyAskUserQuestionTool } from "./application/ask-user-question-tool.js";
import { createPickyOpenPickleResponseTool } from "./application/open-pickle-response-tool.js";
import { PickySkillCatalog } from "./application/skill-catalog.js";
import { installExtensionCrashGuard } from "./extension-crash-guard.js";
import { removeConnectionInfo, writeConnectionInfo } from "./connection-info-store.js";
import { PROTOCOL_VERSION, ThinkingLevelSchema } from "./protocol.js";
import { logAgentd } from "./local-log.js";

const port = Number(process.env.PICKY_AGENTD_PORT ?? 17631);
const token = process.env.PICKY_AGENTD_TOKEN;
const appSupportDir = process.env.PICKY_APP_SUPPORT_DIR ?? defaultAppSupportRoot();
const initialDefaultCwd = process.env.PICKY_DEFAULT_CWD ?? process.cwd();
const currentDefaultCwd = { value: initialDefaultCwd };
const mainAgentCwd = process.env.PICKY_MAIN_AGENT_CWD ?? initialDefaultCwd;
const mainAgentThinkingLevel = parseMainAgentThinkingLevel(process.env.PICKY_MAIN_AGENT_THINKING_LEVEL);
const mainAgentModelPattern = process.env.PICKY_MAIN_AGENT_MODEL?.trim() || undefined;
const mainAgentRuntimeMode = process.env.PICKY_MAIN_AGENT_RUNTIME === "openai-realtime" ? "openai-realtime" : "pi";

if (!token) {
  console.error("PICKY_AGENTD_TOKEN is required");
  process.exit(1);
}

// pi extensions run in-process within agentd. A throw from a passive hook
// (e.g. an idle-timer screensaver calling `ctx.ui.custom`, or an extension
// referencing a pi TUI API like `theme.fg` that Picky does not expose) would
// otherwise propagate up the timer/microtask stack and tear the daemon down,
// taking every running Pickle session with it. The crash guard swallows
// extension-originated errors after structured logging so the agent (and
// whoever inspects logs) can recognise unsupported references, while real
// daemon bugs are still re-thrown.
installExtensionCrashGuard();

const useMockRuntime = process.env.PICKY_AGENTD_RUNTIME === "mock";
logAgentd("startup", { port, runtime: useMockRuntime ? "mock" : "pi", mainAgentRuntimeMode, appSupportDir, defaultCwd: currentDefaultCwd.value, mainAgentCwd, mainAgentThinkingLevel, mainAgentModelPattern });
let supervisor: SessionSupervisor;
const askUserQuestionTool = createPickyAskUserQuestionTool();
const skillCatalog = new PickySkillCatalog();
// Pickle delegation tools are reserved for Picky.
const runtime = useMockRuntime
  ? new MockRuntime()
  : new PiSdkRuntime({
      customTools: [askUserQuestionTool],
    });

const piMainRuntime = useMockRuntime
  ? undefined
  : new PiSdkRuntime({
      thinkingLevel: mainAgentThinkingLevel,
      modelPattern: mainAgentModelPattern,
      // Picky has no UI surface for blocking dialogs (ask_user_question/confirm/input/...).
      // Without this flag, any extension or tool that calls `ctx.ui.<dialog>` would hang the Picky
      // session forever (`applyMainRuntimeEvent` ignores `extension_ui` events). Reject blocking
      // calls eagerly so the LLM gets a usable error and can fall back to picky_start_pickle.
      disableBlockingDialogs: true,
      customTools: [
        createPickyStartPickleTool(startPickleFromMainContext),
        createPickyPickleSessionsTool(() => supervisor.listPickleSessions()),
        createPickySteerPickleTool(steerPickleSession),
        createPickyOpenPickleResponseTool((request) => supervisor.requestOpenPickleReport(request)),
      ],
    });

const realtimeMainRuntime = useMockRuntime
  ? undefined
  : new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        handoff: startPickleFromMainContext,
        listPickleSessions: () => supervisor.listPickleSessions(),
        steerPickleSession: steerPickleSession,
        searchSkills: (request) => skillCatalog.search(request),
        getSkillDetails: (request) => skillCatalog.details(request),
      },
    });

const mainRuntime = useMockRuntime || !piMainRuntime || !realtimeMainRuntime
  ? undefined
  : new SelectableMainRuntime({
      initialMode: mainAgentRuntimeMode,
      piRuntime: piMainRuntime,
      realtimeRuntime: realtimeMainRuntime,
    });
supervisor = new SessionSupervisor(runtime, new SessionStore(appSupportDir), {
  taskRouter: useMockRuntime ? new ConservativeMockTaskRouter() : undefined,
  mainRuntime,
});
await supervisor.load();
const server = new AgentdServer({
  port,
  token,
  supervisor,
  setDefaultCwd: (cwd) => {
    currentDefaultCwd.value = cwd;
    logAgentd("default cwd updated", { defaultCwd: cwd });
  },
});
const boundPort = await server.start();
const connectionInfoPath = await writeConnectionInfo(appSupportDir, {
  protocolVersion: PROTOCOL_VERSION,
  url: `ws://127.0.0.1:${boundPort}`,
  token,
  port: boundPort,
  pid: process.pid,
  appSupportDir,
  defaultCwd: currentDefaultCwd.value,
  startedAt: new Date().toISOString(),
});
logAgentd("connection info written", { path: connectionInfoPath });
console.log(`picky-agentd listening on 127.0.0.1:${boundPort}`);

if (mainRuntime) {
  void supervisor.prewarmMainAgent(mainAgentCwd)
    .then(() => console.log(`Picky prewarmed for ${mainAgentCwd}`))
    .catch((error) => console.error(`Picky prewarm failed: ${error instanceof Error ? error.message : String(error)}`));
}

async function startPickleFromMainContext(request: PickyHandoffRequest) {
  const context = supervisor.currentMainContext();
  if (!context) throw new Error("No active Picky context to hand off.");
  const cwd = request.cwd?.trim() || currentDefaultCwd.value;
  logAgentd("pickle start requested", { contextId: context.id, titleChars: request.title.length, instructionChars: request.instructions.length, cwd });
  supervisor.announceMainHandoff(
    context.id,
    request.userMessage?.trim() || "이건 피클에 맡길게요. 진행 상황은 Picky dock에서 확인할 수 있어요.",
  );
  const session = await supervisor.createPickleFromHandoff(context, { title: request.title, instructions: request.instructions, cwd });
  logAgentd("pickle started", { contextId: context.id, sessionId: session.id, titleChars: session.title.length, cwd: session.cwd });
  return { sessionId: session.id, title: session.title, cwd: session.cwd };
}

async function steerPickleSession(request: PickyPickleSteerRequest) {
  logAgentd("pickle steer requested", { sessionId: request.sessionId, textChars: request.message.length });
  const session = await supervisor.steerPickleSession(request.sessionId, request.message);
  logAgentd("pickle steer sent", { sessionId: session.id, status: session.status });
  return session;
}

function parseMainAgentThinkingLevel(value: string | undefined) {
  if (!value) return "medium" as const;
  const parsed = ThinkingLevelSchema.safeParse(value);
  if (parsed.success) return parsed.data;
  logAgentd("invalid main thinking level", { value, fallback: "medium" });
  return "medium" as const;
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void removeConnectionInfo(appSupportDir)
      .catch((error) => logAgentd("connection info remove failed", { error: error instanceof Error ? error.message : String(error) }))
      .then(() => server.stop())
      .then(() => process.exit(0));
  });
}
