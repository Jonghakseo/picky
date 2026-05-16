import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { CommandEnvelopeSchema, PROTOCOL_VERSION } from "./protocol.js";

const extensionPath = join(process.cwd(), "..", "pi-extensions", "picky-handoff", "index.ts");
const originalConnectionFile = process.env.PICKY_AGENTD_CONNECTION_FILE;
const hadOriginalWebSocket = "WebSocket" in globalThis;
const originalWebSocket = (globalThis as { WebSocket?: unknown }).WebSocket;

afterEach(() => {
  if (originalConnectionFile === undefined) delete process.env.PICKY_AGENTD_CONNECTION_FILE;
  else process.env.PICKY_AGENTD_CONNECTION_FILE = originalConnectionFile;
  if (hadOriginalWebSocket) (globalThis as { WebSocket?: unknown }).WebSocket = originalWebSocket;
  else delete (globalThis as { WebSocket?: unknown }).WebSocket;
});

describe("picky-handoff extension protocol contract", () => {
  it("sends an agentd-compatible pinPickleSession command when the connection file has no protocolVersion", async () => {
    const temp = await mkdtemp(join(tmpdir(), "picky-handoff-extension-"));
    process.env.PICKY_AGENTD_CONNECTION_FILE = join(temp, "agentd-connection.json");
    await writeFile(
      process.env.PICKY_AGENTD_CONNECTION_FILE,
      JSON.stringify({ url: "ws://127.0.0.1:17631", token: "test-token", defaultCwd: "/tmp/default-cwd" }),
      "utf8",
    );

    const sentPayloads: unknown[] = [];
    const openedUrls: string[] = [];
    installFakeWebSocket(sentPayloads, openedUrls);
    const registered = await registerExtensionCommand();

    await registered.handler("Pin the idle task", {
      cwd: undefined,
      ui: { notify: () => undefined },
      isIdle: () => true,
      sessionManager: {
        getSessionFile: () => "/tmp/pi-session.jsonl",
        getBranch: () => [],
      },
    });

    expect(openedUrls).toEqual(["ws://127.0.0.1:17631/?token=test-token"]);
    expect(sentPayloads).toHaveLength(1);
    const parsed = CommandEnvelopeSchema.parse(sentPayloads[0]);
    expect(parsed.type).toBe("pinPickleSession");
    expect(parsed.protocolVersion).toBe(PROTOCOL_VERSION);
    if (parsed.type === "pinPickleSession") {
      expect(parsed.context.cwd).toBe("/tmp/default-cwd");
      expect(parsed.context.activeApp?.name).toBe("Pi");
    }
  });
});

async function registerExtensionCommand(): Promise<{ handler(args: string, ctx: FakeCommandContext): Promise<void> }> {
  let registered: { handler(args: string, ctx: FakeCommandContext): Promise<void> } | undefined;
  const module = await import(pathToFileURL(extensionPath).href) as { default(pi: FakePiExtensionAPI): void };
  module.default({
    getSessionName: () => "Pi Session",
    registerCommand: (_name, options) => { registered = { handler: options.handler }; },
  });
  if (!registered) throw new Error("picky-handoff extension did not register a command");
  return registered;
}

function installFakeWebSocket(sentPayloads: unknown[], openedUrls: string[]): void {
  class FakeWebSocket {
    private listeners: Partial<Record<"open" | "message" | "error" | "close", (event: { data?: unknown; error?: unknown; reason?: unknown }) => void>> = {};

    constructor(readonly url: string | URL) {
      openedUrls.push(String(url));
      setTimeout(() => this.listeners.open?.({}), 0);
    }

    send(data: string): void {
      const payload = JSON.parse(data) as Record<string, unknown>;
      sentPayloads.push(payload);
      setTimeout(() => {
        this.listeners.message?.({
          data: JSON.stringify({
            type: "sessionUpdated",
            session: { id: "session-pinned", title: payload.title ?? "Pinned", status: "completed" },
          }),
        });
      }, 0);
    }

    close(): void {
      this.listeners.close?.({});
    }

    addEventListener(type: "open" | "message" | "error" | "close", listener: (event: { data?: unknown; error?: unknown; reason?: unknown }) => void): void {
      this.listeners[type] = listener;
    }
  }

  (globalThis as { WebSocket?: unknown }).WebSocket = FakeWebSocket;
}

interface FakeCommandContext {
  cwd?: string;
  ui: { notify(message: string, level?: "info" | "warning" | "error" | "success"): void };
  isIdle(): boolean;
  sessionManager: {
    getSessionFile(): string | undefined;
    getBranch(): unknown[];
  };
}

interface FakePiExtensionAPI {
  getSessionName(): string | undefined;
  registerCommand(name: string, options: { description: string; handler(args: string, ctx: FakeCommandContext): Promise<void> }): void;
}
