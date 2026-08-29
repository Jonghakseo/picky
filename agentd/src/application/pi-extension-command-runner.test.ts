import { EventEmitter } from "node:events";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { PiExtensionCommandRunner, type RpcChildProcess } from "./pi-extension-command-runner.js";

class FakeRpcChild extends EventEmitter implements RpcChildProcess {
  stdin = new PassThrough();
  stdout = new PassThrough();
  stderr = new PassThrough();
  readonly kill = vi.fn((signal?: NodeJS.Signals | number) => {
    this.emit("exit", null, signal === "SIGKILL" ? "SIGKILL" : "SIGTERM");
    return true;
  });

  respond(frame: unknown): void {
    this.stdout.write(`${JSON.stringify(frame)}\n`);
  }

  exit(code = 0): void {
    this.emit("exit", code, null);
  }
}

class SigtermResistantRpcChild extends EventEmitter implements RpcChildProcess {
  stdin = new PassThrough();
  stdout = new PassThrough();
  stderr = new PassThrough();
  readonly kill = vi.fn((signal?: NodeJS.Signals | number) => {
    if (signal === "SIGKILL") this.emit("exit", null, "SIGKILL");
    return true;
  });
}

class UnresponsiveRpcChild extends EventEmitter implements RpcChildProcess {
  stdin = new PassThrough();
  stdout = new PassThrough();
  stderr = new PassThrough();
  readonly kill = vi.fn((_signal?: NodeJS.Signals | number) => false);
}

function request() {
  return {
    agentDir: "/tmp/picky-agent",
    extensionPath: "/tmp/cron/index.ts",
    command: "install" as const,
    environment: { PI_CODING_AGENT_DIR: "/tmp/picky-agent", PI_CRON_PI_BIN: "/tmp/pi" },
  };
}

describe("PiExtensionCommandRunner", () => {
  it("loads only the resolved extension and dispatches a correlated prompt after Cron registration", async () => {
    const child = new FakeRpcChild();
    const requests: Array<Record<string, unknown>> = [];
    child.stdin.on("data", (chunk) => {
      const frame = JSON.parse(chunk.toString()) as Record<string, unknown>;
      requests.push(frame);
      if (frame.type === "get_commands") {
        child.respond({ id: frame.id, type: "response", command: "get_commands", success: true, data: { commands: [{ name: "cron", source: "extension" }] } });
      } else if (frame.type === "prompt") {
        child.respond({ id: frame.id, type: "response", command: "prompt", success: true });
        child.exit();
      }
    });
    const spawn = vi.fn(() => child);
    const runner = new PiExtensionCommandRunner({ resolveRpcEntry: () => "/tmp/rpc-entry.mjs", spawn });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: true });
    expect(spawn).toHaveBeenCalledWith(process.execPath, expect.arrayContaining([
      "/tmp/rpc-entry.mjs", "--mode", "rpc", "--no-session", "--no-extensions", "--extension", "/tmp/cron/index.ts",
      "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-builtin-tools",
    ]), expect.objectContaining({ env: request().environment }));
    expect(requests).toEqual([
      { id: "picky-cron-get-commands", type: "get_commands" },
      { id: "picky-cron-prompt", type: "prompt", message: "/cron install" },
    ]);
  });

  it("fails closed without sending a prompt when the isolated extension did not register Cron", async () => {
    const child = new FakeRpcChild();
    const requests: Array<Record<string, unknown>> = [];
    child.stdin.on("data", (chunk) => {
      const frame = JSON.parse(chunk.toString()) as Record<string, unknown>;
      requests.push(frame);
      child.respond({ id: frame.id, type: "response", command: "get_commands", success: true, data: { commands: [] } });
    });
    const runner = new PiExtensionCommandRunner({ resolveRpcEntry: () => "/tmp/rpc-entry.mjs", spawn: () => child });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: false, errorMessage: "Cron command was not registered by the isolated extension" });
    expect(requests).toEqual([{ id: "picky-cron-get-commands", type: "get_commands" }]);
    expect(child.kill).toHaveBeenCalledWith("SIGTERM");
  });

  it("fails closed and terminates when Cron requests an interactive dialog", async () => {
    const child = new FakeRpcChild();
    child.stdin.on("data", (chunk) => {
      const frame = JSON.parse(chunk.toString()) as Record<string, unknown>;
      if (frame.type === "get_commands") {
        child.respond({ id: frame.id, type: "response", command: "get_commands", success: true, data: { commands: [{ name: "cron", source: "extension" }] } });
      } else if (frame.type === "prompt") {
        child.respond({ type: "extension_ui_request", id: "confirm-1", method: "confirm", title: "Unexpected", message: "No" });
      }
    });
    const runner = new PiExtensionCommandRunner({ resolveRpcEntry: () => "/tmp/rpc-entry.mjs", spawn: () => child });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: false, errorMessage: "Cron lifecycle command requested unexpected confirm dialog" });
    expect(child.kill).toHaveBeenCalledWith("SIGTERM");
  });

  it("retains error notifications as lifecycle context while waiting for the durable probe", async () => {
    const child = new FakeRpcChild();
    child.stdin.on("data", (chunk) => {
      const frame = JSON.parse(chunk.toString()) as Record<string, unknown>;
      if (frame.type === "get_commands") {
        child.respond({ id: frame.id, type: "response", command: "get_commands", success: true, data: { commands: [{ name: "cron", source: "extension" }] } });
      } else if (frame.type === "prompt") {
        child.respond({ type: "extension_ui_request", id: "notify-1", method: "notify", notifyType: "error", message: "launchctl warning" });
        child.respond({ id: frame.id, type: "response", command: "prompt", success: true });
        child.exit();
      }
    });
    const runner = new PiExtensionCommandRunner({ resolveRpcEntry: () => "/tmp/rpc-entry.mjs", spawn: () => child });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: true, notifications: ["launchctl warning"] });
  });

  it("records extension errors without treating them as a successful lifecycle acknowledgement", async () => {
    const child = new FakeRpcChild();
    child.stdin.on("data", (chunk) => {
      const frame = JSON.parse(chunk.toString()) as Record<string, unknown>;
      if (frame.type === "get_commands") {
        child.respond({ id: frame.id, type: "response", command: "get_commands", success: true, data: { commands: [{ name: "cron", source: "extension" }] } });
      } else if (frame.type === "prompt") {
        child.respond({ type: "extension_error", extensionPath: "/tmp/cron/index.ts", event: "command", error: "launchctl failed" });
      }
    });
    const runner = new PiExtensionCommandRunner({ resolveRpcEntry: () => "/tmp/rpc-entry.mjs", spawn: () => child });

    await expect(runner.run(request())).resolves.toMatchObject({
      ok: false,
      errorMessage: "Cron extension error: launchctl failed",
      extensionErrors: ["launchctl failed"],
    });
  });

  it("runs a temporary fake extension through bundled Pi RPC without loading user extensions", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-cron-rpc-"));
    const extension = join(root, "fake-cron.mjs");
    await writeFile(extension, `export default function (pi) {
  pi.registerCommand("cron", { description: "Temporary test command", handler: async () => {} });
}\n`);
    try {
      const runner = new PiExtensionCommandRunner({
        timeoutMs: 5_000,
        // Vitest's import.meta shim has no resolve(). The package export itself
        // is exercised by production's ESM resolver; this test executes its
        // bundled entry against a temporary extension.
        resolveRpcEntry: () => join(process.cwd(), "node_modules", "@earendil-works", "pi-coding-agent", "dist", "bundle", "rpc-entry.js"),
      });
      await expect(runner.run({
        agentDir: join(root, "agent"),
        extensionPath: extension,
        command: "install",
        environment: { ...process.env, PI_CODING_AGENT_DIR: join(root, "agent"), PI_CRON_PI_BIN: "/tmp/pi" },
      })).resolves.toMatchObject({ ok: true });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }, 10_000);

  it("force-kills a hanging RPC child that ignores SIGTERM", async () => {
    const child = new SigtermResistantRpcChild();
    const runner = new PiExtensionCommandRunner({
      resolveRpcEntry: () => "/tmp/rpc-entry.mjs",
      spawn: () => child,
      timeoutMs: 5,
      forceKillGraceMs: 5,
    });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: false, errorMessage: "Pi RPC lifecycle command timed out after 5ms" });
    expect(child.kill.mock.calls.map(([signal]) => signal)).toEqual(["SIGTERM", "SIGKILL"]);
  });

  it("settles at the force-kill deadline even when the child never emits exit", async () => {
    const child = new UnresponsiveRpcChild();
    const runner = new PiExtensionCommandRunner({
      resolveRpcEntry: () => "/tmp/rpc-entry.mjs",
      spawn: () => child,
      timeoutMs: 5,
      forceKillGraceMs: 5,
    });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: false, errorMessage: "Pi RPC lifecycle command timed out after 5ms" });
    expect(child.kill.mock.calls.map(([signal]) => signal)).toEqual(["SIGTERM", "SIGKILL"]);
  });

  it("bounds a hanging RPC command with termination", async () => {
    const child = new FakeRpcChild();
    const runner = new PiExtensionCommandRunner({
      resolveRpcEntry: () => "/tmp/rpc-entry.mjs",
      spawn: () => child,
      timeoutMs: 5,
      forceKillGraceMs: 5,
    });

    await expect(runner.run(request())).resolves.toMatchObject({ ok: false, errorMessage: "Pi RPC lifecycle command timed out after 5ms" });
    expect(child.kill).toHaveBeenCalledWith("SIGTERM");
  });
});
