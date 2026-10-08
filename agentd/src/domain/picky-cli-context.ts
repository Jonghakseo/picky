/**
 * Caller identity handed to a `picky` CLI invocation that a Picky-hosted Pi session started.
 *
 * The runtime issues one context per live Pi session and injects it into the shell command of
 * `bash` / `bash_async start` tool calls (see `runtime/picky-cli-context.ts`). The CLI reads it
 * back out of its own environment and sends it to the daemon, which asks the owning runtime
 * whether the context is still live.
 *
 * This module is pure wire/env shape so the CLI, the server, and the runtime agree on one format.
 * It deliberately never reads `process.env`: the whole point of the design is that the context
 * travels per command, not through a process-global variable shared by every session in a daemon.
 */

/** Environment variable that carries the serialized caller context into a tool-run shell. */
export const PICKY_CLI_CONTEXT_ENV_VAR = "PICKY_CLI_CONTEXT";

/** Pi's own session-id variable, exposed by Pi's bash tool (`exposeSessionEnvironment`). */
export const PI_SESSION_ID_ENV_VAR = "PI_SESSION_ID";

export interface PickyCliCallerContext {
  /** Identifies the issuing runtime handle. Unique per process; never reused after disposal. */
  readonly bindingId: string;
  /** Picky session id of the caller. `picky` for the main agent, otherwise the Pickle id. */
  readonly sessionId: string;
  /** Pi session id live when the context was issued. */
  readonly piSessionId: string;
  /** Bumped whenever the handle's Pi session is replaced or invalidated. */
  readonly generation: number;
}

export type PickyCliCallerContextErrorCode =
  /** The value is absent, not JSON, or missing required fields. */
  | "malformed"
  /** No live binding claims this context (wrong daemon, disposed handle, forged value). */
  | "unknown"
  /** The issuing Pi session was replaced (`/new`, resume, fork) after the context was issued. */
  | "stale"
  /** The shell's `PI_SESSION_ID` disagrees with the injected context. */
  | "piSessionMismatch";

export class PickyCliCallerContextError extends Error {
  readonly code: PickyCliCallerContextErrorCode;

  constructor(code: PickyCliCallerContextErrorCode, message: string) {
    super(message);
    this.name = "PickyCliCallerContextError";
    this.code = code;
  }
}

export function serializePickyCliCallerContext(context: PickyCliCallerContext): string {
  // Fixed key order keeps the injected command text stable for the same context.
  return JSON.stringify({
    bindingId: context.bindingId,
    sessionId: context.sessionId,
    piSessionId: context.piSessionId,
    generation: context.generation,
  });
}

/** Parses a serialized or already-decoded context. Throws `malformed` for anything unusable. */
export function parsePickyCliCallerContext(value: unknown): PickyCliCallerContext {
  const decoded = typeof value === "string" ? decodeJson(value) : value;
  if (typeof decoded !== "object" || decoded === null) throw malformed("caller context is not an object");
  const record = decoded as Record<string, unknown>;
  return {
    bindingId: requiredId(record.bindingId, "bindingId"),
    sessionId: requiredId(record.sessionId, "sessionId"),
    piSessionId: requiredId(record.piSessionId, "piSessionId"),
    generation: requiredGeneration(record.generation),
  };
}

/**
 * Reads the caller context a Picky-hosted shell was given.
 *
 * Returns `undefined` when the command did not come from a Picky session (a plain terminal).
 * Throws `piSessionMismatch` when the shell's live `PI_SESSION_ID` contradicts the injected
 * context, which is what an inherited context from an older/foreign shell looks like.
 */
export function readPickyCliCallerContext(env: Readonly<Record<string, string | undefined>>): PickyCliCallerContext | undefined {
  const raw = env[PICKY_CLI_CONTEXT_ENV_VAR]?.trim();
  if (!raw) return undefined;
  const context = parsePickyCliCallerContext(raw);
  const piSessionId = env[PI_SESSION_ID_ENV_VAR]?.trim();
  if (piSessionId && piSessionId !== context.piSessionId) {
    throw new PickyCliCallerContextError("piSessionMismatch", "Picky CLI caller context was issued by a different Pi session.");
  }
  return context;
}

export function samePickyCliCallerContext(left: PickyCliCallerContext, right: PickyCliCallerContext): boolean {
  return left.bindingId === right.bindingId
    && left.sessionId === right.sessionId
    && left.piSessionId === right.piSessionId
    && left.generation === right.generation;
}

/** The shell statement that exports the context for one command and its children. */
export function pickyCliCallerContextExport(context: PickyCliCallerContext): string {
  return `export ${PICKY_CLI_CONTEXT_ENV_VAR}=${shellQuote(serializePickyCliCallerContext(context))}`;
}

/**
 * Prefixes a tool command with its caller context.
 *
 * Mirrors how Pi's own `commandPrefix` joins setup and command, so multi-line commands, heredocs,
 * and `&&` chains keep working. Re-injection is a no-op so a reload or a second handler pass
 * cannot stack exports.
 */
export function withPickyCliCallerContext(command: string, context: PickyCliCallerContext): string {
  const statement = pickyCliCallerContextExport(context);
  if (command.startsWith(`${statement}\n`)) return command;
  return `${statement}\n${command}`;
}

function decodeJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    throw malformed("caller context is not valid JSON");
  }
}

function requiredId(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim() === "") throw malformed(`${field} is missing`);
  return value;
}

function requiredGeneration(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) throw malformed("generation is not a non-negative integer");
  return value;
}

function malformed(reason: string): PickyCliCallerContextError {
  return new PickyCliCallerContextError("malformed", `Picky CLI caller context is malformed: ${reason}.`);
}

/** POSIX single-quote escaping so no context value can break out of the export statement. */
function shellQuote(value: string): string {
  return `'${value.split("'").join(`'\\''`)}'`;
}
