import { describe, expect, it } from "vitest";
import { buildRealtimeConnection, normalizeAzureRealtimeHost, OpenAIRealtimeMainRuntime, parseAzureRealtimeEndpointUrl, type RealtimeWebSocketLike } from "./openai-realtime-main-runtime.js";
import { SelectableMainRuntime } from "./selectable-main-runtime.js";
import type { AgentRuntime, MainRealtimeRuntime, RuntimeSessionHandle, ThinkingLevel } from "./types.js";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { OpenAIRealtimeAuthConfig, PickyAgentSession, PickyContextPacket } from "../protocol.js";

describe("OpenAI Realtime provider connection builders", () => {
  it("builds OpenAI GA websocket URL without the beta header for gpt-realtime models", () => {
    const connection = buildRealtimeConnection({
      provider: "openai",
      apiKey: "sk-test",
      modelOrDeployment: "gpt-realtime-2",
      voice: "marin",
    });

    expect(connection.url).toBe("wss://api.openai.com/v1/realtime?model=gpt-realtime-2");
    expect(connection.headers).toEqual({ Authorization: "Bearer sk-test" });
  });

  it("keeps the beta header for older OpenAI realtime preview models", () => {
    const connection = buildRealtimeConnection({
      provider: "openai",
      apiKey: "sk-test",
      modelOrDeployment: "gpt-4o-realtime-preview",
      voice: "marin",
    });

    expect(connection.url).toBe("wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview");
    expect(connection.headers.Authorization).toBe("Bearer sk-test");
    expect(connection.headers["OpenAI-Beta"]).toBe("realtime=v1");
  });

  it("builds Azure OpenAI GA websocket URL and api-key auth", () => {
    const connection = buildRealtimeConnection({
      provider: "azure_openai",
      apiKey: "azure-key",
      modelOrDeployment: "rt-deployment",
      voice: "marin",
      azure: {
        resourceEndpoint: "https://picky-resource.openai.azure.com",
        apiShape: "ga",
      },
    });

    expect(connection.url).toBe("wss://picky-resource.openai.azure.com/openai/v1/realtime?model=rt-deployment");
    expect(connection.headers).toEqual({ "api-key": "azure-key" });
  });

  it("builds Azure OpenAI preview websocket URL with api-version", () => {
    const connection = buildRealtimeConnection({
      provider: "azure_openai",
      apiKey: "azure-key",
      modelOrDeployment: "rt-deployment",
      voice: "marin",
      azure: {
        resourceEndpoint: "picky-resource.openai.azure.com",
        apiVersion: "2025-04-01-preview",
        apiShape: "preview",
      },
    });

    expect(connection.url).toBe("wss://picky-resource.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&deployment=rt-deployment");
    expect(connection.headers).toEqual({ "api-key": "azure-key" });
  });

  it("derives Azure OpenAI preview connection from full Realtime URL", () => {
    const connection = buildRealtimeConnection({
      provider: "azure_openai",
      apiKey: "azure-key",
      modelOrDeployment: "ignored-when-url-has-deployment",
      voice: "marin",
      azure: {
        resourceEndpoint: "https://creatrip-openai-api-us2.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5",
        apiShape: "ga",
      },
    });

    expect(connection.url).toBe("wss://creatrip-openai-api-us2.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5");
    expect(connection.headers).toEqual({ "api-key": "azure-key" });
  });

  it("parses full Azure Realtime URLs into host, deployment, and API shape", () => {
    expect(parseAzureRealtimeEndpointUrl("https://x.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=rt-15")).toEqual({
      host: "x.openai.azure.com",
      deployment: "rt-15",
      apiVersion: "2024-10-01-preview",
      apiShape: "preview",
    });
    expect(parseAzureRealtimeEndpointUrl("wss://x.openai.azure.com/openai/v1/realtime?model=rt-ga")).toEqual({
      host: "x.openai.azure.com",
      deployment: "rt-ga",
      apiVersion: undefined,
      apiShape: "ga",
    });
  });

  it("normalizes Azure endpoint hosts and rejects paths", () => {
    expect(normalizeAzureRealtimeHost("https://x.openai.azure.com")).toBe("x.openai.azure.com");
    expect(normalizeAzureRealtimeHost("x.openai.azure.com")).toBe("x.openai.azure.com");
    expect(() => normalizeAzureRealtimeHost("https://x.openai.azure.com/openai/deployments/foo")).toThrow(/must not include/);
  });
});

describe("OpenAIRealtimeMainRuntime OpenAI GA protocol", () => {
  it("exposes skill lookup tools and omits the pointer overlay tool", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const sessionUpdate = sent.find((event) => event.type === "session.update")!;
    const toolNames = sessionUpdate.session.tools.map((tool: Record<string, unknown>) => tool.name);

    expect(toolNames).toContain("picky_skills_search");
    expect(toolNames).toContain("picky_skill_details");
    expect(toolNames).not.toContain("picky_pointer_overlay");
  });

  it("passes the active cwd to skill lookup tool handlers", async () => {
    const socket = new FakeRealtimeSocket();
    const cwdCalls: Array<string | undefined> = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async searchSkills(request) {
          cwdCalls.push(request.cwd);
          return { query: request.query ?? "", root: request.cwd ?? "", total: 0, skills: [] };
        },
      },
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context({ cwd: "/tmp/project" }) });
    socket.serverEvent({
      type: "response.output_item.done",
      item: {
        type: "function_call",
        name: "picky_skills_search",
        call_id: "call-skills",
        arguments: JSON.stringify({ query: "debug" }),
      },
    });
    await settle();

    expect(cwdCalls).toEqual(["/tmp/project"]);
  });

  it("returns a minimal side session list with only id, title, cwd, and last message", async () => {
    const socket = new FakeRealtimeSocket();
    let listCalls = 0;
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listSideSessions() {
          listCalls += 1;
          return Array.from({ length: 6 }, (_, index) => ({
            id: `side-${index + 1}`,
            title: `Side ${index + 1}`,
            status: index % 2 === 0 ? "running" : "completed",
            cwd: "/tmp/project",
            createdAt: "2026-05-09T00:00:00.000Z",
            updatedAt: `2026-05-09T00:00:0${index}.000Z`,
            lastSummary: `Summary ${index + 1}`,
            logs: ["very long raw log that should not be returned"],
            tools: [{ toolCallId: "tool-1", name: "bash", status: "succeeded", startedAt: "2026-05-09T00:00:00.000Z", endedAt: "2026-05-09T00:00:00.000Z", preview: "tool preview should not be returned" }],
            artifacts: [{ id: "artifact-1", kind: "report", title: "artifact should not be returned", path: "/tmp/artifact.md", updatedAt: "2026-05-09T00:00:00.000Z" }],
            changedFiles: [{ path: "file.ts", status: "modified", summary: "changed file should not be returned" }],
            messages: [
              { id: "message-1", kind: "agent_text", createdAt: "2026-05-09T00:00:00.000Z", text: "older message should not be returned" },
              { id: "message-2", kind: "agent_text", createdAt: "2026-05-09T00:00:01.000Z", text: `Last message ${index + 1}` },
            ],
          } satisfies PickyAgentSession));
        },
      },
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: {
        type: "function_call",
        name: "picky_side_sessions",
        call_id: "call-side-sessions",
        arguments: JSON.stringify({ includeTerminal: false, page: 1, limit: 2 }),
      },
    });
    await settle();

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const output = sent.find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output")!;
    const payload = JSON.parse(output.item.output);

    expect(listCalls).toBe(1);
    expect(payload.sessions).toEqual([
      { id: "side-1", title: "Side 1", cwd: "/tmp/project", lastMessage: "Last message 1" },
      { id: "side-3", title: "Side 3", cwd: "/tmp/project", lastMessage: "Last message 3" },
    ]);
    expect(payload.total).toBe(3);
    expect(payload.hasMore).toBe(true);
    expect(payload).not.toHaveProperty("instruction");
    expect(output.item.output).not.toContain("very long raw log");
    expect(output.item.output).not.toContain("tool preview should not be returned");
    expect(output.item.output).not.toContain("artifact should not be returned");
    expect(output.item.output).not.toContain("changed file should not be returned");
    expect(output.item.output).not.toContain("older message should not be returned");
  });

  it("executes each realtime function call only once when GA emits multiple done events", async () => {
    const socket = new FakeRealtimeSocket();
    let listCalls = 0;
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listSideSessions() {
          listCalls += 1;
          return [];
        },
      },
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({ type: "response.function_call_arguments.done", call_id: "call-dup", name: "picky_side_sessions", arguments: "{}" });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_side_sessions", call_id: "call-dup", arguments: "{}" } });
    await settle();

    const outputEvents = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    expect(listCalls).toBe(1);
    expect(outputEvents).toHaveLength(1);
  });

  it("keeps a tool-call response open and resets transcript accumulation for the final reply", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
    });
    const handle = await runtime.prewarm({ sessionId: "picky-main-agent" });
    const events: Array<any> = [];
    handle.subscribe((event) => events.push(event));

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({ type: "response.output_audio_transcript.delta", delta: "조회 중" });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_side_sessions", call_id: "call-tool", arguments: "{}" } });
    socket.serverEvent({ type: "response.done", response: { status: "completed", output: [{ type: "function_call", call_id: "call-tool" }] } });
    socket.serverEvent({ type: "response.output_audio_transcript.delta", delta: "완료" });
    socket.serverEvent({ type: "response.done", response: { status: "completed", output: [{ type: "message" }] } });
    await settle();

    const doneEvents = events.filter((event) => event.type === "main_realtime_turn_done");
    expect(doneEvents).toHaveLength(1);
    expect(doneEvents[0]).toMatchObject({ inputId: "input-1", finalTranscript: "완료" });
  });

  it("uses GA assistant output_text content for bootstrap messages", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const assistantBootstrap = sent.find((event) =>
      event.type === "conversation.item.create" && event.item?.role === "assistant"
    )!;

    expect(assistantBootstrap.item.content[0].type).toBe("output_text");
  });
});

describe("OpenAIRealtimeMainRuntime Azure preview protocol", () => {
  it("uses preview session and response fields without GA-only session.type", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "azure_openai",
        apiKey: "azure-key",
        modelOrDeployment: "gpt-realtime-1.5",
        voice: "marin",
        azure: {
          resourceEndpoint: "https://x.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5",
          apiShape: "preview",
          apiVersion: "2024-10-01-preview",
        },
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await runtime.commitMainRealtimeVoiceTurn("input-1");

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const sessionUpdate = sent.find((event) => event.type === "session.update")!;
    const responseCreate = sent.find((event) => event.type === "response.create")!;

    expect(sessionUpdate.session).not.toHaveProperty("type");
    expect(sessionUpdate.session).not.toHaveProperty("output_modalities");
    expect(sessionUpdate.session).not.toHaveProperty("audio");
    expect(sessionUpdate.session.modalities).toEqual(["text", "audio"]);
    expect(sessionUpdate.session.voice).toBe("verse");
    expect(responseCreate.response).toEqual({ modalities: ["text", "audio"] });
  });

  it("does not send response.cancel when cancelling before a response exists", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "azure_openai",
        apiKey: "azure-key",
        modelOrDeployment: "gpt-realtime-1.5",
        voice: "verse",
        azure: {
          resourceEndpoint: "https://x.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5",
          apiShape: "preview",
          apiVersion: "2024-10-01-preview",
        },
      },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await runtime.cancelMainRealtimeVoiceTurn("input-1");

    const sentTypes = socket.sent.map((raw) => JSON.parse(raw).type);
    expect(sentTypes).not.toContain("response.cancel");
    expect(sentTypes).toContain("input_audio_buffer.clear");
  });
});

describe("SelectableMainRuntime", () => {
  it("keeps Pi runtime as the default main path and rejects realtime-only voice commands", async () => {
    const pi = new RecordingRuntime("pi");
    const realtime = new RecordingRealtimeRuntime("realtime");
    const runtime = new SelectableMainRuntime({ initialMode: "pi", piRuntime: pi, realtimeRuntime: realtime });

    await runtime.create({ text: "hello", imagePaths: [] }, { sessionId: "main" });

    expect(pi.calls).toEqual(["pi.create"]);
    expect(realtime.calls).toEqual([]);
    await expect(runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() })).rejects.toThrow(/not selected/);
  });

  it("routes main prompts and voice commands to realtime only after explicit mode switch", async () => {
    const pi = new RecordingRuntime("pi");
    const realtime = new RecordingRealtimeRuntime("realtime");
    const runtime = new SelectableMainRuntime({ initialMode: "pi", piRuntime: pi, realtimeRuntime: realtime });

    expect(runtime.setMainAgentRuntimeMode("openai-realtime")).toBe(true);
    runtime.configureMainRealtimeAuth({ provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-1.5", voice: "marin" });
    await runtime.create({ text: "hello", imagePaths: [] }, { sessionId: "main" });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await runtime.appendMainRealtimeInputAudio("input-1", "AAAA");
    await runtime.commitMainRealtimeVoiceTurn("input-1");

    expect(pi.calls).toEqual([]);
    expect(realtime.calls).toEqual([
      "realtime.configure",
      "realtime.create",
      "realtime.beginVoice",
      "realtime.appendAudio",
      "realtime.commitVoice",
    ]);
  });
});

class FakeRealtimeSocket implements RealtimeWebSocketLike {
  readyState = 1;
  sent: string[] = [];
  private listeners = new Map<string, Array<(...args: any[]) => void>>();

  constructor() {
    queueMicrotask(() => this.emit("open"));
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    this.readyState = 3;
    this.emit("close", 1000, Buffer.from(""));
  }

  serverEvent(event: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(event)));
  }

  on(event: "open" | "message" | "close" | "error", listener: (...args: any[]) => void): this {
    const listeners = this.listeners.get(event) ?? [];
    listeners.push(listener);
    this.listeners.set(event, listeners);
    if (event === "open" && this.readyState === 1) queueMicrotask(listener);
    return this;
  }

  private emit(event: string, ...args: any[]): void {
    for (const listener of this.listeners.get(event) ?? []) listener(...args);
  }
}

function fakeToolHandlers() {
  const session: PickyAgentSession = {
    id: "side",
    title: "Side",
    status: "completed",
    cwd: "/tmp",
    createdAt: "2026-05-09T00:00:00.000Z",
    updatedAt: "2026-05-09T00:00:00.000Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
  };
  return {
    async handoff() { return { sessionId: "side", title: "Side" }; },
    listSideSessions() { return []; },
    async steerSideSession() { return session; },
    async searchSkills() { return { query: "", root: "/tmp/skills", total: 1, skills: [{ name: "debug", description: "Debug", path: "/tmp/skills/debug/SKILL.md" }] }; },
    async getSkillDetails() { return { name: "debug", description: "Debug", path: "/tmp/skills/debug/SKILL.md", frontmatter: { name: "debug" }, content: "---\nname: debug\n---\n" }; },
  };
}

class RecordingRuntime implements AgentRuntime {
  calls: string[] = [];
  constructor(private readonly label: string) {}
  async create(_prompt: BuiltPrompt, _options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.calls.push(`${this.label}.create`);
    return handle(`${this.label}-handle`);
  }
  setThinkingLevel(_level: ThinkingLevel): void {
    this.calls.push(`${this.label}.thinking`);
  }
}

class RecordingRealtimeRuntime extends RecordingRuntime implements MainRealtimeRuntime {
  configureMainRealtimeAuth(_config: OpenAIRealtimeAuthConfig): void {
    this.calls.push("realtime.configure");
  }
  async beginMainRealtimeVoiceTurn(_turn: { inputId: string; context: PickyContextPacket }): Promise<void> {
    this.calls.push("realtime.beginVoice");
  }
  async appendMainRealtimeInputAudio(_inputId: string, _audioBase64: string): Promise<void> {
    this.calls.push("realtime.appendAudio");
  }
  async commitMainRealtimeVoiceTurn(_inputId: string): Promise<void> {
    this.calls.push("realtime.commitVoice");
  }
  async cancelMainRealtimeVoiceTurn(_inputId?: string, _playedAudioMs?: number): Promise<void> {
    this.calls.push("realtime.cancelVoice");
  }
}

function handle(id: string): RuntimeSessionHandle {
  return {
    id,
    async followUp() {},
    async steer() { return { handledSynchronously: false }; },
    async abort() {},
    clearQueue: () => ({ steering: [], followUp: [] }),
    getSteeringMessages: () => [],
    getFollowUpMessages: () => [],
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    isStreaming: false,
    subscribe: () => () => {},
  };
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setImmediate(resolve));
}

function context(overrides: Partial<PickyContextPacket> = {}): PickyContextPacket {
  return {
    id: "context-realtime",
    source: "voice",
    capturedAt: "2026-05-09T00:00:00.000Z",
    transcript: undefined,
    screenshots: [],
    inkMarks: [],
    warnings: [],
    ...overrides,
  };
}
