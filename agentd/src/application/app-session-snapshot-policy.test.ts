import { describe, expect, it } from "vitest";
import {
  APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT,
  boundedSessionForAppHydration,
  boundedSessionForProjectionSnapshot,
  eventPayloadByteLength,
  minimalSessionForAppSnapshot,
  sessionUpdatedPayloadFitsAppFrame,
} from "./app-session-snapshot-policy.js";
import { PROTOCOL_VERSION, PickyAgentSessionSchema, type PickyAgentSessionParsed } from "../protocol.js";

function session(overrides: Partial<PickyAgentSessionParsed> = {}): PickyAgentSessionParsed {
  return PickyAgentSessionSchema.parse({
    id: "snapshot-policy-session",
    title: "Snapshot policy session",
    status: "completed",
    cwd: "/tmp/project",
    piSessionFilePath: "/tmp/project/.pi/session.jsonl",
    createdAt: "2026-08-24T00:00:00.000Z",
    updatedAt: "2026-08-24T00:00:01.000Z",
    logs: [],
    tools: [],
    subagentRuns: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    ...overrides,
  });
}

function oversizedText(sizeInMiB: number): string {
  return "x".repeat(sizeInMiB * 1024 * 1024);
}

describe("app session snapshot policy", () => {
  it("keeps a normal hydration unchanged", () => {
    const original = session();

    expect(boundedSessionForAppHydration(original)).toEqual({
      session: original,
      omittedFields: [],
    });
  });

  it("degrades oversized hydrations in the documented field order", () => {
    expect(boundedSessionForAppHydration(session({
      subagentRuns: [{ runId: 1, agent: "worker", task: oversizedText(9), status: "running", startedAt: "2026-08-24T00:00:00.000Z" }],
    })).omittedFields).toEqual(["subagentRuns"]);

    expect(boundedSessionForAppHydration(session({
      subagentRuns: [{ runId: 1, agent: "worker", task: oversizedText(3), status: "running", startedAt: "2026-08-24T00:00:00.000Z" }],
      tools: [{ toolCallId: "tool", name: "bash", status: "running", preview: oversizedText(9) }],
    })).omittedFields).toEqual(["subagentRuns", "tools"]);

    const messages = [{ id: "message", kind: "agent_text" as const, createdAt: "2026-08-24T00:00:00.000Z", text: oversizedText(9) }];
    const withoutMessages = boundedSessionForAppHydration(session({ messages }));
    expect(withoutMessages.omittedFields).toEqual(["subagentRuns", "tools", "messages"]);
    expect(withoutMessages.session?.messageJournalAvailable).toBe(false);

    const oversizedQueue = [{ id: "queued", text: oversizedText(9), enqueuedAt: "2026-08-24T00:00:00.000Z" }];
    const minimal = boundedSessionForAppHydration(session({ queuedSteers: oversizedQueue }));
    expect(minimal.omittedFields).toEqual(["subagentRuns", "tools", "messages", "extendedMetadata"]);
    expect(minimal.session).toEqual(minimalSessionForAppSnapshot(session({ queuedSteers: oversizedQueue })));

    expect(boundedSessionForAppHydration(session({
      id: oversizedText(9),
    }))).toEqual({ omittedFields: ["entireSession"] });
  });

  it("truncates title and path fields in minimal snapshots", () => {
    const result = minimalSessionForAppSnapshot(session({
      title: "t".repeat(501),
      cwd: "/" + "c".repeat(2_001),
      piSessionFilePath: "/" + "p".repeat(2_001),
    }));

    expect(result.title).toHaveLength(501);
    expect(result.title).toMatch(/…$/);
    expect(result.cwd).toHaveLength(2_001);
    expect(result.cwd).toMatch(/…$/);
    expect(result.piSessionFilePath).toHaveLength(2_001);
    expect(result.piSessionFilePath).toMatch(/…$/);
  });

  it("measures the UTF-8 encoded event envelope against the safe payload limit", () => {
    const payload = { type: "sessionUpdated" as const, session: session({ title: "한글😀".repeat(200) }) };
    const measured = eventPayloadByteLength(payload);
    const expected = Buffer.byteLength(JSON.stringify({
      id: "event-00000000-0000-0000-0000-000000000000",
      protocolVersion: PROTOCOL_VERSION,
      timestamp: "2026-01-01T00:00:00.000Z",
      ...payload,
    }), "utf8");

    expect(measured).toBe(expected);
    expect(measured).toBeGreaterThan(JSON.stringify(payload).length);
    expect(sessionUpdatedPayloadFitsAppFrame(session())).toBe(true);
    expect(eventPayloadByteLength({ type: "sessionUpdated", session: session({ id: oversizedText(9) }) })).toBeGreaterThan(APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT);
  });

  it("uses the app hydration omission order for bounded projection snapshots", () => {
    const result = boundedSessionForProjectionSnapshot(session({
      messages: [{ id: "message", kind: "agent_text", createdAt: "2026-08-24T00:00:00.000Z", text: oversizedText(9) }],
    }), {
      requestId: "recovery-001",
      epoch: "daemon-epoch-001",
    });

    expect(result.omittedFields).toEqual(["subagentRuns", "tools", "messages"]);
    expect(result.session?.messages).toEqual([]);
    expect(result.session?.messageJournalAvailable).toBe(false);
    expect(result.session).toBeDefined();
    expect(eventPayloadByteLength({
      type: "sessionProjectionSnapshot",
      requestId: "recovery-001",
      sessionId: "snapshot-policy-session",
      epoch: "daemon-epoch-001",
      revision: result.session?.revision ?? 0,
      complete: false,
      omittedFields: result.omittedFields,
      projection: result.session!,
    })).toBeLessThanOrEqual(APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT);
  });

  it("builds a bounded bootstrap projection snapshot without recovery correlation", () => {
    const result = boundedSessionForProjectionSnapshot(session(), {
      epoch: "daemon-epoch-001",
    });

    expect(result.session?.revision).toBe(0);
    expect(eventPayloadByteLength({
      type: "sessionProjectionSnapshot",
      sessionId: "snapshot-policy-session",
      epoch: "daemon-epoch-001",
      revision: result.session?.revision ?? 0,
      complete: result.omittedFields.length === 0,
      omittedFields: result.omittedFields,
      projection: result.session!,
    })).toBeLessThanOrEqual(APP_EVENT_SAFE_PAYLOAD_BYTE_LIMIT);
  });

  it("preserves the durable revision when the projection snapshot reaches the minimal fallback", () => {
    const result = boundedSessionForProjectionSnapshot(session({
      revision: 17,
      queuedSteers: [{ id: "queued", text: oversizedText(9), enqueuedAt: "2026-08-24T00:00:00.000Z" }],
    }), {
      requestId: "recovery-minimal",
      epoch: "daemon-epoch-001",
    });

    expect(result.omittedFields).toEqual([
      "logs", "tools", "todoState", "subagentRuns", "artifacts", "changedFiles", "messages",
      "messageJournalAvailable", "queuedSteers", "queuedFollowUps", "steeringMode", "followUpMode",
      "currentAssistantRun", "pendingExtensionUiRequest",
    ]);
    expect(result.session?.revision).toBe(17);
  });
});
