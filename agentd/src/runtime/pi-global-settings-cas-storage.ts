import { closeSync, existsSync, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import lockfile from "proper-lockfile";
import { modelScopeRevision } from "./pi-model-resolution.js";
import { PiModelScopeConflictError } from "./model-scope-errors.js";

/** The public structural type accepted by `SettingsManager.fromStorage`. */
type PiSettingsStorage = Parameters<typeof SettingsManager.fromStorage>[0];
type SettingsScope = "global" | "project";

/**
 * Holds Pi's global `settings.json` lock across one SettingsManager transaction.
 *
 * Pi's file storage uses `proper-lockfile` 4.1.2 with `realpath: false`; this
 * adapter deliberately shares that lock protocol without importing Pi internals.
 * Its `withLock` implementation is the storage passed to `SettingsManager`, so
 * Pi itself still performs migration, field-level merge, and JSON serialization.
 */
export class PiGlobalSettingsCASStorage {
  private readonly globalSettingsPath: string;
  private isGlobalLockHeld = false;
  private expectedRevision: string | undefined;
  private validatedWrite = false;

  constructor(agentDir: string) {
    this.globalSettingsPath = join(agentDir, "settings.json");
  }

  async setEnabledModels(expectedRevision: string, patterns: string[] | undefined): Promise<void> {
    const release = this.acquireGlobalLock();
    this.isGlobalLockHeld = true;
    this.expectedRevision = expectedRevision;
    this.validatedWrite = false;
    try {
      const settingsManager = SettingsManager.fromStorage(this as PiSettingsStorage);
      settingsManager.setEnabledModels(patterns);
      await settingsManager.flush();
      const errors = settingsManager.drainErrors();
      const conflict = errors.map((entry) => entry.error).find((error) => error instanceof PiModelScopeConflictError);
      if (conflict) throw conflict;
      if (errors.length > 0) throw new Error(errors.map((entry) => entry.error.message).join("; "));
      if (!this.validatedWrite) throw new Error("Pi settings manager did not write the model scope");
    } finally {
      this.expectedRevision = undefined;
      this.isGlobalLockHeld = false;
      release();
    }
  }

  /**
   * Structural SettingsStorage implementation consumed by the public Pi API.
   * Project settings are intentionally absent because this transaction writes
   * only the global enabledModels source.
   */
  withLock(scope: SettingsScope, fn: (current: string | undefined) => string | undefined): void {
    if (scope === "project") {
      fn(undefined);
      return;
    }
    if (!this.isGlobalLockHeld) throw new Error("Global settings storage used outside its lock");

    const current = readFileSync(this.globalSettingsPath, "utf8");
    const next = fn(current);
    if (next === undefined) return;

    // This is SettingsManager's merge/migration/write callback. Checking the
    // raw persisted enabledModels here makes the CAS atomic with Pi TUI writers
    // that honour the same proper-lockfile protocol.
    const currentScope = JSON.parse(stripBOM(current)) as { enabledModels?: string[] };
    if (modelScopeRevision(currentScope.enabledModels) !== this.expectedRevision) {
      throw new PiModelScopeConflictError();
    }
    writeFileSync(this.globalSettingsPath, next, "utf8");
    this.validatedWrite = true;
  }

  private acquireGlobalLock(): () => void {
    const directory = dirname(this.globalSettingsPath);
    if (!existsSync(this.globalSettingsPath)) {
      mkdirSync(directory, { recursive: true });
      try {
        const descriptor = openSync(this.globalSettingsPath, "wx");
        writeFileSync(descriptor, "{}", "utf8");
        closeSync(descriptor);
      } catch (error) {
        if (!(error instanceof Error) || !("code" in error) || error.code !== "EEXIST") throw error;
      }
    }
    return this.acquireLockSyncWithPiRetry();
  }

  private acquireLockSyncWithPiRetry(): () => void {
    const maxAttempts = 10;
    const delayMs = 20;
    let lastError: unknown;
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        return lockfile.lockSync(this.globalSettingsPath, { realpath: false });
      } catch (error) {
        const code = typeof error === "object" && error !== null && "code" in error
          ? String(error.code)
          : undefined;
        if (code !== "ELOCKED" || attempt === maxAttempts) throw error;
        lastError = error;
        const startedAt = Date.now();
        while (Date.now() - startedAt < delayMs) {
          // Pi's synchronous settings storage intentionally uses a short busy wait.
        }
      }
    }
    throw lastError ?? new Error("Failed to acquire Pi settings lock");
  }
}

function stripBOM(value: string): string {
  return value.charCodeAt(0) === 0xFEFF ? value.slice(1) : value;
}
