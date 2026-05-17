import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
        resourceEndpoint: "https://example-openai.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5",
        apiShape: "ga",
      },
    });

    expect(connection.url).toBe("wss://example-openai.openai.azure.com/openai/realtime?api-version=2024-10-01-preview&deployment=gpt-realtime-1.5");
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

    expect(sessionUpdate.session.audio.input.transcription.prompt).toContain("Picky");
    expect(sessionUpdate.session.audio.input.transcription.prompt).toContain("Pickle");
    expect(toolNames).toContain("picky_start_pickle");
    expect(toolNames).toContain("picky_pickle_sessions");
    expect(toolNames).toContain("picky_steer_pickle");
    expect(toolNames).toContain("picky_skills_search");
    expect(toolNames).toContain("picky_skill_details");
    expect(toolNames).toContain("read_picky_user_guide");
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

  it("returns minimal outputs for steer and skill lookup tools", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async steerPickleSession() {
          return {
            id: "pickle-1",
            title: "Pickle 1",
            status: "running",
            cwd: "/tmp/project",
            createdAt: "2026-05-09T00:00:00.000Z",
            updatedAt: "2026-05-09T00:00:01.000Z",
            lastSummary: "summary should not be returned",
            logs: ["log should not be returned"],
            tools: [{ toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "tool should not be returned" }],
            artifacts: [],
            changedFiles: [],
            messages: [{ id: "message-1", kind: "agent_text", createdAt: "2026-05-09T00:00:00.000Z", text: "message should not be returned" }],
          } satisfies PickyAgentSession;
        },
        async searchSkills() {
          return {
            query: "debug",
            root: "/tmp/project",
            roots: ["/tmp/project/.pi"],
            total: 1,
            skills: [{ name: "debug", description: "Debug workflow", path: "/tmp/skills/debug/SKILL.md", match: "matched snippet" }],
          };
        },
        async getSkillDetails() {
          return {
            name: "debug",
            description: "Debug workflow",
            path: "/tmp/skills/debug/SKILL.md",
            match: "matched snippet",
            frontmatter: { name: "debug", description: "Debug workflow" },
            content: "---\nname: debug\n---\n\nUse systematic debugging.",
          };
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
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_steer_pickle", call_id: "call-steer", arguments: JSON.stringify({ sessionId: "pickle-1", message: "continue" }) } });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_skills_search", call_id: "call-search", arguments: JSON.stringify({ query: "debug" }) } });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_skill_details", call_id: "call-details", arguments: JSON.stringify({ name: "debug" }) } });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "read_picky_user_guide", call_id: "call-guide", arguments: JSON.stringify({ section: "3. Global shortcuts", query: "shortcuts" }) } });
    await settle();

    const outputs = Object.fromEntries(socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output")
      .map((event) => [event.item.call_id, JSON.parse(event.item.output)]));

    expect(outputs["call-steer"]).toEqual({ id: "pickle-1", title: "Pickle 1", status: "running", cwd: "/tmp/project" });
    expect(JSON.stringify(outputs["call-steer"])).not.toContain("summary should not be returned");
    expect(outputs["call-search"]).toEqual({ total: 1, skills: [{ name: "debug", description: "Debug workflow", match: "matched snippet" }] });
    expect(JSON.stringify(outputs["call-search"])).not.toContain("/tmp/skills/debug/SKILL.md");
    expect(outputs["call-details"]).toEqual({ name: "debug", description: "Debug workflow", instructions: "---\nname: debug\n---\n\nUse systematic debugging." });
    expect(outputs["call-details"]).not.toHaveProperty("path");
    expect(outputs["call-details"]).not.toHaveProperty("frontmatter");
    expect(outputs["call-details"]).not.toHaveProperty("match");
    expect(outputs["call-guide"]).toEqual({ section: "3. Global shortcuts", query: "shortcuts", content: "## 3. Global shortcuts\n\nShortcut details.", excerpted: true });
  });

  it("returns a minimal Pickle session list with only id, title, cwd, and last message", async () => {
    const socket = new FakeRealtimeSocket();
    let listCalls = 0;
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listPickleSessions() {
          listCalls += 1;
          return Array.from({ length: 6 }, (_, index) => ({
            id: `pickle-${index + 1}`,
            title: `Pickle ${index + 1}`,
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
        name: "picky_pickle_sessions",
        call_id: "call-pickle-sessions",
        arguments: JSON.stringify({ includeTerminal: false, page: 1, limit: 2 }),
      },
    });
    await settle();

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const output = sent.find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output")!;
    const payload = JSON.parse(output.item.output);

    expect(listCalls).toBe(1);
    expect(payload.sessions).toEqual([
      { id: "pickle-1", title: "Pickle 1", cwd: "/tmp/project", lastMessage: "Last message 1" },
      { id: "pickle-3", title: "Pickle 3", cwd: "/tmp/project", lastMessage: "Last message 3" },
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

  it("accepts legacy realtime Pickle tool names from existing transcripts", async () => {
    const socket = new FakeRealtimeSocket();
    let listCalls = 0;
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listPickleSessions() {
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
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_pickle_sessions", call_id: "call-list", arguments: "{}" } });
    await settle();

    expect(listCalls).toBe(1);
  });

  it("executes each realtime function call only once when GA emits multiple done events", async () => {
    const socket = new FakeRealtimeSocket();
    let listCalls = 0;
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listPickleSessions() {
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
    socket.serverEvent({ type: "response.function_call_arguments.done", call_id: "call-dup", name: "picky_pickle_sessions", arguments: "{}" });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_pickle_sessions", call_id: "call-dup", arguments: "{}" } });
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
    const handle = await runtime.prewarm({ sessionId: "picky" });
    const events: Array<any> = [];
    handle.subscribe((event) => events.push(event));

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({ type: "response.output_audio_transcript.delta", delta: "조회 중" });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_pickle_sessions", call_id: "call-tool", arguments: "{}" } });
    socket.serverEvent({ type: "response.done", response: { status: "completed", output: [{ type: "function_call", call_id: "call-tool" }] } });
    socket.serverEvent({ type: "response.output_audio_transcript.delta", delta: "완료" });
    socket.serverEvent({ type: "response.done", response: { status: "completed", output: [{ type: "message" }] } });
    await settle();

    const doneEvents = events.filter((event) => event.type === "main_realtime_turn_done");
    expect(doneEvents).toHaveLength(1);
    expect(doneEvents[0]).toMatchObject({ inputId: "input-1", finalTranscript: "완료" });
  });

  it("ignores cancelled response transcript fragments after a newer realtime turn starts", async () => {
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
    const handle = await runtime.prewarm({ sessionId: "picky" });
    const events: Array<any> = [];
    handle.subscribe((event) => events.push(event));

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({ type: "response.created", response: { id: "response-1" } });
    await runtime.cancelMainRealtimeVoiceTurn("input-1");
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-2", context: context({ id: "context-2" }) });
    socket.serverEvent({ type: "response.created", response: { id: "response-2" } });
    socket.serverEvent({ type: "response.output_audio_transcript.delta", response_id: "response-1", delta: "stale" });
    socket.serverEvent({ type: "response.output_audio_transcript.delta", response_id: "response-2", delta: "fresh" });
    socket.serverEvent({ type: "response.done", response: { id: "response-2", status: "completed", output: [{ type: "message" }] } });
    await settle();

    expect(events.filter((event) => event.type === "main_realtime_output_transcript_delta")).toEqual([
      { type: "main_realtime_output_transcript_delta", inputId: "input-2", delta: "fresh" },
    ]);
    expect(events.filter((event) => event.type === "main_realtime_turn_done").at(-1)).toMatchObject({ inputId: "input-2", finalTranscript: "fresh" });
  });

  it("sends final ink-marked context images before committing realtime audio", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-realtime-image-"));
    const imagePath = join(dir, "annotated.jpg");
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
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
    await runtime.commitMainRealtimeVoiceTurn("input-1", context({
      id: "context-ink",
      screenshots: [{ id: "shot-1", label: "Main", path: imagePath, screenId: "screen1" }],
      inkMarks: [{
        id: "ink-1",
        source: "voice",
        kind: "freehand-highlight",
        screenId: "screen1",
        points: [{ x: 10, y: 20 }, { x: 40, y: 60 }],
        bounds: { x: 10, y: 20, width: 30, height: 40 },
        strokeWidth: 12,
        opacity: 0.75,
      }],
    }));

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const commitIndex = sent.findIndex((event) => event.type === "input_audio_buffer.commit");
    const contextIndex = sent.findIndex((event) =>
      event.type === "conversation.item.create" &&
      event.item?.role === "user" &&
      JSON.stringify(event.item.content).includes("User-marked screen regions")
    );
    const contextItem = sent[contextIndex];

    expect(contextIndex).toBeGreaterThan(-1);
    expect(commitIndex).toBeGreaterThan(contextIndex);
    expect(contextItem.item.content.some((part: Record<string, unknown>) => part.type === "input_image" && String(part.image_url).startsWith("data:image/jpeg;base64,"))).toBe(true);
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
    expect(sessionUpdate.session.input_audio_transcription.prompt).toContain("Picky");
    expect(sessionUpdate.session.input_audio_transcription.prompt).toContain("Pickle");
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
    id: "pickle",
    title: "Pickle",
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
    async handoff() { return { sessionId: "pickle", title: "Pickle" }; },
    listPickleSessions() { return []; },
    async steerPickleSession() { return session; },
    async searchSkills() { return { query: "", root: "/tmp/skills", total: 1, skills: [{ name: "debug", description: "Debug", path: "/tmp/skills/debug/SKILL.md" }] }; },
    async getSkillDetails() { return { name: "debug", description: "Debug", path: "/tmp/skills/debug/SKILL.md", frontmatter: { name: "debug" }, content: "---\nname: debug\n---\n" }; },
    async readUserGuide() { return { section: "3. Global shortcuts", query: "shortcuts", path: "/tmp/docs/user-manual.md", content: "## 3. Global shortcuts\n\nShortcut details.", totalChars: 1200, excerpted: true }; },
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
  async commitMainRealtimeVoiceTurn(_inputId: string, _context?: PickyContextPacket): Promise<void> {
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
