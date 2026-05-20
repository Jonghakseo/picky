import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { addUsage, buildRealtimeConnection, extractUsageSnapshot, normalizeAzureRealtimeHost, OpenAIRealtimeMainRuntime, parseAzureRealtimeEndpointUrl, toQuotaSnapshot, type RealtimeWebSocketLike } from "./openai-realtime-main-runtime.js";
import type { CodexQuotaSnapshot } from "./codex-oauth.js";
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

  it("swaps the apiKey bearer for a Codex OAuth bearer plus ChatGPT-Account-ID when an OAuth bundle is provided", () => {
    const connection = buildRealtimeConnection({
      provider: "openai",
      authMode: "codexOAuth",
      apiKey: "",
      modelOrDeployment: "gpt-realtime-2",
      voice: "marin",
    }, {
      accessToken: "oauth-token",
      accountId: "acct_123",
      isFedramp: false,
      source: "pi",
    });

    expect(connection.headers.Authorization).toBe("Bearer oauth-token");
    expect(connection.headers["ChatGPT-Account-ID"]).toBe("acct_123");
    expect(connection.headers.originator).toBe("codex_cli_rs");
    expect(connection.headers.version).toBeDefined();
    expect(connection.headers["OpenAI-Beta"]).toBeUndefined();
  });

  it("rejects Codex OAuth bundles for the Azure provider", () => {
    expect(() => buildRealtimeConnection({
      provider: "azure_openai",
      apiKey: "azure-key",
      modelOrDeployment: "rt-deployment",
      voice: "marin",
      azure: { resourceEndpoint: "https://r.openai.azure.com", apiShape: "ga" },
    }, {
      accessToken: "oauth-token",
      accountId: "acct_123",
      isFedramp: false,
      source: "pi",
    })).toThrow(/only supports the openai provider/);
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

  it("hides archived Pickles by default and returns a minimal session list with only id, title, cwd, and last message", async () => {
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
            // Mark every other Pickle archived so the default filter has work to do.
            archived: index % 2 === 1,
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
        arguments: JSON.stringify({ page: 1, limit: 2 }),
      },
    });
    await settle();

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const output = sent.find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output")!;
    const payload = JSON.parse(output.item.output);

    expect(listCalls).toBe(1);
    // Only odd-indexed Pickles are archived (pickle-2, pickle-4, pickle-6); the
    // remaining three (pickle-1, pickle-3, pickle-5) survive, page 1 limit 2
    // returns the first two.
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

  it("returns archived Pickles when includeArchive is explicitly true", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listPickleSessions() {
          return [
            { id: "p-live", title: "Live", status: "running", cwd: "/x", createdAt: "2026-05-09T00:00:00.000Z", updatedAt: "2026-05-09T00:00:02.000Z", lastSummary: "", logs: [], tools: [], artifacts: [], changedFiles: [] } satisfies PickyAgentSession,
            { id: "p-archived", title: "Archived", status: "completed", archived: true, cwd: "/x", createdAt: "2026-05-09T00:00:00.000Z", updatedAt: "2026-05-09T00:00:01.000Z", lastSummary: "", logs: [], tools: [], artifacts: [], changedFiles: [] } satisfies PickyAgentSession,
          ];
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
        call_id: "call-with-archive",
        arguments: JSON.stringify({ includeArchive: true }),
      },
    });
    await settle();

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const output = sent.find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output")!;
    const payload = JSON.parse(output.item.output);

    expect(payload.sessions.map((s: { id: string }) => s.id)).toEqual(["p-live", "p-archived"]);
    expect(payload.total).toBe(2);
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

  it("accumulates usage from response.done and emits session totals", async () => {
    const socket = new FakeRealtimeSocket();
    const events: any[] = [];
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
    const handle = await runtime.create({ text: "hi", imagePaths: [] }, { sessionId: "picky" });
    handle.subscribe((event) => events.push(event));

    socket.serverEvent({
      type: "response.done",
      response: {
        id: "resp-1",
        status: "completed",
        usage: {
          total_tokens: 120,
          input_tokens: 80,
          output_tokens: 40,
          input_token_details: { cached_tokens: 12, text_tokens: 30, audio_tokens: 50 },
          output_token_details: { text_tokens: 10, audio_tokens: 30 },
        },
      },
    });
    socket.serverEvent({
      type: "response.done",
      response: {
        id: "resp-2",
        status: "completed",
        usage: { total_tokens: 30, input_tokens: 20, output_tokens: 10 },
      },
    });

    const usageEvents = events.filter((e) => e.type === "main_realtime_usage");
    expect(usageEvents).toHaveLength(2);
    expect(usageEvents[0].lastTurn.totalTokens).toBe(120);
    expect(usageEvents[0].lastTurn.cachedInputTokens).toBe(12);
    expect(usageEvents[0].lastTurn.inputAudioTokens).toBe(50);
    expect(usageEvents[0].session.totalTokens).toBe(120);
    expect(usageEvents[1].session.totalTokens).toBe(150);
    expect(usageEvents[1].session.inputTokens).toBe(100);
    expect(usageEvents[1].session.outputTokens).toBe(50);
  });

  it("packs the entire transcript into a single user-role primer to survive Realtime's assistant-replay limitation", async () => {
    // Regression: OpenAI Realtime accepts assistant-role text items via
    // `conversation.item.create` without error, but the model ignores them
    // when generating the next response. Replaying user + assistant in
    // alternation — the obvious approach — surfaced only the user side and
    // left the model with no memory of its own past replies. We work around
    // this by collapsing both sides into ONE user message that explicitly
    // frames the block as context.
    const sockets: FakeRealtimeSocket[] = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => {
        const socket = new FakeRealtimeSocket();
        sockets.push(socket);
        return socket;
      },
    });
    runtime.setMainRealtimeHistoryProvider(() => [
      { role: "user", text: "first question" },
      { role: "assistant", text: "first answer" },
      { role: "user", text: "second question" },
    ]);
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    expect(sockets).toHaveLength(1);
    const items = sockets[0]!.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "conversation.item.create")
      .map((event) => event.item);
    // Bootstrap pair (user persona + assistant "OK") + 1 primer item.
    expect(items.length).toBeGreaterThanOrEqual(3);
    const primer = items[2];
    expect(primer.role).toBe("user");
    expect(primer.content[0].type).toBe("input_text");
    const primerText: string = primer.content[0].text;
    expect(primerText).toContain("[Picky context replay]");
    expect(primerText).toContain("User: first question");
    expect(primerText).toContain("Picky: first answer");
    expect(primerText).toContain("User: second question");
    expect(primerText).toContain("[End of context replay");
    // Crucially: no assistant-role replay item, because the API silently
    // drops those for context purposes.
    const replayItemRoles = items.slice(2).map((i: any) => i.role);
    expect(replayItemRoles).not.toContain("assistant");
  });

  it("notes truncated turns inside the primer when history exceeds the replay limit", async () => {
    const sockets: FakeRealtimeSocket[] = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => {
        const socket = new FakeRealtimeSocket();
        sockets.push(socket);
        return socket;
      },
    });
    // Build 65 messages so 5 must be dropped (limit is 60).
    const history: { role: "user" | "assistant"; text: string }[] = [];
    for (let i = 0; i < 65; i += 1) {
      history.push({ role: i % 2 === 0 ? "user" : "assistant", text: `msg${i}` });
    }
    runtime.setMainRealtimeHistoryProvider(() => history);

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    const items = sockets[0]!.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "conversation.item.create")
      .map((event) => event.item);
    const primer = items[2];
    const primerText: string = primer.content[0].text;
    expect(primerText).toContain("5 earlier turn(s) omitted");
    // Truncated turns are the *oldest*; the most recent 60 stay.
    expect(primerText).not.toContain("msg0\n");
    expect(primerText).toContain("msg64");
  });

  it("reconnects and rebuilds the primer after the websocket closes", async () => {
    const sockets: FakeRealtimeSocket[] = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        apiKey: "sk-test",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => {
        const socket = new FakeRealtimeSocket();
        sockets.push(socket);
        return socket;
      },
    });
    const history: { role: "user" | "assistant"; text: string }[] = [];
    runtime.setMainRealtimeHistoryProvider(() => history);

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    history.push({ role: "user", text: "prior user turn" });
    history.push({ role: "assistant", text: "prior assistant turn" });

    // Simulate the WS server closing the connection (e.g., 60-minute cap).
    sockets[0]!.close();
    await settle();

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-2", context: context() });
    await settle();

    expect(sockets).toHaveLength(2);
    const items = sockets[1]!.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "conversation.item.create")
      .map((event) => event.item);
    // Bootstrap pair + single primer item, no assistant replay item.
    expect(items.slice(0, 3).map((i: any) => i.role)).toEqual(["user", "assistant", "user"]);
    const primerText: string = items[2].content[0].text;
    expect(primerText).toContain("User: prior user turn");
    expect(primerText).toContain("Picky: prior assistant turn");
  });

  it("sends audio modality by default and switches to text when narration is disabled", async () => {
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
    const handle = await runtime.create({ text: "hi", imagePaths: [] }, { sessionId: "picky" });
    await settle();

    const firstCreate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "response.create");
    expect(firstCreate?.response).toEqual({ output_modalities: ["audio"] });

    runtime.setMainAgentNarrationEnabled(false);
    socket.sent.length = 0;
    await handle.followUp({ text: "text-only please", imagePaths: [] });

    const secondCreate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "response.create");
    expect(secondCreate?.response).toEqual({ output_modalities: ["text"] });
  });

  it("omits the TTS parenthesis hint from session.update instructions and the bootstrap user item", async () => {
    // Regression: the Pi pipeline strips `( ... )` before TTS playback, but
    // Realtime synthesises audio directly so any leftover hint makes the
    // model start reading URLs and paths aloud.
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
    expect(sessionUpdate.session.instructions).not.toContain("`( ... )`");
    expect(sessionUpdate.session.instructions).not.toContain("automatically skips parenthesised content");

    const bootstrapUser = sent.find((event) =>
      event.type === "conversation.item.create" && event.item?.role === "user"
    )!;
    const bootstrapText: string = bootstrapUser.item.content[0].text;
    expect(bootstrapText).not.toContain("`( ... )`");
    expect(bootstrapText).not.toContain("automatically skips parenthesised content");
  });

  it("routes text followUp prompts through conversation.item.create + response.create", async () => {
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
    const handle = await runtime.create({ text: "original", imagePaths: [] }, { sessionId: "picky" });
    await settle();
    socket.sent.length = 0;

    // Simulate a text-routed turn (quick input / CLI / Pickle completion all
    // funnel through `handle.followUp` after the initial create).
    await handle.followUp({ text: "pickle finished", imagePaths: [] });

    const events = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const item = events.find((e) => e.type === "conversation.item.create");
    expect(item?.item.role).toBe("user");
    expect(item?.item.content[0]).toEqual({ type: "input_text", text: "pickle finished" });
    expect(events.find((e) => e.type === "response.create")).toBeDefined();
  });

  it("emits a quota event from a stubbed Codex fetcher when using codexOAuth", async () => {
    const socket = new FakeRealtimeSocket();
    const events: any[] = [];
    const snapshot: CodexQuotaSnapshot = {
      planType: "plus",
      primary: { used: 100, limit: 1000, remaining: 900, windowLabel: "5_hours" },
      secondary: { used: 5, limit: 50, remaining: 45, windowLabel: "weekly" },
      raw: {},
      fetchedAt: "2026-05-09T00:00:00.000Z",
    };
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: {
        provider: "openai",
        authMode: "codexOAuth",
        modelOrDeployment: "gpt-realtime-2",
        voice: "marin",
      },
      webSocketFactory: () => socket,
      codexOAuthLoader: async () => ({ accessToken: "token", accountId: "acct", isFedramp: false, source: "pi" }),
      codexQuotaFetcher: async () => snapshot,
    });
    const handle = await runtime.create({ text: "hi", imagePaths: [] }, { sessionId: "picky" });
    handle.subscribe((event) => events.push(event));
    await settle();
    await runtime.refreshCodexQuota();

    const quotaEvents = events.filter((e) => e.type === "main_realtime_quota");
    expect(quotaEvents.length).toBeGreaterThanOrEqual(1);
    const last = quotaEvents[quotaEvents.length - 1];
    expect(last.quota?.planType).toBe("plus");
    expect(last.quota?.primary?.remaining).toBe(900);
    expect(last.quota?.secondary?.windowLabel).toBe("weekly");
  });
});

describe("OpenAI Realtime usage helpers", () => {
  it("extracts a normalized snapshot from response.usage", () => {
    const snapshot = extractUsageSnapshot({
      total_tokens: 50,
      input_tokens: 30,
      output_tokens: 20,
      input_token_details: { cached_tokens: 5, audio_tokens: 15, text_tokens: 10 },
      output_token_details: { audio_tokens: 18, text_tokens: 2 },
    });
    expect(snapshot).toEqual({
      totalTokens: 50,
      inputTokens: 30,
      outputTokens: 20,
      cachedInputTokens: 5,
      inputTextTokens: 10,
      inputAudioTokens: 15,
      outputTextTokens: 2,
      outputAudioTokens: 18,
    });
    expect(extractUsageSnapshot(undefined)).toBeUndefined();
    expect(extractUsageSnapshot({ total_tokens: 0, input_tokens: 0, output_tokens: 0 })).toBeUndefined();
  });

  it("adds two snapshots field-wise", () => {
    const a = extractUsageSnapshot({ total_tokens: 10, input_tokens: 6, output_tokens: 4 })!;
    const b = extractUsageSnapshot({ total_tokens: 7, input_tokens: 3, output_tokens: 4 })!;
    const sum = addUsage(a, b);
    expect(sum.totalTokens).toBe(17);
    expect(sum.inputTokens).toBe(9);
    expect(sum.outputTokens).toBe(8);
  });

  it("converts CodexQuotaSnapshot to MainRealtimeQuotaSnapshot shape", () => {
    const snapshot = toQuotaSnapshot({
      planType: "pro",
      primary: { used: 1, limit: 2, remaining: 1, windowLabel: "hourly" },
      raw: {},
      fetchedAt: "2026-05-09T00:00:00.000Z",
    });
    expect(snapshot?.planType).toBe("pro");
    expect(snapshot?.primary?.windowLabel).toBe("hourly");
    expect(snapshot?.secondary).toBeUndefined();
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

describe("OpenAIRealtimeMainRuntime user memory tools", () => {
  // The memory tools are the only piece of long-term state the Realtime model
  // can manipulate on its own behalf. These tests pin three contracts:
  //   (1) the user memory snapshot ends up inside session.update.instructions
  //       under a stable header so the model can rely on it being visible,
  //   (2) a picky_remember tool call relays its content to the supervisor and
  //       echoes back the assigned id, and
  //   (3) memory mutations push a fresh session.update so the new set lands
  //       in the model's context for the very next turn (no reconnect wait).

  it("embeds the user memory snapshot inside session.update.instructions", async () => {
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
    runtime.setMainRealtimeUserMemoryProvider(() => [
      { id: "mem-a", content: "User goes by 'Jong'" },
      { id: "mem-b", content: "Treat \"이 페이지\" as the OpenAI Realtime docs" },
    ]);
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });

    const sessionUpdate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "session.update")!;
    const instructions: string = sessionUpdate.session.instructions;
    expect(instructions).toContain("## Long-term user memory");
    expect(instructions).toContain("(id=mem-a) User goes by 'Jong'");
    expect(instructions).toContain("(id=mem-b) Treat \"이 페이지\"");
  });

  it("renders a placeholder line when no memories are stored", async () => {
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
    runtime.setMainRealtimeUserMemoryProvider(() => []);
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });

    const sessionUpdate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "session.update")!;
    expect(sessionUpdate.session.instructions).toContain("(No long-term memories stored yet.)");
  });

  it("declares picky_remember / list / update / forget tools in the session.update tools array", async () => {
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
    const sessionUpdate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "session.update")!;
    const toolNames = sessionUpdate.session.tools.map((t: any) => t.name);
    expect(toolNames).toContain("picky_remember");
    expect(toolNames).toContain("picky_list_memories");
    expect(toolNames).toContain("picky_update_memory");
    expect(toolNames).toContain("picky_forget");
  });

  it("routes a picky_remember tool call through rememberUserFact and emits a function_call_output with the assigned id", async () => {
    const socket = new FakeRealtimeSocket();
    const remembered: Array<{ content: string }> = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async rememberUserFact({ content }) {
          remembered.push({ content });
          return { ok: true as const, memory: { id: "mem-xyz", content } };
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
    // Simulate the model finishing a picky_remember function call. The runtime
    // dispatches `runFunctionCall` from `response.output_item.done` when the
    // server delivers the completed function_call item in one shot.
    socket.serverEvent({
      type: "response.output_item.done",
      item: {
        type: "function_call",
        name: "picky_remember",
        call_id: "call-1",
        arguments: JSON.stringify({ content: "User prefers concise replies" }),
      },
    });
    await settle();

    expect(remembered).toEqual([{ content: "User prefers concise replies" }]);
    const functionCallOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    expect(functionCallOutput).toBeTruthy();
    expect(functionCallOutput!.item.output).toContain("mem-xyz");
    expect(functionCallOutput!.item.output).toContain("User prefers concise replies");
  });

  it("resends session.update with the new memory set when refreshUserMemoryInstructions is invoked", async () => {
    const socket = new FakeRealtimeSocket();
    let memories: Array<{ id: string; content: string }> = [];
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
    runtime.setMainRealtimeUserMemoryProvider(() => memories);
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });

    const sessionUpdatesBefore = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "session.update");
    expect(sessionUpdatesBefore.length).toBeGreaterThanOrEqual(1);
    expect(sessionUpdatesBefore.at(-1)!.session.instructions).toContain("(No long-term memories stored yet.)");

    // Simulate a `picky_remember` mutation outside the runtime
    // (the supervisor mutates picky.json, then calls refresh).
    memories = [{ id: "mem-1", content: "Always answer in Korean" }];
    runtime.refreshUserMemoryInstructions();
    await settle();

    const sessionUpdatesAfter = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "session.update");
    expect(sessionUpdatesAfter.length).toBe(sessionUpdatesBefore.length + 1);
    expect(sessionUpdatesAfter.at(-1)!.session.instructions).toContain("(id=mem-1) Always answer in Korean");
  });

  it("packs the most recent N history turns into session.update.instructions as the model's own memory", async () => {
    const socket = new FakeRealtimeSocket();
    const history: { role: "user" | "assistant"; text: string }[] = [];
    // Build a transcript longer than the instructions cap so we exercise the trim.
    for (let i = 0; i < 30; i += 1) {
      history.push({ role: i % 2 === 0 ? "user" : "assistant", text: `turn-${i}` });
    }
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
    runtime.setMainRealtimeHistoryProvider(() => history);

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    const sessionUpdate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "session.update")
      .at(-1)!;
    const instructions: string = sessionUpdate.session.instructions;
    expect(instructions).toContain("## Recent conversation (your own memory)");
    // Oldest 10 entries should be omitted (cap = 20). Newest 20 stay.
    expect(instructions).not.toContain("turn-0\n");
    expect(instructions).not.toContain("turn-9 ");
    expect(instructions).toContain("turn-10");
    expect(instructions).toContain("turn-29");
    // Role labels must let the model identify its own past replies.
    expect(instructions).toContain("User: turn-10");
    expect(instructions).toContain("Picky (you): turn-11");
  });

  it("refreshConversationInstructions resends session.update with the latest recent history snapshot", async () => {
    const socket = new FakeRealtimeSocket();
    let history: { role: "user" | "assistant"; text: string }[] = [];
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
    runtime.setMainRealtimeHistoryProvider(() => history);
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    const updatesBefore = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "session.update");
    expect(updatesBefore.at(-1)!.session.instructions).not.toContain("## Recent conversation");

    // Supervisor would call this right after appending the assistant message of
    // the freshly-completed realtime turn.
    history = [
      { role: "user", text: "내 이름은 서종학이야" },
      { role: "assistant", text: "알겠어. 종학아 안녕." },
    ];
    runtime.refreshConversationInstructions();
    await settle();

    const updatesAfter = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "session.update");
    expect(updatesAfter.length).toBe(updatesBefore.length + 1);
    const refreshed: string = updatesAfter.at(-1)!.session.instructions;
    expect(refreshed).toContain("## Recent conversation (your own memory)");
    expect(refreshed).toContain("User: 내 이름은 서종학이야");
    expect(refreshed).toContain("Picky (you): 알겠어. 종학아 안녕.");
  });
});

describe("OpenAIRealtimeMainRuntime context recall + pickle tools", () => {
  // These three tools share one design goal: let the model answer follow-up
  // questions about *earlier* state without spawning a new Pickle. The tests
  // pin the contracts that matter to the user-facing behaviour: the tools are
  // declared on the session, the runtime relays them to the right supervisor
  // method, and the result shape stays text-only so the conversation token
  // budget stays bounded.

  it("declares the three new tools on session.update.tools", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    const sessionUpdate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "session.update")!;
    const toolNames = sessionUpdate.session.tools.map((t: any) => t.name);
    expect(toolNames).toContain("picky_recall_recent_context");
    expect(toolNames).toContain("picky_inspect_active_pickle");
    expect(toolNames).toContain("picky_abort_pickle");
  });

  it("routes picky_recall_recent_context through recallRecentMainContext and strips screenshot bytes from the result", async () => {
    const socket = new FakeRealtimeSocket();
    let limitReceived: number | undefined;
    const recentPacket: PickyContextPacket = {
      id: "ctx-prev",
      source: "voice",
      capturedAt: "2026-05-19T12:00:00.000Z",
      cwd: "/tmp/picky",
      transcript: "이 페이지 어떻게 봐?",
      activeApp: { name: "Safari" },
      activeWindow: { title: "OpenAI Realtime guide" },
      browser: { url: "https://platform.openai.com/docs/realtime", title: "Realtime API" },
      selectedText: "This is the selected snippet ".repeat(20),
      screenshots: [{ label: "screen-1", path: "/tmp/shot.png", screenId: "display-1", isCursorScreen: true } as PickyContextPacket["screenshots"][number]],
      inkMarks: [],
      warnings: [],
    };
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        recallRecentMainContext({ limit }: { limit?: number }) { limitReceived = limit; return [recentPacket]; },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_recall_recent_context", call_id: "call-recall", arguments: JSON.stringify({ limit: 3 }) },
    });
    await settle();

    expect(limitReceived).toBe(3);
    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    expect(fnOutput).toBeTruthy();
    const output = JSON.parse(fnOutput!.item.output);
    expect(output.count).toBe(1);
    expect(output.contexts).toHaveLength(1);
    const c = output.contexts[0];
    expect(c.id).toBe("ctx-prev");
    expect(c.browser.url).toBe("https://platform.openai.com/docs/realtime");
    expect(c.activeApp).toBe("Safari");
    expect(c.screenshots).toEqual([{ label: "screen-1", screenId: "display-1", isCursorScreen: true }]);
    // Long selectedText gets truncated to the 200-char preview cap.
    expect(c.selectedTextPreview.length).toBeLessThanOrEqual(200);
    // Binary path field must not leak into the tool result.
    expect(JSON.stringify(c.screenshots[0])).not.toContain("/tmp/shot.png");
  });

  it("routes picky_inspect_active_pickle through inspectPickleSession and returns a compact summary", async () => {
    const socket = new FakeRealtimeSocket();
    let inspectedId: string | undefined;
    const targetSession: PickyAgentSession = {
      id: "pickle-target",
      title: "Refactor cursor follow spring",
      status: "running",
      cwd: "/tmp/picky",
      createdAt: "2026-05-19T09:00:00.000Z",
      updatedAt: "2026-05-19T09:05:00.000Z",
      lastSummary: "Inspecting CursorFollowSpring.swift to wire the new\nspeed multiplier.",
      logs: [],
      tools: [
        { toolCallId: "t1", name: "Read", status: "succeeded" },
        { toolCallId: "t2", name: "Read", status: "succeeded" },
        { toolCallId: "t3", name: "Edit", status: "succeeded", preview: "Edited CursorFollowSpring.swift" },
      ],
      artifacts: [],
      changedFiles: [
        { path: "Picky/CursorFollowSpring.swift", status: "modified" },
      ],
      activitySummary: { read: 2, bash: 0, edit: 1, write: 0, thinking: 3, other: 0 },
    };
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        inspectPickleSession({ sessionId }: { sessionId: string }) { inspectedId = sessionId; return targetSession; },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_inspect_active_pickle", call_id: "call-insp", arguments: JSON.stringify({ sessionId: "pickle-target" }) },
    });
    await settle();

    expect(inspectedId).toBe("pickle-target");
    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    expect(fnOutput).toBeTruthy();
    const output = JSON.parse(fnOutput!.item.output);
    expect(output.id).toBe("pickle-target");
    expect(output.status).toBe("running");
    expect(output.recentToolCalls).toHaveLength(3);
    expect(output.recentToolCalls.map((t: any) => t.name)).toEqual(["Read", "Read", "Edit"]);
    expect(output.changedFiles).toEqual([{ path: "Picky/CursorFollowSpring.swift", status: "modified" }]);
    expect(output.activity).toEqual({ read: 2, edit: 1, thinking: 3 });
    // Multi-line summary gets flattened to single-line, truncated at 240.
    expect(output.lastSummary).not.toContain("\n");
  });

  it("returns ok:false when picky_inspect_active_pickle is called with an unknown session id", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        inspectPickleSession() { return undefined; },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_inspect_active_pickle", call_id: "call-miss", arguments: JSON.stringify({ sessionId: "nope" }) },
    });
    await settle();

    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    const output = JSON.parse(fnOutput!.item.output);
    expect(output.ok).toBe(false);
    expect(output.error).toMatch(/no pickle with id/);
    expect(output.error).toMatch(/picky_pickle_sessions/);
  });

  it("declares picky_unarchive_pickle on session.update.tools", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    const sessionUpdate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "session.update")!;
    const toolNames = sessionUpdate.session.tools.map((t: any) => t.name);
    expect(toolNames).toContain("picky_unarchive_pickle");
  });

  it("routes picky_unarchive_pickle through unarchivePickleSession and echoes the post-unarchive status", async () => {
    const socket = new FakeRealtimeSocket();
    let unarchivedId: string | undefined;
    const restored: PickyAgentSession = {
      id: "pickle-archived",
      title: "Last week's refactor",
      // Session was completed before being archived; unarchive does NOT
      // flip status back to running. The tool result keeps `completed` so
      // the model can nudge the user toward picky_start_pickle if they want
      // to continue rather than picky_steer_pickle (which would fail on a
      // terminal session).
      status: "completed",
      cwd: "/tmp/picky",
      createdAt: "2026-05-12T09:00:00.000Z",
      updatedAt: "2026-05-12T10:00:00.000Z",
      archived: false,
      logs: [],
      tools: [],
      artifacts: [],
      changedFiles: [],
    };
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async unarchivePickleSession({ sessionId }: { sessionId: string }) { unarchivedId = sessionId; return restored; },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_unarchive_pickle", call_id: "call-unarc", arguments: JSON.stringify({ sessionId: "pickle-archived" }) },
    });
    await settle();

    expect(unarchivedId).toBe("pickle-archived");
    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    const output = JSON.parse(fnOutput!.item.output);
    expect(output.id).toBe("pickle-archived");
    expect(output.status).toBe("completed");
    expect(output.archived).toBe(false);
  });

  it("routes picky_abort_pickle through abortPickleSession and echoes the new status", async () => {
    const socket = new FakeRealtimeSocket();
    let abortedId: string | undefined;
    const targetSession: PickyAgentSession = {
      id: "pickle-target",
      title: "Big refactor",
      status: "cancelled",
      cwd: "/tmp/picky",
      createdAt: "2026-05-19T09:00:00.000Z",
      updatedAt: "2026-05-19T09:05:00.000Z",
      logs: [],
      tools: [],
      artifacts: [],
      changedFiles: [],
    };
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async abortPickleSession({ sessionId }: { sessionId: string }) { abortedId = sessionId; return targetSession; },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_abort_pickle", call_id: "call-abort", arguments: JSON.stringify({ sessionId: "pickle-target" }) },
    });
    await settle();

    expect(abortedId).toBe("pickle-target");
    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output");
    const output = JSON.parse(fnOutput!.item.output);
    expect(output.id).toBe("pickle-target");
    expect(output.status).toBe("cancelled");
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
    // Default fakes: no memories, every CRUD succeeds with synthetic data.
    // Tests that actually exercise memory tool behaviour replace these via
    // an inline tool handler block instead of monkey-patching.
    async rememberUserFact({ content }: { content: string }) { return { ok: true as const, memory: { id: "mem-fake", content } }; },
    async updateUserFact({ id, content }: { id: string; content: string }) { return { ok: true as const, memory: { id, content } }; },
    async forgetUserFact({ id }: { id: string }) { return { ok: true as const, removed: { id, content: "" } }; },
    listUserFacts() { return [] as Array<{ id: string; content: string }>; },
    recallRecentMainContext() { return [] as PickyContextPacket[]; },
    inspectPickleSession() { return session; },
    async abortPickleSession() { return { ...session, status: "cancelled" as const }; },
    async unarchivePickleSession() { return { ...session, archived: false }; },
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
