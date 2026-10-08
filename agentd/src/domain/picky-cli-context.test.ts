import { describe, expect, it } from "vitest";
import {
  PICKY_CLI_CONTEXT_ENV_VAR,
  PI_SESSION_ID_ENV_VAR,
  type PickyCliCallerContext,
  PickyCliCallerContextError,
  parsePickyCliCallerContext,
  pickyCliCallerContextExport,
  readPickyCliCallerContext,
  samePickyCliCallerContext,
  serializePickyCliCallerContext,
  withPickyCliCallerContext,
} from "./picky-cli-context.js";

const context: PickyCliCallerContext = {
  bindingId: "binding-1",
  sessionId: "pickle-7",
  piSessionId: "pi-abc",
  generation: 2,
};

function errorCode(run: () => unknown): string {
  try {
    run();
  } catch (error) {
    return error instanceof PickyCliCallerContextError ? error.code : `unexpected:${String(error)}`;
  }
  return "no-error";
}

describe("picky CLI caller context wire shape", () => {
  it("round-trips through the environment the CLI actually reads", () => {
    const env = { [PICKY_CLI_CONTEXT_ENV_VAR]: serializePickyCliCallerContext(context), [PI_SESSION_ID_ENV_VAR]: "pi-abc" };

    expect(readPickyCliCallerContext(env)).toEqual(context);
  });

  it("reports no caller for a plain terminal", () => {
    expect(readPickyCliCallerContext({})).toBeUndefined();
    expect(readPickyCliCallerContext({ [PICKY_CLI_CONTEXT_ENV_VAR]: "   " })).toBeUndefined();
  });

  it("rejects a context whose Pi session disagrees with the running shell", () => {
    // An inherited variable from an older shell looks exactly like this.
    const env = { [PICKY_CLI_CONTEXT_ENV_VAR]: serializePickyCliCallerContext(context), [PI_SESSION_ID_ENV_VAR]: "pi-other" };

    expect(errorCode(() => readPickyCliCallerContext(env))).toBe("piSessionMismatch");
  });

  it("rejects values that cannot be trusted as an identity", () => {
    expect(errorCode(() => parsePickyCliCallerContext("not json"))).toBe("malformed");
    expect(errorCode(() => parsePickyCliCallerContext("[]"))).toBe("malformed");
    expect(errorCode(() => parsePickyCliCallerContext(JSON.stringify({ ...context, sessionId: "" })))).toBe("malformed");
    expect(errorCode(() => parsePickyCliCallerContext(JSON.stringify({ ...context, generation: 1.5 })))).toBe("malformed");
    expect(errorCode(() => parsePickyCliCallerContext(JSON.stringify({ ...context, generation: -1 })))).toBe("malformed");
    expect(errorCode(() => parsePickyCliCallerContext(JSON.stringify({ bindingId: "b", sessionId: "s" })))).toBe("malformed");
  });

  it("compares identities field by field", () => {
    expect(samePickyCliCallerContext(context, { ...context })).toBe(true);
    expect(samePickyCliCallerContext(context, { ...context, generation: 3 })).toBe(false);
    expect(samePickyCliCallerContext(context, { ...context, bindingId: "binding-2" })).toBe(false);
  });
});

describe("caller context command injection", () => {
  it("keeps the model's command intact underneath the export", () => {
    const command = "cd /tmp && picky whoami --json";

    expect(withPickyCliCallerContext(command, context)).toBe(`${pickyCliCallerContextExport(context)}\n${command}`);
  });

  it("does not stack exports when the same context is applied twice", () => {
    const once = withPickyCliCallerContext("echo hi", context);

    expect(withPickyCliCallerContext(once, context)).toBe(once);
  });

  // The shell-level proof that a hostile value stays inside the variable lives in
  // runtime/picky-cli-context.test.ts, where the statement runs through a real shell.
  it("exports a single shell-quoted statement", () => {
    const statement = pickyCliCallerContextExport(context);

    expect(statement.startsWith(`export ${PICKY_CLI_CONTEXT_ENV_VAR}='`)).toBe(true);
    expect(statement.endsWith("'")).toBe(true);
    expect(statement.split("\n")).toHaveLength(1);
  });
});
