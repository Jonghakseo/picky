import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";
import type { WebSocket } from "ws";
import { CRON_PACKAGE_SOURCE } from "./cron-package-lifecycle.js";
import { createDefaultPackageManager, PackageOperations, type PackageManager } from "./package-operations.js";

function packageManager(overrides: Partial<PackageManager> = {}): PackageManager {
  return {
    installAndPersist: vi.fn(async () => {}),
    removeAndPersist: vi.fn(async () => true),
    checkAvailableUpdates: vi.fn(async () => []),
    update: vi.fn(async () => {}),
    setProgressCallback: vi.fn(),
    flush: vi.fn(async () => {}),
    resolveInstalledExtension: vi.fn(async () => "/tmp/cron/index.ts"),
    ...overrides,
  };
}

function subject(input: {
  packageManager?: PackageManager;
  reconcile?: ReturnType<typeof vi.fn>;
} = {}) {
  const events: Array<Record<string, unknown>> = [];
  const manager = input.packageManager ?? packageManager();
  const reconcile = input.reconcile ?? vi.fn(async () => ({ ok: true }));
  const operations = new PackageOperations({
    createPackageManager: () => manager,
    createCronLifecycle: () => ({ reconcile }),
    getAgentDir: () => "/tmp/picky-agent",
    send: (_ws, event) => events.push(event),
  });
  operations.start();
  return { operations, events, manager, reconcile };
}

describe("PackageOperations Cron lifecycle sequencing", () => {
  it("resolves setup only from existing configured package files without installing", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-cron-existing-"));
    const packageRoot = join(root, "npm", "node_modules", "@ryan_nookpi", "pi-extension-cron");
    const installAndPersist = vi.fn(async () => {});
    const settingsManager = SettingsManager.inMemory({ packages: [CRON_PACKAGE_SOURCE] });
    const configuredPackage = {
      source: CRON_PACKAGE_SOURCE,
      scope: "user" as const,
      filtered: false,
      installedPath: packageRoot,
    };
    const manager = createDefaultPackageManager(
      { cwd: root, agentDir: root },
      {
        createSettingsManager: () => settingsManager,
        createPackageManager: () => ({
          installAndPersist,
          removeAndPersist: vi.fn(async () => true),
          checkAvailableUpdates: vi.fn(async () => []),
          update: vi.fn(async () => {}),
          setProgressCallback: vi.fn(),
          listConfiguredPackages: () => [configuredPackage],
        } as PackageManager & { listConfiguredPackages(): typeof configuredPackage[] }),
      },
    );

    try {
      await expect(manager.resolveInstalledExtension!(CRON_PACKAGE_SOURCE)).rejects.toThrow(/files are missing/);
      expect(installAndPersist).not.toHaveBeenCalled();

      await mkdir(packageRoot, { recursive: true });
      await writeFile(join(packageRoot, "package.json"), JSON.stringify({ pi: { extensions: ["./index.ts"] } }));
      await writeFile(join(packageRoot, "index.ts"), "export default function cron() {}\n");
      await expect(manager.resolveInstalledExtension!(CRON_PACKAGE_SOURCE)).resolves.toBe(join(packageRoot, "index.ts"));
      expect(installAndPersist).not.toHaveBeenCalled();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("installs, flushes, then reconciles Cron and marks the package as changed", async () => {
    const { operations, events, manager, reconcile } = subject();

    await operations.runOperation({} as WebSocket, "install-cron", "install", CRON_PACKAGE_SOURCE);

    expect(manager.installAndPersist).toHaveBeenCalledWith(CRON_PACKAGE_SOURCE);
    expect(manager.flush).toHaveBeenCalledOnce();
    expect(reconcile).toHaveBeenCalledWith({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" });
    expect(events).toContainEqual(expect.objectContaining({
      type: "packageOperationCompleted", requestId: "install-cron", operation: "install", ok: true, packageChanged: true,
    }));
  });

  it("reports changed Cron package files when settings flush fails before setup", async () => {
    const reconcile = vi.fn();
    const { operations, events } = subject({
      reconcile,
      packageManager: packageManager({ flush: vi.fn(async () => { throw new Error("settings are read-only"); }) }),
    });

    await operations.runOperation({} as WebSocket, "install-flush-failure", "install", CRON_PACKAGE_SOURCE);

    expect(reconcile).not.toHaveBeenCalled();
    expect(events).toContainEqual(expect.objectContaining({
      requestId: "install-flush-failure",
      ok: false,
      packageChanged: true,
      errorMessage: "settings are read-only",
    }));
  });

  it("reports installed-but-unconfigured Cron as a retryable partial success", async () => {
    const reconcile = vi.fn(async () => ({ ok: false, errorMessage: "launchctl did not load Cron" }));
    const { operations, events, manager } = subject({ reconcile });

    await operations.runOperation({} as WebSocket, "install-partial", "install", CRON_PACKAGE_SOURCE);

    expect(manager.installAndPersist).toHaveBeenCalledOnce();
    expect(events).toContainEqual(expect.objectContaining({
      requestId: "install-partial", ok: false, packageChanged: true, errorMessage: "launchctl did not load Cron",
    }));
  });

  it("reconciles setup without invoking a package mutation", async () => {
    const { operations, events, manager, reconcile } = subject();

    await operations.runSetup({} as WebSocket, "setup-cron", CRON_PACKAGE_SOURCE);

    expect(manager.installAndPersist).not.toHaveBeenCalled();
    expect(manager.update).not.toHaveBeenCalled();
    expect(manager.removeAndPersist).not.toHaveBeenCalled();
    expect(reconcile).toHaveBeenCalledWith({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" });
    expect(events).toContainEqual(expect.objectContaining({ requestId: "setup-cron", operation: "setup", ok: true, packageChanged: false }));
  });

  it("does not remove the npm package when Cron unload verification fails", async () => {
    const reconcile = vi.fn(async () => ({ ok: false, errorMessage: "Cron is still loaded" }));
    const { operations, events, manager } = subject({ reconcile });

    await operations.runOperation({} as WebSocket, "remove-cron", "remove", CRON_PACKAGE_SOURCE);

    expect(manager.removeAndPersist).not.toHaveBeenCalled();
    expect(events).toContainEqual(expect.objectContaining({ requestId: "remove-cron", ok: false, packageChanged: false }));
  });

  it("reports daemon-only removal when package deletion fails", async () => {
    const { operations, events, manager } = subject({
      packageManager: packageManager({ removeAndPersist: vi.fn(async () => { throw new Error("npm remove failed"); }) }),
    });

    await operations.runOperation({} as WebSocket, "remove-package-failure", "remove", CRON_PACKAGE_SOURCE);

    expect(events).toContainEqual(expect.objectContaining({
      requestId: "remove-package-failure",
      ok: false,
      packageChanged: false,
      errorMessage: "Cron daemon was removed, but the package remains installed: npm remove failed",
    }));
    expect(manager.removeAndPersist).toHaveBeenCalledOnce();
  });

  it("reports a structured partial removal when package files change before settings flush fails", async () => {
    const { operations, events, manager } = subject({
      packageManager: packageManager({ flush: vi.fn(async () => { throw new Error("settings are read-only"); }) }),
    });

    await operations.runOperation({} as WebSocket, "remove-flush-failure", "remove", CRON_PACKAGE_SOURCE);

    expect(manager.removeAndPersist).toHaveBeenCalledOnce();
    expect(events).toContainEqual(expect.objectContaining({
      requestId: "remove-flush-failure",
      ok: false,
      packageChanged: true,
      errorMessage: "Cron daemon and package files were removed, but package settings could not be persisted: settings are read-only",
    }));
  });

  it("reinstalls Cron lifecycle after package updates", async () => {
    const { operations, events, manager, reconcile } = subject();

    await operations.runOperation({} as WebSocket, "update-cron", "update", CRON_PACKAGE_SOURCE);

    expect(manager.update).toHaveBeenCalledWith(CRON_PACKAGE_SOURCE);
    expect(reconcile).toHaveBeenCalledWith({
      source: CRON_PACKAGE_SOURCE,
      agentDir: "/tmp/picky-agent",
      desiredState: "installed",
      forceCommand: true,
    });
    expect(events).toContainEqual(expect.objectContaining({ requestId: "update-cron", ok: true, packageChanged: true }));
  });

  it("keeps the per-agent queue held until Cron lifecycle verification settles", async () => {
    const calls: string[] = [];
    let releaseLifecycle: (() => void) | undefined;
    let markLifecycleStarted: (() => void) | undefined;
    const lifecycleStarted = new Promise<void>((resolve) => { markLifecycleStarted = resolve; });
    const lifecycleGate = new Promise<void>((resolve) => { releaseLifecycle = resolve; });
    const manager = packageManager({
      installAndPersist: vi.fn(async (source: string) => { calls.push(`install:${source}`); }),
    });
    const reconcile = vi.fn(async () => {
      calls.push("lifecycle:start");
      markLifecycleStarted?.();
      await lifecycleGate;
      calls.push("lifecycle:end");
      return { ok: true };
    });
    const { operations } = subject({ packageManager: manager, reconcile });

    const first = operations.runOperation({} as WebSocket, "install-cron-serialized", "install", CRON_PACKAGE_SOURCE);
    await lifecycleStarted;
    const second = operations.runOperation({} as WebSocket, "install-after-cron", "install", "npm:@example/plugin");
    await new Promise<void>((resolve) => { setImmediate(resolve); });

    expect(calls).toEqual([`install:${CRON_PACKAGE_SOURCE}`, "lifecycle:start"]);
    releaseLifecycle?.();
    await Promise.all([first, second]);
    expect(calls).toEqual([
      `install:${CRON_PACKAGE_SOURCE}`,
      "lifecycle:start",
      "lifecycle:end",
      "install:npm:@example/plugin",
    ]);
  });

  it("keeps non-Cron package completion compatible with the existing event shape", async () => {
    const { operations, events } = subject();

    await operations.runOperation({} as WebSocket, "install-other", "install", "npm:@example/plugin");

    expect(events).toContainEqual(expect.objectContaining({ requestId: "install-other", ok: true }));
    expect(events.find((event) => event.requestId === "install-other")).not.toHaveProperty("packageChanged");
  });
});
