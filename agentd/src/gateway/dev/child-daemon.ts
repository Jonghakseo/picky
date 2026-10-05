/**
 * A throwaway child agentd, spawned the way Picky.app spawns one per Pickle
 * (docs/per-pickle-daemon-topology.md, Picky/PickyAgentDaemonLauncher.swift).
 *
 * The stand-in hub used to create every Pickle inside the primary, so the dev
 * stack and the e2e tests never exercised the topology the app actually runs:
 * one daemon per Pickle, each with its own projection stream. Two ownership
 * bugs hid behind that gap.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { join } from "node:path";

export interface ChildDaemonOptions {
  sessionId: string;
  /** Working directory of the Pickle, which is also the child's default cwd. */
  sessionCwd: string;
  /** The agentd package root, the directory that holds `src/index.ts`. */
  packageRoot: string;
  /** Shared with the primary: one token, one session store. */
  token: string;
  appSupportDir: string;
  primaryUrl: string;
  print?: (line: string) => void;
}

const READY_PATTERN = /picky-agentd listening on 127\.0\.0\.1:(\d+)/;
const START_TIMEOUT_MS = 90_000;

export class ChildDaemon {
  private constructor(
    readonly sessionId: string,
    readonly url: string,
    private readonly process: ChildProcess,
  ) {}

  /** Resolves once the child printed the port it bound, like the app's launcher waits. */
  static async spawn(options: ChildDaemonOptions): Promise<ChildDaemon> {
    const print = options.print ?? (() => {});
    const child = spawn("node", ["--import", "tsx", join(options.packageRoot, "src", "index.ts")], {
      cwd: options.packageRoot,
      env: {
        ...process.env,
        PICKY_AGENTD_RUNTIME: "mock",
        PICKY_AGENTD_MODE: "child",
        PICKY_AGENTD_SESSION_ID: options.sessionId,
        PICKY_AGENTD_SESSION_CWD: options.sessionCwd,
        PICKY_AGENTD_PRIMARY_URL: options.primaryUrl,
        PICKY_AGENTD_TOKEN: options.token,
        PICKY_APP_SUPPORT_DIR: options.appSupportDir,
        PICKY_AGENTD_PARENT_PID: String(process.pid),
        // A child binds an OS-assigned port; an inherited primary port would be
        // ignored, but leaving it out keeps the environment honest.
        PICKY_AGENTD_PORT: undefined,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const label = options.sessionId.slice(0, 16);
    child.stderr?.on("data", (chunk: Buffer) => print(`[child ${label}!] ${chunk.toString().trimEnd()}`));

    const port = await new Promise<number>((resolveReady, rejectReady) => {
      const timer = setTimeout(() => rejectReady(new Error("the child daemon did not start in time")), START_TIMEOUT_MS);
      child.stdout?.on("data", (chunk: Buffer) => {
        const line = chunk.toString();
        print(`[child ${label}] ${line.trimEnd()}`);
        const match = READY_PATTERN.exec(line);
        if (!match) return;
        clearTimeout(timer);
        resolveReady(Number(match[1]));
      });
      child.once("exit", (code) => {
        clearTimeout(timer);
        rejectReady(new Error(`the child daemon exited with code ${String(code)}`));
      });
    });

    return new ChildDaemon(options.sessionId, `ws://127.0.0.1:${port}`, child);
  }

  /** Releasing a child is how the Mac ends one: the session stays in the store. */
  async stop(): Promise<void> {
    if (this.process.exitCode !== null || this.process.signalCode !== null) return;
    const exited = new Promise<void>((done) => this.process.once("exit", () => done()));
    this.process.kill("SIGTERM");
    const timer = setTimeout(() => this.process.kill("SIGKILL"), 5_000);
    timer.unref?.();
    await exited;
    clearTimeout(timer);
  }
}
