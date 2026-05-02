import { AgentdServer } from "./server.js";
import { ArtifactStore, defaultAppSupportRoot } from "./artifact-store.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import { PiSdkRuntime } from "./runtime/pi-sdk-runtime.js";
import { ConservativeMockTaskRouter } from "./task-router.js";
import { createPickyHandoffTool, createPickySideFollowUpTool, createPickySideSessionsTool } from "./application/handoff-tool.js";
import { removeConnectionInfo, writeConnectionInfo } from "./connection-info-store.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import { logAgentd } from "./local-log.js";

const port = Number(process.env.PICKY_AGENTD_PORT ?? 17631);
const token = process.env.PICKY_AGENTD_TOKEN;
const appSupportDir = process.env.PICKY_APP_SUPPORT_DIR ?? defaultAppSupportRoot();
const defaultCwd = process.env.PICKY_DEFAULT_CWD ?? process.cwd();

if (!token) {
  console.error("PICKY_AGENTD_TOKEN is required");
  process.exit(1);
}

const useMockRuntime = process.env.PICKY_AGENTD_RUNTIME === "mock";
logAgentd("startup", { port, runtime: useMockRuntime ? "mock" : "pi", appSupportDir, defaultCwd });
const runtime = useMockRuntime ? new MockRuntime() : new PiSdkRuntime();
let supervisor: SessionSupervisor;
const mainRuntime = useMockRuntime
  ? undefined
  : new PiSdkRuntime({
      customTools: [
        createPickyHandoffTool(async (request) => {
          const context = supervisor.currentMainContext();
          if (!context) throw new Error("No active Picky main-agent context to hand off.");
          logAgentd("handoff requested", { contextId: context.id, titleChars: request.title.length, instructionChars: request.instructions.length });
          supervisor.announceMainHandoff(
            context.id,
            request.userMessage?.trim() || "복잡한 작업이라 사이드 에이전트에 위임하겠습니다. 진행 상황은 오른쪽 위 오버레이에서 볼 수 있어요.",
          );
          const session = await supervisor.createSideFromHandoff(context, { title: request.title, instructions: request.instructions });
          logAgentd("handoff started", { contextId: context.id, sessionId: session.id, titleChars: session.title.length });
          return { sessionId: session.id, title: session.title };
        }),
        createPickySideSessionsTool(() => supervisor.listSideSessions()),
        createPickySideFollowUpTool(async (request) => {
          const context = supervisor.currentMainContext();
          logAgentd("side follow-up requested", { sessionId: request.sessionId, textChars: request.message.length, contextId: context?.id });
          const session = await supervisor.followUpSideSession(request.sessionId, request.message, context);
          logAgentd("side follow-up queued", { sessionId: session.id, status: session.status });
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

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void removeConnectionInfo(appSupportDir)
      .catch((error) => logAgentd("connection info remove failed", { error: error instanceof Error ? error.message : String(error) }))
      .then(() => server.stop())
      .then(() => process.exit(0));
  });
}
