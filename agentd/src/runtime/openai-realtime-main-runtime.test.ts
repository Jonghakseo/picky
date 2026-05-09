import { describe, expect, it } from "vitest";
import { buildRealtimeConnection, normalizeAzureRealtimeHost } from "./openai-realtime-main-runtime.js";
import { SelectableMainRuntime } from "./selectable-main-runtime.js";
import type { AgentRuntime, MainRealtimeRuntime, RuntimeSessionHandle, ThinkingLevel } from "./types.js";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { OpenAIRealtimeAuthConfig, PickyContextPacket } from "../protocol.js";

describe("OpenAI Realtime provider connection builders", () => {
  it("builds OpenAI public websocket URL and bearer auth", () => {
    const connection = buildRealtimeConnection({
      provider: "openai",
      apiKey: "sk-test",
      modelOrDeployment: "gpt-realtime-2",
      voice: "marin",
    });

    expect(connection.url).toBe("wss://api.openai.com/v1/realtime?model=gpt-realtime-2");
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

  it("normalizes Azure endpoint hosts and rejects paths", () => {
    expect(normalizeAzureRealtimeHost("https://x.openai.azure.com")).toBe("x.openai.azure.com");
    expect(normalizeAzureRealtimeHost("x.openai.azure.com")).toBe("x.openai.azure.com");
    expect(() => normalizeAzureRealtimeHost("https://x.openai.azure.com/openai/deployments/foo")).toThrow(/must not include/);
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
