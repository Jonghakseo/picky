import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { BrowserMetadataSchema, CommandEnvelopeSchema, EventEnvelopeSchema, EventEnvelopeVariantSchema, PickyAgentSessionSchema, PickySessionMetaPatchSchema, PickySessionProjectionMutationSchema, PickySessionProjectionMutationVariantSchema, PROTOCOL_VERSION } from "./protocol.js";
import { mutationNames, persistedSessionFieldOwnership } from "./domain/session-projection-ownership.js";

const contractsRoot = join(process.cwd(), "..", "contracts", "protocol");

type Fixture = Record<string, unknown>;

function eventVariantSchema(fixture: Fixture) {
  const schema = EventEnvelopeVariantSchema.options.find((option) => option.shape.type.value === fixture.type);
  if (!schema) throw new Error(`No event schema for fixture type ${String(fixture.type)}`);
  return schema;
}

function unwrapSchema(schema: z.ZodTypeAny): z.ZodTypeAny {
  while (true) {
    if (
      schema instanceof z.ZodOptional
      || schema instanceof z.ZodNullable
      || schema instanceof z.ZodDefault
    ) {
      schema = schema._def.innerType;
      continue;
    }
    if (schema instanceof z.ZodEffects) {
      schema = schema._def.schema;
      continue;
    }
    return schema;
  }
}

function unknownFixtureKeys(schema: z.ZodTypeAny, fixture: unknown, path = ""): string[] {
  schema = unwrapSchema(schema);

  if (schema instanceof z.ZodRecord) return [];

  if (schema instanceof z.ZodArray) {
    if (!Array.isArray(fixture)) return [];
    return fixture.flatMap((item, index) => unknownFixtureKeys(schema.element, item, `${path}[${index}]`));
  }

  if (!(schema instanceof z.ZodObject) || !fixture || typeof fixture !== "object" || Array.isArray(fixture)) return [];

  return Object.entries(fixture).flatMap(([key, value]) => {
    const keyPath = path ? `${path}.${key}` : key;
    const childSchema = schema.shape[key];
    return childSchema ? unknownFixtureKeys(childSchema, value, keyPath) : [keyPath];
  });
}

function pointerOverlayEvent(extraRequestFields: Record<string, unknown> = {}) {
  return {
    id: "event-pointer-legacy",
    protocolVersion: PROTOCOL_VERSION,
    timestamp: "2026-07-19T00:00:00.000Z",
    type: "pointerOverlayRequested",
    request: {
      id: "pointer-legacy",
      x: 640,
      y: 360,
      screenBounds: { x: 0, y: 0, width: 1728, height: 1117 },
      screenshotSize: { width: 1280, height: 827 },
      ...extraRequestFields,
    },
  };
}

function annotationOverlayEvent(annotation: Record<string, unknown>) {
  return {
    id: "event-annotation-legacy",
    protocolVersion: PROTOCOL_VERSION,
    timestamp: "2026-07-19T00:00:00.000Z",
    type: "annotationOverlayRequested",
    request: {
      id: "annotation-legacy",
      mode: "replace",
      annotations: [annotation],
    },
  };
}

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

  it("keeps the hello fixture protocol and supported versions current", () => {
    const fixture = JSON.parse(readFileSync(join(contractsRoot, "hello.event.json"), "utf8"));
    expect(fixture.protocolVersion).toBe(PROTOCOL_VERSION);
    expect(fixture.supportedProtocolVersions).toEqual([PROTOCOL_VERSION]);
  });

  it("parses main activity and extension UI protocol variants", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-main-ui-answer",
      protocolVersion: PROTOCOL_VERSION,
      type: "answerMainExtensionUi",
      requestId: "main-ui-1",
      value: { choice: "continue" },
    })).toMatchObject({ type: "answerMainExtensionUi", requestId: "main-ui-1" });
    expect(EventEnvelopeSchema.parse({
      id: "event-main-activity",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-23T00:00:00.000Z",
      type: "mainActivityUpdated",
      activity: { kind: "tool", toolCallId: "tool-1", toolName: "read", status: "running" },
    })).toMatchObject({ type: "mainActivityUpdated", activity: { toolName: "read" } });
    expect(EventEnvelopeSchema.parse({
      id: "event-main-ui-cancelled",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-23T00:00:00.000Z",
      type: "mainExtensionUiCancelled",
      requestId: "main-ui-1",
    })).toMatchObject({ type: "mainExtensionUiCancelled", requestId: "main-ui-1" });
  });

  it("detects nested unknown keys in event fixtures", () => {    const fixture = {
      id: "event-pointer-overlay",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "pointerOverlayRequested",
      request: {
        id: "pointer-001",
        x: 640,
        y: 360,
        screenBounds: { x: 0, y: 0, width: 1728, height: 1117, staleNestedKey: true },
        screenshotSize: { width: 1280, height: 827 },
      },
    };

    expect(unknownFixtureKeys(eventVariantSchema(fixture), fixture)).toContain("request.screenBounds.staleNestedKey");
  });

  it("matches every event fixture exactly to its schema", () => {
    for (const name of readdirSync(contractsRoot).filter((file) => file.endsWith(".event.json"))) {
      const fixture = JSON.parse(readFileSync(join(contractsRoot, name), "utf8"));
      expect(unknownFixtureKeys(eventVariantSchema(fixture), fixture)).toEqual([]);
    }
  });

  it("pins the mainTurnSettled fixture variant and contextId", () => {
    const fixture = JSON.parse(readFileSync(join(contractsRoot, "main-turn-settled.event.json"), "utf8"));

    expect(EventEnvelopeSchema.parse(fixture)).toMatchObject({
      type: "mainTurnSettled",
      contextId: "context-overlay-only-001",
    });
  });

  it("ignores retired pointer radius fields", () => {
    const current = EventEnvelopeSchema.parse(pointerOverlayEvent());
    const legacy = EventEnvelopeSchema.parse(pointerOverlayEvent({ r: 24 }));

    expect(legacy).toEqual(current);
  });

  it("treats omitted and false annotation spotlight as equivalent visual defaults", () => {
    const omitted = EventEnvelopeSchema.parse(annotationOverlayEvent({
      id: "annotation-spotlight-omitted",
      shape: "rect",
      x: 10,
      y: 20,
      w: 30,
      h: 40,
    }));
    const explicitFalse = EventEnvelopeSchema.parse(annotationOverlayEvent({
      id: "annotation-spotlight-false",
      shape: "rect",
      x: 10,
      y: 20,
      w: 30,
      h: 40,
      spotlight: false,
    }));

    if (omitted.type !== "annotationOverlayRequested" || explicitFalse.type !== "annotationOverlayRequested") {
      throw new Error("Expected annotation overlay requests");
    }
    expect(omitted.request.annotations[0]?.spotlight).toBeUndefined();
    expect(explicitFalse.request.annotations[0]?.spotlight).toBe(false);
    expect(Boolean(omitted.request.annotations[0]?.spotlight)).toBe(Boolean(explicitFalse.request.annotations[0]?.spotlight));
  });

  it("requires exactly one prepared visual variant", () => {
    const fixture = JSON.parse(readFileSync(join(contractsRoot, "main-visual-narration-segment-prepared.event.json"), "utf8"));

    expect(() => EventEnvelopeSchema.parse({ ...fixture, visual: { kind: "point" } })).toThrow();
    expect(() => EventEnvelopeSchema.parse({ ...fixture, visual: { kind: "annotations" } })).toThrow();
  });

  it("accepts an empty committed visual segment without prose", () => {
    const fixture = JSON.parse(readFileSync(join(contractsRoot, "main-visual-narration-segment-committed.event.json"), "utf8"));
    const parsed = EventEnvelopeSchema.parse({ ...fixture, text: undefined, sentenceCount: 0 });

    expect(parsed).toMatchObject({ type: "mainVisualNarrationSegmentCommitted", sentenceCount: 0 });
    if (parsed.type === "mainVisualNarrationSegmentCommitted") expect(parsed.text).toBeUndefined();
  });

  it("ignores retired annotation ttlMs fields", () => {
    const annotation = { id: "annotation-ttl", shape: "rect", x: 10, y: 20, w: 30, h: 40 } as const;
    const current = EventEnvelopeSchema.parse(annotationOverlayEvent(annotation));
    const legacy = EventEnvelopeSchema.parse(annotationOverlayEvent({ ...annotation, ttlMs: 5_000 }));

    expect(legacy).toEqual(current);
  });

  it("accepts structured PATH commands and rejects PATH spotlight", () => {
    const annotation = {
      id: "annotation-path",
      shape: "path",
      commands: [
        { type: "move", x: 10, y: 20 },
        { type: "cubic", c1x: 30, c1y: 40, c2x: 50, c2y: 60, x: 70, y: 80 },
      ],
    } as const;

    expect(EventEnvelopeSchema.parse(annotationOverlayEvent(annotation))).toMatchObject({
      type: "annotationOverlayRequested",
      request: { annotations: [annotation] },
    });
    expect(() => EventEnvelopeSchema.parse(annotationOverlayEvent({ ...annotation, spotlight: true }))).toThrow("path does not support spotlight");
  });

  it("rejects retired annotation circle and target shapes", () => {
    for (const shape of ["circle", "target"]) {
      expect(() => EventEnvelopeSchema.parse(annotationOverlayEvent({ id: `annotation-${shape}`, shape }))).toThrow();
    }
  });

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
        protocolVersion: PROTOCOL_VERSION,
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
        protocolVersion: PROTOCOL_VERSION,
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
          protocolVersion: PROTOCOL_VERSION,
          ...command,
        }),
      ).not.toThrow();
    }
  });

  it("parses steer commands with optional captured context", () => {
    const parsed = CommandEnvelopeSchema.parse({
      id: "cmd-steer-context",
      protocolVersion: PROTOCOL_VERSION,
      type: "steer",
      sessionId: "session-001",
      text: "look at this screenshot",
      visualDslEnabled: true,
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
    if (parsed.type === "steer") {
      expect(parsed.context?.screenshots[0]?.path).toBe("/tmp/shot.png");
      expect(parsed.visualDslEnabled).toBe(true);
    }
  });


  it("parses clearQueue commands for every queue kind", () => {
    for (const kind of ["steering", "followUp", "all"] as const) {
      expect(() =>
        CommandEnvelopeSchema.parse({
          id: `cmd-clear-${kind}`,
          protocolVersion: PROTOCOL_VERSION,
          type: "clearQueue",
          sessionId: "session-001",
          kind,
        }),
      ).not.toThrow();
    }
  });

  it("parses package operation commands and progress/completion events", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-package-install",
      protocolVersion: PROTOCOL_VERSION,
      type: "installPackage",
      source: "npm:@example/plugin",
    })).toMatchObject({ type: "installPackage", source: "npm:@example/plugin" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-package-remove",
      protocolVersion: PROTOCOL_VERSION,
      type: "removePackage",
      source: "npm:@example/plugin",
    })).toMatchObject({ type: "removePackage", source: "npm:@example/plugin" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-package-check-updates",
      protocolVersion: PROTOCOL_VERSION,
      type: "checkPackageUpdates",
    })).toMatchObject({ type: "checkPackageUpdates" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-package-update",
      protocolVersion: PROTOCOL_VERSION,
      type: "updatePackage",
      source: "npm:@example/plugin",
    })).toMatchObject({ type: "updatePackage", source: "npm:@example/plugin" });

    expect(EventEnvelopeSchema.parse({
      id: "event-package-updates",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "packageUpdatesAvailable",
      commandId: "cmd-package-check-updates",
      sources: ["npm:@example/plugin"],
    })).toMatchObject({ type: "packageUpdatesAvailable", sources: ["npm:@example/plugin"] });

    expect(EventEnvelopeSchema.parse({
      id: "event-package-updates-failed",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "packageUpdatesAvailable",
      commandId: "cmd-package-check-updates",
      sources: [],
      failed: true,
    })).toMatchObject({ type: "packageUpdatesAvailable", sources: [], failed: true });

    expect(EventEnvelopeSchema.parse({
      id: "event-package-progress",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "packageOperationProgress",
      requestId: "cmd-package-install",
      operation: "install",
      source: "npm:@example/plugin",
      message: "Installing npm:@example/plugin...",
    })).toMatchObject({ type: "packageOperationProgress", operation: "install" });

    expect(EventEnvelopeSchema.parse({
      id: "event-package-completed",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "packageOperationCompleted",
      requestId: "cmd-package-update",
      operation: "update",
      source: "npm:@example/plugin",
      ok: false,
      errorMessage: "npm was not found",
    })).toMatchObject({ type: "packageOperationCompleted", operation: "update", ok: false });
  });

  it("parses slim todo state updates including authoritative clears", () => {
    expect(EventEnvelopeSchema.parse({
      id: "event-todo-state",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-14T01:00:00.000Z",
      type: "sessionTodoStateUpdated",
      sessionId: "session-001",
      todoState: null,
      seq: 10,
    })).toMatchObject({ type: "sessionTodoStateUpdated", sessionId: "session-001", todoState: null, seq: 10 });
  });

  it("parses message rewind commands and events", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-list-rewind",
      protocolVersion: PROTOCOL_VERSION,
      type: "listRewindTargets",
      sessionId: "session-001",
    })).toMatchObject({ type: "listRewindTargets", sessionId: "session-001" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-session-diff",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionDiff",
      sessionId: "session-001",
      view: "unstaged",
      requestId: "request-session-diff",
    })).toMatchObject({ type: "getSessionDiff", view: "unstaged", requestId: "request-session-diff" });
    expect(() => CommandEnvelopeSchema.parse({
      id: "cmd-session-diff-missing-request",
      protocolVersion: PROTOCOL_VERSION,
      type: "getSessionDiff",
      sessionId: "session-001",
      view: "unstaged",
    })).toThrow();

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-rewind",
      protocolVersion: PROTOCOL_VERSION,
      type: "rewindSession",
      sessionId: "session-001",
      entryId: "entry-user-2",
    })).toMatchObject({ type: "rewindSession", entryId: "entry-user-2" });

    expect(EventEnvelopeSchema.parse({
      id: "event-session-diff",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "sessionDiffResult",
      sessionId: "session-001",
      view: "unstaged",
      isGitRepo: true,
      files: [{ path: "source.ts", status: "modified", additions: 3, deletions: 1, diff: "@@ -1 +1 @@", truncated: false }],
      filesTruncated: false,
      requestId: "request-session-diff",
    })).toMatchObject({ type: "sessionDiffResult", files: [{ path: "source.ts", additions: 3 }], requestId: "request-session-diff" });

    expect(EventEnvelopeSchema.parse({
      id: "event-rewind-targets",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "rewindTargetsSnapshot",
      sessionId: "session-001",
      requestId: "cmd-list-rewind",
      targets: [{ entryId: "entry-user-1", text: "A", createdAt: "2026-07-19T00:00:00.000Z" }],
    })).toMatchObject({ type: "rewindTargetsSnapshot", targets: [{ entryId: "entry-user-1", text: "A" }] });

    expect(EventEnvelopeSchema.parse({
      id: "event-rewound",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "sessionRewound",
      sessionId: "session-001",
      editorText: "B",
      removedIds: ["msg-user-b", "msg-agent-b"],
    })).toMatchObject({ type: "sessionRewound", editorText: "B", removedIds: ["msg-user-b", "msg-agent-b"] });
  });

  it("parses external push-to-talk control command and events", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-ptt-press",
      protocolVersion: PROTOCOL_VERSION,
      type: "controlPushToTalkFromExternal",
      action: "press",
    })).toMatchObject({ type: "controlPushToTalkFromExternal", action: "press" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-ptt-complete",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePushToTalkControlRequest",
      requestId: "ptt-control-1",
    })).toMatchObject({ type: "completePushToTalkControlRequest", requestId: "ptt-control-1" });

    expect(EventEnvelopeSchema.parse({
      id: "event-ptt-request",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "pushToTalkControlRequested",
      requestId: "ptt-control-1",
      action: "release",
    })).toMatchObject({ type: "pushToTalkControlRequested", action: "release" });

    expect(EventEnvelopeSchema.parse({
      id: "event-ptt-ack",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "pushToTalkControlAck",
      commandId: "cmd-ptt-release",
      action: "release",
    })).toMatchObject({ type: "pushToTalkControlAck", action: "release" });
  });

  it("parses Picky settings commands and round-trip events", () => {
    expect(CommandEnvelopeSchema.parse({
      id: "cmd-settings-list",
      protocolVersion: PROTOCOL_VERSION,
      type: "listPickySettings",
      caller: "mainAgent",
    })).toMatchObject({ type: "listPickySettings", caller: "mainAgent" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-settings-set",
      protocolVersion: PROTOCOL_VERSION,
      type: "setPickySettings",
      key: "hud.dockVisible",
      value: true,
      displayId: "display-1",
    })).toMatchObject({ type: "setPickySettings", key: "hud.dockVisible", value: true, displayId: "display-1" });

    expect(CommandEnvelopeSchema.parse({
      id: "cmd-settings-complete",
      protocolVersion: PROTOCOL_VERSION,
      type: "completePickySettingsRequest",
      requestId: "picky-settings-1",
      result: { key: "hud.dockVisible", value: true },
    })).toMatchObject({ type: "completePickySettingsRequest", requestId: "picky-settings-1" });

    expect(EventEnvelopeSchema.parse({
      id: "event-settings-request",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "pickySettingsRequested",
      requestId: "picky-settings-1",
      action: "set",
      key: "hud.dockVisible",
      value: true,
      toggle: false,
      displayId: "display-1",
      caller: "mainAgent",
    })).toMatchObject({ type: "pickySettingsRequested", action: "set", caller: "mainAgent" });

    expect(EventEnvelopeSchema.parse({
      id: "event-settings-ack",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-07-19T00:00:00.000Z",
      type: "pickySettingsAck",
      commandId: "cmd-settings-set",
      result: { key: "hud.dockVisible", value: true, persisted: true, applied: true, restartRequired: false, revision: 1 },
    })).toMatchObject({ type: "pickySettingsAck", commandId: "cmd-settings-set" });
  });

  it("parses session message events with full message payloads", () => {
    expect(() =>
      EventEnvelopeSchema.parse({
        id: "event-message-appended",
        protocolVersion: PROTOCOL_VERSION,
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
        protocolVersion: PROTOCOL_VERSION,
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

  it("parses subagent invocation message events with optional activity fields", () => {
    expect(() =>
      EventEnvelopeSchema.parse({
        id: "event-subagent-invocation",
        protocolVersion: PROTOCOL_VERSION,
        timestamp: "2026-08-02T00:00:00.000Z",
        type: "sessionMessageAppended",
        sessionId: "session-001",
        message: {
          id: "message-subagent-invocation",
          kind: "subagent_invocation",
          createdAt: "2026-08-02T00:00:00.000Z",
          subagentInvocation: {
            invocationId: "tool-subagent-1",
            action: "chain",
            planned: [{ agent: "worker", task: "Implement" }, { agent: "reviewer", task: "Review" }],
            completed: true,
          },
        },
        seq: 2,
      }),
    ).not.toThrow();
    expect(PickyAgentSessionSchema.parse({
      id: "session-summary", title: "Pickle", status: "running", createdAt: "2026-08-02T00:00:00.000Z", updatedAt: "2026-08-02T00:00:00.000Z",
      logs: [], tools: [], artifacts: [], changedFiles: [], messageJournalAvailable: false,
    }).messageJournalAvailable).toBe(false);
    expect(PickyAgentSessionSchema.parse({
      id: "session-001", title: "Pickle", status: "running", createdAt: "2026-08-02T00:00:00.000Z", updatedAt: "2026-08-02T00:00:00.000Z",
      logs: [], tools: [], artifacts: [], changedFiles: [],
      messageJournalAvailable: false,
      subagentRuns: [{ runId: 1, agent: "worker", task: "Implement", status: "done", resultText: "Full markdown response", invocationId: "tool-subagent-1", lastActivity: { toolName: "edit", toolCallCount: 2, contextUsage: { tokens: 84_000, contextWindow: 200_000, percent: 42 } } }],
    }).subagentRuns[0]).toMatchObject({
      resultText: "Full markdown response",
      invocationId: "tool-subagent-1",
      lastActivity: { toolName: "edit", contextUsage: { tokens: 84_000, contextWindow: 200_000, percent: 42 } },
    });
  });

  it("parses agent activity session message events", () => {
    expect(() =>
      EventEnvelopeSchema.parse({
        id: "event-activity-message",
        protocolVersion: PROTOCOL_VERSION,
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
      protocolVersion: PROTOCOL_VERSION,
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

  it("preserves absent, null, and value semantics for projection meta patches", () => {
    expect(PickySessionMetaPatchSchema.parse({})).toEqual({});
    expect(PickySessionMetaPatchSchema.parse({ cwd: null })).toEqual({ cwd: null });
    expect(PickySessionMetaPatchSchema.parse({ title: "Renamed Pickle" })).toEqual({ title: "Renamed Pickle" });
    expect(() => PickySessionMetaPatchSchema.parse({ finalAnswer: "owned elsewhere" })).toThrow();
  });

  it("requires ordered non-empty projection transactions and known mutation variants", () => {
    const transaction = {
      id: "event-projection-transaction",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-08-24T00:00:00.000Z",
      type: "sessionProjectionTransaction",
      sessionId: "session-001",
      epoch: "epoch-001",
      baseRevision: 3,
      revision: 4,
      mutations: [{ type: "metaPatch", patch: { status: "completed" } }],
    };

    expect(() => EventEnvelopeSchema.parse(transaction)).not.toThrow();
    expect(() => EventEnvelopeSchema.parse({ ...transaction, revision: 3 })).toThrow();
    expect(() => EventEnvelopeSchema.parse({ ...transaction, mutations: [] })).toThrow();
    expect(() => PickySessionProjectionMutationSchema.parse({ type: "unknown" })).toThrow();
  });

  it("rejects message replacements whose identifiers disagree", () => {
    expect(() => PickySessionProjectionMutationSchema.parse({
      type: "messageReplace",
      messageId: "message-original",
      message: { id: "message-replacement", kind: "agent_text", createdAt: "2026-08-24T00:00:00.000Z", text: "Updated answer" },
    })).toThrow();
  });

  it("rejects extension UI requests for another transaction session", () => {
    expect(() => EventEnvelopeSchema.parse({
      id: "event-projection-extension-ui",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-08-24T00:00:00.000Z",
      type: "sessionProjectionTransaction",
      sessionId: "session-001",
      epoch: "epoch-001",
      baseRevision: 3,
      revision: 4,
      mutations: [{
        type: "extensionUiRequestSet",
        request: {
          id: "extension-request-001",
          sessionId: "other-session",
          method: "confirm",
          createdAt: "2026-08-24T00:00:00.000Z",
        },
      }],
    })).toThrow();
  });

  it("round-trips every ownership mutation variant", () => {
    const mutations: Record<string, unknown> = {
      metaPatch: { type: "metaPatch", patch: { title: "Updated title" } },
      messageAppend: { type: "messageAppend", message: { id: "message-001", kind: "agent_text", createdAt: "2026-08-24T00:00:00.000Z", text: "Answer" } },
      messageReplace: { type: "messageReplace", messageId: "message-001", message: { id: "message-001", kind: "agent_text", createdAt: "2026-08-24T00:00:00.000Z", text: "Updated answer" } },
      messageRemove: { type: "messageRemove", messageId: "message-001" },
      messagesImport: { type: "messagesImport", messages: [] },
      logAppend: { type: "logAppend", line: "completed" },
      toolUpsert: { type: "toolUpsert", tool: { toolCallId: "tool-001", name: "read", status: "succeeded" } },
      todoSet: { type: "todoSet", todoState: null },
      subagentRunsSet: { type: "subagentRunsSet", runs: [] },
      artifactUpsert: { type: "artifactUpsert", artifact: { id: "artifact-001", kind: "report", title: "Report", updatedAt: "2026-08-24T00:00:00.000Z" } },
      changedFilesSet: { type: "changedFilesSet", changedFiles: [] },
      queueSet: { type: "queueSet", queuedSteers: [], queuedFollowUps: [], steeringMode: "one-at-a-time", followUpMode: "one-at-a-time" },
      activitySet: { type: "activitySet", activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 } },
      finalAnswerSet: { type: "finalAnswerSet", finalAnswer: null },
      extensionUiRequestSet: { type: "extensionUiRequestSet", request: null },
    };

    for (const [type, mutation] of Object.entries(mutations)) {
      expect(PickySessionProjectionMutationSchema.parse(mutation)).toEqual(mutation);
      expect(mutationNamesForOwnership()).toContain(type);
    }
  });

  it("keeps projection mutation ownership and schema variants in exact parity", () => {
    expect(new Set(PickySessionProjectionMutationVariantSchema.options.map((option) => option.shape.type.value))).toEqual(
      new Set(persistedSessionFieldOwnership.flatMap(mutationNames)),
    );
  });

  it("keeps meta patch fields in exact parity with manifest ownership", () => {
    expect(new Set(Object.keys(PickySessionMetaPatchSchema.shape))).toEqual(
      new Set(persistedSessionFieldOwnership
        .filter((entry) => entry.v2Mutation === "metaPatch")
        .map((entry) => entry.field)),
    );
  });

  it("rejects inconsistent projection snapshot omission metadata", () => {
    const snapshot = {
      id: "event-projection-snapshot",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-08-24T00:00:00.000Z",
      type: "sessionProjectionSnapshot",
      requestId: "snapshot-001",
      sessionId: "session-001",
      epoch: "epoch-001",
      revision: 4,
      complete: false,
      omittedFields: ["messages"],
      projection: {
        id: "session-001",
        title: "Projection",
        status: "running",
        createdAt: "2026-08-24T00:00:00.000Z",
        updatedAt: "2026-08-24T00:00:00.000Z",
      },
    };

    expect(EventEnvelopeSchema.parse(snapshot)).toMatchObject({ type: "sessionProjectionSnapshot", complete: false, omittedFields: ["messages"] });
    expect(() => EventEnvelopeSchema.parse({ ...snapshot, complete: true })).toThrow();
    expect(() => EventEnvelopeSchema.parse({ ...snapshot, omittedFields: ["notAStoredSessionField"] })).toThrow();
    expect(() => EventEnvelopeSchema.parse({ ...snapshot, omittedFields: ["messages", "messages"] })).toThrow();
  });

  it("keeps v2 projection events dormant in the server", () => {
    const serverSource = readFileSync(new URL("./server.ts", import.meta.url), "utf8");
    expect(serverSource).not.toMatch(/(?:broadcast|send)\(\{[\s\S]{0,300}type:\s*["']sessionProjection(?:Transaction|Snapshot)["']/);
  });

  function mutationNamesForOwnership() {
    return persistedSessionFieldOwnership.flatMap(mutationNames);
  }

  it("rejects invalid protocol versions", () => {
    expect(() => CommandEnvelopeSchema.parse({ id: "bad", protocolVersion: "old", type: "listSessions" })).toThrow(/Invalid literal value/);
  });
});
