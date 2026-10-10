import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { describe, expect, it, vi } from "vitest";
import {
  PICKY_CLI_CONTEXT_ENV_VAR,
  PI_SESSION_ID_ENV_VAR,
  type PickyCliCallerContext,
  PickyCliCallerContextError,
  readPickyCliCallerContext,
} from "../domain/picky-cli-context.js";
import {
  applyPickyCliSessionShutdown,
  createPickyCliCallerBinding,
  createPickyCliContextExtension,
  PICKY_CLI_CONTEXT_EXTENSION_NAME,
  type PickyCliCallerBinding,
  validatePickyCliContext,
} from "./picky-cli-context.js";

const run = promisify(execFile);

type ToolCallHandler = (event: { toolName: string; toolCallId: string; parentToolCallId?: string; input: Record<string, unknown> }, ctx: unknown) => void;
type ShutdownHandler = (event: { type: "session_shutdown"; reason: "quit" | "reload" | "new" | "resume" | "fork" }, ctx: unknown) => void;

interface BoundExtension {
  toolCall: ToolCallHandler;
  shutdown: ShutdownHandler;
}

/** Binds the extension the way Pi does: run the factory, keep the handlers it registers. */
function bindExtension(binding: PickyCliCallerBinding): BoundExtension {
  const extension = createPickyCliContextExtension(binding);
  const factory = typeof extension === "function" ? extension : extension.factory;
  const handlers = new Map<string, unknown>();
  // The extension registers synchronously; `void` just acknowledges Pi's wider factory signature.
  void factory({ on: (event: string, handler: unknown) => { handlers.set(event, handler); } } as never);
  const toolCall = handlers.get("tool_call") as ToolCallHandler | undefined;
  const shutdown = handlers.get("session_shutdown") as ShutdownHandler | undefined;
  if (!toolCall || !shutdown) throw new Error("extension did not register its handlers");
  return { toolCall, shutdown };
}

function sessionContext(piSessionId: string): unknown {
  return { sessionManager: { getSessionId: () => piSessionId } };
}

function bashCall(command: string): { toolName: string; toolCallId: string; input: Record<string, unknown> } {
  return { toolName: "bash", toolCallId: "call-1", input: { command } };
}

function errorCode(check: () => void): string {
  try {
    check();
  } catch (error) {
    return error instanceof PickyCliCallerContextError ? error.code : `unexpected:${String(error)}`;
  }
  return "no-error";
}

/** Runs the patched command in a real shell and reports what the CLI would have seen. */
async function readContextFromShell(command: string, piSessionId: string): Promise<PickyCliCallerContext | undefined> {
  const probe = `${command}\nprintf '%s' "$${PICKY_CLI_CONTEXT_ENV_VAR}"`;
  const { stdout } = await run("/bin/sh", ["-c", probe], { env: { PATH: process.env.PATH ?? "", [PI_SESSION_ID_ENV_VAR]: piSessionId } });
  return readPickyCliCallerContext({ [PICKY_CLI_CONTEXT_ENV_VAR]: stdout, [PI_SESSION_ID_ENV_VAR]: piSessionId });
}

describe("picky CLI caller binding", () => {
  it("issues no identity before a Pi session is live", () => {
    const binding = createPickyCliCallerBinding("pickle-1");

    expect(binding.current()).toBeUndefined();

    binding.dispose();
  });

  it("validates the context it issued for the live Pi session", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    binding.bindPiSession("pi-1");
    const context = binding.current();

    expect(context).toMatchObject({ sessionId: "pickle-1", piSessionId: "pi-1" });
    expect(() => validatePickyCliContext(context!)).not.toThrow();

    binding.dispose();
  });

  it("gives separate sessions in one daemon separate identities", () => {
    const main = createPickyCliCallerBinding("picky");
    const pickle = createPickyCliCallerBinding("pickle-1");
    main.bindPiSession("pi-main");
    pickle.bindPiSession("pi-pickle");

    const mainContext = main.current()!;

    expect(mainContext.bindingId).not.toBe(pickle.current()!.bindingId);
    // A Pickle cannot borrow the main agent's binding id to speak for the main agent.
    expect(errorCode(() => validatePickyCliContext({ ...mainContext, sessionId: "pickle-1" }))).toBe("unknown");

    main.dispose();
    pickle.dispose();
  });

  it("rejects an identity from an unknown or already disposed handle", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    binding.bindPiSession("pi-1");
    const context = binding.current()!;

    binding.dispose();

    expect(errorCode(() => validatePickyCliContext(context))).toBe("unknown");
    expect(errorCode(() => validatePickyCliContext({ ...context, bindingId: "made-up" }))).toBe("unknown");
  });

  it("retires an identity when the Pi session is replaced", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    binding.bindPiSession("pi-1");
    const beforeNew = binding.current()!;

    // What `/new` does: the old session shuts down, then the runtime factory binds the next one.
    applyPickyCliSessionShutdown(binding, "new");
    binding.bindPiSession("pi-2");

    expect(errorCode(() => validatePickyCliContext(beforeNew))).toBe("stale");
    expect(() => validatePickyCliContext(binding.current()!)).not.toThrow();
    expect(binding.current()!.generation).not.toBe(beforeNew.generation);

    binding.dispose();
  });

  it("keeps the identity across an extension reload on the same Pi session", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    binding.bindPiSession("pi-1");
    const issued = binding.current()!;

    applyPickyCliSessionShutdown(binding, "reload");
    // The reloaded resource loader re-runs the factory against the same live session.
    binding.bindPiSession("pi-1");

    expect(() => validatePickyCliContext(issued)).not.toThrow();

    binding.dispose();
  });

  it("drops the registration when the handle quits", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    binding.bindPiSession("pi-1");
    const issued = binding.current()!;

    applyPickyCliSessionShutdown(binding, "quit");

    expect(binding.current()).toBeUndefined();
    expect(errorCode(() => validatePickyCliContext(issued))).toBe("unknown");
  });

  it("refuses a stale generation even when the Pi session id is reused", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    binding.bindPiSession("pi-1");
    const issued = binding.current()!;

    applyPickyCliSessionShutdown(binding, "fork");
    binding.bindPiSession("pi-1");

    expect(errorCode(() => validatePickyCliContext(issued))).toBe("stale");

    binding.dispose();
  });
});

describe("caller context injection into tool calls", () => {
  it("is a hidden inline extension with a stable name", () => {
    const binding = createPickyCliCallerBinding("pickle-1");

    expect(createPickyCliContextExtension(binding)).toMatchObject({ name: PICKY_CLI_CONTEXT_EXTENSION_NAME, hidden: true });

    binding.dispose();
  });

  it("gives a real bash command the identity the CLI can read back", async () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    const event = bashCall("picky whoami --json");

    toolCall(event, sessionContext("pi-1"));

    expect(await readContextFromShell(event.input.command as string, "pi-1")).toEqual(binding.current());
    expect(event.input.command).toContain("picky whoami --json");

    binding.dispose();
  });

  it("does not put the identity in the daemon's own environment", async () => {
    // Agents run this suite inside a Pickle shell, which already exports the
    // variable. Clear it so the assertion only sees what the extension writes.
    vi.stubEnv(PICKY_CLI_CONTEXT_ENV_VAR, undefined);
    const binding = createPickyCliCallerBinding("pickle-1");
    try {
      const { toolCall } = bindExtension(binding);
      const event = bashCall("true");

      toolCall(event, sessionContext("pi-1"));
      await readContextFromShell(event.input.command as string, "pi-1");

      expect(process.env[PICKY_CLI_CONTEXT_ENV_VAR]).toBeUndefined();
    } finally {
      binding.dispose();
      vi.unstubAllEnvs();
    }
  });

  it("survives a hostile value in a real shell instead of executing it", async () => {
    const binding = createPickyCliCallerBinding("pickle';touch /tmp/picky-cli-context-escape;#");
    const { toolCall } = bindExtension(binding);
    const event = bashCall("printf ''");

    toolCall(event, sessionContext("pi-1"));

    expect(await readContextFromShell(event.input.command as string, "pi-1")).toEqual(binding.current());

    binding.dispose();
  });

  it("patches a bash_async job the same way, since its command also runs in a shell", async () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    const event = { toolName: "bash_async", toolCallId: "call-2", input: { action: "start", command: "picky pickle-rename --self Review" } };

    toolCall(event, sessionContext("pi-1"));

    expect(await readContextFromShell(event.input.command, "pi-1")).toEqual(binding.current());

    binding.dispose();
  });

  it("leaves bash_async queries alone, since only start runs a command", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    const event = { toolName: "bash_async", toolCallId: "call-3", input: { action: "status", jobId: "job-1" } };

    toolCall(event, sessionContext("pi-1"));

    expect(event.input).toEqual({ action: "status", jobId: "job-1" });

    binding.dispose();
  });

  it("leaves other tools untouched", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    const event = { toolName: "read", toolCallId: "call-4", input: { path: "README.md" } };

    toolCall(event, sessionContext("pi-1"));

    expect(event.input).toEqual({ path: "README.md" });

    binding.dispose();
  });

  it("covers a nested bash call a codemode script issues", async () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    const event = { toolName: "bash", toolCallId: "call-5/1", parentToolCallId: "call-5", input: { command: "picky whoami" } };

    toolCall(event, sessionContext("pi-1"));

    expect(await readContextFromShell(event.input.command, "pi-1")).toEqual(binding.current());

    binding.dispose();
  });

  it("hands out nothing while no Pi session is live", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall, shutdown } = bindExtension(binding);
    shutdown({ type: "session_shutdown", reason: "new" }, undefined);
    const event = bashCall("picky whoami");

    toolCall(event, { sessionManager: { getSessionId: () => "" } });

    expect(event.input.command).toBe("picky whoami");

    binding.dispose();
  });

  it("names the Pi session that is live at call time, not the one bound earlier", async () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    binding.bindPiSession("pi-1");
    const stale = binding.current()!;
    const event = bashCall("picky whoami");

    toolCall(event, sessionContext("pi-2"));

    const delivered = await readContextFromShell(event.input.command as string, "pi-2");
    expect(delivered?.piSessionId).toBe("pi-2");
    expect(errorCode(() => validatePickyCliContext(stale))).toBe("stale");
    expect(() => validatePickyCliContext(delivered!)).not.toThrow();

    binding.dispose();
  });

  it("injects once when the same call is patched again", () => {
    const binding = createPickyCliCallerBinding("pickle-1");
    const { toolCall } = bindExtension(binding);
    const event = bashCall("picky whoami");

    toolCall(event, sessionContext("pi-1"));
    const afterFirst = event.input.command;
    toolCall(event, sessionContext("pi-1"));

    expect(event.input.command).toBe(afterFirst);

    binding.dispose();
  });
});
