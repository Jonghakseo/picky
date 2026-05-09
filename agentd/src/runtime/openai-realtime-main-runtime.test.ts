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
    async showPointer() { return { request: {} }; },
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

function context(): PickyContextPacket {
  return {
    id: "context-realtime",
    source: "voice",
    capturedAt: "2026-05-09T00:00:00.000Z",
    transcript: undefined,
    screenshots: [],
    inkMarks: [],
    warnings: [],
  };
}
