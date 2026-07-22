import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

export const NPM_COMMAND_TIMEOUT_EXIT_CODE = 124;
const FORCE_KILL_GRACE_MS = 2_000;

export interface NpmCommandRunnerInvocation {
  timeoutMs: number;
  command: string[];
  npmArgs: string[];
}

export function parseNpmCommandRunnerArguments(args: string[]): NpmCommandRunnerInvocation {
  const timeoutIndex = args.indexOf("--timeout-ms");
  const commandIndex = args.indexOf("--command-json");
  if (timeoutIndex < 0 || commandIndex < 0) {
    throw new Error("npm command runner requires --timeout-ms and --command-json");
  }
  const timeoutMs = Number(args[timeoutIndex + 1]);
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error(`Invalid npm command timeout: ${JSON.stringify(args[timeoutIndex + 1])}`);
  }
  const parsed = JSON.parse(args[commandIndex + 1] ?? "null") as unknown;
  if (!Array.isArray(parsed) || parsed.length === 0 || !parsed.every((value) => typeof value === "string")) {
    throw new Error("npm command runner command must be a non-empty string array");
  }
  let consumedEnd = commandIndex + 2;
  if (args[consumedEnd] === "--") {
    const managerIdentity = args[consumedEnd + 1];
    if (!managerIdentity) throw new Error("npm command runner manager identity is missing");
    consumedEnd += 2;
  }
  return {
    timeoutMs,
    command: parsed,
    npmArgs: args.slice(consumedEnd),
  };
}

export async function runNpmCommandWithTimeout(
  invocation: NpmCommandRunnerInvocation,
  spawnCommand: typeof spawn = spawn,
  forceKillGraceMs = FORCE_KILL_GRACE_MS,
): Promise<number> {
  const [executable, ...baseArgs] = invocation.command;
  const usesProcessGroup = process.platform !== "win32";
  const child = spawnCommand(executable!, [...baseArgs, ...invocation.npmArgs], {
    stdio: "inherit",
    env: process.env,
    detached: usesProcessGroup,
  });

  return await new Promise<number>((resolveExit) => {
    let requestedExitCode: number | undefined;
    let naturalExitCode: number | undefined;
    let childExited = false;
    let forceKillTimer: NodeJS.Timeout | undefined;
    let processTreePollTimer: NodeJS.Timeout | undefined;
    const beginTermination = (exitCode: number, initialSignal: NodeJS.Signals) => {
      requestedExitCode ??= exitCode;
      signalProcessTree(child, initialSignal, usesProcessGroup);
      forceKillTimer ??= setTimeout(() => signalProcessTree(child, "SIGKILL", usesProcessGroup), forceKillGraceMs);
      pollForTerminatedTree();
    };
    const timeout = setTimeout(() => {
      process.stderr.write(`Picky npm command timed out after ${invocation.timeoutMs}ms\n`);
      beginTermination(NPM_COMMAND_TIMEOUT_EXIT_CODE, "SIGTERM");
    }, invocation.timeoutMs);

    const onSigterm = () => beginTermination(1, "SIGTERM");
    const onSigint = () => beginTermination(1, "SIGINT");
    process.once("SIGTERM", onSigterm);
    process.once("SIGINT", onSigint);

    const finish = (exitCode: number) => {
      clearTimeout(timeout);
      if (forceKillTimer) clearTimeout(forceKillTimer);
      if (processTreePollTimer) clearTimeout(processTreePollTimer);
      process.off("SIGTERM", onSigterm);
      process.off("SIGINT", onSigint);
      resolveExit(exitCode);
    };
    function pollForTerminatedTree() {
      if (processTreePollTimer) return;
      if (childExited && !isProcessTreeAlive(child, usesProcessGroup)) {
        finish(requestedExitCode ?? naturalExitCode ?? 1);
        return;
      }
      processTreePollTimer = setTimeout(() => {
        processTreePollTimer = undefined;
        pollForTerminatedTree();
      }, 25);
    }

    child.once("error", (error) => {
      process.stderr.write(`Picky npm command failed to start: ${error.message}\n`);
      finish(127);
    });
    child.once("exit", (code, signal) => {
      childExited = true;
      if (typeof code === "number") {
        naturalExitCode = code;
      } else {
        process.stderr.write(`Picky npm command exited from signal ${signal ?? "unknown"}\n`);
        naturalExitCode = 1;
      }
      pollForTerminatedTree();
    });
  });
}

function isProcessTreeAlive(child: ChildProcess, usesProcessGroup: boolean): boolean {
  if (child.pid === undefined) return false;
  if (!usesProcessGroup) return child.exitCode === null && child.signalCode === null;
  try {
    process.kill(-child.pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function signalProcessTree(child: ChildProcess, signal: NodeJS.Signals, usesProcessGroup: boolean): void {
  if (child.pid === undefined) return;
  try {
    if (usesProcessGroup) {
      process.kill(-child.pid, signal);
    } else {
      child.kill(signal);
    }
  } catch {
    // The command may have exited between timeout delivery and process-group signaling.
  }
}

async function main(): Promise<void> {
  try {
    const invocation = parseNpmCommandRunnerArguments(process.argv.slice(2));
    process.exitCode = await runNpmCommandWithTimeout(invocation);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`Picky npm command runner error: ${message}\n`);
    process.exitCode = 2;
  }
}

const isMain = process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) void main();
