import { PickyExtensionError } from "./application/extension-ui-bridge.js";
import { logAgentd } from "./local-log.js";

const EXTENSION_PATH_PATTERNS: readonly RegExp[] = [
  /[/\\]\.pi[/\\]agent[/\\]extensions[/\\]([^/\\:?#)]+)/,
  /[/\\]node_modules[/\\](?:@[^/\\]+[/\\])?(pi-extension-[^/\\:?#)]+)/,
];

interface CrashOrigin {
  /** Best-effort extension identifier extracted from the stack (or the typed error metadata). */
  readonly extension?: string;
  /** First stack frame that pointed at extension code, if any. */
  readonly extensionFrame?: string;
}

/**
 * Inspect an error to decide whether it originated from a pi extension running
 * inside agentd (either a local one under `~/.pi/agent/extensions/` or a
 * published `pi-extension-*` package), and to extract a human-readable
 * extension identifier for diagnostic logging.
 */
export function classifyExtensionCrash(reason: unknown): CrashOrigin | undefined {
  const error = reason instanceof Error ? reason : undefined;
  if (error instanceof PickyExtensionError) {
    return { extension: error.extensionApi };
  }
  const stack = typeof error?.stack === "string" ? error.stack : undefined;
  if (!stack) return undefined;
  for (const line of stack.split("\n")) {
    for (const pattern of EXTENSION_PATH_PATTERNS) {
      const match = line.match(pattern);
      if (match) return { extension: match[1], extensionFrame: line.trim() };
    }
  }
  return undefined;
}

interface CrashGuardOptions {
  readonly log?: (event: string, fields: Record<string, string | number | boolean | null | undefined>) => void;
  /**
   * Swap out the rethrow path during tests. Production passes through to the
   * default Node behaviour: rethrow on `uncaughtException`, allow Node to log
   * `unhandledRejection`. Returning `false` suppresses the rethrow (used in
   * tests that want to assert the guard decided to escalate without actually
   * crashing the test process).
   */
  readonly rethrow?: (reason: unknown, source: "uncaughtException" | "unhandledRejection") => boolean | void;
}

interface InstalledGuard {
  uncaughtException: (error: Error) => void;
  unhandledRejection: (reason: unknown) => void;
  uninstall: () => void;
}

/**
 * Install global handlers that keep agentd alive when a pi extension throws
 * an uncaught exception or rejects a promise nobody awaits. The handler
 * deliberately scopes the safety net to extension code: any error that does
 * not look like it came from an extension is re-thrown so genuine daemon bugs
 * remain visible exactly as before.
 *
 * Logged fields:
 * - `source`: `"uncaughtException"` or `"unhandledRejection"`.
 * - `extension`: extracted extension package or local folder name when known.
 * - `extensionFrame`: first stack frame pointing into extension code.
 * - `errorName`/`errorMessage`: original error identity for the agent to react on.
 * - `sessionId` and `extensionApi`: present when the crash flowed through a typed `PickyExtensionError`.
 * - `stack`: full stack trace (truncated to keep the line bounded).
 */
export function installExtensionCrashGuard(options: CrashGuardOptions = {}): InstalledGuard {
  const log = options.log ?? logAgentd;

  const handle = (reason: unknown, source: "uncaughtException" | "unhandledRejection"): boolean => {
    const origin = classifyExtensionCrash(reason);
    if (!origin) return false;
    const error = reason instanceof Error ? reason : undefined;
    const typed = reason instanceof PickyExtensionError ? reason : undefined;
    log("extension uncaught error swallowed", {
      source,
      extension: origin.extension,
      extensionFrame: origin.extensionFrame,
      extensionApi: typed?.extensionApi,
      sessionId: typed?.sessionId,
      errorName: error?.name ?? typeof reason,
      errorMessage: error?.message ?? safeStringify(reason),
      stack: truncate(error?.stack, 4000),
    });
    return true;
  };

  const onUncaught = (error: Error) => {
    if (handle(error, "uncaughtException")) return;
    if (options.rethrow && options.rethrow(error, "uncaughtException") === false) return;
    throw error;
  };
  const onRejection = (reason: unknown) => {
    if (handle(reason, "unhandledRejection")) return;
    if (options.rethrow && options.rethrow(reason, "unhandledRejection") === false) return;
    throw reason;
  };

  process.on("uncaughtException", onUncaught);
  process.on("unhandledRejection", onRejection);
  return {
    uncaughtException: onUncaught,
    unhandledRejection: onRejection,
    uninstall: () => {
      process.off("uncaughtException", onUncaught);
      process.off("unhandledRejection", onRejection);
    },
  };
}

function safeStringify(value: unknown): string {
  if (value === undefined) return "undefined";
  if (value === null) return "null";
  try {
    return typeof value === "string" ? value : JSON.stringify(value);
  } catch {
    return Object.prototype.toString.call(value);
  }
}

function truncate(value: string | undefined, max: number): string | undefined {
  if (!value) return value;
  return value.length <= max ? value : `${value.slice(0, max)}…<${value.length - max} more chars>`;
}
