import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { BrowserMetadataSchema, CommandEnvelopeSchema, EventEnvelopeSchema, OpenAIRealtimeAuthConfigSchema } from "./protocol.js";

const contractsRoot = join(process.cwd(), "..", "contracts", "protocol");

describe("protocol contract fixtures", () => {
  for (const name of readdirSync(contractsRoot).filter((file) => file.endsWith(".request.json"))) {
    it(`parses command fixture ${name}`, () => {
      const fixture = JSON.parse(readFileSync(join(contractsRoot, name), "utf8"));
      expect(() => CommandEnvelopeSchema.parse(fixture)).not.toThrow();
    });
  }

  for (const name of readdirSync(contractsRoot).filter((file) => file.endsWith(".event.json"))) {
    it(`parses event fixture ${name}`, () => {
      const fixture = JSON.parse(readFileSync(join(contractsRoot, name), "utf8"));
      expect(() => EventEnvelopeSchema.parse(fixture)).not.toThrow();
    });
  }

  it("preserves optional browser selected text metadata", () => {
    expect(BrowserMetadataSchema.parse({ url: "https://example.com", title: "Example", selectedText: "highlight" })).toEqual({
      url: "https://example.com",
      title: "Example",
      selectedText: "highlight",
    });
  });

  it("parses completed side-session pin commands", () => {
    expect(() =>
      CommandEnvelopeSchema.parse({
        id: "cmd-pin",
        protocolVersion: "2026-05-09",
        type: "pinSideSession",
        title: "Pinned Pi session",
        context: {
          id: "context-pin",
          source: "text",
          capturedAt: "2026-05-02T00:00:00.000Z",
          transcript: "Pin this completed Pi session",
          screenshots: [],
          inkMarks: [],
  warnings: [],
        },
      }),
    ).not.toThrow();
  });

  it("parses manual empty side-session commands", () => {
    expect(() =>
      CommandEnvelopeSchema.parse({
        id: "cmd-empty-side",
        protocolVersion: "2026-05-09",
        type: "createEmptySideSession",
        context: {
          id: "context-empty-side",
          source: "system",
          capturedAt: "2026-05-05T00:00:00.000Z",
          cwd: "/tmp/project",
          screenshots: [],
          warnings: ["manualSideAgent=true"],
        },
      }),
    ).not.toThrow();
  });

  it("parses steer commands with optional captured context", () => {
    const parsed = CommandEnvelopeSchema.parse({
      id: "cmd-steer-context",
      protocolVersion: "2026-05-09",
      type: "steer",
      sessionId: "session-001",
      text: "look at this screenshot",
      context: {
        id: "context-steer",
        source: "text-follow-up",
        capturedAt: "2026-05-05T00:00:00.000Z",
        transcript: "look at this screenshot",
        screenshots: [{ id: "shot-1", label: "Main", path: "/tmp/shot.png" }],
        inkMarks: [],
  warnings: [],
      },
    });

    expect(parsed.type).toBe("steer");
    if (parsed.type === "steer") expect(parsed.context?.screenshots[0]?.path).toBe("/tmp/shot.png");
  });

  it("parses realtime commit commands with optional final ink context", () => {
    const parsed = CommandEnvelopeSchema.parse({
      id: "cmd-realtime-commit-context",
      protocolVersion: "2026-05-09",
      type: "commitMainRealtimeVoiceTurn",
      inputId: "input-1",
      context: {
        id: "context-realtime-ink",
        source: "voice",
        capturedAt: "2026-05-09T00:00:00.000Z",
        screenshots: [{ id: "shot-1", label: "Main", path: "/tmp/annotated.jpg" }],
        inkMarks: [{
          id: "ink-1",
          source: "voice",
          kind: "freehand-highlight",
          screenId: "screen1",
          points: [{ x: 10, y: 20 }, { x: 30, y: 40 }],
          bounds: { x: 10, y: 20, width: 20, height: 20 },
          strokeWidth: 12,
          opacity: 0.75,
        }],
        warnings: [],
      },
    });

    expect(parsed.type).toBe("commitMainRealtimeVoiceTurn");
    if (parsed.type === "commitMainRealtimeVoiceTurn") expect(parsed.context?.inkMarks).toHaveLength(1);
  });

  it("parses clearQueue commands for every queue kind", () => {
    for (const kind of ["steering", "followUp", "all"] as const) {
      expect(() =>
        CommandEnvelopeSchema.parse({
          id: `cmd-clear-${kind}`,
          protocolVersion: "2026-05-09",
          type: "clearQueue",
          sessionId: "session-001",
          kind,
        }),
      ).not.toThrow();
    }
  });

  it("parses session message events with full message payloads", () => {
    expect(() =>
      EventEnvelopeSchema.parse({
        id: "event-message-appended",
        protocolVersion: "2026-05-09",
        timestamp: "2026-05-05T00:00:00.000Z",
        type: "sessionMessageAppended",
        sessionId: "session-001",
        message: {
          id: "message-001",
          kind: "agent_text",
          createdAt: "2026-05-05T00:00:00.000Z",
          originatedBy: "main_agent",
          text: "Done",
          assistantRun: { model: "anthropic/claude-opus-4-7", thinkingLevel: "xhigh" },
        },
        seq: 1,
      }),
    ).not.toThrow();
  });

  it("parses agent activity session message events", () => {
    expect(() =>
      EventEnvelopeSchema.parse({
        id: "event-activity-message",
        protocolVersion: "2026-05-09",
        timestamp: "2026-05-05T00:00:00.000Z",
        type: "sessionMessageAppended",
        sessionId: "session-001",
        message: {
          id: "message-activity-001",
          kind: "agent_activity",
          createdAt: "2026-05-05T00:00:00.000Z",
          activitySnapshot: { edit: 1, bash: 2, thinking: 3, other: 4 },
        },
        seq: 2,
      }),
    ).not.toThrow();
  });

  it("parses session queue updates with optional mode fields", () => {
    const base = {
      id: "event-queue-updated",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-05T00:00:00.000Z",
      type: "sessionQueueUpdated",
      sessionId: "session-001",
      steering: [{ text: "steer", enqueuedAt: "2026-05-05T00:00:00.000Z" }],
      followUp: [{ text: "follow", enqueuedAt: "2026-05-05T00:00:00.000Z" }],
      seq: 2,
    };

    expect(() => EventEnvelopeSchema.parse(base)).not.toThrow();
    expect(() => EventEnvelopeSchema.parse({ ...base, steeringMode: "one-at-a-time", followUpMode: "all" })).not.toThrow();
  });

  it("parses realtime runtime mode and auth commands", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-runtime-mode",
      protocolVersion: "2026-05-09",
      type: "setMainAgentRuntimeMode",
      mode: "openai-realtime",
    })).toMatchObject({ type: "setMainAgentRuntimeMode", mode: "openai-realtime" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-realtime-auth",
      protocolVersion: "2026-05-09",
      type: "configureMainRealtimeAuth",
      provider: "openai",
      apiKey: "sk-test",
      modelOrDeployment: "gpt-realtime-1.5",
      voice: "marin",
      reasoningEffort: "medium",
    })).toMatchObject({ type: "configureMainRealtimeAuth", modelOrDeployment: "gpt-realtime-1.5" });
  });

  it("validates Azure OpenAI realtime auth config shape", () => {
    expect(OpenAIRealtimeAuthConfigSchema.parse({
      provider: "azure_openai",
      apiKey: "azure-key",
      modelOrDeployment: "deployment",
      voice: "marin",
      azure: { resourceEndpoint: "https://x.openai.azure.com", apiShape: "ga" },
    })).toMatchObject({ provider: "azure_openai" });

    expect(() => OpenAIRealtimeAuthConfigSchema.parse({
      provider: "azure_openai",
      apiKey: "azure-key",
      modelOrDeployment: "deployment",
      voice: "marin",
    })).toThrow(/Azure OpenAI realtime config is required/);
  });

  it("parses realtime voice and output events", () => {
    expect(EventEnvelopeSchema.parse({
      id: "event-realtime-state",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "mainRealtimeStateChanged",
      state: "speaking",
    })).toMatchObject({ type: "mainRealtimeStateChanged", state: "speaking" });

    expect(EventEnvelopeSchema.parse({
      id: "event-realtime-audio",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "mainRealtimeOutputAudioDelta",
      inputId: "input-1",
      audioBase64: "AAAA",
    })).toMatchObject({ type: "mainRealtimeOutputAudioDelta", audioBase64: "AAAA" });

    expect(EventEnvelopeSchema.parse({
      id: "event-realtime-done",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "mainRealtimeTurnDone",
      inputId: "input-1",
      status: "completed",
      finalTranscript: "완료",
    })).toMatchObject({ type: "mainRealtimeTurnDone", finalTranscript: "완료" });
  });

  it("rejects invalid protocol versions", () => {
    expect(() => CommandEnvelopeSchema.parse({ id: "bad", protocolVersion: "old", type: "listSessions" })).toThrow(/Invalid literal value/);
  });
});
