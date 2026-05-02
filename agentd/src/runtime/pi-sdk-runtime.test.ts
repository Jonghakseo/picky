import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";

class FakeSession extends EventEmitter {
  sessionFile = "/tmp/fake-session.jsonl";
  prompts: string[] = [];
  promptOptions: unknown[] = [];
  followUps: string[] = [];
  steers: string[] = [];
  bound = false;

  async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    this.emit("event", { type: "agent_start" });
    this.emit("event", { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "ok" } });
  }

  async followUp(text: string): Promise<void> {
    this.followUps.push(text);
  }

  async steer(text: string): Promise<void> {
    this.steers.push(text);
  }

  async abort(): Promise<void> {}

  async bindExtensions(): Promise<void> {
    this.bound = true;
  }

  subscribe(listener: (event: unknown) => void): () => void {
    this.on("event", listener);
    return () => this.off("event", listener);
  }
}

describe("PiSdkRuntime", () => {
  it("creates a Pi session through injected documented factory hooks without live model calls", async () => {
    const fakeSession = new FakeSession();
    const runtime = new PiSdkRuntime({
      getAgentDir: () => "/tmp/.pi/agent",
      createServices: vi.fn(async () => ({ diagnostics: [{ level: "warning", message: "fake diagnostic" }] })) as never,
      createSessionFromServices: vi.fn(async () => ({ session: fakeSession, extensionsResult: { extensions: [], errors: [], runtime: {} } })) as never,
      createRuntime: vi.fn(async (factory, options) => {
        const result = await factory({ cwd: options.cwd, agentDir: options.agentDir, sessionManager: options.sessionManager });
        return {
          session: result.session,
          diagnostics: result.diagnostics,
          setRebindSession: vi.fn(),
        };
      }) as never,
    });

    const handle = await runtime.create({ text: "hello", imagePaths: [] }, { cwd: "/tmp/project", sessionId: "session-1" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(fakeSession.bound).toBe(true);
    expect(fakeSession.prompts).toEqual(["hello"]);
    expect(events).toContainEqual({ type: "log", line: "pi diagnostic: {\"level\":\"warning\",\"message\":\"fake diagnostic\"}" });
    expect(events).toContainEqual({ type: "log", line: "pi session: /tmp/fake-session.jsonl" });
    expect(events).toContainEqual({ type: "status", status: "running", summary: "Agent started" });
    expect(events).toContainEqual({ type: "assistant_delta", delta: "ok" });
  });

  it("starts an idle Pi turn for follow-up input instead of only queueing it", async () => {
    const fakeSession = new FakeSession();
    const runtime = new PiSdkRuntime({
      getAgentDir: () => "/tmp/.pi/agent",
      createServices: vi.fn(async () => ({ diagnostics: [] })) as never,
      createSessionFromServices: vi.fn(async () => ({ session: fakeSession, extensionsResult: { extensions: [], errors: [], runtime: {} } })) as never,
      createRuntime: vi.fn(async (factory, options) => {
        const result = await factory({ cwd: options.cwd, agentDir: options.agentDir, sessionManager: options.sessionManager });
        return {
          session: result.session,
          diagnostics: result.diagnostics,
          setRebindSession: vi.fn(),
        };
      }) as never,
    });

    const handle = await runtime.create({ text: "initial", imagePaths: [] }, { cwd: "/tmp/project", sessionId: "session-1" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await handle.followUp({ text: "next voice input", imagePaths: [] });

    expect(fakeSession.prompts).toEqual(["initial", "next voice input"]);
    expect(fakeSession.followUps).toEqual([]);
    expect(fakeSession.promptOptions[1]).toMatchObject({ source: "rpc", streamingBehavior: "followUp" });
  });

  it("gates real Pi integration behind PICKY_RUN_PI_INTEGRATION", async () => {
    if (process.env.PICKY_RUN_PI_INTEGRATION !== "1") return;
    const runtime = new PiSdkRuntime();
    const handle = await runtime.create({ text: "Say hello and stop.", imagePaths: [] }, { cwd: process.cwd(), sessionId: "integration" });
    expect(handle.id).toBe("integration");
    await handle.abort();
  });
});
