import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { addUsage, buildRealtimeConnection, extractUsageSnapshot, normalizeAzureRealtimeHost, OpenAIRealtimeMainRuntime, parseAzureRealtimeEndpointUrl, toQuotaSnapshot, type RealtimeWebSocketLike } from "./openai-realtime-main-runtime.js";
import type { CodexQuotaSnapshot } from "./codex-oauth.js";
import { SelectableMainRuntime } from "./selectable-main-runtime.js";
import type { AgentRuntime, MainRealtimeRuntime, RuntimeEvent, RuntimeSessionHandle, ThinkingLevel } from "./types.js";
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
  it("clamps Pi max thinking to the highest supported Realtime effort", async () => {
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
    runtime.setThinkingLevel("max");

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-max", context: context() });

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const sessionUpdate = sent.find((event) => event.type === "session.update")!;
    expect(sessionUpdate.session.reasoning.effort).toBe("xhigh");
  });

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
    const startPickleTool = sessionUpdate.session.tools.find((tool: Record<string, unknown>) => tool.name === "picky_start_pickle");
    const runBashTool = sessionUpdate.session.tools.find((tool: Record<string, unknown>) => tool.name === "picky_run_bash");

    expect(sessionUpdate.session.audio.input.transcription.prompt).toContain("Picky");
    expect(sessionUpdate.session.audio.input.transcription.prompt).toContain("Pickle");
    expect(toolNames).toContain("picky_start_pickle");
    expect(startPickleTool?.description).toContain("Ask once before calling");
    expect(toolNames).toContain("picky_pickle_sessions");
    expect(toolNames).toContain("picky_steer_pickle");
    expect(toolNames).toContain("picky_skills");
    expect(toolNames).not.toContain("picky_skill");
    expect(toolNames).not.toContain("picky_skills_search");
    expect(toolNames).not.toContain("picky_skill_details");
    expect(toolNames).toContain("read_picky_user_guide");
    expect(toolNames).toContain("picky_read_file");
    expect(toolNames).toContain("picky_run_bash");
    expect(runBashTool?.description).toContain("small script");
    expect(runBashTool?.description).toContain("pbcopy");
    expect(runBashTool?.description).toContain("osascript");
    expect(runBashTool?.description).toContain("enforced 10s timeout");
    expect(toolNames).toContain("picky_write_file");
    expect(toolNames).not.toContain("picky_pointer_overlay");
    expect(sessionUpdate.session.instructions).toContain("Realtime voice mode overrides");
    expect(sessionUpdate.session.instructions).toContain("novel reusable workflow");
    expect(sessionUpdate.session.instructions).toContain("multi-turn instructions, multiple tool calls, or tool chaining");
    expect(sessionUpdate.session.instructions).toContain("picky_skills");
    expect(sessionUpdate.session.instructions).toContain("do not say you cannot run it just because it automates a local app");
  });

  it("disposes the live websocket on handle abort so a reset starts a fresh realtime conversation", async () => {
    const sockets: FakeRealtimeSocket[] = [];
    let history: Array<{ role: "user" | "assistant"; text: string }> = [
      { role: "user", text: "old topic that must not survive reset" },
    ];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: fakeToolHandlers(),
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => {
        const socket = new FakeRealtimeSocket();
        sockets.push(socket);
        return socket;
      },
    });
    runtime.setMainRealtimeHistoryProvider?.(() => history);

    const handle = await runtime.prewarm!({ sessionId: "picky" });
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    expect(sockets).toHaveLength(1);
    expect(sockets[0].sent.join("\n")).toContain("old topic that must not survive reset");

    await handle.abort();
    expect(sockets[0].readyState).toBe(3);

    history = [];
    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-2", context: context() });
    expect(sockets).toHaveLength(2);
    expect(sockets[1].sent.join("\n")).not.toContain("old topic that must not survive reset");
  });

  it("snapshots Picky skills once at connect and embeds the names in session.update instructions", async () => {
    const socket = new FakeRealtimeSocket();
    let listCalls = 0;
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        listPickySkills() {
          listCalls += 1;
          return [
            { name: "create-picky-skill", description: "Author a new Picky skill", path: "/tmp/skills/create-picky-skill/SKILL.md" },
            { name: "prefer-korean", description: "Reply in Korean for casual chitchat", path: "/tmp/skills/prefer-korean/SKILL.md" },
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

    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const sessionUpdate = sent.find((event) => event.type === "session.update")!;
    expect(listCalls).toBe(1);
    expect(sessionUpdate.session.instructions).toContain("## Picky skills");
    expect(sessionUpdate.session.instructions).toContain("create-picky-skill \u2014 Author a new Picky skill \u2014 path: /tmp/skills/create-picky-skill/SKILL.md");
    expect(sessionUpdate.session.instructions).toContain("prefer-korean \u2014 Reply in Korean for casual chitchat \u2014 path: /tmp/skills/prefer-korean/SKILL.md");
    expect(sessionUpdate.session.instructions).toContain("picky_skills");
  });

  it("falls back to an empty Picky skill section when no skills are authored yet", async () => {
    const socket = new FakeRealtimeSocket();
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: { ...fakeToolHandlers(), listPickySkills: () => [] },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    const sent = socket.sent.map((raw) => JSON.parse(raw) as Record<string, any>);
    const sessionUpdate = sent.find((event) => event.type === "session.update")!;
    expect(sessionUpdate.session.instructions).toContain("No Picky skills authored yet");
  });

  it("returns minimal outputs for steer and skill catalog tools", async () => {
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
        listPickySkills() {
          return [{ name: "debug", description: "Debug workflow", path: "/tmp/skills/debug.md" }];
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
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "picky_skills", call_id: "call-skills", arguments: JSON.stringify({}) } });
    socket.serverEvent({ type: "response.output_item.done", item: { type: "function_call", name: "read_picky_user_guide", call_id: "call-guide", arguments: JSON.stringify({ section: "3. Global shortcuts", query: "shortcuts" }) } });
    await settle();

    const outputs = Object.fromEntries(socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .filter((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output")
      .map((event) => [event.item.call_id, JSON.parse(event.item.output)]));

    // The steer reply is a bare success message — no session metadata.
    // A `status: "completed"` snapshot from the supervisor used to make
    // the realtime voice agent misread a successful steer as a failure,
    // so the response was reduced to a single line shared with the
    // Pi SDK runtime's picky_steer_pickle tool.
    expect(outputs["call-steer"]).toEqual({ message: "Steering sent to Pickle" });
    expect(outputs["call-skills"]).toEqual({ total: 1, skills: [{ name: "debug", description: "Debug workflow", path: "/tmp/skills/debug.md" }] });
    expect(outputs["call-skills"].skills[0]).not.toHaveProperty("instructions");
    expect(outputs["call-skills"].skills[0]).not.toHaveProperty("frontmatter");
    expect(outputs["call-skills"].skills[0]).not.toHaveProperty("match");
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

  it("does not emit `connecting` when the websocket closes without a fresh ensureConnected", async () => {
    // Regression: the previous behaviour emitted `state: connecting` from
    // the ws.close handler so the HUD could show a transient spinner. In
    // practice nothing triggers a reconnect until the user PTTs / submits
    // text, so the cursor was stuck in the processing colour (.loading
    // phase) for the entire idle window between turns. The close path now
    // logs the disconnect but leaves the last broadcast state in place;
    // the next ensureConnected naturally emits connecting -> ready when
    // the user interacts.
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
    const handle = await runtime.prewarm({ sessionId: "picky" });
    const stateEvents: Array<{ state: string; message?: string }> = [];
    handle.subscribe((event) => {
      if (event.type === "main_realtime_state") stateEvents.push({ state: event.state, message: event.message });
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    // The exact last state at this point depends on the connect path
    // (`ready` after bootstrap, then `listening` once beginVoiceTurn runs);
    // what matters is that ws.close does NOT push another state event.
    const beforeClose = stateEvents.length;
    const lastStateBeforeClose = stateEvents.at(-1)!.state;
    sockets[0]!.close();
    await settle();

    expect(stateEvents.length).toBe(beforeClose);
    expect(stateEvents.at(-1)!.state).toBe(lastStateBeforeClose);
  });

  it("still emits `failed` when the websocket fires an error", async () => {
    // Companion to the close-quiet test: a true error (TLS, auth, network)
    // is a different signal from a normal close, and Picky's voice machine
    // needs that signal to clearToIdle and surface the error message.
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
    const handle = await runtime.prewarm({ sessionId: "picky" });
    const stateEvents: Array<{ state: string; message?: string }> = [];
    handle.subscribe((event) => {
      if (event.type === "main_realtime_state") stateEvents.push({ state: event.state, message: event.message });
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    sockets[0]!.serverError(new Error("WS handshake rejected"));
    await settle();

    const failed = stateEvents.find((e) => e.state === "failed");
    expect(failed).toBeTruthy();
    expect(failed!.message).toContain("WS handshake rejected");
  });

  it("does not emit `failed` when the server sends a soft error frame over a healthy websocket", async () => {
    // Regression: a server-side `error` frame (e.g.
    // input_audio_buffer_commit_empty when the user releases PTT before
    // 100ms of audio is captured) used to escalate to state="failed",
    // which forced Picky's voice machine to clearToIdle and reset the
    // in-flight turn. In practice OpenAI keeps honoring the
    // response.create that came with the bad commit, so the response
    // still streams back; the HUD got wedged because the voice machine
    // had already been told the turn failed. The runtime now logs the
    // diagnostic and leaves the last broadcast state alone. Real
    // failures still surface via response.done(status="failed") and
    // ws.on("error"), each of which has its own test.
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
    const stateEvents: Array<{ state: string; message?: string }> = [];
    handle.subscribe((event) => {
      if (event.type === "main_realtime_state") stateEvents.push({ state: event.state, message: event.message });
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    await settle();

    const beforeError = stateEvents.length;
    const lastStateBeforeError = stateEvents.at(-1)!.state;

    socket.serverEvent({
      type: "error",
      error: {
        type: "invalid_request_error",
        code: "input_audio_buffer_commit_empty",
        event_id: "event-fake-1",
        message:
          "Error committing input audio buffer: buffer too small. Expected at least 100ms of audio, but buffer only has 0.00ms of audio.",
      },
    });
    await settle();

    expect(stateEvents.length).toBe(beforeError);
    expect(stateEvents.at(-1)!.state).toBe(lastStateBeforeError);
    expect(stateEvents.some((e) => e.state === "failed")).toBe(false);
  });

  it("sends audio modality by default and switches to text when TTS is disabled", async () => {
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

    runtime.setMainAgentTTSEnabled(false);
    socket.sent.length = 0;
    await handle.followUp({ text: "text-only please", imagePaths: [] });

    const secondCreate = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "response.create");
    expect(secondCreate?.response).toEqual({ output_modalities: ["text"] });
  });

  it("routes response.output_text events to the transcript channel when TTS is disabled", async () => {
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
    runtime.setMainAgentTTSEnabled(false);

    const events: RuntimeEvent[] = [];
    const handle = await runtime.create({ text: "hi", imagePaths: [] }, { sessionId: "picky" });
    handle.subscribe((event) => events.push(event));
    await settle();

    socket.serverEvent({ type: "response.created", response: { id: "response-1" } });
    socket.serverEvent({ type: "response.output_text.delta", response_id: "response-1", delta: "Hello " });
    socket.serverEvent({ type: "response.output_text.delta", response_id: "response-1", delta: "world." });
    socket.serverEvent({ type: "response.output_text.done", response_id: "response-1", text: "Hello world." });
    await settle();

    const deltas = events.filter((event) => event.type === "main_realtime_output_transcript_delta") as Array<{ delta: string }>;
    expect(deltas.map((event) => event.delta)).toEqual(["Hello ", "world."]);

    const done = events.find((event) => event.type === "main_realtime_output_transcript_completed") as { transcript: string } | undefined;
    expect(done?.transcript).toBe("Hello world.");
  });

  it("routes Azure response.text events to the transcript channel when TTS is disabled", async () => {
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
    runtime.setMainAgentTTSEnabled(false);

    const events: RuntimeEvent[] = [];
    const handle = await runtime.create({ text: "hi", imagePaths: [] }, { sessionId: "picky" });
    handle.subscribe((event) => events.push(event));
    await settle();

    socket.serverEvent({ type: "response.created", response: { id: "response-1" } });
    socket.serverEvent({ type: "response.text.delta", response_id: "response-1", delta: "안녕" });
    socket.serverEvent({ type: "response.text.done", response_id: "response-1", text: "안녕" });
    await settle();

    const deltas = events.filter((event) => event.type === "main_realtime_output_transcript_delta") as Array<{ delta: string }>;
    expect(deltas.map((event) => event.delta)).toEqual(["안녕"]);

    const done = events.find((event) => event.type === "main_realtime_output_transcript_completed") as { transcript: string } | undefined;
    expect(done?.transcript).toBe("안녕");
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
    expect(instructions).toContain("Automatically maintain memory when you learn durable, reusable information");
    expect(instructions).toContain("The user does NOT need to say \"remember\"");
    expect(instructions).toContain("If new information conflicts with or meaningfully refines an existing memory");
    expect(instructions).toContain("- User goes by 'Jong'");
    expect(instructions).toContain("- Treat \"이 페이지\"");
    expect(instructions).not.toContain("(id=mem-a)");
    expect(instructions).not.toContain("(id=mem-b)");
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
    const toolsByName = Object.fromEntries(sessionUpdate.session.tools.map((t: any) => [t.name, t]));
    const toolNames = Object.keys(toolsByName);
    expect(toolNames).toContain("picky_remember");
    expect(toolNames).toContain("picky_list_memories");
    expect(toolNames).toContain("picky_update_memory");
    expect(toolNames).toContain("picky_forget");
    expect(toolsByName.picky_remember.description).toContain("explicit wording is NOT required");
    expect(toolsByName.picky_update_memory.description).toContain("Use proactively");
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
    expect(sessionUpdatesAfter.at(-1)!.session.instructions).toContain("- Always answer in Korean");
    expect(sessionUpdatesAfter.at(-1)!.session.instructions).not.toContain("(id=mem-1)");
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

describe("OpenAIRealtimeMainRuntime pickle tools", () => {
  // These tools let the model answer questions about delegated Pickles without
  // spawning another Pickle. The tests pin the contracts that matter to the
  // user-facing behaviour: the tools are declared on the session and the
  // runtime relays them to the right supervisor method.

  it("declares the Pickle tools on session.update.tools", async () => {
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
    expect(toolNames).toContain("picky_inspect_active_pickle");
    expect(toolNames).toContain("picky_abort_pickle");
    expect(toolNames).not.toContain("picky_recall_recent_context");
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

describe("OpenAIRealtimeMainRuntime filesystem / shell tools", () => {
  it("dispatches picky_read_file through the readFile handler and forwards the active cwd", async () => {
    const socket = new FakeRealtimeSocket();
    const calls: Array<{ path: string; offset?: number; limit?: number; cwd?: string; callId: string }> = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async readFile(request) {
          calls.push(request);
          return {
            ok: true,
            path: request.path,
            resolvedPath: "/tmp/project/AGENTS.md",
            content: "line-1\nline-2",
            totalLines: 200,
            totalBytes: 9000,
            offset: request.offset ?? 0,
            limit: request.limit ?? 40,
            truncated: true,
            summary: "Two-line excerpt; full file has 200 lines.",
          };
        },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context({ cwd: "/tmp/project" }) });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_read_file", call_id: "call-read", arguments: JSON.stringify({ path: "AGENTS.md", limit: 40 }) },
    });
    await settle();

    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({ path: "AGENTS.md", offset: undefined, limit: 40, cwd: "/tmp/project", callId: "call-read" });

    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output" && event.item.call_id === "call-read");
    const payload = JSON.parse(fnOutput!.item.output);
    expect(payload.ok).toBe(true);
    expect(payload.content).toBe("line-1\nline-2");
    expect(payload.truncated).toBe(true);
    expect(payload.summary).toContain("200 lines");
  });

  it("dispatches picky_run_bash and echoes the handler's logPath/summary back to the model", async () => {
    const socket = new FakeRealtimeSocket();
    const calls: Array<{ command: string; cwd?: string; callId: string }> = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async runBash(request) {
          calls.push(request);
          return {
            ok: true,
            command: request.command,
            cwd: request.cwd ?? "/tmp",
            exitCode: 0,
            signal: null,
            output: "...tail of output\n",
            totalBytes: 12_000,
            durationMs: 120,
            timedOut: false,
            truncated: true,
            logPath: "/var/log/picky/RealtimeToolOutputs/call-bash.log",
            summary: "npm test passed. 42 tests OK.",
          };
        },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context({ cwd: "/tmp/project" }) });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_run_bash", call_id: "call-bash", arguments: JSON.stringify({ command: "npm test" }) },
    });
    await settle();

    expect(calls).toEqual([{ command: "npm test", cwd: "/tmp/project", callId: "call-bash" }]);

    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output" && event.item.call_id === "call-bash");
    const payload = JSON.parse(fnOutput!.item.output);
    expect(payload).toMatchObject({
      ok: true,
      exitCode: 0,
      truncated: true,
      logPath: "/var/log/picky/RealtimeToolOutputs/call-bash.log",
      summary: "npm test passed. 42 tests OK.",
    });
  });

  it("dispatches picky_write_file with the requested mode and returns a body-free payload", async () => {
    const socket = new FakeRealtimeSocket();
    const calls: Array<{ path: string; content: string; mode?: "overwrite" | "append"; cwd?: string; callId: string }> = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async writeFile(request) {
          calls.push(request);
          return {
            ok: true,
            path: request.path,
            resolvedPath: `/tmp/project/${request.path}`,
            bytesWritten: Buffer.byteLength(request.content, "utf8"),
            mode: request.mode ?? "overwrite",
          };
        },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context({ cwd: "/tmp/project" }) });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_write_file", call_id: "call-write", arguments: JSON.stringify({ path: "notes.md", content: "hello\n", mode: "append" }) },
    });
    await settle();

    expect(calls).toEqual([{ path: "notes.md", content: "hello\n", mode: "append", cwd: "/tmp/project", callId: "call-write" }]);

    const fnOutput = socket.sent
      .map((raw) => JSON.parse(raw) as Record<string, any>)
      .find((event) => event.type === "conversation.item.create" && event.item?.type === "function_call_output" && event.item.call_id === "call-write");
    const payload = JSON.parse(fnOutput!.item.output);
    expect(payload).toEqual({
      ok: true,
      path: "notes.md",
      resolvedPath: "/tmp/project/notes.md",
      bytesWritten: 6,
      mode: "append",
    });
    // The body must never be echoed back to the model.
    expect(JSON.stringify(payload)).not.toContain("hello");
  });

  it("normalizes invalid mode values on picky_write_file to overwrite", async () => {
    const socket = new FakeRealtimeSocket();
    const modes: Array<string | undefined> = [];
    const runtime = new OpenAIRealtimeMainRuntime({
      toolHandlers: {
        ...fakeToolHandlers(),
        async writeFile(request) {
          modes.push(request.mode);
          return { ok: true, path: request.path, resolvedPath: `/tmp/${request.path}`, bytesWritten: 1, mode: request.mode ?? "overwrite" };
        },
      },
      defaultConfig: { provider: "openai", apiKey: "sk-test", modelOrDeployment: "gpt-realtime-2", voice: "marin" },
      webSocketFactory: () => socket,
    });

    await runtime.beginMainRealtimeVoiceTurn({ inputId: "input-1", context: context() });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_write_file", call_id: "call-w1", arguments: JSON.stringify({ path: "a.txt", content: "x", mode: "WHATEVER" }) },
    });
    socket.serverEvent({
      type: "response.output_item.done",
      item: { type: "function_call", name: "picky_write_file", call_id: "call-w2", arguments: JSON.stringify({ path: "b.txt", content: "x" }) },
    });
    await settle();

    expect(modes).toEqual(["overwrite", undefined]);
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

  serverError(error: Error): void {
    this.emit("error", error);
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
    listPickySkills() { return [] as Array<{ name: string; description: string; path: string }>; },
    async readUserGuide() { return { section: "3. Global shortcuts", query: "shortcuts", path: "/tmp/docs/user-manual.md", content: "## 3. Global shortcuts\n\nShortcut details.", totalChars: 1200, excerpted: true }; },
    // Default fakes: no memories, every CRUD succeeds with synthetic data.
    // Tests that actually exercise memory tool behaviour replace these via
    // an inline tool handler block instead of monkey-patching.
    async rememberUserFact({ content }: { content: string }) { return { ok: true as const, memory: { id: "mem-fake", content } }; },
    async updateUserFact({ id, content }: { id: string; content: string }) { return { ok: true as const, memory: { id, content } }; },
    async forgetUserFact({ id }: { id: string }) { return { ok: true as const, removed: { id, content: "" } }; },
    listUserFacts() { return [] as Array<{ id: string; content: string }>; },
    inspectPickleSession() { return session; },
    async abortPickleSession() { return { ...session, status: "cancelled" as const }; },
    async unarchivePickleSession() { return { ...session, archived: false }; },
    // Realtime filesystem / shell tool stubs. Tests that exercise the new
    // dispatch paths override these inline. Defaults are minimal happy-path
    // values so unrelated tests continue to compile and pass.
    async readFile() {
      return { ok: true as const, path: "stub.txt", resolvedPath: "/tmp/stub.txt", content: "", totalLines: 0, totalBytes: 0, offset: 0, limit: 40, truncated: false };
    },
    async runBash() {
      return { ok: true as const, command: "stub", cwd: "/tmp", exitCode: 0, signal: null, output: "", totalBytes: 0, durationMs: 0, timedOut: false, truncated: false };
    },
    async writeFile() {
      return { ok: true as const, path: "stub.txt", resolvedPath: "/tmp/stub.txt", bytesWritten: 0, mode: "overwrite" as const };
    },
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
