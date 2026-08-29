import { chmod, mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CRON_PACKAGE_SOURCE, CronPackageLifecycle, DefaultCronLifecycleProbe, isCronPackageSource, type CronLifecycleProbe, type CronPackageLifecycleDependencies } from "./cron-package-lifecycle.js";

const extensionPath = "/tmp/cron-package/index.ts";
const piBinary = "/tmp/picky-pi";

function probe(overrides: Partial<CronLifecycleProbe> = {}): CronLifecycleProbe {
  return {
    isInstalled: vi.fn(async () => false),
    isUninstalled: vi.fn(async () => false),
    ...overrides,
  };
}

type LifecycleOverrides = Omit<Partial<CronPackageLifecycleDependencies>, "resolveExtension"> & {
  resolveExtension?: CronPackageLifecycleDependencies["resolveExtension"];
};

function lifecycle(overrides: LifecycleOverrides = {}) {
  const { resolveExtension, ...rest } = overrides;
  return new CronPackageLifecycle({
    resolveExtension: resolveExtension ?? vi.fn(async () => extensionPath),
    runCommand: vi.fn(async () => ({ ok: true, stderr: "", notifications: [], extensionErrors: [] })),
    probe: probe(),
    environment: { PI_CRON_PI_BIN: piBinary, PI_CRON_LAUNCHD_PLIST_PATH: "/tmp/dev.pi.cron.plist" },
    isExecutable: vi.fn(async () => true),
    ...rest,
  });
}

describe("CronPackageLifecycle", () => {
  it("recognizes only the curated Cron npm source", () => {
    expect(isCronPackageSource(CRON_PACKAGE_SOURCE)).toBe(true);
    expect(isCronPackageSource("npm:@ryan_nookpi/pi-extension-cron@1.2.3")).toBe(true);
    expect(isCronPackageSource("npm:@ryan_nookpi/pi-extension-memory-layer")).toBe(false);
    expect(isCronPackageSource("npm:@ryan_nookpi/pi-extension-cron/other")).toBe(false);
  });

  it("runs install with the exact Pi binary and verifies the durable postcondition", async () => {
    let installed = false;
    const isInstalled = vi.fn(async () => installed);
    const runCommand = vi.fn(async (input: { environment: NodeJS.ProcessEnv }) => {
      installed = true;
      expect(input.environment).toMatchObject({ PI_CODING_AGENT_DIR: "/tmp/picky-agent", PI_CRON_PI_BIN: piBinary });
      return { ok: true, stderr: "", notifications: [], extensionErrors: [] };
    });
    const subject = lifecycle({ runCommand, probe: probe({ isInstalled }) });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" })).resolves.toEqual({ ok: true });
    expect(runCommand).toHaveBeenCalledWith(expect.objectContaining({ extensionPath, command: "install" }));
    expect(isInstalled).toHaveBeenCalledWith({
      plistPath: "/tmp/dev.pi.cron.plist",
      daemonPath: "/tmp/cron-package/daemon.mjs",
      piBinaryPath: piBinary,
    });
  });

  it("prefers Picky's resolved Pi path over a stale inherited Cron override", async () => {
    let installed = false;
    const runCommand = vi.fn(async (input: { environment: NodeJS.ProcessEnv }) => {
      installed = true;
      expect(input.environment.PI_CRON_PI_BIN).toBe("/tmp/picky-resolved-pi");
      return { ok: true, stderr: "", notifications: [], extensionErrors: [] };
    });
    const isExecutable = vi.fn(async (path: string) => path === "/tmp/picky-resolved-pi");
    const subject = lifecycle({
      environment: {
        PICKY_PI_BINARY_PATH: "/tmp/picky-resolved-pi",
        PI_CRON_PI_BIN: "/tmp/stale-pi",
        PI_CRON_LAUNCHD_PLIST_PATH: "/tmp/dev.pi.cron.plist",
      },
      isExecutable,
      runCommand,
      probe: probe({ isInstalled: async () => installed }),
    });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" })).resolves.toEqual({ ok: true });
    expect(isExecutable).toHaveBeenCalledWith("/tmp/picky-resolved-pi");
  });

  it("does not rerun install when the exact durable state is already verified", async () => {
    const runCommand = vi.fn();
    const subject = lifecycle({ runCommand, probe: probe({ isInstalled: async () => true }) });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" })).resolves.toEqual({ ok: true });
    expect(runCommand).not.toHaveBeenCalled();
  });

  it("reruns install for an update even when the previous durable state still looks valid", async () => {
    const runCommand = vi.fn(async () => ({ ok: true, stderr: "", notifications: [], extensionErrors: [] }));
    const subject = lifecycle({ runCommand, probe: probe({ isInstalled: async () => true }) });

    await expect(subject.reconcile({
      source: CRON_PACKAGE_SOURCE,
      agentDir: "/tmp/picky-agent",
      desiredState: "installed",
      forceCommand: true,
    })).resolves.toEqual({ ok: true });
    expect(runCommand).toHaveBeenCalledWith(expect.objectContaining({ command: "install" }));
  });

  it("reports a visible lifecycle failure when no executable Pi path is available", async () => {
    const runCommand = vi.fn();
    const subject = lifecycle({ environment: {}, runCommand });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" })).resolves.toMatchObject({
      ok: false,
      errorMessage: "Cron setup requires an executable Pi binary path (PI_CRON_PI_BIN)",
    });
    expect(runCommand).not.toHaveBeenCalled();
  });

  it("accepts the desired durable state after an ambiguous RPC acknowledgement loss", async () => {
    let installed = false;
    const runCommand = vi.fn(async () => {
      installed = true;
      return { ok: false, errorMessage: "stdin closed", stderr: "", notifications: ["installed"], extensionErrors: [] };
    });
    const subject = lifecycle({ runCommand, probe: probe({ isInstalled: async () => installed }) });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "installed" })).resolves.toEqual({ ok: true });
  });

  it("does not resolve or run Cron when plist absence and launchctl unload are already verified", async () => {
    const resolveExtension = vi.fn();
    const runCommand = vi.fn();
    const subject = lifecycle({ resolveExtension, runCommand, probe: probe({ isUninstalled: async () => true }) });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "uninstalled" })).resolves.toEqual({ ok: true });
    expect(resolveExtension).not.toHaveBeenCalled();
    expect(runCommand).not.toHaveBeenCalled();
  });

  it("keeps failure visible when uninstall cannot reach the durable unloaded state", async () => {
    const runCommand = vi.fn(async () => ({ ok: true, stderr: "", notifications: [], extensionErrors: [] }));
    const subject = lifecycle({ runCommand, probe: probe({ isUninstalled: async () => false }) });

    await expect(subject.reconcile({ source: CRON_PACKAGE_SOURCE, agentDir: "/tmp/picky-agent", desiredState: "uninstalled" })).resolves.toMatchObject({
      ok: false,
      errorMessage: expect.stringContaining("Cron uninstall did not reach its durable launchd postcondition"),
    });
    expect(runCommand).toHaveBeenCalledWith(expect.objectContaining({ command: "uninstall" }));
  });

  it("verifies plist contents and loaded state through hermetic command overrides", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-cron-probe-"));
    const plistPath = join(root, "dev.pi.cron.plist");
    const plutilPath = join(root, "plutil");
    const launchctlPath = join(root, "launchctl");
    await writeFile(plistPath, "temporary plist fixture");
    await writeFile(plutilPath, `#!/bin/sh
case "$2" in
  ProgramArguments) printf '%s\\n' '["/usr/bin/node","/tmp/cron/daemon.mjs"]' ;;
  EnvironmentVariables) printf '%s\\n' '{"PI_CRON_PI_BIN":"/tmp/picky-pi"}' ;;
  *) exit 2 ;;
esac
`);
    await writeFile(launchctlPath, `#!/bin/sh
if [ "\${PICKY_TEST_LAUNCHCTL_EXIT:-0}" -ne 0 ]; then
  if [ "\${PICKY_TEST_LAUNCHCTL_MISSING:-0}" -eq 1 ]; then
    printf '%s\n' 'Could not find service "dev.pi.cron" in domain for user' >&2
  else
    printf '%s\n' 'launchctl unavailable' >&2
  fi
  exit "$PICKY_TEST_LAUNCHCTL_EXIT"
fi
printf 'arguments = {\\n\\t%s\\n}\\nenvironment = {\\n\\tPI_CRON_PI_BIN => %s\\n}\\n' "\${PICKY_TEST_LOADED_DAEMON:-/tmp/cron/daemon.mjs}" "\${PICKY_TEST_LOADED_PI:-/tmp/picky-pi}"
`);
    await Promise.all([chmod(plutilPath, 0o755), chmod(launchctlPath, 0o755)]);

    try {
      const loadedProbe = new DefaultCronLifecycleProbe({
        PI_CRON_PLUTIL_BIN: plutilPath,
        PI_CRON_LAUNCHCTL_BIN: launchctlPath,
        PICKY_TEST_LAUNCHCTL_EXIT: "0",
      });
      await expect(loadedProbe.isInstalled({
        plistPath,
        daemonPath: "/tmp/cron/daemon.mjs",
        piBinaryPath: "/tmp/picky-pi",
      })).resolves.toBe(true);
      await expect(loadedProbe.isInstalled({
        plistPath,
        daemonPath: "/tmp/cron/daemon.mjs",
        piBinaryPath: "/tmp/other-pi",
      })).resolves.toBe(false);
      const staleLoadedProbe = new DefaultCronLifecycleProbe({
        PI_CRON_PLUTIL_BIN: plutilPath,
        PI_CRON_LAUNCHCTL_BIN: launchctlPath,
        PICKY_TEST_LAUNCHCTL_EXIT: "0",
        PICKY_TEST_LOADED_DAEMON: "/tmp/cron/daemon.mjs.backup",
        PICKY_TEST_LOADED_PI: "/tmp/picky-pi.backup",
      });
      await expect(staleLoadedProbe.isInstalled({
        plistPath,
        daemonPath: "/tmp/cron/daemon.mjs",
        piBinaryPath: "/tmp/picky-pi",
      })).resolves.toBe(false);

      await unlink(plistPath);
      const unloadedProbe = new DefaultCronLifecycleProbe({
        PI_CRON_PLUTIL_BIN: plutilPath,
        PI_CRON_LAUNCHCTL_BIN: launchctlPath,
        PICKY_TEST_LAUNCHCTL_EXIT: "1",
        PICKY_TEST_LAUNCHCTL_MISSING: "1",
      });
      await expect(unloadedProbe.isUninstalled({ plistPath })).resolves.toBe(true);
      await expect(loadedProbe.isUninstalled({ plistPath })).resolves.toBe(false);
      const genericFailureProbe = new DefaultCronLifecycleProbe({
        PI_CRON_PLUTIL_BIN: plutilPath,
        PI_CRON_LAUNCHCTL_BIN: launchctlPath,
        PICKY_TEST_LAUNCHCTL_EXIT: "1",
      });
      await expect(genericFailureProbe.isUninstalled({ plistPath })).resolves.toBe(false);
      const unverifiedProbe = new DefaultCronLifecycleProbe({
        PI_CRON_PLUTIL_BIN: plutilPath,
        PI_CRON_LAUNCHCTL_BIN: join(root, "missing-launchctl"),
        PI_CRON_PROBE_TIMEOUT_MS: "10",
      });
      await expect(unverifiedProbe.isUninstalled({ plistPath })).resolves.toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects a non-Cron source before resolving any extension", async () => {
    const resolveExtension = vi.fn();
    const subject = lifecycle({ resolveExtension });

    await expect(subject.reconcile({ source: "npm:@example/plugin", agentDir: "/tmp/picky-agent", desiredState: "installed" })).resolves.toMatchObject({ ok: false });
    expect(resolveExtension).not.toHaveBeenCalled();
  });
});
