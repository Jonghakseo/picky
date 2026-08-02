import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { DefaultPackageManager, getAgentDir, SettingsManager, type ProgressEvent } from "@earendil-works/pi-coding-agent";
import type { WebSocket } from "ws";
import { resolveNpmCommand } from "../domain/npm-command.js";
import { logAgentd } from "../local-log.js";
import { CancellablePackageProcessController, installCancellablePackageCommands } from "./package-process-controller.js";

export interface PackageManager {
  installAndPersist(source: string): Promise<void>;
  removeAndPersist(source: string): Promise<boolean>;
  checkAvailableUpdates(): Promise<Array<{ source: string }>>;
  update(source: string): Promise<void>;
  setProgressCallback(callback: ((event: ProgressEvent) => void) | undefined): void;
  /** Waits until package settings changes are durable before completing the request. */
  flush?(): Promise<void>;
  /** Stops external commands and settles the active mutation before the queue is released. */
  cancel?(): Promise<void>;
}

export interface PackageManagerFactoryOptions {
  cwd: string;
  agentDir: string;
}

type PiPackageManagerOptions = ConstructorParameters<typeof DefaultPackageManager>[0];

export interface DefaultPackageManagerDependencies {
  createSettingsManager?: (cwd: string, agentDir?: string) => SettingsManager;
  createPackageManager?: (options: PiPackageManagerOptions) => PackageManager;
  execPath?: string;
  fileExists?: (path: string) => boolean;
  npmCommandRunnerPath?: string;
  npmCommandTimeoutMs?: number;
}

const DEFAULT_NPM_COMMAND_TIMEOUT_MS = 90_000;
const DEFAULT_PACKAGE_OPERATION_TIMEOUT_MS = 110_000;
const DEFAULT_NPM_COMMAND_RUNNER_PATH = fileURLToPath(new URL("./npm-command-runner.js", import.meta.url));

/** Creates the Pi package manager with a runtime-only bundled npm fallback. */
export function createDefaultPackageManager(
  options: PackageManagerFactoryOptions,
  dependencies: DefaultPackageManagerDependencies = {},
): PackageManager {
  const settingsManager = (dependencies.createSettingsManager ?? SettingsManager.create)(options.cwd, options.agentDir);
  const execPath = dependencies.execPath ?? process.execPath;
  const fileExists = dependencies.fileExists ?? existsSync;
  const packageManagerSettings = new Proxy(settingsManager, {
    get(target, property) {
      if (property === "getNpmCommand") {
        return () => resolveNpmCommand({
          configured: target.getNpmCommand(),
          execPath,
          fileExists,
          runnerPath: dependencies.npmCommandRunnerPath ?? DEFAULT_NPM_COMMAND_RUNNER_PATH,
          timeoutMs: dependencies.npmCommandTimeoutMs ?? DEFAULT_NPM_COMMAND_TIMEOUT_MS,
        });
      }
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const usesDefaultPackageManager = dependencies.createPackageManager === undefined;
  const packageManager = (dependencies.createPackageManager ?? ((params) => new DefaultPackageManager(params)))({
    ...options,
    settingsManager: packageManagerSettings,
  });
  const processController = usesDefaultPackageManager ? new CancellablePackageProcessController() : undefined;
  if (processController) installCancellablePackageCommands(packageManager as object, processController);

  return {
    installAndPersist: (packageSource) => packageManager.installAndPersist(packageSource),
    removeAndPersist: (packageSource) => packageManager.removeAndPersist(packageSource),
    checkAvailableUpdates: () => (packageManager as DefaultPackageManager).checkForAvailableUpdates(),
    update: (packageSource) => (packageManager as DefaultPackageManager).update(packageSource),
    setProgressCallback: (callback) => packageManager.setProgressCallback(callback),
    cancel: processController ? () => processController.cancelAll() : undefined,
    flush: async () => {
      await settingsManager.flush();
      const errors = settingsManager.drainErrors();
      if (errors.length > 0) {
        throw new Error(errors.map(({ scope, error }) => `Failed to persist ${scope} settings: ${error.message}`).join("; "));
      }
    },
  };
}

type PackageOperationEvent =
  | { type: "packageUpdatesAvailable"; commandId: string; sources: string[]; failed?: boolean }
  | { type: "packageOperationProgress"; requestId: string; operation: "install" | "remove" | "update"; source: string; message: string }
  | { type: "packageOperationCompleted"; requestId: string; operation: "install" | "remove" | "update"; source: string; ok: boolean; errorMessage?: string };

type PackageMutationOutcome =
  | { kind: "completed" }
  | { kind: "failed"; error: unknown }
  | { kind: "timedOut"; timeoutMs: number };

export interface PackageOperationsDependencies {
  createPackageManager?: (options: PackageManagerFactoryOptions) => PackageManager;
  getAgentDir?: () => string;
  packageOperationTimeoutMs?: number;
  send(ws: WebSocket, event: PackageOperationEvent): void;
}

/** Serializes package-manager work that mutates the shared Pi agent settings directory. */
export class PackageOperations {
  private chains = new Map<string, Promise<void>>();
  private activeManagers = new Set<PackageManager>();
  private stopping = false;

  constructor(private readonly dependencies: PackageOperationsDependencies) {}

  start(): void {
    this.stopping = false;
  }

  async stop(): Promise<void> {
    this.stopping = true;
    const activeManagers = [...this.activeManagers];
    await Promise.all(activeManagers.map(async (packageManager) => {
      await packageManager.cancel?.().catch((error) => {
        logAgentd("package operation shutdown cancellation failed", {
          error: error instanceof Error ? error.message : String(error),
        });
      });
    }));
    await Promise.all([...this.chains.values()].map(async (operation) => {
      await operation.catch(() => {});
    }));
  }

  async runUpdateCheck(ws: WebSocket, commandId: string): Promise<void> {
    const agentDir = (this.dependencies.getAgentDir ?? getAgentDir)();
    await this.enqueue(agentDir, async () => {
      const packageManager = this.createPackageManager(agentDir);
      this.activeManagers.add(packageManager);
      try {
        try {
          const updates = await packageManager.checkAvailableUpdates();
          this.dependencies.send(ws, { type: "packageUpdatesAvailable", commandId, sources: updates.map(({ source }) => source) });
        } catch (error) {
          logAgentd("package update check failed", {
            error: error instanceof Error ? error.message : String(error),
          });
          this.dependencies.send(ws, { type: "packageUpdatesAvailable", commandId, sources: [], failed: true });
        }
      } finally {
        this.activeManagers.delete(packageManager);
      }
    });
  }

  async runOperation(
    ws: WebSocket,
    requestId: string,
    operation: "install" | "remove" | "update",
    source: string,
  ): Promise<void> {
    if (this.stopping) {
      this.dependencies.send(ws, {
        type: "packageOperationCompleted",
        requestId,
        operation,
        source,
        ok: false,
        errorMessage: "Package operation rejected because the daemon is stopping",
      });
      return;
    }
    const agentDir = (this.dependencies.getAgentDir ?? getAgentDir)();
    await this.enqueue(agentDir, () => this.execute(ws, requestId, operation, source, agentDir));
  }

  private createPackageManager(agentDir: string): PackageManager {
    const createPackageManager = this.dependencies.createPackageManager ?? createDefaultPackageManager;
    return createPackageManager({ cwd: process.cwd(), agentDir });
  }

  private async enqueue(agentDir: string, operation: () => Promise<void>): Promise<void> {
    const previous = this.chains.get(agentDir) ?? Promise.resolve();
    const current = previous.catch(() => {}).then(async () => {
      if (this.stopping) return;
      await operation();
    });
    this.chains.set(agentDir, current);
    void current.finally(() => {
      if (this.chains.get(agentDir) === current) {
        this.chains.delete(agentDir);
      }
    }).catch(() => {});
    await current;
  }

  private async execute(
    ws: WebSocket,
    requestId: string,
    operation: "install" | "remove" | "update",
    source: string,
    agentDir: string,
  ): Promise<void> {
    const packageManager = this.createPackageManager(agentDir);
    this.activeManagers.add(packageManager);
    packageManager.setProgressCallback((event) => {
      const message = event.message ?? `${event.action} ${event.source}`;
      this.dependencies.send(ws, { type: "packageOperationProgress", requestId, operation, source, message });
    });
    try {
      const mutation = operation === "install"
        ? packageManager.installAndPersist(source)
        : operation === "remove"
          ? packageManager.removeAndPersist(source).then(() => undefined)
          : packageManager.update(source);
      const outcome = await waitForPackageMutation(
        mutation,
        this.dependencies.packageOperationTimeoutMs ?? DEFAULT_PACKAGE_OPERATION_TIMEOUT_MS,
      );
      if (outcome.kind === "timedOut") {
        this.dependencies.send(ws, {
          type: "packageOperationCompleted",
          requestId,
          operation,
          source,
          ok: false,
          errorMessage: `Package operation timed out after ${outcome.timeoutMs}ms`,
        });
        // Cancel every external command owned by the default package mutation,
        // then keep the per-agentDir queue held until the mutation settles. A
        // custom manager without cancellation remains serialized rather than
        // risking concurrent writes to the same package/settings directories.
        await packageManager.cancel?.().catch((error) => {
          logAgentd("package operation cancellation failed", {
            operation,
            source,
            error: error instanceof Error ? error.message : String(error),
          });
        });
        await mutation.catch(() => {});
        return;
      }
      try {
        if (outcome.kind === "failed") throw outcome.error;
        await packageManager.flush?.();
        this.dependencies.send(ws, { type: "packageOperationCompleted", requestId, operation, source, ok: true });
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : String(error);
        this.dependencies.send(ws, { type: "packageOperationCompleted", requestId, operation, source, ok: false, errorMessage });
      }
    } finally {
      packageManager.setProgressCallback(undefined);
      this.activeManagers.delete(packageManager);
    }
  }
}

async function waitForPackageMutation(mutation: Promise<void>, timeoutMs: number): Promise<PackageMutationOutcome> {
  return await new Promise<PackageMutationOutcome>((resolveOutcome) => {
    let settled = false;
    const finish = (outcome: PackageMutationOutcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolveOutcome(outcome);
    };
    const timer = setTimeout(() => finish({ kind: "timedOut", timeoutMs }), timeoutMs);
    void mutation.then(
      () => finish({ kind: "completed" }),
      (error: unknown) => finish({ kind: "failed", error }),
    );
  });
}
