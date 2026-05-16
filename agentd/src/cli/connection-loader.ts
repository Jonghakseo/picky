import { homedir } from "node:os";
import { join } from "node:path";
import { readConnectionInfo } from "../connection-info-store.js";

export interface PickyCliConnection {
  url: string;
  token: string;
  port: number;
  appSupportDir: string;
}

/**
 * Locate Picky.app's agentd connection info file. Resolution order:
 *   1. PICKY_APP_SUPPORT_DIR env (used by tests and ad-hoc dev runs)
 *   2. macOS default: ~/Library/Application Support/Picky
 *
 * Always re-read from disk on every CLI invocation so a daemon restart
 * (which rotates token + port) is picked up without caching.
 */
export function defaultAppSupportDir(): string {
  const override = process.env.PICKY_APP_SUPPORT_DIR;
  if (override && override.trim().length > 0) return override;
  return join(homedir(), "Library", "Application Support", "Picky");
}

export class PickyCliDaemonNotRunningError extends Error {
  constructor(public readonly appSupportDir: string, cause?: unknown) {
    super(
      `Picky daemon is not reachable. Make sure Picky.app is running. (Looked for connection info under ${appSupportDir})`,
    );
    this.name = "PickyCliDaemonNotRunningError";
    if (cause instanceof Error) (this as { cause?: unknown }).cause = cause;
  }
}

export async function loadCliConnection(appSupportDir = defaultAppSupportDir()): Promise<PickyCliConnection> {
  try {
    const info = await readConnectionInfo(appSupportDir);
    return { url: info.url, token: info.token, port: info.port, appSupportDir };
  } catch (error) {
    throw new PickyCliDaemonNotRunningError(appSupportDir, error);
  }
}
