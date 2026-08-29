import { spawn, type ChildProcess, type SpawnOptionsWithoutStdio } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { Readable, Writable } from "node:stream";
const GET_COMMANDS_REQUEST_ID = "picky-cron-get-commands";
const PROMPT_REQUEST_ID = "picky-cron-prompt";
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_FORCE_KILL_GRACE_MS = 1_000;

export type PiExtensionCommand = "install" | "uninstall";

export interface PiExtensionCommandRunRequest {
  agentDir: string;
  extensionPath: string;
  command: PiExtensionCommand;
  environment: NodeJS.ProcessEnv;
}

export interface PiExtensionCommandRunResult {
  ok: boolean;
  errorMessage?: string;
  stderr: string;
  notifications: string[];
  extensionErrors: string[];
}

export interface RpcChildProcess {
  stdin: Writable | null;
  stdout: Readable | null;
  stderr: Readable | null;
  once(event: "error", listener: (error: Error) => void): this;
  once(event: "exit", listener: (code: number | null, signal: NodeJS.Signals | null) => void): this;
  kill(signal?: NodeJS.Signals | number): boolean;
}

export interface PiExtensionCommandRunnerDependencies {
  resolveRpcEntry?: () => string;
  spawn?: (command: string, args: string[], options: SpawnOptionsWithoutStdio) => RpcChildProcess;
  timeoutMs?: number;
  forceKillGraceMs?: number;
}

interface RunnerState {
  failure?: string;
  promptAcknowledged: boolean;
  registered: boolean;
  notifications: string[];
  extensionErrors: string[];
}

interface FrameActions {
  fail(message: string): void;
  terminate(): void;
  send(payload: Record<string, unknown>): void;
  endInput(): void;
}

/**
 * Runs one extension slash command through Pi RPC without loading user extensions,
 * skills, context files, tools, or prompt templates. It first proves that the exact
 * extension registered the requested command so an unregistered `/cron` can never
 * fall through to a model prompt.
 */
export class PiExtensionCommandRunner {
  constructor(private readonly dependencies: PiExtensionCommandRunnerDependencies = {}) {}

  async run(request: PiExtensionCommandRunRequest): Promise<PiExtensionCommandRunResult> {
    const resolveRpcEntry = this.dependencies.resolveRpcEntry ?? (() => fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent/rpc-entry")));
    const spawnRpc = this.dependencies.spawn ?? ((command, args, options) => spawn(command, args, options) as unknown as RpcChildProcess);
    const child = spawnRpc(process.execPath, [
      resolveRpcEntry(),
      "--mode", "rpc",
      "--no-session",
      "--no-extensions",
      "--extension", request.extensionPath,
      "--no-skills",
      "--no-prompt-templates",
      "--no-context-files",
      "--no-builtin-tools",
    ], {
      cwd: process.cwd(),
      env: request.environment,
      stdio: "pipe",
    });

    return await new Promise<PiExtensionCommandRunResult>((resolve) => {
      let stdoutBuffer = "";
      let stderr = "";
      const state: RunnerState = {
        promptAcknowledged: false,
        registered: false,
        notifications: [],
        extensionErrors: [],
      };
      let finished = false;
      let timeout: NodeJS.Timeout | undefined;
      let forceKillTimer: NodeJS.Timeout | undefined;

      const fail = (message: string) => {
        state.failure ??= message;
      };
      const endInput = () => {
        if (child.stdin && !child.stdin.destroyed) child.stdin.end();
      };
      const terminate = () => {
        endInput();
        try { child.kill("SIGTERM"); } catch { /* Child may already be gone. */ }
        forceKillTimer ??= setTimeout(() => {
          try { child.kill("SIGKILL"); } catch { /* Child may already be gone. */ }
          fail("Pi RPC did not exit before the force-kill deadline");
          complete(null, "SIGKILL");
        }, this.dependencies.forceKillGraceMs ?? DEFAULT_FORCE_KILL_GRACE_MS);
      };
      const send = (payload: Record<string, unknown>) => {
        if (!child.stdin || child.stdin.destroyed || child.stdin.writableEnded) {
          fail("Pi RPC stdin closed before command dispatch");
          return;
        }
        child.stdin.write(`${JSON.stringify(payload)}\n`);
      };
      const complete = (code: number | null, signal: NodeJS.Signals | null) => {
        if (finished) return;
        finished = true;
        if (timeout) clearTimeout(timeout);
        if (forceKillTimer) clearTimeout(forceKillTimer);
        if (code !== 0 && !state.failure) fail(`Pi RPC exited with ${signal ? `signal ${signal}` : `code ${code ?? "unknown"}`}`);
        if (!state.registered && !state.failure) fail("Cron command was not registered by the isolated extension");
        if (!state.promptAcknowledged && !state.failure) fail("Pi RPC did not acknowledge the Cron command prompt");
        if (state.extensionErrors.length > 0 && !state.failure) fail(`Cron extension error: ${state.extensionErrors.join("; ")}`);
        resolve({
          ok: state.failure === undefined,
          errorMessage: state.failure,
          stderr,
          notifications: state.notifications,
          extensionErrors: state.extensionErrors,
        });
      };
      const processFrame = (frame: unknown) => {
        processRpcFrame(frame, request.command, state, { fail, terminate, send, endInput });
      };
      const consumeStdout = (chunk: Buffer | string) => {
        stdoutBuffer += chunk.toString();
        while (true) {
          const newline = stdoutBuffer.indexOf("\n");
          if (newline < 0) return;
          const raw = stdoutBuffer.slice(0, newline).replace(/\r$/, "");
          stdoutBuffer = stdoutBuffer.slice(newline + 1);
          if (!raw) continue;
          try {
            processFrame(JSON.parse(raw));
          } catch (error) {
            fail(`Pi RPC emitted invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
            terminate();
          }
        }
      };

      child.stdout?.on("data", consumeStdout);
      child.stderr?.on("data", (chunk: Buffer | string) => { stderr += chunk.toString(); });
      child.once("error", (error) => {
        fail(`Pi RPC failed to start: ${error.message}`);
        complete(null, null);
      });
      child.once("exit", complete);
      timeout = setTimeout(() => {
        fail(`Pi RPC lifecycle command timed out after ${this.dependencies.timeoutMs ?? DEFAULT_TIMEOUT_MS}ms`);
        terminate();
      }, this.dependencies.timeoutMs ?? DEFAULT_TIMEOUT_MS);
      send({ id: GET_COMMANDS_REQUEST_ID, type: "get_commands" });
    });
  }
}

function processRpcFrame(
  frame: unknown,
  command: PiExtensionCommand,
  state: RunnerState,
  actions: FrameActions,
): void {
  if (!frame || typeof frame !== "object") {
    actions.fail("Pi RPC emitted a non-object frame");
    actions.terminate();
    return;
  }
  const event = frame as Record<string, unknown>;
  if (event.type === "extension_error") {
    const message = typeof event.error === "string" ? event.error : JSON.stringify(event);
    state.extensionErrors.push(message);
    actions.fail(`Cron extension error: ${message}`);
    actions.terminate();
    return;
  }
  if (event.type === "extension_ui_request") {
    processExtensionUiRequest(event, state, actions);
    return;
  }
  if (event.type === "response") processResponse(event, command, state, actions);
}

function processExtensionUiRequest(
  event: Record<string, unknown>,
  state: RunnerState,
  actions: FrameActions,
): void {
  const method = String(event.method);
  if (method === "notify") {
    state.notifications.push(typeof event.message === "string" ? event.message : JSON.stringify(event));
    return;
  }
  if (!["confirm", "select", "input", "editor"].includes(method)) return;
  actions.fail(`Cron lifecycle command requested unexpected ${method} dialog`);
  actions.terminate();
}

function processResponse(
  event: Record<string, unknown>,
  command: PiExtensionCommand,
  state: RunnerState,
  actions: FrameActions,
): void {
  if (event.id === GET_COMMANDS_REQUEST_ID) {
    processCommandsResponse(event, command, state, actions);
    return;
  }
  if (event.id !== PROMPT_REQUEST_ID) return;
  if (event.success !== true || event.command !== "prompt") {
    actions.fail(typeof event.error === "string" ? event.error : "Pi RPC rejected the Cron command prompt");
  } else {
    state.promptAcknowledged = true;
  }
  actions.endInput();
}

function processCommandsResponse(
  event: Record<string, unknown>,
  command: PiExtensionCommand,
  state: RunnerState,
  actions: FrameActions,
): void {
  if (event.success !== true || event.command !== "get_commands") {
    actions.fail(typeof event.error === "string" ? event.error : "Pi RPC rejected get_commands");
    actions.terminate();
    return;
  }
  const commands = (event.data as { commands?: unknown } | undefined)?.commands;
  state.registered = Array.isArray(commands) && commands.some(isCronExtensionCommand);
  if (!state.registered) {
    actions.fail("Cron command was not registered by the isolated extension");
    actions.terminate();
    return;
  }
  actions.send({
    id: PROMPT_REQUEST_ID,
    type: "prompt",
    message: command === "install" ? "/cron install" : "/cron uninstall --yes",
  });
}

function isCronExtensionCommand(command: unknown): boolean {
  return command !== null
    && typeof command === "object"
    && (command as Record<string, unknown>).name === "cron"
    && (command as Record<string, unknown>).source === "extension";
}
