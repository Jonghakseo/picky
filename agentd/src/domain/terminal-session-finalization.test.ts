import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickyContextPacket, PickySessionMessage } from "../protocol.js";
import { PickySessionProjectionMutationSchema } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "../runtime/types.js";
import { mutationNames, persistedSessionFieldOwnership, requiredTransientOwnershipIds } from "./session-projection-ownership.js";
import { finalizeTerminalSession, type TerminalSessionFinalizationInput } from "./terminal-session-finalization.js";

const now = "2026-08-24T13:06:20.000Z";

function currentSession(): PickyAgentSession {
  return {
    id: "terminal-session",
    revision: 7,
    title: "Terminal replay",
    status: "running",
    createdAt: "2026-08-24T13:06:19.000Z",
    updatedAt: "2026-08-24T13:06:19.000Z",
    lastSummary: "Working",
    thinkingPreview: "Preparing the final result.",
    logs: [],
    tools: [{ toolCallId: "tool-read", name: "read", status: "running", preview: "Read the session state" }],
    artifacts: [],
    changedFiles: [],
    messages: [{ id: "thinking-1", kind: "agent_thinking", createdAt: "2026-08-24T13:06:19.700Z", text: "Preparing the final result." }],
    activitySummary: { read: 1, bash: 0, edit: 0, write: 0, thinking: 1, other: 0 },
  };
}

function input(event: Extract<RuntimeEvent, { type: "status" }>): TerminalSessionFinalizationInput {
  const messages: PickySessionMessage[] = [{
    id: "answer-1",
    kind: "agent_text",
    createdAt: now,
    text: event.finalAnswer ?? "draft answer",
  }];
  return {
    currentSession: currentSession(),
    messageSnapshot: {
      journal: currentSession().messages ?? [],
      removedIds: [],
      cancelledIds: [],
      assistantDraft: "draft answer",
      thinkingDraft: "Preparing the final result.",
      activeThinkingId: "thinking-1",
    },
    runtimeSnapshot: {
      assistantDraft: "draft answer",
      thinkingDraft: "Preparing the final result.",
      thinkingActive: true,
      pendingThinkingDelta: "",
      seenToolCallIds: ["tool-read"],
      processedTerminalRun: false,
    },
    event,
    prepared: {
      messages,
      artifacts: [{
        id: "artifact-pr-123",
        kind: "link",
        title: "Pull request",
        url: "https://github.com/creatrip/picky/pull/123",
        updatedAt: now,
      }],
      activitySummary: { read: 1, bash: 0, edit: 0, write: 0, thinking: 1, other: 0 },
    },
    now,
  };
}

describe("finalizeTerminalSession", () => {
  it("stages the canonical completion fixture as a complete terminal projection", async () => {
    const fixture = JSON.parse(await readFile(new URL("../../../contracts/perf/terminal-completion.runtime.json", import.meta.url), "utf8")) as {
      withArtifacts: Array<{ event: RuntimeEvent }>;
    };
    const event = fixture.withArtifacts.at(-1)?.event;
    if (!event || event.type !== "status") throw new Error("Canonical terminal fixture has no final status event");

    const replay = await replayV1UntilTerminal(fixture.withArtifacts.map(({ event: fixtureEvent }) => fixtureEvent));
    const result = finalizeTerminalSession({
      currentSession: replay.before,
      messageSnapshot: replay.messageSnapshot,
      runtimeSnapshot: replay.runtimeSnapshot,
      event,
      prepared: {
        messages: replay.after.messages ?? [],
        artifacts: replay.after.artifacts,
        activitySummary: replay.after.activitySummary,
      },
      now: replay.after.updatedAt,
    });

    // Characterize the actual v1 terminal result using the same canonical fixture. Time is
    // injected into the planner from that result, so this comparison covers the complete
    // persisted projection without coupling the planner to clocks or SessionSupervisor.
    expect(normalizeTerminalSession(result.nextSession)).toEqual(normalizeTerminalSession(replay.after));
    expect(result.mutations.map((mutation) => mutation.type)).toEqual([
      "metaPatch", "messageRemove", "messagesImport", "artifactUpsert", "activitySet", "finalAnswerSet",
    ]);
    expect(result.transientResets).toEqual([
      "SessionMessageBuilder.states",
      "RuntimeEventHandler.assistantDrafts",
      "RuntimeEventHandler.thinkingDrafts",
      "RuntimeEventHandler.thinkingActive",
      "RuntimeEventHandler.pendingThinkingFlushes",
    ]);
  });

  it("stages the canonical no-artifact completion fixture as a complete terminal projection", async () => {
    const fixture = JSON.parse(await readFile(new URL("../../../contracts/perf/terminal-completion.runtime.json", import.meta.url), "utf8")) as {
      withoutArtifacts: Array<{ event: RuntimeEvent }>;
    };
    const event = fixture.withoutArtifacts.at(-1)?.event;
    if (!event || event.type !== "status") throw new Error("Canonical no-artifact terminal fixture has no final status event");

    const replay = await replayV1UntilTerminal(fixture.withoutArtifacts.map(({ event: fixtureEvent }) => fixtureEvent));
    const result = finalizeTerminalSession({
      currentSession: replay.before,
      messageSnapshot: replay.messageSnapshot,
      runtimeSnapshot: replay.runtimeSnapshot,
      event,
      prepared: {
        messages: replay.after.messages ?? [],
        artifacts: replay.after.artifacts,
        activitySummary: replay.after.activitySummary,
      },
      now: replay.after.updatedAt,
    });

    expect(normalizeTerminalSession(result.nextSession)).toEqual(normalizeTerminalSession(replay.after));
    expect(result.mutations.map((mutation) => mutation.type)).not.toContain("artifactUpsert");
    expect(result.transientResets).toEqual([
      "SessionMessageBuilder.states",
      "RuntimeEventHandler.assistantDrafts",
      "RuntimeEventHandler.thinkingDrafts",
      "RuntimeEventHandler.thinkingActive",
      "RuntimeEventHandler.pendingThinkingFlushes",
    ]);
  });

  it("produces only declared v2 mutations and manifest-owned transient reset identifiers", () => {
    const result = finalizeTerminalSession(input({ type: "status", status: "completed", finalAnswer: "draft answer" }));
    const allowedMutations = new Set(persistedSessionFieldOwnership.flatMap(mutationNames));

    for (const mutation of result.mutations) {
      expect(PickySessionProjectionMutationSchema.parse(mutation)).toEqual(mutation);
      expect(allowedMutations).toContain(mutation.type);
    }
    for (const transientReset of result.transientResets) expect(requiredTransientOwnershipIds).toContain(transientReset);
  });

  it("is deterministic and leaves every input snapshot untouched", () => {
    const source = input({ type: "status", status: "completed", finalAnswer: "draft answer" });
    const before = structuredClone(source);

    const first = finalizeTerminalSession(source);
    const second = finalizeTerminalSession(source);

    expect(first).toEqual(second);
    expect(source).toEqual(before);
  });

  it("rejects non-terminal runtime status events", () => {
    expect(() => finalizeTerminalSession(input({ type: "status", status: "running" }))).toThrow("requires a terminal status");
  });
});

async function replayV1UntilTerminal(events: readonly RuntimeEvent[]): Promise<{
  before: PickyAgentSession;
  after: PickyAgentSession;
  messageSnapshot: { journal: readonly PickySessionMessage[]; removedIds: readonly string[]; cancelledIds: readonly string[]; assistantDraft: string; thinkingDraft: string; activeThinkingId?: string };
  runtimeSnapshot: { assistantDraft: string; thinkingDraft: string; thinkingActive: boolean; pendingThinkingDelta: string; pendingThinkingPreview?: string; seenToolCallIds: readonly string[]; processedTerminalRun: boolean };
}> {
  const root = await mkdtemp(join(tmpdir(), "picky-terminal-finalization-"));
  try {
    const supervisor = new SessionSupervisor(new FixtureRuntime(), new SessionStore(root), { sessionIdFactory: () => "terminal-session" });
    await supervisor.load();
    const session = await supervisor.create({
      id: "terminal-replay-context",
      source: "text",
      capturedAt: "2026-08-24T13:06:19.000Z",
      transcript: "Capture the terminal completion baseline.",
      cwd: "/tmp/picky-terminal-replay",
      screenshots: [],
      inkMarks: [],
      warnings: [],
    } satisfies PickyContextPacket);
    const internals = supervisor as unknown as {
      applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void>;
      messageBuilder: { terminalSnapshot(sessionId: string): { journal: readonly PickySessionMessage[]; removedIds: readonly string[]; cancelledIds: readonly string[]; assistantDraft: string; thinkingDraft: string; activeThinkingId?: string } };
      runtimeEventHandler: { terminalSnapshot(sessionId: string): { assistantDraft: string; thinkingDraft: string; thinkingActive: boolean; pendingThinkingDelta: string; pendingThinkingPreview?: string; seenToolCallIds: readonly string[]; processedTerminalRun: boolean } };
    };
    const terminal = events.at(-1);
    if (!terminal || terminal.type !== "status") throw new Error("Fixture must end with a status event");
    for (const event of events.slice(0, -1)) await internals.applyRuntimeEvent(session.id, event);

    const before = structuredClone(supervisor.get(session.id)!);
    const messageSnapshot = internals.messageBuilder.terminalSnapshot(session.id);
    const runtimeSnapshot = internals.runtimeEventHandler.terminalSnapshot(session.id);
    await internals.applyRuntimeEvent(session.id, terminal);
    return { before, after: structuredClone(supervisor.get(session.id)!), messageSnapshot, runtimeSnapshot };
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

function normalizeTerminalSession(session: PickyAgentSession): PickyAgentSession {
  // W5.2 intentionally leaves revision assignment to commitSession, and the existing v1 path
  // obtains the tool-ended timestamp from its own clock. Compare every durable semantic field.
  return {
    ...session,
    revision: 0,
    updatedAt: "normalized",
    tools: session.tools.map(({ endedAt: _endedAt, ...tool }) => tool),
  };
}

class FixtureRuntime implements AgentRuntime {
  async create(_prompt: unknown, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    return new FixtureHandle(options.sessionId ?? "terminal-session");
  }
}

class FixtureHandle implements RuntimeSessionHandle {
  constructor(readonly id: string) {}
  async followUp(): Promise<void> {}
  async steer(): Promise<{ handledSynchronously: boolean }> { return { handledSynchronously: false }; }
  async abort(): Promise<void> {}
  clearQueue(): { steering: string[]; followUp: string[] } { return { steering: [], followUp: [] }; }
  getSteeringMessages(): readonly string[] { return []; }
  getFollowUpMessages(): readonly string[] { return []; }
  steeringMode: "one-at-a-time" = "one-at-a-time";
  followUpMode: "one-at-a-time" = "one-at-a-time";
  isStreaming = false;
  subscribe(_listener: (event: RuntimeEvent) => void): () => void { return () => {}; }
}
