import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { BrowserMetadataSchema, CommandEnvelopeSchema, EventEnvelopeSchema } from "./protocol.js";

const contractsRoot = join(process.cwd(), "..", "contracts", "protocol");

function contextFixture() {
  return {
    id: "context-fixture",
    source: "text" as const,
    capturedAt: "2026-05-02T00:00:00.000Z",
    transcript: "Pin this completed Pi session",
    screenshots: [],
    inkMarks: [],
    warnings: [],
  };
}

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

  it("parses completed Pickle-session pin commands", () => {
    expect(() =>
      CommandEnvelopeSchema.parse({
        id: "cmd-pin",
        protocolVersion: "2026-05-09",
        type: "pinPickleSession",
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

  it("parses manual empty Pickle-session commands", () => {
    expect(() =>
      CommandEnvelopeSchema.parse({
        id: "cmd-empty-pickle",
        protocolVersion: "2026-05-09",
        type: "createEmptyPickleSession",
        context: {
          id: "context-empty-pickle",
          source: "system",
          capturedAt: "2026-05-05T00:00:00.000Z",
          cwd: "/tmp/project",
          screenshots: [],
          warnings: ["manualPickle=true"],
        },
      }),
    ).not.toThrow();
  });

  it("parses Pickle session commands", () => {
    for (const command of [
      { type: "createEmptyPickleSession", context: { ...contextFixture(), source: "system" as const } },
      { type: "pinPickleSession", context: contextFixture(), title: "Pinned Pi session" },
      { type: "duplicatePickleSession", sessionId: "session-source" },
    ]) {
      expect(() =>
        CommandEnvelopeSchema.parse({
          id: `cmd-pickle-${command.type}`,
          protocolVersion: "2026-05-09",
          ...command,
        }),
      ).not.toThrow();
    }
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

  it("parses message rewind commands and events", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-list-rewind",
      protocolVersion: "2026-05-09",
      type: "listRewindTargets",
      sessionId: "session-001",
    })).toMatchObject({ type: "listRewindTargets", sessionId: "session-001" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-rewind",
      protocolVersion: "2026-05-09",
      type: "rewindSession",
      sessionId: "session-001",
      entryId: "entry-user-2",
    })).toMatchObject({ type: "rewindSession", entryId: "entry-user-2" });

    expect(EventEnvelopeSchema.parse({
      id: "event-rewind-targets",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "rewindTargetsSnapshot",
      sessionId: "session-001",
      requestId: "cmd-list-rewind",
      targets: [{ entryId: "entry-user-1", text: "A", createdAt: "2026-05-09T00:00:00.000Z" }],
    })).toMatchObject({ type: "rewindTargetsSnapshot", targets: [{ entryId: "entry-user-1", text: "A" }] });

    expect(EventEnvelopeSchema.parse({
      id: "event-rewound",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "sessionRewound",
      sessionId: "session-001",
      editorText: "B",
      removedIds: ["msg-user-b", "msg-agent-b"],
    })).toMatchObject({ type: "sessionRewound", editorText: "B", removedIds: ["msg-user-b", "msg-agent-b"] });
  });

  it("parses external push-to-talk control command and events", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-ptt-press",
      protocolVersion: "2026-05-09",
      type: "controlPushToTalkFromExternal",
      action: "press",
    })).toMatchObject({ type: "controlPushToTalkFromExternal", action: "press" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-ptt-complete",
      protocolVersion: "2026-05-09",
      type: "completePushToTalkControlRequest",
      requestId: "ptt-control-1",
    })).toMatchObject({ type: "completePushToTalkControlRequest", requestId: "ptt-control-1" });

    expect(EventEnvelopeSchema.parse({
      id: "event-ptt-request",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "pushToTalkControlRequested",
      requestId: "ptt-control-1",
      action: "release",
    })).toMatchObject({ type: "pushToTalkControlRequested", action: "release" });

    expect(EventEnvelopeSchema.parse({
      id: "event-ptt-ack",
      protocolVersion: "2026-05-09",
      timestamp: "2026-05-09T00:00:00.000Z",
      type: "pushToTalkControlAck",
      commandId: "cmd-ptt-release",
      action: "release",
    })).toMatchObject({ type: "pushToTalkControlAck", action: "release" });
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
          assistantRun: { model: "openai-codex/gpt-5.6", thinkingLevel: "max" },
        },
        seq: 1,
      }),
    ).not.toThrow();
  });

  it("parses extension notify session message events with severity", () => {
    expect(() =>
      EventEnvelopeSchema.parse({
        id: "event-notify-message",
        protocolVersion: "2026-05-09",
        timestamp: "2026-05-05T00:00:00.000Z",
        type: "sessionMessageAppended",
        sessionId: "session-001",
        message: {
          id: "notify-001",
          kind: "system",
          createdAt: "2026-05-05T00:00:00.000Z",
          text: "Pi extension warning",
          notifyType: "warning",
        },
        seq: 2,
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




  it("rejects invalid protocol versions", () => {
    expect(() => CommandEnvelopeSchema.parse({ id: "bad", protocolVersion: "old", type: "listSessions" })).toThrow(/Invalid literal value/);
  });
});
