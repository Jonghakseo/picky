/**
 * Gateway process configuration (docs/remote-pwa-implementation.md 2.1).
 *
 * The gateway is the only Picky process that accepts input from outside the
 * Mac, so every knob is an explicit environment variable and the listen address
 * is hard-coded to loopback.
 */
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

export const GATEWAY_LOOPBACK_HOST = "127.0.0.1";
export const DEFAULT_GATEWAY_PORT = 17640;

export interface GatewayConfig {
  /** Loopback port. Tailscale Serve or a tunnel is what makes it reachable. */
  port: number;
  /** Bearer token the hub presents on `/hub`. */
  hubToken: string;
  appSupportDir: string;
  /** `<appSupportDir>/Remote`: devices, vapid keys, audit log, uploads, tmp. */
  dataDir: string;
  /** Directory with the built PWA. */
  webRoot: string;
  parentPid?: number;
}

export interface GatewayConfigInput {
  env: NodeJS.ProcessEnv;
  /** Directory of the compiled entry (`dist/gateway`), used for the web root default. */
  entryDir: string;
}

export function parseGatewayConfig({ env, entryDir }: GatewayConfigInput): GatewayConfig {
  const hubToken = env.PICKY_GATEWAY_HUB_TOKEN?.trim();
  if (!hubToken) throw new Error("PICKY_GATEWAY_HUB_TOKEN is required");

  const appSupportDir = env.PICKY_APP_SUPPORT_DIR?.trim() || defaultAppSupportRoot();
  const webRootOverride = env.PICKY_GATEWAY_WEB_ROOT?.trim();

  return {
    port: parsePort(env.PICKY_GATEWAY_PORT),
    hubToken,
    appSupportDir,
    dataDir: join(appSupportDir, "Remote"),
    // `dist/gateway/main.js` ships next to `dist/web/`, so the sibling directory
    // is the default. Tests and the dev harness pass an explicit root.
    webRoot: webRootOverride
      ? (isAbsolute(webRootOverride) ? webRootOverride : resolve(webRootOverride))
      : resolve(entryDir, "..", "web"),
    parentPid: parseParentPidValue(env.PICKY_AGENTD_PARENT_PID),
  };
}

function parsePort(raw: string | undefined): number {
  const trimmed = raw?.trim();
  if (!trimmed) return DEFAULT_GATEWAY_PORT;
  const port = Number(trimmed);
  // 0 is allowed so tests and the dev harness can bind an ephemeral port.
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new Error(`Invalid PICKY_GATEWAY_PORT: ${JSON.stringify(raw)}`);
  }
  return port;
}

function parseParentPidValue(raw: string | undefined): number | undefined {
  const trimmed = raw?.trim();
  if (!trimmed || !/^[0-9]+$/.test(trimmed)) return undefined;
  const pid = Number(trimmed);
  return Number.isSafeInteger(pid) && pid > 0 ? pid : undefined;
}

function defaultAppSupportRoot(): string {
  return join(homedir(), "Library", "Application Support", "Picky");
}
