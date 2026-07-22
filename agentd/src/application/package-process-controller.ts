import { spawn, type ChildProcess } from "node:child_process";

const DEFAULT_FORCE_KILL_GRACE_MS = 2_000;
const DEFAULT_POLL_INTERVAL_MS = 25;

interface CommandOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
}

interface CommandResult {
  code: number | null;
  signal: NodeJS.Signals | null;
}

export interface CancellablePackageProcessControllerOptions {
  forceKillGraceMs?: number;
  pollIntervalMs?: number;
}

/**
 * Runs package-manager commands in isolated process groups and can cancel every
 * command started by one package mutation. Completion waits for the whole group,
 * not only its leader, so lifecycle descendants cannot overlap the next mutation.
 */
export class CancellablePackageProcessController {
  private readonly forceKillGraceMs: number;
  private readonly pollIntervalMs: number;
  private readonly active = new Set<TrackedPackageProcess>();
  private cancelled = false;

  constructor(options: CancellablePackageProcessControllerOptions = {}) {
    this.forceKillGraceMs = options.forceKillGraceMs ?? DEFAULT_FORCE_KILL_GRACE_MS;
    this.pollIntervalMs = options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS;
  }

  async runCommand(command: string, args: string[], options?: CommandOptions): Promise<void> {
    const result = await this.start(command, args, options, "inherit").completion;
    if (result.code !== 0) {
      const exitStatus = result.code === null ? `signal ${result.signal ?? "unknown"}` : `code ${result.code}`;
      throw new Error(`${command} ${args.join(" ")} failed with ${exitStatus}`);
    }
  }

  async runCommandCapture(command: string, args: string[], options?: CommandOptions): Promise<string> {
    const tracked = this.start(command, args, options, "capture");
    let stdout = "";
    let stderr = "";
    tracked.child.stdout?.on("data", (data: Buffer | string) => { stdout += data.toString(); });
    tracked.child.stderr?.on("data", (data: Buffer | string) => { stderr += data.toString(); });
    let timeout: NodeJS.Timeout | undefined;
    let timedOut = false;
    if (typeof options?.timeoutMs === "number") {
      timeout = setTimeout(() => {
        timedOut = true;
        void tracked.cancel("timed out");
      }, options.timeoutMs);
    }
    try {
      const result = await tracked.completion;
      if (timedOut) throw new Error(`${command} ${args.join(" ")} timed out after ${options?.timeoutMs}ms`);
      if (result.code !== 0) {
        const exitStatus = result.code === null ? `signal ${result.signal ?? "unknown"}` : `code ${result.code}`;
        throw new Error(`${command} ${args.join(" ")} failed with ${exitStatus}: ${stderr || stdout}`);
      }
      return stdout.trim();
    } catch (error) {
      if (timedOut) throw new Error(`${command} ${args.join(" ")} timed out after ${options?.timeoutMs}ms`);
      throw error;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  async cancelAll(): Promise<void> {
    this.cancelled = true;
    await Promise.all([...this.active].map(async (tracked) => {
      await tracked.cancel("cancelled").catch(() => {});
    }));
  }

  private start(
    command: string,
    args: string[],
    options: CommandOptions | undefined,
    stdio: "inherit" | "capture",
  ): TrackedPackageProcess {
    if (this.cancelled) throw new Error("Package command cancelled before start");
    const usesProcessGroup = process.platform !== "win32";
    const child = spawn(command, args, {
      cwd: options?.cwd,
      env: { ...process.env, ...options?.env },
      stdio: stdio === "capture" ? ["ignore", "pipe", "pipe"] : "inherit",
      detached: usesProcessGroup,
    });
    const tracked = new TrackedPackageProcess(child, {
      usesProcessGroup,
      forceKillGraceMs: this.forceKillGraceMs,
      pollIntervalMs: this.pollIntervalMs,
    });
    this.active.add(tracked);
    void tracked.completion.finally(() => this.active.delete(tracked)).catch(() => {});
    return tracked;
  }
}

interface PatchablePackageManager {
  runCommand(command: string, args: string[], options?: CommandOptions): Promise<void>;
  runCommandCapture(command: string, args: string[], options?: CommandOptions): Promise<string>;
}

/** Installs the controller at Pi's external-command seam on its default manager. */
export function installCancellablePackageCommands(
  packageManager: object,
  controller: CancellablePackageProcessController,
): void {
  const host = packageManager as Partial<PatchablePackageManager>;
  if (typeof host.runCommand !== "function" || typeof host.runCommandCapture !== "function") {
    throw new Error("Pi package manager command seam is unavailable");
  }
  host.runCommand = controller.runCommand.bind(controller);
  host.runCommandCapture = controller.runCommandCapture.bind(controller);
}

class TrackedPackageProcess {
  readonly completion: Promise<CommandResult>;
  private resolveCompletion!: (result: CommandResult) => void;
  private rejectCompletion!: (error: Error) => void;
  private exited = false;
  private exitCode: number | null = null;
  private exitSignal: NodeJS.Signals | null = null;
  private spawnError: Error | undefined;
  private cancellationReason: string | undefined;
  private finished = false;
  private forceKillTimer: NodeJS.Timeout | undefined;
  private pollTimer: NodeJS.Timeout | undefined;

  constructor(
    readonly child: ChildProcess,
    private readonly options: {
      usesProcessGroup: boolean;
      forceKillGraceMs: number;
      pollIntervalMs: number;
    },
  ) {
    this.completion = new Promise<CommandResult>((resolve, reject) => {
      this.resolveCompletion = resolve;
      this.rejectCompletion = reject;
    });
    child.once("error", (error) => {
      this.spawnError = error;
      this.exited = true;
      this.checkFinished();
    });
    child.once("exit", (code, signal) => {
      this.exited = true;
      this.exitCode = code;
      this.exitSignal = signal;
      this.checkFinished();
    });
  }

  async cancel(reason: string): Promise<void> {
    if (this.finished) return;
    this.cancellationReason = this.cancellationReason ?? reason;
    this.signal("SIGTERM");
    this.forceKillTimer ??= setTimeout(() => this.signal("SIGKILL"), this.options.forceKillGraceMs);
    this.schedulePoll();
    await this.completion.then(() => undefined, () => undefined);
  }

  private checkFinished(): void {
    if (this.finished) return;
    if (!this.exited || this.isTreeAlive()) {
      if (this.exited || this.cancellationReason) this.schedulePoll();
      return;
    }
    this.finished = true;
    if (this.forceKillTimer) clearTimeout(this.forceKillTimer);
    if (this.pollTimer) clearTimeout(this.pollTimer);
    if (this.spawnError) {
      this.rejectCompletion(this.spawnError);
    } else if (this.cancellationReason) {
      this.rejectCompletion(new Error(`Package command ${this.cancellationReason}`));
    } else {
      this.resolveCompletion({ code: this.exitCode, signal: this.exitSignal });
    }
  }

  private schedulePoll(): void {
    if (this.finished || this.pollTimer) return;
    this.pollTimer = setTimeout(() => {
      this.pollTimer = undefined;
      this.checkFinished();
    }, this.options.pollIntervalMs);
  }

  private isTreeAlive(): boolean {
    const pid = this.child.pid;
    if (pid === undefined) return !this.exited;
    if (!this.options.usesProcessGroup) return !this.exited;
    try {
      process.kill(-pid, 0);
      return true;
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "EPERM";
    }
  }

  private signal(signal: NodeJS.Signals): void {
    const pid = this.child.pid;
    if (pid === undefined) return;
    try {
      if (this.options.usesProcessGroup) process.kill(-pid, signal);
      else this.child.kill(signal);
    } catch {
      this.checkFinished();
    }
  }
}
