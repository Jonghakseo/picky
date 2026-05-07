import { afterEach, describe, expect, it, vi } from "vitest";
import { PickyExtensionError, PickyOverlayUnsupportedError } from "./application/extension-ui-bridge.js";
import { classifyExtensionCrash, installExtensionCrashGuard } from "./extension-crash-guard.js";

describe("classifyExtensionCrash", () => {
  it("recognises PickyExtensionError subclasses without inspecting the stack", () => {
    const error = new PickyOverlayUnsupportedError("session-overlay");
    expect(classifyExtensionCrash(error)).toEqual({ extension: "ctx.ui.custom" });
  });

  it("recognises a generic PickyExtensionError carrying its api hint", () => {
    const error = new PickyExtensionError("ctx.theme.fg is not implemented", "ctx.theme.fg", "session-1");
    expect(classifyExtensionCrash(error)).toEqual({ extension: "ctx.theme.fg" });
  });

  it("identifies a TypeError thrown from a local pi extension folder", () => {
    const error = new TypeError("theme.fg is not a function");
    error.stack = [
      "TypeError: theme.fg is not a function",
      "    at updateFooter (/Users/creatrip/.pi/agent/extensions/until/index.ts:239:24)",
      "    at scheduleNext (/Users/creatrip/.pi/agent/extensions/until/index.ts:330:5)",
      "    at Timeout.<anonymous> (node:internal/timers:594:17)",
    ].join("\n");
    expect(classifyExtensionCrash(error)).toEqual({
      extension: "until",
      extensionFrame: "at updateFooter (/Users/creatrip/.pi/agent/extensions/until/index.ts:239:24)",
    });
  });

  it("identifies an error originating in a published pi-extension-* npm package", () => {
    const error = new Error("boom");
    error.stack = [
      "Error: boom",
      "    at showScreensaver (/Users/creatrip/.nvm/versions/node/v22.11.0/lib/node_modules/@ryan_nookpi/pi-extension-idle-screensaver/index.ts:68:22)",
      "    at Timeout.<anonymous> (node:internal/timers:594:17)",
    ].join("\n");
    expect(classifyExtensionCrash(error)).toEqual({
      extension: "pi-extension-idle-screensaver",
      extensionFrame: "at showScreensaver (/Users/creatrip/.nvm/versions/node/v22.11.0/lib/node_modules/@ryan_nookpi/pi-extension-idle-screensaver/index.ts:68:22)",
    });
  });

  it("returns undefined when the stack does not point at any extension code", () => {
    const error = new Error("daemon bug");
    error.stack = [
      "Error: daemon bug",
      "    at run (/Users/creatrip/Documents/picky/agentd/src/server.ts:42:7)",
    ].join("\n");
    expect(classifyExtensionCrash(error)).toBeUndefined();
  });
});

describe("installExtensionCrashGuard", () => {
  let installed: ReturnType<typeof installExtensionCrashGuard> | undefined;

  afterEach(() => {
    installed?.uninstall();
    installed = undefined;
  });

  it("swallows uncaughtException originating in an extension and logs structured detail", () => {
    const log = vi.fn();
    installed = installExtensionCrashGuard({ log });

    const error = new TypeError("theme.fg is not a function");
    error.stack = [
      "TypeError: theme.fg is not a function",
      "    at updateFooter (/Users/creatrip/.pi/agent/extensions/until/index.ts:239:24)",
    ].join("\n");

    expect(() => installed!.uncaughtException(error)).not.toThrow();
    expect(log).toHaveBeenCalledWith("extension uncaught error swallowed", expect.objectContaining({
      source: "uncaughtException",
      extension: "until",
      errorName: "TypeError",
      errorMessage: "theme.fg is not a function",
    }));
  });

  it("swallows unhandledRejection of PickyOverlayUnsupportedError and surfaces session/api context", () => {
    const log = vi.fn();
    installed = installExtensionCrashGuard({ log });

    const error = new PickyOverlayUnsupportedError("session-overlay-1");
    expect(() => installed!.unhandledRejection(error)).not.toThrow();

    const fields = log.mock.calls[0]?.[1] as Record<string, unknown>;
    expect(fields).toMatchObject({
      source: "unhandledRejection",
      extensionApi: "ctx.ui.custom",
      sessionId: "session-overlay-1",
      errorName: "PickyOverlayUnsupportedError",
    });
    expect(typeof fields.errorMessage).toBe("string");
    expect(fields.errorMessage as string).toContain("ctx.ui.custom");
  });

  it("rethrows uncaughtException that does not originate from extension code", () => {
    const log = vi.fn();
    const rethrow = vi.fn(() => false);
    installed = installExtensionCrashGuard({ log, rethrow });

    const error = new Error("real daemon bug");
    error.stack = [
      "Error: real daemon bug",
      "    at run (/Users/creatrip/Documents/picky/agentd/src/server.ts:42:7)",
    ].join("\n");

    expect(() => installed!.uncaughtException(error)).not.toThrow();
    expect(rethrow).toHaveBeenCalledWith(error, "uncaughtException");
    expect(log).not.toHaveBeenCalled();
  });

  it("rethrows unhandledRejection that does not originate from extension code", () => {
    const rethrow = vi.fn(() => false);
    installed = installExtensionCrashGuard({ rethrow });

    const error = new Error("unrelated rejection");
    error.stack = [
      "Error: unrelated rejection",
      "    at handler (/Users/creatrip/Documents/picky/agentd/src/server.ts:99:9)",
    ].join("\n");

    expect(() => installed!.unhandledRejection(error)).not.toThrow();
    expect(rethrow).toHaveBeenCalledWith(error, "unhandledRejection");
  });
});
