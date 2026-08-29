import { access, constants, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { execFile } from "node:child_process";
import { PiExtensionCommandRunner, type PiExtensionCommandRunResult } from "./pi-extension-command-runner.js";

const execFileAsync = promisify(execFile);
export const CRON_PACKAGE_SOURCE = "npm:@ryan_nookpi/pi-extension-cron";
export const CRON_LAUNCH_AGENT_LABEL = "dev.pi.cron";
const DEFAULT_PROBE_TIMEOUT_MS = 5_000;

export type CronLifecycleDesiredState = "installed" | "uninstalled";

export interface CronLifecycleProbe {
  isInstalled(input: { plistPath: string; daemonPath: string; piBinaryPath: string }): Promise<boolean>;
  isUninstalled(input: { plistPath: string }): Promise<boolean>;
}

export interface CronPackageLifecycleDependencies {
  resolveExtension(source: string): Promise<string>;
  runCommand?: (input: {
    agentDir: string;
    extensionPath: string;
    command: "install" | "uninstall";
    environment: NodeJS.ProcessEnv;
  }) => Promise<PiExtensionCommandRunResult>;
  probe?: CronLifecycleProbe;
  environment?: NodeJS.ProcessEnv;
  homeDirectory?: () => string;
  isExecutable?: (path: string) => Promise<boolean>;
}

export interface CronLifecycleResult {
  ok: boolean;
  errorMessage?: string;
}

/** True only for the curated Cron npm identity, with an optional npm version suffix. */
export function isCronPackageSource(source: string): boolean {
  return /^npm:@ryan_nookpi\/pi-extension-cron(?:@[^/]+)?$/.test(source.trim());
}

/**
 * Reconciles Cron's public slash-command lifecycle with durable launchd state.
 * RPC transport acknowledgements are diagnostic only: the requested postcondition
 * is authoritative after an ambiguous child-process result.
 */
export class CronPackageLifecycle {
  constructor(private readonly dependencies: CronPackageLifecycleDependencies) {}

  async reconcile(input: {
    source: string;
    agentDir: string;
    desiredState: CronLifecycleDesiredState;
    forceCommand?: boolean;
  }): Promise<CronLifecycleResult> {
    if (!isCronPackageSource(input.source)) {
      return { ok: false, errorMessage: `Cron lifecycle is unavailable for non-Cron source: ${input.source}` };
    }

    const environment = this.dependencies.environment ?? process.env;
    const plistPath = environment.PI_CRON_LAUNCHD_PLIST_PATH
      ?? join((this.dependencies.homeDirectory ?? homedir)(), "Library", "LaunchAgents", `${CRON_LAUNCH_AGENT_LABEL}.plist`);
    if (input.desiredState === "uninstalled") {
      const alreadyUninstalled = await this.isUninstalled(plistPath);
      if (alreadyUninstalled) return { ok: true };
    }

    let extensionPath: string;
    try {
      extensionPath = await this.dependencies.resolveExtension(input.source);
    } catch (error) {
      return { ok: false, errorMessage: `Unable to resolve the installed Cron extension: ${error instanceof Error ? error.message : String(error)}` };
    }
    const daemonPath = join(dirname(extensionPath), "daemon.mjs");

    if (input.desiredState === "uninstalled") {
      const run = await this.safeRun({
        agentDir: input.agentDir,
        extensionPath,
        command: "uninstall",
        environment: { ...environment, PI_CODING_AGENT_DIR: input.agentDir },
      });
      const reconciled = await this.isUninstalled(plistPath);
      return reconciled
        ? { ok: true }
        : { ok: false, errorMessage: lifecycleFailureMessage("uninstall", run) };
    }

    const piBinaryPath = environment.PICKY_PI_BINARY_PATH ?? environment.PI_CRON_PI_BIN;
    if (!piBinaryPath || !(await (this.dependencies.isExecutable ?? executableFile)(piBinaryPath))) {
      return { ok: false, errorMessage: "Cron setup requires an executable Pi binary path (PI_CRON_PI_BIN)" };
    }
    const alreadyInstalled = await this.isInstalled(plistPath, daemonPath, piBinaryPath);
    if (alreadyInstalled && !input.forceCommand) return { ok: true };

    const run = await this.safeRun({
      agentDir: input.agentDir,
      extensionPath,
      command: "install",
      environment: { ...environment, PI_CODING_AGENT_DIR: input.agentDir, PI_CRON_PI_BIN: piBinaryPath },
    });
    const reconciled = await this.isInstalled(plistPath, daemonPath, piBinaryPath);
    return reconciled
      ? { ok: true }
      : { ok: false, errorMessage: lifecycleFailureMessage("install", run) };
  }

  private async safeRun(input: {
    agentDir: string;
    extensionPath: string;
    command: "install" | "uninstall";
    environment: NodeJS.ProcessEnv;
  }): Promise<PiExtensionCommandRunResult> {
    try {
      return await (this.dependencies.runCommand ?? ((request) => new PiExtensionCommandRunner().run(request)))(input);
    } catch (error) {
      return {
        ok: false,
        errorMessage: error instanceof Error ? error.message : String(error),
        stderr: "",
        notifications: [],
        extensionErrors: [],
      };
    }
  }

  private probe(): CronLifecycleProbe {
    return this.dependencies.probe ?? new DefaultCronLifecycleProbe(this.dependencies.environment ?? process.env);
  }

  private async isInstalled(plistPath: string, daemonPath: string, piBinaryPath: string): Promise<boolean> {
    return await this.probe().isInstalled({ plistPath, daemonPath, piBinaryPath }).catch(() => false);
  }

  private async isUninstalled(plistPath: string): Promise<boolean> {
    return await this.probe().isUninstalled({ plistPath }).catch(() => false);
  }
}

export class DefaultCronLifecycleProbe implements CronLifecycleProbe {
  constructor(private readonly environment: NodeJS.ProcessEnv = process.env) {}

  async isInstalled(input: { plistPath: string; daemonPath: string; piBinaryPath: string }): Promise<boolean> {
    try {
      await access(input.plistPath, constants.F_OK);
      const [programArguments, environmentVariables, launchctl] = await Promise.all([
        plistValue(input.plistPath, "ProgramArguments", this.environment),
        plistValue(input.plistPath, "EnvironmentVariables", this.environment),
        launchctlPrint(this.environment),
      ]);
      return Array.isArray(programArguments)
        && programArguments.includes(input.daemonPath)
        && isExactCronPiBinary(environmentVariables, input.piBinaryPath)
        && launchctl.loaded
        && launchctlBlockValues(launchctl.output, "arguments").includes(input.daemonPath)
        && launchctlEnvironmentValue(launchctl.output, "PI_CRON_PI_BIN") === input.piBinaryPath;
    } catch {
      return false;
    }
  }

  async isUninstalled(input: { plistPath: string }): Promise<boolean> {
    const [plistAbsent, loaded] = await Promise.all([
      pathIsExplicitlyAbsent(input.plistPath),
      launchctlPrint(this.environment),
    ]);
    return plistAbsent && loaded.verified && !loaded.loaded;
  }
}

async function executableFile(path: string): Promise<boolean> {
  try {
    const details = await stat(path);
    if (!details.isFile()) return false;
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function plistValue(plistPath: string, key: "ProgramArguments" | "EnvironmentVariables", environment: NodeJS.ProcessEnv): Promise<unknown> {
  const { stdout } = await execFileAsync(
    environment.PI_CRON_PLUTIL_BIN ?? "/usr/bin/plutil",
    ["-extract", key, "json", "-o", "-", plistPath],
    processOptions(environment),
  );
  return JSON.parse(stdout);
}

async function launchctlPrint(environment: NodeJS.ProcessEnv): Promise<{ loaded: boolean; output: string; verified: boolean }> {
  const uid = typeof process.getuid === "function" ? process.getuid() : undefined;
  if (uid === undefined) return { loaded: false, output: "", verified: false };
  try {
    const { stdout } = await execFileAsync(
      environment.PI_CRON_LAUNCHCTL_BIN ?? "/bin/launchctl",
      ["print", `gui/${uid}/${CRON_LAUNCH_AGENT_LABEL}`],
      processOptions(environment),
    );
    return { loaded: true, output: stdout, verified: true };
  } catch (error) {
    const failure = error as { code?: unknown; killed?: boolean; signal?: unknown; stderr?: unknown };
    const stderr = typeof failure.stderr === "string" ? failure.stderr : "";
    const verifiedUnloaded = typeof failure.code === "number"
      && failure.killed !== true
      && failure.signal == null
      && /could not find service\b/i.test(stderr);
    return { loaded: false, output: "", verified: verifiedUnloaded };
  }
}

async function pathIsExplicitlyAbsent(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return false;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT";
  }
}

function launchctlBlockValues(output: string, name: string): string[] {
  const lines = output.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === `${name} = {`);
  if (start < 0) return [];
  const values: string[] = [];
  for (const line of lines.slice(start + 1)) {
    const value = line.trim();
    if (value === "}") return values;
    if (value) values.push(value.replace(/^\d+\s*=\s*/, ""));
  }
  return [];
}

function launchctlEnvironmentValue(output: string, key: string): string | undefined {
  for (const value of launchctlBlockValues(output, "environment")) {
    const separator = value.indexOf("=>");
    if (separator < 0 || value.slice(0, separator).trim() !== key) continue;
    return value.slice(separator + 2).trim();
  }
  return undefined;
}

function processOptions(environment: NodeJS.ProcessEnv): { env: NodeJS.ProcessEnv; timeout: number; killSignal: NodeJS.Signals } {
  const configured = Number(environment.PI_CRON_PROBE_TIMEOUT_MS);
  const timeout = Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_PROBE_TIMEOUT_MS;
  return { env: environment, timeout, killSignal: "SIGKILL" };
}

function isExactCronPiBinary(environmentVariables: unknown, piBinaryPath: string): boolean {
  return environmentVariables !== null
    && typeof environmentVariables === "object"
    && (environmentVariables as Record<string, unknown>).PI_CRON_PI_BIN === piBinaryPath;
}

function lifecycleFailureMessage(command: "install" | "uninstall", run: PiExtensionCommandRunResult): string {
  const details = [run.errorMessage, ...run.extensionErrors, ...run.notifications, run.stderr.trim()]
    .filter((value): value is string => Boolean(value))
    .join("; ");
  return `Cron ${command} did not reach its durable launchd postcondition${details ? `: ${details}` : ""}`;
}
