/**
 * Gateway entry point, built to `dist/gateway/main.js`.
 *
 * Launched by the remote hub inside Picky.app while remote access is on. It
 * follows the daemon's lifecycle rules: a parent watchdog so an app crash takes
 * the gateway with it, and a clean exit on SIGINT/SIGTERM.
 */
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseGatewayConfig } from "./config.js";
import { GatewayServer } from "./server.js";
import { startParentExitWatcher } from "../parent-watchdog.js";
import { logGateway } from "./log.js";

const entryDir = dirname(fileURLToPath(import.meta.url));
const config = parseGatewayConfig({ env: process.env, entryDir });

logGateway("startup", {
  port: config.port,
  dataDir: config.dataDir,
  webRoot: config.webRoot,
  parentPid: config.parentPid ?? null,
});

const server = new GatewayServer({ config });
const boundPort = await server.start();
// Readiness line the hub waits for, written straight to stdout so it is never
// filtered by the structured logger's env switch.
process.stdout.write(`picky-gateway listening on 127.0.0.1:${boundPort}\n`);

let shuttingDown = false;
const parentWatcher = startParentExitWatcher({
  parentPid: config.parentPid,
  onParentExit: () => void shutdown(),
  log: (event, fields) => logGateway(event, fields),
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => void shutdown());
}

async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  parentWatcher?.stop();
  await server.stop();
  process.exit(0);
}
