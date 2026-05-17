import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";

class FakeSession extends EventEmitter {
  sessionFile = "/tmp/fake-session.jsonl";
  prompts: string[] = [];
  promptOptions: unknown[] = [];
  followUps: string[] = [];
  steers: string[] = [];
  aborts = 0;
  newSessions = 0;
  reloads = 0;
  thinkingLevels: string[] = [];
  isStreaming = false;
  isCompacting = false;
  bound = false;
  uiContext?: Record<string, unknown>;
  // Mirrors the real Pi session queue surface so PiSdkRuntimeSession can call
  // getSteeringMessages / getFollowUpMessages / clearQueue without optional-chaining guards.
  steeringQueue: string[] = [];
  followUpQueue: string[] = [];
  steeringMode: "one-at-a-time" | "all" = "one-at-a-time";
  followUpMode: "one-at-a-time" | "all" = "one-at-a-time";
  getSteeringMessages(): readonly string[] { return this.steeringQueue; }
  getFollowUpMessages(): readonly string[] { return this.followUpQueue; }
  clearQueue(): { steering: string[]; followUp: string[] } {
    const cleared = { steering: this.steeringQueue.slice(), followUp: this.followUpQueue.slice() };
    this.steeringQueue = [];
    this.followUpQueue = [];
    return cleared;
  }
  state: {
    messages: Array<Record<string, unknown>>;
    model?: { api: string; provider: string; id: string };
  } = {
    messages: [],
    model: { api: "anthropic-messages", provider: "anthropic", id: "claude-fake" },
  };
  appendedMessages: Array<Record<string, unknown>> = [];
  extensionCommands: Array<{ invocationName: string; description?: string; sourceInfo?: { baseDir?: string; path?: string; source?: string; scope?: string; origin?: string } }> = [];
  promptTemplates: Array<{ name: string; description: string }> = [];
  skills: Array<{ name: string; description: string }> = [];
  activeToolNames = ["read", "bash", "edit", "write"];
  setActiveToolsByNameCalls: string[][] = [];
  bashExecutions: Array<{ command: string; excludeFromContext?: boolean }> = [];
  recordedBashResults: Array<{ command: string; result: unknown; excludeFromContext?: boolean }> = [];
  userBashEvents: Array<{ type?: "user_bash"; command: string; excludeFromContext: boolean; cwd: string }> = [];
  userBashResult?: unknown;
  extensionRunner = {
    getRegisteredCommands: () => this.extensionCommands,
    emitUserBash: async (event: { type?: "user_bash"; command: string; excludeFromContext: boolean; cwd: string }) => {
      this.userBashEvents.push(event);
      return this.userBashResult ? { result: this.userBashResult } : undefined;
    },
  };
  resourceLoader = {
    getSkills: () => ({ skills: this.skills }),
  };
  sessionManager = {
    appendMessage: (message: Record<string, unknown>): string => {
      this.appendedMessages.push(message);
      return `entry-${this.appendedMessages.length}`;
    },
  };

  async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    (options as { preflightResult?: (success: boolean) => void } | undefined)?.preflightResult?.(true);
    this.emit("event", { type: "agent_start" });
    this.emit("event", { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "ok" } });
  }

  async followUp(text: string): Promise<void> {
    this.followUps.push(text);
  }

  async steer(text: string): Promise<void> {
    this.steers.push(text);
  }

  async abort(): Promise<void> {
    this.aborts += 1;
    this.isStreaming = false;
  }

  async reload(): Promise<void> {
    this.reloads += 1;
  }

  async executeBash(command: string, _onChunk?: (chunk: string) => void, options?: { excludeFromContext?: boolean }): Promise<{ output: string; exitCode: number; cancelled: boolean; truncated: boolean }> {
    this.bashExecutions.push({ command, excludeFromContext: options?.excludeFromContext });
    _onChunk?.("/tmp/project\n");
    const result = { output: "/tmp/project\n", exitCode: 0, cancelled: false, truncated: false };
    this.recordBashResult(command, result, options);
    return result;
  }

  recordBashResult(command: string, result: unknown, options?: { excludeFromContext?: boolean }): void {
    this.recordedBashResults.push({ command, result, excludeFromContext: options?.excludeFromContext });
  }

  getActiveToolNames(): string[] {
    return [...this.activeToolNames];
  }

  setActiveToolsByName(toolNames: string[]): void {
    this.setActiveToolsByNameCalls.push([...toolNames]);
    this.activeToolNames = [...toolNames];
  }

  setThinkingLevel(level: string): void {
    this.thinkingLevels.push(level);
  }

  async bindExtensions(options?: { uiContext?: Record<string, unknown> }): Promise<void> {
    this.bound = true;
    this.uiContext = options?.uiContext;
  }

  subscribe(listener: (event: unknown) => void): () => void {
    this.on("event", listener);
    return () => this.off("event", listener);
  }
}

class SilentSlashCommandSession extends FakeSession {
  override async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    (options as { preflightResult?: (success: boolean) => void } | undefined)?.preflightResult?.(true);
    // No events emitted - simulates Pi handling /slash extension commands or input handlers
    // that return action: "handled" without starting an agent turn.
  }
}

// Mirrors the real Pi runtime more closely than `SilentSlashCommandSession`: `session.prompt()`
// suspends at an internal `await` (Pi awaits `_tryExecuteExtensionCommand`) before resuming and
// running `preflightResult(true)` -> `return` synchronously. That microtask ordering reverses
// the queue-up order of the awaiting-acceptance continuation vs the prompt-resolution `.then`
// handler in PiSdkRuntimeSession.promptUntilAccepted, which used to leak through as a missing
// `Handled without agent turn` synthetic completion (`/diff-review` HUD spinner regression).
class AsyncSilentSlashCommandSession extends FakeSession {
  override async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    // Yield once before calling preflightResult so the call site has time to register its
    // `promptPromise.then` handler. This reproduces the real Pi flow where `_tryExecuteExtensionCommand`
    // suspends `prompt()` until the slash handler resolves.
    await Promise.resolve();
    (options as { preflightResult?: (success: boolean) => void } | undefined)?.preflightResult?.(true);
  }
}

// Mirrors Pi's server-side slash command expansion: when a /skill:<name> prompt arrives during
// an active stream, Pi enqueues an expanded form (e.g. the SKILL.md body) into followUpQueue
// instead of the raw text the user typed. The runtime adapter is expected to capture the raw ->
// expansion mapping by diffing this queue right after the prompt is accepted.
class SkillExpansionFakeSession extends FakeSession {
  expansionFor(rawText: string): string {
    const match = rawText.match(/^\/skill:([\w.-]+)/);
    if (!match) return rawText;
    return `<skill name="${match[1]}">SKILL body for ${match[1]}</skill>\n${rawText.slice(match[0].length).trim()}`;
  }

  override async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    if (this.isStreaming && text.startsWith("/skill:")) {
      this.followUpQueue.push(this.expansionFor(text));
    }
    (options as { preflightResult?: (success: boolean) => void } | undefined)?.preflightResult?.(true);
  }
}

class RaceSkillExpansionFakeSession extends SkillExpansionFakeSession {
  override async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    if (this.isStreaming && text.startsWith("/skill:")) {
      const expansion = this.expansionFor(text);
      this.followUpQueue.push(expansion);
      this.emit("event", { type: "queue_update", steering: [...this.steeringQueue], followUp: [...this.followUpQueue] });
    }
    (options as { preflightResult?: (success: boolean) => void } | undefined)?.preflightResult?.(true);
  }
}

class BlockingPromptSession extends FakeSession {
  private promptFinished: Promise<void>;
  private finishPrompt!: () => void;

  constructor() {
    super();
    this.promptFinished = new Promise((resolve) => {
      this.finishPrompt = resolve;
    });
  }

  override async prompt(text: string, options?: unknown): Promise<void> {
    this.prompts.push(text);
    this.promptOptions.push(options);
    (options as { preflightResult?: (success: boolean) => void } | undefined)?.preflightResult?.(true);
    this.emit("event", { type: "agent_start" });
    await this.promptFinished;
  }

  resolvePrompt(): void {
    this.finishPrompt();
  }
}

function makeRuntime(fakeSession: FakeSession): PiSdkRuntime {
  return new PiSdkRuntime({
    getAgentDir: () => "/tmp/.pi/agent",
    createServices: vi.fn(async () => ({ diagnostics: [] })) as never,
    createSessionFromServices: vi.fn(async () => ({ session: fakeSession, extensionsResult: { extensions: [], errors: [], runtime: {} } })) as never,
    createRuntime: vi.fn(async (factory, options) => {
      const result = await factory({ cwd: options.cwd, agentDir: options.agentDir, sessionManager: options.sessionManager });
      return {
        session: result.session,
        diagnostics: result.diagnostics,
        setRebindSession: vi.fn(),
        cwd: options.cwd,
        newSession: vi.fn(async () => {
          fakeSession.newSessions += 1;
          return { cancelled: false };
        }),
      };
    }) as never,
  });
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

  it("mirrors Pi extension injected user and custom messages", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.prewarm!({ cwd: "/tmp/project", sessionId: "session-1" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "message_start", message: { role: "user", content: [{ type: "text", text: "extension follow-up" }] } });
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "subagent", content: "custom result", display: true } });
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "hidden", content: "hidden result", display: false } });

    expect(events).toContainEqual({ type: "input_message", role: "user", text: "extension follow-up", originatedBy: "pi_extension" });
    expect(events).toContainEqual({ type: "input_message", role: "custom", text: "custom result", originatedBy: "pi_extension", display: true, customType: "subagent" });
    expect(events).toContainEqual({ type: "input_message", role: "custom", text: "hidden result", originatedBy: "pi_extension", display: false, customType: "hidden" });
  });

  it("executes user bash directly through the Pi session and preserves context inclusion flag", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm!({ cwd: "/tmp/project", sessionId: "session-1" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const result = await handle.executeUserBash!("pwd", { excludeFromContext: true });

    expect(result.output).toBe("/tmp/project\n");
    expect(fakeSession.userBashEvents).toEqual([{ type: "user_bash", command: "pwd", excludeFromContext: true, cwd: "/tmp/project" }]);
    expect(fakeSession.bashExecutions).toEqual([{ command: "pwd", excludeFromContext: true }]);
    expect(fakeSession.recordedBashResults).toHaveLength(1);
    expect(events).toContainEqual(expect.objectContaining({ type: "tool", name: "bash", status: "running", preview: "pwd" }));
    expect(events).toContainEqual(expect.objectContaining({ type: "tool", name: "bash", status: "succeeded", preview: "pwd" }));
  });

  it("records extension-provided user bash results without invoking local bash", async () => {
    const fakeSession = new FakeSession();
    fakeSession.userBashResult = { output: "remote\n", exitCode: 0, cancelled: false, truncated: false };
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm!({ cwd: "/tmp/project", sessionId: "session-1" });

    const result = await handle.executeUserBash!("hostname");

    expect(result.output).toBe("remote\n");
    expect(fakeSession.bashExecutions).toEqual([]);
    expect(fakeSession.recordedBashResults).toHaveLength(1);
    expect(fakeSession.recordedBashResults[0]).toMatchObject({ command: "hostname", excludeFromContext: false });
  });


  it("starts an idle Pi turn for follow-up input instead of only queueing it", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.create({ text: "initial", imagePaths: [] }, { cwd: "/tmp/project", sessionId: "session-1" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await handle.followUp({ text: "next voice input", imagePaths: [] });

    expect(fakeSession.prompts).toEqual(["initial", "next voice input"]);
    expect(fakeSession.followUps).toEqual([]);
    expect(fakeSession.promptOptions[1]).toMatchObject({ source: "rpc", streamingBehavior: "followUp" });
  });

  it("starts an idle Pi turn for steering input instead of only queueing it", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.create({ text: "initial", imagePaths: [] }, { cwd: "/tmp/project", sessionId: "session-1" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await handle.steer({ text: "focus on the previous result", imagePaths: [] });

    expect(fakeSession.prompts).toEqual(["initial", "focus on the previous result"]);
    expect(fakeSession.steers).toEqual([]);
    expect(fakeSession.promptOptions[1]).toMatchObject({ source: "rpc", streamingBehavior: "steer" });
  });

  it("interrupts an active Pi turn before sending replacement input", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });
    fakeSession.isStreaming = true;
    await handle.interrupt?.({ text: "replacement voice input", imagePaths: [] });

    expect(fakeSession.aborts).toBe(1);
    expect(fakeSession.prompts).toEqual(["replacement voice input"]);
    expect(fakeSession.promptOptions[0]).toMatchObject({ source: "rpc" });
    expect(fakeSession.promptOptions[0]).not.toMatchObject({ streamingBehavior: "followUp" });
  });

  it("returns from followUp after Pi accepts the prompt instead of waiting for the whole turn", async () => {
    const fakeSession = new BlockingPromptSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-1" });

    const result = await Promise.race([
      handle.followUp({ text: "long Pickle follow-up", imagePaths: [] }).then(() => "returned"),
      delay(20).then(() => "timeout"),
    ]);

    expect(result).toBe("returned");
    expect(fakeSession.prompts).toEqual(["long Pickle follow-up"]);
    expect(fakeSession.promptOptions[0]).toMatchObject({ source: "rpc", streamingBehavior: "followUp" });
    fakeSession.resolvePrompt();
  });

  it("returns from interrupt after Pi accepts replacement input instead of waiting for the whole turn", async () => {
    const fakeSession = new BlockingPromptSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });
    fakeSession.isStreaming = true;

    const result = await Promise.race([
      handle.interrupt!({ text: "replacement voice input", imagePaths: [] }).then(() => "returned"),
      delay(20).then(() => "timeout"),
    ]);

    expect(result).toBe("returned");
    expect(fakeSession.aborts).toBe(1);
    expect(fakeSession.prompts).toEqual(["replacement voice input"]);
    expect(fakeSession.promptOptions[0]).toMatchObject({ source: "rpc" });
    fakeSession.resolvePrompt();
  });

  it("bridges askUserQuestion forms through extension UI requests", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-form" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const askUserQuestion = fakeSession.uiContext?.askUserQuestion as ((request: unknown) => Promise<unknown>) | undefined;
    expect(askUserQuestion).toBeTypeOf("function");
    const answerPromise = askUserQuestion!({ title: "Pick", questions: [{ id: "choice", type: "radio", options: ["A", "B"] }] });
    const event = events.find((candidate) => typeof candidate === "object" && candidate && (candidate as { type?: string }).type === "extension_ui") as { request: { id: string; method: string; questions?: unknown[] }; waitsForInput: boolean } | undefined;

    expect(event).toMatchObject({ type: "extension_ui", waitsForInput: true, request: { method: "askUserQuestion" } });
    expect(event?.request.questions).toHaveLength(1);
    await handle.answerExtensionUi?.(event!.request.id, { choice: "B" });
    await expect(answerPromise).resolves.toEqual({ choice: "B" });
  });

  it("synthesizes completed status when Pi handles a slash extension command without emitting any events", async () => {
    const fakeSession = new SilentSlashCommandSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-slash" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    await handle.followUp({ text: "/diff-review", imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(statusEvents(events)).toEqual([{ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true }]);
  });

  it("synthesizes completed status and reports handledSynchronously even when Pi suspends prompt() before preflight (real-Pi shape)", async () => {
    const fakeSession = new AsyncSilentSlashCommandSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-slash-async" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const outcome = await handle.steer({ text: "/diff-review", imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(outcome).toEqual({ handledSynchronously: true });
    expect(statusEvents(events)).toEqual([{ type: "status", status: "completed", summary: "Handled without agent turn", noTurnRan: true }]);
  });

  it("does not synthesize completed when the prompt was queued during an active stream", async () => {
    const fakeSession = new SilentSlashCommandSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-queued-slash" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    await handle.followUp({ text: "queued slash command", imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(statusEvents(events)).toEqual([]);
  });

  it("translates the first queue_update emitted synchronously before preflightResult (Pi's real ordering)", async () => {
    const fakeSession = new RaceSkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-skill-race" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const rawText = "/skill:self-healing 으로 검증";
    await handle.followUp({ text: rawText, imagePaths: [] });

    const queueUpdates = events.filter((event): event is { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] } => (event as { type?: string }).type === "queue_update");
    expect(queueUpdates).toEqual([{ type: "queue_update", steering: [], followUp: [rawText] }]);
    expect(handle.getFollowUpMessages()).toEqual([rawText]);
  });

  it("translates Pi-side /skill: expansion back to the raw user text in queue_update events and getFollowUpMessages", async () => {
    const fakeSession = new SkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-skill-expansion" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const rawText = "/skill:self-healing 으로 검증";
    await handle.followUp({ text: rawText, imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const expansion = fakeSession.expansionFor(rawText);

    // Pi later emits a queue_update reflecting the Pi-side expansion text. The runtime adapter
    // must translate that back to the raw text the user typed before forwarding to subscribers.
    fakeSession.emit("event", { type: "queue_update", steering: [], followUp: [expansion] });

    const queueUpdates = events.filter((event): event is { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] } => (event as { type?: string }).type === "queue_update");
    expect(queueUpdates).toEqual([{ type: "queue_update", steering: [], followUp: [rawText] }]);
    expect(handle.getFollowUpMessages()).toEqual([rawText]);
    expect(handle.getSteeringMessages()).toEqual([]);
  });

  it("suppresses the duplicate role=custom echo Pi emits for an expanded /skill: command", async () => {
    const fakeSession = new SkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-skill-echo" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const rawText = "/skill:self-healing 으로 검증";
    await handle.followUp({ text: rawText, imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const expansion = fakeSession.expansionFor(rawText);

    // Pi processes the queued follow-up and emits a role=custom message_start carrying the
    // expansion (the SKILL.md body) as a Pi-extension context message. Picky already shows the
    // raw text as the user bubble via supervisor.drainDeliveredQueueItems, so this echo would
    // be a duplicate. The runtime adapter must suppress it.
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "skill", content: [{ type: "text", text: expansion }] } });

    const inputMessages = events.filter((event) => (event as { type?: string }).type === "input_message");
    expect(inputMessages).toEqual([]);
  });

  it("preserves the slash expansion mapping across repeated identical /skill: submissions", async () => {
    const fakeSession = new SkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-skill-repeated" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const rawText = "/skill:self-healing 으로 검증";
    await handle.followUp({ text: rawText, imagePaths: [] });
    await handle.followUp({ text: rawText, imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const expansion = fakeSession.expansionFor(rawText);

    fakeSession.emit("event", { type: "queue_update", steering: [], followUp: [expansion, expansion] });
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "skill", content: [{ type: "text", text: expansion }] } });
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "skill", content: [{ type: "text", text: expansion }] } });

    const queueUpdates = events.filter((event): event is { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] } => (event as { type?: string }).type === "queue_update");
    expect(queueUpdates).toEqual([{ type: "queue_update", steering: [], followUp: [rawText, rawText] }]);
    const inputMessages = events.filter((event) => (event as { type?: string }).type === "input_message");
    expect(inputMessages).toEqual([]);
  });

  it("suppresses a role=custom echo whose text has trailing whitespace compared to the queued expansion", async () => {
    const fakeSession = new SkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-skill-trim" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const rawText = "/skill:self-healing 으로 검증";
    await handle.followUp({ text: rawText, imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const expansion = fakeSession.expansionFor(rawText);

    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "skill", content: [{ type: "text", text: `${expansion}\n  ` }] } });

    const inputMessages = events.filter((event) => (event as { type?: string }).type === "input_message");
    expect(inputMessages).toEqual([]);
  });

  it("does not suppress role=custom messages whose text is unrelated to any submitted /skill: command", async () => {
    const fakeSession = new SkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-custom-unrelated" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    await handle.followUp({ text: "/skill:self-healing args", imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));

    // Unrelated custom message (e.g. a subagent or a different extension) must still be emitted.
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "subagent", content: [{ type: "text", text: "unrelated custom note" }] } });

    const inputMessages = events.filter((event) => (event as { type?: string }).type === "input_message");
    expect(inputMessages).toEqual([
      { type: "input_message", role: "custom", text: "unrelated custom note", originatedBy: "pi_extension", customType: "subagent" },
    ]);
  });

  it("clearQueue drops cached slash expansion mappings so a later identical custom message is no longer suppressed", async () => {
    const fakeSession = new SkillExpansionFakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-skill-clear" });
    fakeSession.isStreaming = true;
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const rawText = "/skill:self-healing 으로 검증";
    await handle.followUp({ text: rawText, imagePaths: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const expansion = fakeSession.expansionFor(rawText);

    handle.clearQueue();
    fakeSession.emit("event", { type: "message_start", message: { role: "custom", customType: "skill", content: [{ type: "text", text: expansion }] } });

    const inputMessages = events.filter((event) => (event as { type?: string }).type === "input_message");
    expect(inputMessages).toEqual([
      { type: "input_message", role: "custom", text: expansion, originatedBy: "pi_extension", customType: "skill" },
    ]);
  });

  it("emits completed from final turn_end when no queues or pending UI remain", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-turn" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "최종 답변" } });
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "최종 답변" }] }, toolResults: [] });

    expect(statusEvents(events)).toContainEqual({ type: "status", status: "completed", summary: "Completed", finalAnswer: "최종 답변", assistantRun: { model: "claude-fake" } });
  });

  it("refreshes context usage at intermediate message boundaries", async () => {
    const fakeSession = new FakeSession();
    (fakeSession as unknown as { getContextUsage: () => { tokens: number; contextWindow: number; percent: number } }).getContextUsage = () => ({ tokens: 88_000, contextWindow: 200_000, percent: 44 });
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-context-boundary" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "message_end", message: { role: "assistant", stopReason: "toolUse", content: [{ type: "toolCall", id: "tool-1", name: "read", arguments: {} }] } });
    fakeSession.emit("event", { type: "message_end", message: { role: "toolResult", toolCallId: "tool-1", toolName: "read", content: [{ type: "text", text: "file contents" }] } });

    expect(events).toContainEqual({ type: "context_usage", usage: { tokens: 88_000, contextWindow: 200_000, percent: 44 } });
    expect(events.filter((event) => (event as { type?: string }).type === "context_usage")).toHaveLength(2);
  });

  it("defers agent_end errors long enough for Pi auto-retry to recover", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-retry" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "error", errorMessage: "network error", content: [] }, toolResults: [] });
    fakeSession.emit("event", { type: "agent_end", messages: [{ role: "assistant", stopReason: "error", errorMessage: "network error", content: [] }] });
    fakeSession.emit("event", { type: "auto_retry_start", attempt: 1, maxAttempts: 3, delayMs: 1, errorMessage: "network error" });
    await delay(5);
    fakeSession.emit("event", { type: "auto_retry_end", success: true, attempt: 1 });
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "복구 완료" }] }, toolResults: [] });

    expect(statusEvents(events).some((event) => event.status === "failed")).toBe(false);
    expect(statusEvents(events)).toContainEqual({ type: "status", status: "running", summary: "Retrying after transient Pi error (1/3)…" });
    expect(statusEvents(events)).toContainEqual({ type: "status", status: "completed", summary: "Completed", finalAnswer: "복구 완료", assistantRun: { model: "claude-fake" } });
  });

  it("defers context overflow errors long enough for Pi compaction retry to recover", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-compaction-retry" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "error", errorMessage: "context_length_exceeded", content: [] }, toolResults: [] });
    fakeSession.emit("event", { type: "agent_end", messages: [{ role: "assistant", stopReason: "error", errorMessage: "context_length_exceeded", content: [] }] });
    fakeSession.emit("event", { type: "compaction_start", reason: "overflow" });
    fakeSession.emit("event", { type: "compaction_end", reason: "overflow", willRetry: true, aborted: false, result: { summary: "요약" } });
    await delay(5);
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "컴팩션 후 완료" }] }, toolResults: [] });

    expect(statusEvents(events).some((event) => event.status === "failed")).toBe(false);
    expect(statusEvents(events)).toContainEqual({ type: "status", status: "running", summary: "Compacting after context overflow…", compactionStarted: true, compactionReason: "overflow" });
    expect(statusEvents(events)).toContainEqual({ type: "status", status: "running", summary: "Compaction completed; retrying…", compactionCompleted: true, compactionReason: "overflow" });
    expect(statusEvents(events)).toContainEqual({ type: "status", status: "completed", summary: "Completed", finalAnswer: "컴팩션 후 완료", assistantRun: { model: "claude-fake" } });
    expect(fakeSession.setActiveToolsByNameCalls).toEqual([["read", "bash", "edit", "write"]]);
  });

  it("emits completion for non-retry automatic threshold compaction", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-threshold-compaction" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "compaction_start", reason: "threshold" });
    fakeSession.emit("event", { type: "compaction_end", reason: "threshold", willRetry: false, aborted: false, result: { summary: "요약" } });

    expect(statusEvents(events)).toContainEqual({ type: "status", status: "running", summary: "Compacting session…", compactionStarted: true, compactionReason: "threshold" });
    expect(statusEvents(events)).toContainEqual({ type: "status", status: "completed", summary: "Session compacted", noTurnRan: true, compactionCompleted: true, compactionReason: "threshold" });
    expect(fakeSession.setActiveToolsByNameCalls).toEqual([["read", "bash", "edit", "write"]]);
  });

  it("reports final failure when an agent_end error has no retry or compaction recovery", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-final-error" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "error", errorMessage: "fatal provider error", content: [] }, toolResults: [] });
    fakeSession.emit("event", { type: "agent_end", messages: [{ role: "assistant", stopReason: "error", errorMessage: "fatal provider error", content: [] }] });
    expect(statusEvents(events).some((event) => event.status === "failed")).toBe(false);

    await delay(5);

    expect(statusEvents(events)).toContainEqual({ type: "status", status: "failed", summary: "Agent error", assistantRun: { model: "claude-fake" } });
  });

  it("reports final failure when overflow compaction cannot recover", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-compaction-failed" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "agent_end", messages: [{ role: "assistant", stopReason: "error", errorMessage: "context_length_exceeded", content: [] }] });
    fakeSession.emit("event", { type: "compaction_start", reason: "overflow" });
    fakeSession.emit("event", { type: "compaction_end", reason: "overflow", willRetry: false, errorMessage: "Context overflow recovery failed" });

    expect(statusEvents(events)).toContainEqual({ type: "status", status: "failed", summary: "Context overflow recovery failed", compactionFailed: true, compactionReason: "overflow" });
  });

  it("marks threshold compaction failures without failing the completed turn", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-threshold-compaction-failed" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "compaction_end", reason: "threshold", willRetry: false, errorMessage: "Auto-compaction failed: summarizer overloaded" });

    expect(statusEvents(events)).toContainEqual({
      type: "status",
      status: "completed",
      summary: "Auto-compaction failed: summarizer overloaded",
      noTurnRan: true,
      compactionFailed: true,
      compactionReason: "threshold",
    });
  });

  it("keeps final turn_end running while Pi reports queued steering or follow-up", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-queued" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    fakeSession.emit("event", { type: "queue_update", steering: ["revise"], followUp: [] });
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "중간 답변" }] }, toolResults: [] });
    fakeSession.emit("event", { type: "queue_update", steering: [], followUp: [] });
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "최종 답변" }] }, toolResults: [] });

    expect(statusEvents(events).map((event) => event.status)).toEqual(["running", "completed"]);
    expect(events).toContainEqual({ type: "queue_update", steering: ["revise"], followUp: [] });
    expect(events).toContainEqual({ type: "queue_update", steering: [], followUp: [] });
  });

  it("keeps final turn_end waiting while bridge extension UI is pending and completes after answer", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-ui" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const confirm = fakeSession.uiContext?.confirm as ((title: string, message: string) => Promise<boolean>) | undefined;
    expect(confirm).toBeTypeOf("function");
    const answerPromise = confirm!("Need confirmation", "Proceed?");
    const request = events.find((event) => typeof event === "object" && event && (event as { type?: string }).type === "extension_ui") as { request: { id: string } } | undefined;
    expect(request?.request.id).toBeTruthy();

    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "입력 대기" }] }, toolResults: [] });
    await handle.answerExtensionUi?.(request!.request.id, { confirmed: true });
    await expect(answerPromise).resolves.toBe(true);
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "완료" }] }, toolResults: [] });

    expect(statusEvents(events).map((event) => event.status)).toEqual(["waiting_for_input", "completed"]);
  });

  it("clears pending extension UI request ids when rebinding the current Pi session", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-ui-rebind" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    const confirm = fakeSession.uiContext?.confirm as ((title: string, message: string) => Promise<boolean>) | undefined;
    expect(confirm).toBeTypeOf("function");
    void confirm!("Stale confirmation", "Proceed?");
    expect(events.some((event) => typeof event === "object" && event && (event as { type?: string }).type === "extension_ui")).toBe(true);

    await (handle as unknown as { bindCurrentSession: () => Promise<void> }).bindCurrentSession();
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "완료" }] }, toolResults: [] });

    expect(statusEvents(events).at(-1)?.status).toBe("completed");
  });

  it("ignores extension UI requests emitted by a stale bridge after rebinding", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "session-ui-stale-bridge" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));
    const staleConfirm = fakeSession.uiContext?.confirm as ((title: string, message: string) => Promise<boolean>) | undefined;
    expect(staleConfirm).toBeTypeOf("function");

    await (handle as unknown as { bindCurrentSession: () => Promise<void> }).bindCurrentSession();
    void staleConfirm!("Stale confirmation", "Proceed?");
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "end_turn", content: [{ type: "text", text: "완료" }] }, toolResults: [] });

    expect(events.filter((event) => typeof event === "object" && event && (event as { type?: string }).type === "extension_ui")).toEqual([]);
    expect(statusEvents(events).at(-1)?.status).toBe("completed");
  });

  it("repairs dangling tool calls from interrupted resumed Pi transcripts", async () => {
    const fakeSession = new FakeSession();
    fakeSession.state.messages = [
      { role: "user", content: [{ type: "text", text: "start" }] },
      {
        role: "assistant",
        stopReason: "toolUse",
        content: [
          { type: "thinking", thinking: "wait for setup" },
          { type: "toolCall", id: "tool-setup", name: "bash", arguments: { command: "sleep 60" } },
        ],
      },
      { role: "user", content: [{ type: "text", text: "continue" }] },
    ];
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.resume!("/tmp/interrupted.jsonl", { cwd: "/tmp/project", sessionId: "session-resume" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));
    await new Promise((resolve) => setTimeout(resolve, 0));

    const repairedAssistant = fakeSession.state.messages[1];
    const content = repairedAssistant.content as Array<Record<string, unknown>>;
    expect(content.some((block) => block.type === "toolCall")).toBe(false);
    expect(content.some((block) => typeof block.text === "string" && block.text.includes("local Picky runtime restarted"))).toBe(true);
    expect(repairedAssistant.stopReason).toBe("end_turn");
    expect(events).toContainEqual({ type: "log", line: "pi transcript repaired: skipped 1 interrupted tool call(s) (bash) from a previous runtime" });
  });

  it("prewarms Pi resources without sending an initial prompt", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(handle.id).toBe("picky");
    expect(fakeSession.bound).toBe(true);
    expect(fakeSession.prompts).toEqual([]);
  });

  it("does not send the delayed initial prompt after abort", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);

    const handle = await runtime.create({ text: "initial task", imagePaths: [] }, { cwd: "/tmp/project", sessionId: "abort-before-initial-prompt" });
    await handle.abort();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(fakeSession.aborts).toBe(1);
    expect(fakeSession.prompts).toEqual([]);
  });

  it("suppresses the aborted turn_end that drains after an explicit abort", async () => {
    // After handle.abort() we already emit a synthetic `cancelled` so the HUD reflects the
    // cancellation immediately. Pi keeps draining the aborted turn and eventually flushes its
    // own turn_end with stopReason="aborted" — that duplicate is the late event that used to
    // stamp a second "Cancelled by user" bubble on top of a steer the user sent in between.
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "abort-late-turn-end" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    await handle.abort();
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "aborted", content: [] }, toolResults: [] });

    expect(statusEvents(events).filter((event) => event.status === "cancelled")).toEqual([
      { type: "status", status: "cancelled", summary: "Cancelled" },
    ]);
  });

  it("suppresses the aborted agent_end that drains after an explicit abort", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "abort-late-agent-end" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    await handle.abort();
    fakeSession.emit("event", { type: "agent_end", messages: [{ role: "assistant", stopReason: "aborted", content: [] }] });

    expect(statusEvents(events).filter((event) => event.status === "cancelled")).toEqual([
      { type: "status", status: "cancelled", summary: "Cancelled" },
    ]);
  });

  it("only suppresses one aborted drain per abort call", async () => {
    // Safety net: if the user aborts a second time (e.g. cancels again after steering), the
    // suppression for the first abort has already been consumed, so the second drain must
    // still flow through.
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "abort-late-twice" });
    const events: unknown[] = [];
    handle.subscribe((event) => events.push(event));

    await handle.abort();
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "aborted", content: [] }, toolResults: [] });
    fakeSession.emit("event", { type: "turn_end", message: { role: "assistant", stopReason: "aborted", content: [] }, toolResults: [] });

    const cancelledStatuses = statusEvents(events).filter((event) => event.status === "cancelled");
    expect(cancelledStatuses).toHaveLength(2);
    expect(cancelledStatuses[0]).toMatchObject({ type: "status", status: "cancelled", summary: "Cancelled" });
    expect(cancelledStatuses[1]).toMatchObject({ type: "status", status: "cancelled", summary: "Cancelled" });
  });

  it("injects a synthetic user/assistant pair into a fresh session and persists both messages", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });

    await handle.injectInitialBootstrap?.({ user: "답변 규칙", assistant: "OK" });

    expect(fakeSession.state.messages).toHaveLength(2);
    expect(fakeSession.state.messages[0]).toMatchObject({ role: "user", content: "답변 규칙" });
    expect(fakeSession.state.messages[1]).toMatchObject({
      role: "assistant",
      content: [{ type: "text", text: "OK" }],
      provider: "anthropic",
      model: "claude-fake",
      stopReason: "stop",
    });
    expect(fakeSession.appendedMessages).toHaveLength(2);
    expect(fakeSession.appendedMessages[0]).toMatchObject({ role: "user" });
    expect(fakeSession.appendedMessages[1]).toMatchObject({ role: "assistant" });
  });

  it("skips bootstrap injection when the session already has messages", async () => {
    const fakeSession = new FakeSession();
    fakeSession.state.messages = [{ role: "user", content: "prior turn" }];
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });

    await handle.injectInitialBootstrap?.({ user: "답변 규칙", assistant: "OK" });

    expect(fakeSession.state.messages).toHaveLength(1);
    expect(fakeSession.appendedMessages).toHaveLength(0);
  });

  it("skips bootstrap injection when the session has no resolved model", async () => {
    const fakeSession = new FakeSession();
    fakeSession.state.model = undefined;
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });

    await handle.injectInitialBootstrap?.({ user: "답변 규칙", assistant: "OK" });

    expect(fakeSession.state.messages).toHaveLength(0);
    expect(fakeSession.appendedMessages).toHaveLength(0);
  });

  it("lists slash commands from extension, prompt template, and skill resources", async () => {
    const fakeSession = new FakeSession();
    fakeSession.extensionCommands = [{ invocationName: "deploy", description: "Deploy an environment" }];
    fakeSession.promptTemplates = [{ name: "fix-tests", description: "Fix failing tests" }];
    fakeSession.skills = [{ name: "context7-cli", description: "Look up library docs" }];
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-commands" });

    expect(handle.listSlashCommands).toBeDefined();
    expect(await handle.listSlashCommands!()).toEqual([
      { name: "new", description: "Start a fresh Pi session in this Picky card", source: "builtin" },
      { name: "name", description: "Set the Pi session display name (usage: /name <session name>)", source: "builtin" },
      { name: "compact", description: "Manually compact the session context (optional: /compact <focus instructions>)", source: "builtin" },
      { name: "reload", description: "Reload Pi skills, extensions, prompts, and context files", source: "builtin" },
      { name: "deploy", description: "Deploy an environment", source: "extension" },
      { name: "fix-tests", description: "Fix failing tests", source: "prompt" },
      { name: "skill:context7-cli", description: "Look up library docs", source: "skill" },
    ]);
  });

  // We intentionally surface every extension command, including overlay-only ones. Pi SDK
  // gives auto-discovered local extensions a shared baseDir (the agent root), which makes any
  // directory-level `ui.custom` scan a false-positive trap that hides clean siblings. Picky's
  // ExtensionUiBridge no-ops the unsupported overlay surface and the crash guard swallows the
  // remaining throws, so we let users see and try the command instead of pre-filtering.
  it("surfaces every extension command, including ones that depend on overlay UI", async () => {
    const fakeSession = new FakeSession();
    fakeSession.extensionCommands = [
      { invocationName: "diff", description: "Diff overlay", sourceInfo: { baseDir: "/tmp/overlay-ext", path: "/tmp/overlay-ext", source: "local", scope: "user", origin: "top-level" } },
      { invocationName: "settings", description: "Toggle setting", sourceInfo: { baseDir: "/tmp/safe-ext", path: "/tmp/safe-ext", source: "local", scope: "user", origin: "top-level" } },
    ];
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-overlay" });

    const commands = await handle.listSlashCommands!();
    const names = commands.map((command) => command.name);
    expect(names).toContain("settings");
    expect(names).toContain("diff");
  });

  it("intercepts /new as a built-in slash command and replaces the underlying Pi session", async () => {
    const fakeSession = new FakeSession();
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-new" });
    const events: Array<{ type: string; status?: string; noTurnRan?: boolean; preserveSessionState?: boolean; reason?: string; cwd?: string; sessionFilePath?: string; summary?: string; line?: string }> = [];
    handle.subscribe((event) => events.push(event as { type: string; status?: string; noTurnRan?: boolean; preserveSessionState?: boolean; reason?: string; cwd?: string; sessionFilePath?: string; summary?: string; line?: string }));

    await handle.followUp({ text: "/new", imagePaths: [] });

    expect(fakeSession.newSessions).toBe(1);
    expect(fakeSession.prompts).toEqual([]);
    expect(events).toContainEqual({ type: "session_replaced", reason: "new", cwd: "/tmp/project", sessionFilePath: "/tmp/fake-session.jsonl" });
    expect(events).toContainEqual({ type: "status", status: "completed", summary: "New session started", noTurnRan: true, preserveSessionState: true });
    const replacementIndex = events.findIndex((event) => event.type === "session_replaced");
    const diagnosticIndex = events.findIndex((event) => event.type === "log" && event.line === "pi session: /tmp/fake-session.jsonl");
    expect(replacementIndex).toBeGreaterThanOrEqual(0);
    expect(diagnosticIndex).toBeGreaterThan(replacementIndex);
  });

  it("intercepts /name as a built-in slash command and renames the underlying Pi session", async () => {
    const fakeSession = new FakeSession();
    const setSessionNameCalls: string[] = [];
    (fakeSession as unknown as { setSessionName: (name: string) => void }).setSessionName = (name: string) => {
      setSessionNameCalls.push(name);
    };
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-name" });
    const events: Array<{ type: string; status?: string; noTurnRan?: boolean; preserveSessionState?: boolean }> = [];
    handle.subscribe((event) => events.push(event as { type: string; status?: string; noTurnRan?: boolean; preserveSessionState?: boolean }));

    await handle.followUp({ text: "/name 새 이름", imagePaths: [] });

    expect(setSessionNameCalls).toEqual(["새 이름"]);
    expect(fakeSession.prompts).toEqual([]);
    expect(events.some((event) => event.type === "status" && event.status === "completed" && event.noTurnRan === true && event.preserveSessionState === true)).toBe(true);
  });

  it("intercepts /compact, forwards optional instructions, and resets context usage", async () => {
    const fakeSession = new FakeSession();
    const compactCalls: Array<string | undefined> = [];
    (fakeSession as unknown as { compact: (instructions?: string) => Promise<unknown> }).compact = async (instructions) => {
      compactCalls.push(instructions);
      return {};
    };
    (fakeSession as unknown as { getContextUsage: () => { tokens: number; contextWindow: number; percent: number } }).getContextUsage = () => ({ tokens: 123_456, contextWindow: 200_000, percent: 62 });
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-compact" });
    const events: Array<{ type: string; status?: string; noTurnRan?: boolean; usage?: unknown }> = [];
    handle.subscribe((event) => events.push(event as { type: string; status?: string; noTurnRan?: boolean; usage?: unknown }));

    await handle.followUp({ text: "/compact focus on bug area", imagePaths: [] });

    expect(compactCalls).toEqual(["focus on bug area"]);
    expect(fakeSession.setActiveToolsByNameCalls).toEqual([["read", "bash", "edit", "write"]]);
    expect(fakeSession.prompts).toEqual([]);
    const statuses = events.filter((event) => event.type === "status").map((event) => event.status);
    expect(statuses).toContain("running");
    expect(statuses).toContain("completed");
    expect(events).toContainEqual({ type: "context_usage", usage: { tokens: null, contextWindow: 200_000, percent: null } });
  });

  it("rejects /compact while the active agent is running", async () => {
    const fakeSession = new FakeSession();
    fakeSession.isStreaming = true;
    const compactCalls: Array<string | undefined> = [];
    (fakeSession as unknown as { compact: (instructions?: string) => Promise<unknown> }).compact = async (instructions) => {
      compactCalls.push(instructions);
      return {};
    };
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-compact-running" });
    const events: Array<{ type: string; status?: string; noTurnRan?: boolean; preserveSessionState?: boolean; line?: string }> = [];
    handle.subscribe((event) => events.push(event as { type: string; status?: string; noTurnRan?: boolean; preserveSessionState?: boolean; line?: string }));

    await handle.followUp({ text: "/compact", imagePaths: [] });

    expect(compactCalls).toEqual([]);
    expect(fakeSession.prompts).toEqual([]);
    expect(events).toContainEqual({ type: "log", line: "/compact rejected: cannot compact while the agent is running" });
    expect(events).toContainEqual({ type: "status", status: "completed", summary: "/compact is unavailable while the agent is running", noTurnRan: true, preserveSessionState: true });
  });

  it("intercepts /reload and reloads Pi resources without an agent turn", async () => {
    const fakeSession = new FakeSession();
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-reload" });
    const events: Array<{ type: string; status?: string; summary?: string; noTurnRan?: boolean; preserveSessionState?: boolean; line?: string }> = [];
    handle.subscribe((event) => events.push(event as { type: string; status?: string; summary?: string; noTurnRan?: boolean; preserveSessionState?: boolean; line?: string }));

    await handle.followUp({ text: "/reload", imagePaths: [] });

    expect(fakeSession.reloads).toBe(1);
    expect(fakeSession.prompts).toEqual([]);
    expect(events).toContainEqual({ type: "status", status: "running", summary: "Reloading Pi resources…" });
    expect(events).toContainEqual({ type: "log", line: "pi resources reloaded" });
    expect(events).toContainEqual({ type: "status", status: "completed", summary: "Pi resources reloaded", noTurnRan: true });
  });

  it("rejects /reload while the active agent is running", async () => {
    const fakeSession = new FakeSession();
    fakeSession.isStreaming = true;
    const handle = await makeRuntime(fakeSession).prewarm({ cwd: "/tmp/project", sessionId: "session-reload-running" });
    const events: Array<{ type: string; status?: string; summary?: string; noTurnRan?: boolean; preserveSessionState?: boolean; line?: string }> = [];
    handle.subscribe((event) => events.push(event as { type: string; status?: string; summary?: string; noTurnRan?: boolean; preserveSessionState?: boolean; line?: string }));

    await handle.followUp({ text: "/reload", imagePaths: [] });

    expect(fakeSession.reloads).toBe(0);
    expect(fakeSession.prompts).toEqual([]);
    expect(events).toContainEqual({ type: "log", line: "/reload rejected: wait for the current response to finish" });
    expect(events).toContainEqual({ type: "status", status: "completed", summary: "/reload is unavailable while the agent is running", noTurnRan: true, preserveSessionState: true });
  });

  it("updates the active Pi session thinking level", async () => {
    const fakeSession = new FakeSession();
    const runtime = makeRuntime(fakeSession);
    const handle = await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });

    handle.setThinkingLevel?.("high");

    expect(fakeSession.thinkingLevels).toEqual(["high"]);
  });

  it("uses updated thinking level for future Pi session creation", async () => {
    const fakeSession = new FakeSession();
    const createSessionFromServices = vi.fn(async () => ({ session: fakeSession, extensionsResult: { extensions: [], errors: [], runtime: {} } }));
    const runtime = new PiSdkRuntime({
      getAgentDir: () => "/tmp/.pi/agent",
      thinkingLevel: "medium",
      createServices: vi.fn(async () => ({ diagnostics: [] })) as never,
      createSessionFromServices: createSessionFromServices as never,
      createRuntime: vi.fn(async (factory, options) => {
        const result = await factory({ cwd: options.cwd, agentDir: options.agentDir, sessionManager: options.sessionManager });
        return {
          session: result.session,
          diagnostics: result.diagnostics,
          setRebindSession: vi.fn(),
        };
      }) as never,
    });

    runtime.setThinkingLevel("xhigh");
    await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });

    expect(createSessionFromServices).toHaveBeenCalledWith(expect.objectContaining({ thinkingLevel: "xhigh" }));
  });

  it("passes an explicit thinking level override to Pi session creation", async () => {
    const fakeSession = new FakeSession();
    const createSessionFromServices = vi.fn(async () => ({ session: fakeSession, extensionsResult: { extensions: [], errors: [], runtime: {} } }));
    const runtime = new PiSdkRuntime({
      getAgentDir: () => "/tmp/.pi/agent",
      thinkingLevel: "medium",
      createServices: vi.fn(async () => ({ diagnostics: [] })) as never,
      createSessionFromServices: createSessionFromServices as never,
      createRuntime: vi.fn(async (factory, options) => {
        const result = await factory({ cwd: options.cwd, agentDir: options.agentDir, sessionManager: options.sessionManager });
        return {
          session: result.session,
          diagnostics: result.diagnostics,
          setRebindSession: vi.fn(),
        };
      }) as never,
    });

    await runtime.prewarm({ cwd: "/tmp/project", sessionId: "picky" });

    expect(createSessionFromServices).toHaveBeenCalledWith(expect.objectContaining({ thinkingLevel: "medium" }));
  });

  it("gates real Pi integration behind PICKY_RUN_PI_INTEGRATION", async () => {
    if (process.env.PICKY_RUN_PI_INTEGRATION !== "1") return;
    const runtime = new PiSdkRuntime();
    const handle = await runtime.create({ text: "Say hello and stop.", imagePaths: [] }, { cwd: process.cwd(), sessionId: "integration" });
    expect(handle.id).toBe("integration");
    await handle.abort();
  });
});

function statusEvents(events: unknown[]): Array<{ type: "status"; status: string; summary?: string }> {
  return events.filter((event): event is { type: "status"; status: string; summary?: string } => (
    typeof event === "object" && event !== null && (event as { type?: string }).type === "status"
  ));
}

async function delay(milliseconds: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}
