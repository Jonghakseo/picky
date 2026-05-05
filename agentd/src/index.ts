import { AgentdServer } from "./server.js";
import { ArtifactStore, defaultAppSupportRoot } from "./artifact-store.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { PiSdkRuntime } from "./runtime/pi-sdk-runtime.js";
import { ConservativeMockTaskRouter } from "./task-router.js";
import { createPickyHandoffTool, createPickySideSessionsTool, createPickySideSteerTool } from "./application/handoff-tool.js";
import { createPickyAskUserQuestionTool } from "./application/ask-user-question-tool.js";
import { createPickyShowPointerTool } from "./application/pointer-tool.js";

import { removeConnectionInfo, writeConnectionInfo } from "./connection-info-store.js";
import { PROTOCOL_VERSION, ThinkingLevelSchema } from "./protocol.js";
import { logAgentd } from "./local-log.js";

const port = Number(process.env.PICKY_AGENTD_PORT ?? 17631);
const token = process.env.PICKY_AGENTD_TOKEN;
const appSupportDir = process.env.PICKY_APP_SUPPORT_DIR ?? defaultAppSupportRoot();
const defaultCwd = process.env.PICKY_DEFAULT_CWD ?? process.cwd();
const mainAgentThinkingLevel = parseMainAgentThinkingLevel(process.env.PICKY_MAIN_AGENT_THINKING_LEVEL);

if (!token) {
  console.error("PICKY_AGENTD_TOKEN is required");
  process.exit(1);
}

const useMockRuntime = process.env.PICKY_AGENTD_RUNTIME === "mock";
logAgentd("startup", { port, runtime: useMockRuntime ? "mock" : "pi", appSupportDir, defaultCwd, mainAgentThinkingLevel });
let supervisor: SessionSupervisor;
const pointerTool = createPickyShowPointerTool(async (request) => supervisor.requestPointerOverlay(request));
const askUserQuestionTool = createPickyAskUserQuestionTool();
// pointer/handoff/side-session tools are reserved for the always-on main agent.
const runtime = useMockRuntime
  ? new MockRuntime()
  : new PiSdkRuntime({
      customTools: [askUserQuestionTool],
    });
const mainRuntime = useMockRuntime
  ? undefined
  : new PiSdkRuntime({
      thinkingLevel: mainAgentThinkingLevel,
      // Main agent has no UI surface for blocking dialogs (ask_user_question/confirm/input/...).
      // Without this flag, any extension or tool that calls `ctx.ui.<dialog>` would hang the main
      // session forever (`applyMainRuntimeEvent` ignores `extension_ui` events). Reject blocking
      // calls eagerly so the LLM gets a usable error and can fall back to picky_handoff.
      disableBlockingDialogs: true,
      customTools: [
        pointerTool,
        createPickyHandoffTool(async (request) => {
          const context = supervisor.currentMainContext();
          if (!context) throw new Error("No active Picky main-agent context to hand off.");
          const cwd = request.cwd?.trim() || context.cwd || defaultCwd;
          logAgentd("handoff requested", { contextId: context.id, titleChars: request.title.length, instructionChars: request.instructions.length, cwd });
          supervisor.announceMainHandoff(
            context.id,
            request.userMessage?.trim() || "복잡한 작업이라 사이드 에이전트에 위임하겠습니다. 진행 상황은 오른쪽 위 오버레이에서 볼 수 있어요.",
          );
          const session = await supervisor.createSideFromHandoff(context, { title: request.title, instructions: request.instructions, cwd });
          logAgentd("handoff started", { contextId: context.id, sessionId: session.id, titleChars: session.title.length, cwd: session.cwd });
          return { sessionId: session.id, title: session.title, cwd: session.cwd };
        }),
        createPickySideSessionsTool(() => supervisor.listSideSessions()),
        createPickySideSteerTool(async (request) => {
          logAgentd("side steer requested", { sessionId: request.sessionId, textChars: request.message.length });
          const session = await supervisor.steerSideSession(request.sessionId, request.message);
          logAgentd("side steer sent", { sessionId: session.id, status: session.status });
          return session;
        }),
      ],
    });
supervisor = new SessionSupervisor(runtime, new SessionStore(appSupportDir), new ArtifactStore(appSupportDir), {
  taskRouter: useMockRuntime ? new ConservativeMockTaskRouter() : undefined,
  mainRuntime,
});
await supervisor.load();
const server = new AgentdServer({ port, token, supervisor });
const boundPort = await server.start();
const connectionInfoPath = await writeConnectionInfo(appSupportDir, {
  protocolVersion: PROTOCOL_VERSION,
  url: `ws://127.0.0.1:${boundPort}`,
  token,
  port: boundPort,
  pid: process.pid,
  appSupportDir,
  defaultCwd,
  startedAt: new Date().toISOString(),
});
logAgentd("connection info written", { path: connectionInfoPath });
console.log(`picky-agentd listening on 127.0.0.1:${boundPort}`);

if (mainRuntime) {
  void supervisor.prewarmMainAgent(defaultCwd)
    .then(() => console.log(`picky main agent prewarmed for ${defaultCwd}`))
    .catch((error) => console.error(`picky main agent prewarm failed: ${error instanceof Error ? error.message : String(error)}`));
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
