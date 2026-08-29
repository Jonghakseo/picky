import { existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DefaultPackageManager, getAgentDir, SettingsManager, type ProgressEvent } from "@earendil-works/pi-coding-agent";
import type { WebSocket } from "ws";
import { resolveNpmCommand } from "../domain/npm-command.js";
import { logAgentd } from "../local-log.js";
import { CronPackageLifecycle, isCronPackageSource, type CronLifecycleResult } from "./cron-package-lifecycle.js";
import { CancellablePackageProcessController, installCancellablePackageCommands } from "./package-process-controller.js";

export interface PackageManager {
  installAndPersist(source: string): Promise<void>;
  removeAndPersist(source: string): Promise<boolean>;
  checkAvailableUpdates(): Promise<Array<{ source: string }>>;
  update(source: string): Promise<void>;
  resolveInstalledExtension?(source: string): Promise<string>;
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
    resolveInstalledExtension: (source) => resolveInstalledExtensionPath(packageManager as DefaultPackageManager, source),
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

type PackageOperation = "install" | "remove" | "update" | "setup";
type PackageOperationEvent =
  | { type: "packageUpdatesAvailable"; commandId: string; sources: string[]; failed?: boolean }
  | { type: "packageOperationProgress"; requestId: string; operation: Exclude<PackageOperation, "setup">; source: string; message: string }
  | { type: "packageOperationCompleted"; requestId: string; operation: PackageOperation; source: string; ok: boolean; errorMessage?: string; packageChanged?: boolean };

type PackageMutationOutcome =
  | { kind: "completed" }
  | { kind: "failed"; error: unknown }
  | { kind: "timedOut"; timeoutMs: number };

export interface CronPackageLifecycleLike {
  reconcile(input: {
    source: string;
    agentDir: string;
    desiredState: "installed" | "uninstalled";
    forceCommand?: boolean;
  }): Promise<CronLifecycleResult>;
}

export interface PackageOperationsDependencies {
  createPackageManager?: (options: PackageManagerFactoryOptions) => PackageManager;
  createCronLifecycle?: (packageManager: PackageManager) => CronPackageLifecycleLike;
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

  async runOperation(ws: WebSocket, requestId: string, operation: Exclude<PackageOperation, "setup">, source: string): Promise<void> {
    await this.enqueueOperation(ws, requestId, operation, source);
  }

  async runSetup(ws: WebSocket, requestId: string, source: string): Promise<void> {
    await this.enqueueOperation(ws, requestId, "setup", source);
  }

  private async enqueueOperation(ws: WebSocket, requestId: string, operation: PackageOperation, source: string): Promise<void> {
    if (this.stopping) {
      this.complete(ws, { requestId, operation, source, ok: false, errorMessage: "Package operation rejected because the daemon is stopping" });
      return;
    }
    const agentDir = (this.dependencies.getAgentDir ?? getAgentDir)();
    await this.enqueue(agentDir, () => this.execute(ws, requestId, operation, source, agentDir));
  }

  private createPackageManager(agentDir: string): PackageManager {
    const createPackageManager = this.dependencies.createPackageManager ?? createDefaultPackageManager;
    return createPackageManager({ cwd: process.cwd(), agentDir });
  }

  private createCronLifecycle(packageManager: PackageManager): CronPackageLifecycleLike {
    if (this.dependencies.createCronLifecycle) return this.dependencies.createCronLifecycle(packageManager);
    return new CronPackageLifecycle({
      resolveExtension: async (source) => {
        if (!packageManager.resolveInstalledExtension) {
          throw new Error("Pi package manager cannot resolve an existing extension without installation");
        }
        return await packageManager.resolveInstalledExtension(source);
      },
    });
  }

  private async enqueue(agentDir: string, operation: () => Promise<void>): Promise<void> {
    const previous = this.chains.get(agentDir) ?? Promise.resolve();
    const current = previous.catch(() => {}).then(async () => {
      if (this.stopping) return;
      await operation();
    });
    this.chains.set(agentDir, current);
    void current.finally(() => {
      if (this.chains.get(agentDir) === current) this.chains.delete(agentDir);
    }).catch(() => {});
    await current;
  }

  private async execute(ws: WebSocket, requestId: string, operation: PackageOperation, source: string, agentDir: string): Promise<void> {
    const packageManager = this.createPackageManager(agentDir);
    this.activeManagers.add(packageManager);
    if (operation !== "setup") {
      packageManager.setProgressCallback((event) => {
        const message = event.message ?? `${event.action} ${event.source}`;
        this.dependencies.send(ws, { type: "packageOperationProgress", requestId, operation, source, message });
      });
    }
    try {
      if (isCronPackageSource(source)) {
        await this.executeCron(ws, requestId, operation, source, agentDir, packageManager);
      } else if (operation === "setup") {
        this.complete(ws, { requestId, operation, source, ok: false, errorMessage: "Setup is available only for the curated Cron package", packageChanged: false });
      } else {
        await this.executePackageMutation(ws, requestId, operation, source, packageManager);
      }
    } finally {
      packageManager.setProgressCallback(undefined);
      this.activeManagers.delete(packageManager);
    }
  }

  private async executeCron(
    ws: WebSocket,
    requestId: string,
    operation: PackageOperation,
    source: string,
    agentDir: string,
    packageManager: PackageManager,
  ): Promise<void> {
    const lifecycle = this.createCronLifecycle(packageManager);
    if (operation === "setup") {
      const result = await lifecycle.reconcile({ source, agentDir, desiredState: "installed" });
      this.complete(ws, { requestId, operation, source, ok: result.ok, errorMessage: result.errorMessage, packageChanged: false });
      return;
    }
    if (operation === "remove") {
      const lifecycleResult = await lifecycle.reconcile({ source, agentDir, desiredState: "uninstalled" });
      if (!lifecycleResult.ok) {
        this.complete(ws, { requestId, operation, source, ok: false, errorMessage: lifecycleResult.errorMessage, packageChanged: false });
        return;
      }
      const removal = await this.runPackageMutation(operation, source, packageManager, (errorMessage) => {
        this.complete(ws, {
          requestId,
          operation,
          source,
          ok: false,
          errorMessage: `Cron daemon was removed, but the package remains installed: ${errorMessage}`,
          packageChanged: false,
        });
      });
      if (removal.reported) return;
      this.complete(ws, removal.ok
        ? { requestId, operation, source, ok: true, packageChanged: true }
        : removal.mutationCompleted
          ? {
            requestId,
            operation,
            source,
            ok: false,
            errorMessage: `Cron daemon and package files were removed, but package settings could not be persisted: ${removal.errorMessage}`,
            packageChanged: true,
          }
          : {
            requestId,
            operation,
            source,
            ok: false,
            errorMessage: `Cron daemon was removed, but the package remains installed: ${removal.errorMessage}`,
            packageChanged: false,
          });
      return;
    }

    const mutationSucceeded = await this.runPackageMutation(operation, source, packageManager, (errorMessage) => {
      this.complete(ws, { requestId, operation, source, ok: false, errorMessage });
    });
    if (!mutationSucceeded.ok) {
      if (!mutationSucceeded.reported) {
        this.complete(ws, {
          requestId,
          operation,
          source,
          ok: false,
          errorMessage: mutationSucceeded.errorMessage,
          ...(mutationSucceeded.mutationCompleted ? { packageChanged: true } : {}),
        });
      }
      return;
    }
    const lifecycleResult = await lifecycle.reconcile({
      source,
      agentDir,
      desiredState: "installed",
      ...(operation === "update" ? { forceCommand: true } : {}),
    });
    this.complete(ws, {
      requestId,
      operation,
      source,
      ok: lifecycleResult.ok,
      errorMessage: lifecycleResult.errorMessage,
      packageChanged: true,
    });
  }

  private async executePackageMutation(
    ws: WebSocket,
    requestId: string,
    operation: Exclude<PackageOperation, "setup">,
    source: string,
    packageManager: PackageManager,
    includePackageChanged?: boolean,
  ): Promise<void> {
    const result = await this.runPackageMutation(operation, source, packageManager, (errorMessage) => {
      this.complete(ws, {
        requestId,
        operation,
        source,
        ok: false,
        errorMessage,
        ...(includePackageChanged === undefined ? {} : { packageChanged: false }),
      });
    });
    if (result.reported) return;
    this.complete(ws, {
      requestId,
      operation,
      source,
      ok: result.ok,
      errorMessage: result.errorMessage,
      ...(includePackageChanged === undefined ? {} : { packageChanged: result.ok && includePackageChanged }),
    });
  }

  private async runPackageMutation(
    operation: Exclude<PackageOperation, "setup">,
    source: string,
    packageManager: PackageManager,
    onTimedOut?: (errorMessage: string) => void,
  ): Promise<{ ok: boolean; errorMessage?: string; reported?: boolean; mutationCompleted?: boolean }> {
    const mutation = operation === "install"
      ? packageManager.installAndPersist(source)
      : operation === "remove"
        ? packageManager.removeAndPersist(source).then(() => undefined)
        : packageManager.update(source);
    const outcome = await waitForPackageMutation(mutation, this.dependencies.packageOperationTimeoutMs ?? DEFAULT_PACKAGE_OPERATION_TIMEOUT_MS);
    if (outcome.kind === "timedOut") {
      const errorMessage = `Package operation timed out after ${outcome.timeoutMs}ms`;
      onTimedOut?.(errorMessage);
      await packageManager.cancel?.().catch((error) => {
        logAgentd("package operation cancellation failed", { operation, source, error: error instanceof Error ? error.message : String(error) });
      });
      await mutation.catch(() => {});
      return { ok: false, errorMessage, reported: onTimedOut !== undefined };
    }
    if (outcome.kind === "failed") {
      const error = outcome.error;
      return { ok: false, errorMessage: error instanceof Error ? error.message : String(error) };
    }
    try {
      await packageManager.flush?.();
      return { ok: true, mutationCompleted: true };
    } catch (error) {
      return {
        ok: false,
        errorMessage: error instanceof Error ? error.message : String(error),
        mutationCompleted: true,
      };
    }
  }

  private complete(ws: WebSocket, event: Omit<Extract<PackageOperationEvent, { type: "packageOperationCompleted" }>, "type">): void {
    this.dependencies.send(ws, {
      type: "packageOperationCompleted",
      ...event,
      ...(event.errorMessage === undefined ? {} : { errorMessage: event.errorMessage }),
      ...(event.packageChanged === undefined ? {} : { packageChanged: event.packageChanged }),
    });
  }
}

async function resolveInstalledExtensionPath(
  packageManager: Pick<DefaultPackageManager, "listConfiguredPackages">,
  source: string,
): Promise<string> {
  if (!isCronPackageSource(source)) throw new Error(`Unsupported existing extension source: ${source}`);
  const configured = packageManager.listConfiguredPackages().filter((candidate) => (
    candidate.scope === "user" && isCronPackageSource(candidate.source)
  ));
  if (configured.length !== 1) {
    throw new Error(`Expected exactly one configured user Cron package, found ${configured.length}`);
  }
  const packageRoot = configured[0]?.installedPath;
  if (!packageRoot || !existsSync(packageRoot)) {
    throw new Error("Configured Cron package files are missing; reinstall the package before setting up its daemon");
  }
  const manifestPath = join(packageRoot, "package.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as { pi?: { extensions?: unknown } };
  const extensions = manifest.pi?.extensions;
  if (!Array.isArray(extensions) || extensions.length !== 1 || typeof extensions[0] !== "string") {
    throw new Error("Installed Cron package must declare exactly one Pi extension entry");
  }
  const extensionPath = resolve(packageRoot, extensions[0]);
  const relativePath = relative(packageRoot, extensionPath);
  if (!relativePath || relativePath.startsWith("..") || isAbsolute(relativePath)) {
    throw new Error("Installed Cron extension entry resolves outside its package directory");
  }
  const details = await stat(extensionPath).catch(() => undefined);
  if (!details?.isFile()) throw new Error("Installed Cron extension entry is missing");
  return extensionPath;
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
