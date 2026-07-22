import { composeAgentdServices, parseAgentdConfig, primeSessionIdFactoryForResume } from "./bootstrap.js";
import { installExtensionCrashGuard } from "./extension-crash-guard.js";
import { removeConnectionInfo, writeConnectionInfo } from "./connection-info-store.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import { logAgentd } from "./local-log.js";
import { parseParentPid, startParentExitWatcher } from "./parent-watchdog.js";
import { PARENT_EXIT_FORCE_SHUTDOWN_MS } from "./domain/shutdown-policy.js";

// pi extensions run in-process within agentd. A throw from a passive hook
// (e.g. an idle-timer screensaver calling `ctx.ui.custom`, or an extension
// referencing a pi TUI API like `theme.fg` that Picky does not expose) would
// otherwise propagate up the timer/microtask stack and tear the daemon down,
// taking every running Pickle session with it. The crash guard swallows
// extension-originated errors after structured logging so the agent (and
// whoever inspects logs) can recognise unsupported references, while real
// daemon bugs are still re-thrown.
installExtensionCrashGuard();

const config = parseAgentdConfig(process.env);
logAgentd("startup", {
  mode: config.mode,
  port: config.port,
  runtime: config.useMockRuntime ? "mock" : "pi",
  appSupportDir: config.appSupportDir,
  defaultCwd: config.defaultCwd,
  mainAgentCwd: config.mainAgentCwd,
  mainAgentThinkingLevel: config.mainAgentThinkingLevel,
  mainAgentModelPattern: config.mainAgentModelPattern,
  pickleThinkingLevel: config.pickleThinkingLevel,
  pickleModelPattern: config.pickleModelPattern,
  sessionId: config.sessionId,
  primaryUrl: config.primaryUrl,
});

const services = composeAgentdServices(config);
let shuttingDown = false;
const parentWatcher = startParentExitWatcher({
  parentPid: parseParentPid(process.env.PICKY_AGENTD_PARENT_PID),
  onParentExit: () => {
    void shutdown(0, { forceExitAfterMs: PARENT_EXIT_FORCE_SHUTDOWN_MS });
  },
});

await services.supervisor.load();
primeSessionIdFactoryForResume(services);
const boundPort = await services.server.start();

// Only the primary daemon owns the shared `agentd-connection.json`. Child daemons publish their
// bound port via the `picky-agentd listening on …` stdout line, which the parent process captures.
if (config.mode === "primary") {
  const connectionInfoPath = await writeConnectionInfo(config.appSupportDir, {
    protocolVersion: PROTOCOL_VERSION,
    url: `ws://127.0.0.1:${boundPort}`,
    token: config.token,
    port: boundPort,
    pid: process.pid,
    appSupportDir: config.appSupportDir,
    defaultCwd: services.currentDefaultCwd.value,
    startedAt: new Date().toISOString(),
  });
  logAgentd("connection info written", { path: connectionInfoPath });
}

console.log(`picky-agentd listening on 127.0.0.1:${boundPort}`);

if (config.mode === "primary" && services.mainRuntime) {
  void services.supervisor.prewarmMainAgent(config.mainAgentCwd)
    .then(() => console.log(`Picky prewarmed for ${config.mainAgentCwd}`))
    .catch((error) => console.error(`Picky prewarm failed: ${error instanceof Error ? error.message : String(error)}`));
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void shutdown(0);
  });
}

async function shutdown(exitCode: number, options: { forceExitAfterMs?: number } = {}): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  parentWatcher?.stop();
  const forceExitTimer = options.forceExitAfterMs
    ? setTimeout(() => process.exit(exitCode), options.forceExitAfterMs)
    : undefined;
  forceExitTimer?.unref();
  if (config.mode === "primary") {
    await removeConnectionInfo(config.appSupportDir).catch((error) => logAgentd("connection info remove failed", { error: error instanceof Error ? error.message : String(error) }));
  }
  await services.server.stop();
  if (forceExitTimer) clearTimeout(forceExitTimer);
  process.exit(exitCode);
}
