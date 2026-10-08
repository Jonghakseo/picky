import { randomUUID } from "node:crypto";
import type { InlineExtension, SessionShutdownEvent, ToolCallEvent } from "@earendil-works/pi-coding-agent";
import type { PickyCliCallerContext } from "../domain/picky-cli-context.js";
import { PickyCliCallerContextError, withPickyCliCallerContext } from "../domain/picky-cli-context.js";

/**
 * Per-session caller identity for the `picky` CLI.
 *
 * One binding belongs to one runtime handle (one Pickle, or the always-on main agent). The
 * binding only issues a context while a Pi session is live, and the extension injects that
 * context into the shell of each `bash` / `bash_async start` call the session makes. Nothing is
 * written to `process.env`: a primary daemon hosts the main agent and in-process Pickles in one
 * process, so a process-global variable would hand every session the same identity.
 *
 * The binding is an anti-confusion mechanism, not an authentication boundary. Anything running
 * with the user's own shell privileges can read or fake the variable; the design only guarantees
 * that Picky never *mistakes* one session for another.
 */
export interface PickyCliCallerBinding {
  readonly bindingId: string;
  /** Picky session id this binding speaks for (`picky` for the main agent). */
  readonly sessionId: string;
  /** The context to hand out right now, or `undefined` while no Pi session is live. */
  current(): PickyCliCallerContext | undefined;
  /** Attach the live Pi session. A different id replaces the identity and bumps the generation. */
  bindPiSession(piSessionId: string): void;
  /** Drop the current identity (session replacement) while keeping the binding registered. */
  invalidate(): void;
  /** Unregister permanently. Contexts issued by this binding can never validate again. */
  dispose(): void;
}

export const PICKY_CLI_CONTEXT_EXTENSION_NAME = "picky-cli-context";

interface BindingState {
  readonly bindingId: string;
  readonly sessionId: string;
  piSessionId?: string;
  generation: number;
  disposed: boolean;
}

/**
 * Live bindings of this process. A daemon only validates contexts it issued itself; the app
 * routes a CLI request to the owning daemon before validation, so a cross-process context is
 * supposed to fail here.
 */
const liveBindings = new Map<string, BindingState>();

export function createPickyCliCallerBinding(sessionId: string): PickyCliCallerBinding {
  const state: BindingState = { bindingId: randomUUID(), sessionId, generation: 0, disposed: false };
  liveBindings.set(state.bindingId, state);
  return {
    bindingId: state.bindingId,
    sessionId: state.sessionId,
    current: () => currentContext(state),
    bindPiSession: (piSessionId: string) => bindPiSession(state, piSessionId),
    invalidate: () => invalidate(state),
    dispose: () => {
      state.disposed = true;
      state.piSessionId = undefined;
      liveBindings.delete(state.bindingId);
    },
  };
}

/**
 * Confirms that a context still names this process's live session.
 *
 * Synchronous on purpose: owner commands call it inside the serialized metadata commit, so the
 * answer cannot go stale between the check and the write.
 */
export function validatePickyCliContext(context: PickyCliCallerContext): void {
  const state = liveBindings.get(context.bindingId);
  if (!state || state.disposed || state.sessionId !== context.sessionId) {
    throw new PickyCliCallerContextError("unknown", "This Picky session does not recognize the CLI caller context.");
  }
  if (state.piSessionId === undefined || state.piSessionId !== context.piSessionId || state.generation !== context.generation) {
    throw new PickyCliCallerContextError("stale", "The Pi session that issued this CLI caller context has been replaced.");
  }
}

/**
 * Injects the caller context into shell commands the session runs.
 *
 * `tool_call` is the only seam that reaches both Pi's built-in `bash` and the `bash_async`
 * extension tool, and it also fires for nested calls a codemode script issues through
 * `ctx.executeTool()`. Mutating `event.input` patches the executed arguments only: Pi validates
 * tool arguments into a `structuredClone`, so the transcript, the HUD preview, and the nested
 * call record all keep the command the model actually wrote.
 */
export function createPickyCliContextExtension(binding: PickyCliCallerBinding): InlineExtension {
  return {
    name: PICKY_CLI_CONTEXT_EXTENSION_NAME,
    hidden: true,
    factory: (pi) => {
      pi.on("tool_call", (event, ctx) => {
        injectPickyCliCallerContext(event, binding, livePiSessionId(ctx));
      });
      pi.on("session_shutdown", (event) => {
        applyPickyCliSessionShutdown(binding, event.reason);
      });
    },
  };
}

/**
 * Lifecycle rule for a shutdown reason.
 *
 * `reload` keeps the identity: an extension reload rebuilds handlers against the same live Pi
 * session, and a CLI call already in flight from a running command must keep working. Every
 * other reason tears the session down, and the runtime factory binds the replacement afterwards.
 */
export function applyPickyCliSessionShutdown(binding: PickyCliCallerBinding, reason: SessionShutdownEvent["reason"]): void {
  if (reason === "reload") return;
  if (reason === "quit") binding.dispose();
  else binding.invalidate();
}

/**
 * Patches one tool call. Returns the injected context so tests can assert what the shell got.
 *
 * `piSessionId` is the session id live at call time. It re-syncs the binding first so a context
 * can never advertise a Pi session that was replaced without the runtime factory noticing.
 */
export function injectPickyCliCallerContext(
  event: ToolCallEvent,
  binding: PickyCliCallerBinding,
  piSessionId: string | undefined,
): PickyCliCallerContext | undefined {
  if (!isShellCommandToolCall(event)) return undefined;
  const input = event.input as { command?: unknown };
  if (typeof input.command !== "string" || input.command === "") return undefined;
  if (piSessionId) binding.bindPiSession(piSessionId);
  const context = binding.current();
  if (!context) return undefined;
  input.command = withPickyCliCallerContext(input.command, context);
  return context;
}

/** `bash` always carries a command; `bash_async` only starts one for `action: "start"`. */
function isShellCommandToolCall(event: ToolCallEvent): boolean {
  if (event.toolName === "bash") return true;
  if (event.toolName !== "bash_async") return false;
  return (event.input as { action?: unknown }).action === "start";
}

function livePiSessionId(ctx: { sessionManager: { getSessionId: () => string } }): string | undefined {
  try {
    return ctx.sessionManager.getSessionId() || undefined;
  } catch {
    // A session being torn down can refuse the read; skip injection instead of failing the call.
    return undefined;
  }
}

function currentContext(state: BindingState): PickyCliCallerContext | undefined {
  if (state.disposed || state.piSessionId === undefined) return undefined;
  return { bindingId: state.bindingId, sessionId: state.sessionId, piSessionId: state.piSessionId, generation: state.generation };
}

function bindPiSession(state: BindingState, piSessionId: string): void {
  if (state.disposed || !piSessionId) return;
  // Same session id after a reload or a repeated bind keeps the generation, so contexts already
  // handed to running commands stay valid.
  if (state.piSessionId === piSessionId) return;
  state.piSessionId = piSessionId;
  state.generation += 1;
}

function invalidate(state: BindingState): void {
  if (state.disposed || state.piSessionId === undefined) return;
  state.piSessionId = undefined;
  state.generation += 1;
}
