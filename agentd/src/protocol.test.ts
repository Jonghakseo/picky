import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { BrowserMetadataSchema, CommandEnvelopeSchema, EventEnvelopeSchema } from "./protocol.js";

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
        protocolVersion: "2026-05-05",
        type: "pinSideSession",
        title: "Pinned Pi session",
        context: {
          id: "context-pin",
          source: "text",
          capturedAt: "2026-05-02T00:00:00.000Z",
          transcript: "Pin this completed Pi session",
          screenshots: [],
          warnings: [],
        },
      }),
    ).not.toThrow();
  });

  it("parses manual empty side-session commands", () => {
    expect(() =>
      CommandEnvelopeSchema.parse({
        id: "cmd-empty-side",
        protocolVersion: "2026-05-05",
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

  it("parses clearQueue commands for every queue kind", () => {
    for (const kind of ["steering", "followUp", "all"] as const) {
      expect(() =>
        CommandEnvelopeSchema.parse({
          id: `cmd-clear-${kind}`,
          protocolVersion: "2026-05-05",
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
        protocolVersion: "2026-05-05",
        timestamp: "2026-05-05T00:00:00.000Z",
        type: "sessionMessageAppended",
        sessionId: "session-001",
        message: {
          id: "message-001",
          kind: "agent_text",
          createdAt: "2026-05-05T00:00:00.000Z",
          originatedBy: "main_agent",
          text: "Done",
        },
        seq: 1,
      }),
    ).not.toThrow();
  });

  it("parses session queue updates with optional mode fields", () => {
    const base = {
      id: "event-queue-updated",
      protocolVersion: "2026-05-05",
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
