import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickySessionProjectionMutation } from "../protocol.js";
import {
  PickySessionProjectionMutationVariantSchema,
  PickySessionProjectionSnapshotEventSchema,
  PickySessionProjectionTransactionEventSchema,
} from "../protocol.js";
import {
  applySessionProjectionSnapshot,
  applySessionProjectionTransaction,
  materializeSessionProjection,
  type SessionProjectionState,
} from "./session-projection-reducer.js";
import { buildSessionProjectionMutations, finalizeTerminalSession } from "./terminal-session-finalization.js";

// Resolved from this module, not the process cwd, so the scenarios load the
// same way under vitest, a bundler, or a future web client.
const conformanceDirectory = new URL("../../../contracts/projection/conformance/", import.meta.url);

interface ConformanceScenario {
  readonly name: string;
  readonly description: string;
  readonly events: readonly Record<string, unknown>[];
  readonly expect: {
    readonly sessionPresent?: boolean;
    readonly signals?: Record<string, number>;
    readonly queueModes?: Record<string, string>;
    readonly sections?: Record<string, unknown>;
  };
}

function loadScenarios(): { file: string; scenario: ConformanceScenario }[] {
  const directory = fileURLToPath(conformanceDirectory);
  return readdirSync(directory)
    .filter((file) => file.endsWith(".json"))
    .sort()
    .map((file) => ({
      file,
      scenario: JSON.parse(readFileSync(new URL(file, conformanceDirectory), "utf8")) as ConformanceScenario,
    }));
}

/** Parses each event through the wire schema, then folds it like a client would. */
function runScenario(scenario: ConformanceScenario): SessionProjectionState | undefined {
  let state: SessionProjectionState | undefined;
  for (const event of scenario.events) {
    if (event.type === "sessionProjectionSnapshot") {
      state = applySessionProjectionSnapshot(state, PickySessionProjectionSnapshotEventSchema.parse(event));
      continue;
    }
    if (event.type === "sessionProjectionTransaction") {
      state = applySessionProjectionTransaction(state, PickySessionProjectionTransactionEventSchema.parse(event));
      continue;
    }
    throw new Error(`Unsupported conformance event type ${String(event.type)}`);
  }
  return state;
}

/**
 * Deep-partial comparison: an object compares only the keys the scenario lists,
 * arrays must match in length and order, and `null` means "no value" because
 * JSON cannot express the difference between absent and undefined.
 */
function matchPartial(actual: unknown, expected: unknown, path: string): void {
  if (expected === null) {
    expect(actual ?? null, `${path} should have no value`).toBeNull();
    return;
  }
  if (Array.isArray(expected)) {
    expect(Array.isArray(actual), `${path} should be an array`).toBe(true);
    const actualArray = actual as unknown[];
    expect(actualArray.length, `${path} length`).toBe(expected.length);
    expected.forEach((item, index) => matchPartial(actualArray[index], item, `${path}[${index}]`));
    return;
  }
  if (typeof expected === "object") {
    expect(typeof actual, `${path} should be an object`).toBe("object");
    expect(actual, `${path} should not be null`).not.toBeNull();
    for (const [key, value] of Object.entries(expected as Record<string, unknown>)) {
      matchPartial((actual as Record<string, unknown>)[key], value, `${path}.${key}`);
    }
    return;
  }
  expect(actual, path).toBe(expected);
}

const scenarios = loadScenarios();

describe("projection conformance scenarios", () => {
  it("finds the shared contract directory", () => {
    expect(scenarios.length).toBeGreaterThan(0);
  });

  for (const { file, scenario } of scenarios) {
    it(`${scenario.name} (${file})`, () => {
      expect(scenario.description, "every scenario states the regression it pins").toBeTruthy();
      const state = runScenario(scenario);

      if (scenario.expect.sessionPresent === false) {
        expect(state, "scenario expects no hydrated session").toBeUndefined();
        return;
      }
      expect(state, "scenario expects a hydrated session").toBeDefined();
      if (!state) return;

      if (scenario.expect.signals) matchPartial(state.signals, scenario.expect.signals, "signals");
      if (scenario.expect.queueModes) matchPartial(state.queueModes, scenario.expect.queueModes, "queueModes");
      for (const [section, expected] of Object.entries(scenario.expect.sections ?? {})) {
        expect(Object.keys(state.sections), `unknown section ${section}`).toContain(section);
        matchPartial(state.sections[section as keyof typeof state.sections], expected, `sections.${section}`);
      }
    });
  }

  it("covers every mutation variant at least once", () => {
    const covered = new Set<string>();
    for (const { scenario } of scenarios) {
      for (const event of scenario.events) {
        if (event.type !== "sessionProjectionTransaction") continue;
        for (const mutation of (event.mutations ?? []) as { type: string }[]) covered.add(mutation.type);
      }
    }
    const declared = PickySessionProjectionMutationVariantSchema.options.map((option) => option.shape.type.value);
    expect(declared.filter((name) => !covered.has(name)), "uncovered mutation variants").toEqual([]);
  });

  it("reaches the same state whether logs arrive as appends or as one replacement", () => {
    const appended = scenarios.find(({ scenario }) => scenario.name === "log-append-sequence");
    const replaced = scenarios.find(({ scenario }) => scenario.name === "log-set-equivalent");
    expect(appended && replaced, "the log equivalence pair must exist").toBeTruthy();
    if (!appended || !replaced) return;
    expect(runScenario(replaced.scenario)).toEqual(runScenario(appended.scenario));
  });
});

const zeroActivity = { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 };

/** Projection-visible fields only; `asyncArchiveIntentId`/`asyncControlJournal` are not projected. */
function projectedFields(session: PickyAgentSession) {
  return {
    id: session.id,
    revision: session.revision ?? 0,
    title: session.title,
    status: session.status,
    cwd: session.cwd,
    piSessionFilePath: session.piSessionFilePath,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    lastSummary: session.lastSummary,
    thinkingPreview: session.thinkingPreview,
    finalAnswer: session.finalAnswer,
    logs: session.logs ?? [],
    tools: session.tools ?? [],
    todoState: session.todoState,
    subagentRuns: session.subagentRuns ?? [],
    agentCycle: session.agentCycle,
    asyncWorkSummary: session.asyncWorkSummary,
    asyncTasks: session.asyncTasks,
    completionTickets: session.completionTickets,
    asyncControl: session.asyncControl,
    artifacts: session.artifacts ?? [],
    changedFiles: session.changedFiles ?? [],
    messages: session.messages ?? [],
    messageJournalAvailable: session.messageJournalAvailable,
    queuedSteers: session.queuedSteers ?? [],
    queuedFollowUps: session.queuedFollowUps ?? [],
    scheduledMessages: session.scheduledMessages ?? [],
    steeringMode: session.steeringMode ?? "one-at-a-time",
    followUpMode: session.followUpMode ?? "one-at-a-time",
    activitySummary: session.activitySummary ?? zeroActivity,
    contextUsage: session.contextUsage,
    currentAssistantRun: session.currentAssistantRun,
    pendingExtensionUiRequest: session.pendingExtensionUiRequest,
    notifyMainOnCompletion: session.notifyMainOnCompletion,
    notifyMacOSOnCompletion: session.notifyMacOSOnCompletion,
    archived: session.archived,
    archivedAt: session.archivedAt,
    pinned: session.pinned,
    lastRequest: session.lastRequest,
  };
}

/** Hydrates `before` through a complete snapshot, then folds the daemon's own diff. */
function roundTrip(before: PickyAgentSession, mutations: readonly PickySessionProjectionMutation[], revision: number) {
  const hydrated = applySessionProjectionSnapshot(undefined, {
    sessionId: before.id,
    revision: before.revision ?? 0,
    omittedFields: [],
    projection: before,
  });
  const reduced = mutations.length === 0
    ? hydrated
    : applySessionProjectionTransaction(hydrated, { sessionId: before.id, revision, mutations });
  expect(reduced, "a hydrated session must survive its own transaction").toBeDefined();
  const materialized = reduced && materializeSessionProjection(reduced);
  expect(materialized, "a loaded session must materialize").toBeDefined();
  return materialized as PickyAgentSession;
}

function baseSession(): PickyAgentSession {
  return {
    id: "round-trip-session",
    revision: 3,
    title: "Round trip",
    status: "running",
    cwd: "/Users/creatrip/Documents/picky",
    piSessionFilePath: "/Users/creatrip/.pi/sessions/round-trip.jsonl",
    createdAt: "2026-08-24T00:00:00.000Z",
    updatedAt: "2026-08-24T00:00:10.000Z",
    logs: ["daemon ready"],
    tools: [{ toolCallId: "tool-a", name: "Read", status: "running" }],
    artifacts: [{ id: "artifact-1", kind: "report", title: "Draft", updatedAt: "2026-08-24T00:00:05.000Z" }],
    changedFiles: [{ path: "agentd/src/protocol.ts", status: "modified" }],
    messages: [
      { id: "m1", kind: "user_text", createdAt: "2026-08-24T00:00:01.000Z", text: "start" },
      { id: "m2", kind: "agent_text", createdAt: "2026-08-24T00:00:02.000Z", text: "working" },
    ],
    messageJournalAvailable: true,
    queuedSteers: [{ text: "stay focused", enqueuedAt: "2026-08-24T00:00:03.000Z" }],
    queuedFollowUps: [],
    scheduledMessages: [],
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    activitySummary: { read: 1, bash: 0, edit: 0, write: 0, thinking: 2, other: 0 },
    todoState: { tasks: [{ id: "todo-1", content: "fold", status: "in_progress" }], updatedAt: "2026-08-24T00:00:04.000Z" },
    subagentRuns: [{ runId: 1, agent: "worker", task: "fold", status: "running" }],
    asyncControl: { controlGeneration: 1, admissionState: "open", operations: [] },
  };
}

const roundTripCases: { name: string; after: (before: PickyAgentSession) => PickyAgentSession }[] = [
  {
    name: "metadata only",
    after: (before) => ({ ...before, title: "Renamed", status: "completed", lastSummary: "done", thinkingPreview: undefined }),
  },
  {
    name: "logs appended",
    after: (before) => ({ ...before, logs: [...(before.logs ?? []), "tool started", "tool finished"] }),
  },
  {
    name: "logs rewritten",
    after: (before) => ({ ...before, logs: ["compacted history"] }),
  },
  {
    name: "tool updated and added",
    after: (before) => ({
      ...before,
      tools: [
        { toolCallId: "tool-a", name: "Read", status: "succeeded", preview: "AGENTS.md" },
        { toolCallId: "tool-b", name: "Bash", status: "running" },
      ],
    }),
  },
  {
    name: "tool removed",
    after: (before) => ({ ...before, tools: [{ toolCallId: "tool-b", name: "Bash", status: "running" }] }),
  },
  {
    name: "messages appended, edited and removed",
    after: (before) => ({
      ...before,
      messages: [
        { id: "m1", kind: "user_text", createdAt: "2026-08-24T00:00:01.000Z", text: "start, edited" },
        { id: "m3", kind: "agent_text", createdAt: "2026-08-24T00:00:06.000Z", text: "finished" },
      ],
    }),
  },
  {
    name: "queue, activity and presentation state",
    after: (before) => ({
      ...before,
      queuedSteers: [],
      queuedFollowUps: [{ id: "follow-1", text: "report back", enqueuedAt: "2026-08-24T00:00:07.000Z" }],
      scheduledMessages: [{ id: "sched-1", text: "ping", dueAt: "2026-08-24T01:00:00.000Z", createdAt: "2026-08-24T00:00:07.000Z" }],
      steeringMode: "all",
      followUpMode: "all",
      activitySummary: { read: 4, bash: 2, edit: 1, write: 0, thinking: 3, other: 0 },
      finalAnswer: "All done.",
      pendingExtensionUiRequest: {
        id: "request-1",
        sessionId: "round-trip-session",
        method: "confirm",
        prompt: "Ship it?",
        createdAt: "2026-08-24T00:00:08.000Z",
      },
    }),
  },
  {
    name: "artifacts, changed files, todo and subagents",
    after: (before) => ({
      ...before,
      artifacts: [
        { id: "artifact-1", kind: "report", title: "Final", updatedAt: "2026-08-24T00:00:09.000Z" },
        { id: "artifact-2", kind: "link", title: "PR", url: "https://example.com/pr/1", updatedAt: "2026-08-24T00:00:09.000Z" },
      ],
      changedFiles: [],
      todoState: undefined,
      subagentRuns: [{ runId: 1, agent: "worker", task: "fold", status: "done" }],
    }),
  },
  {
    name: "async control cleared",
    after: (before) => ({ ...before, asyncControl: undefined }),
  },
  {
    name: "unchanged session",
    after: (before) => ({ ...before }),
  },
];

describe("server diff and client reducer round trip", () => {
  for (const { name, after } of roundTripCases) {
    it(`restores the daemon's next session after ${name}`, () => {
      const before = baseSession();
      const next = after(baseSession());
      const mutations = buildSessionProjectionMutations(before, next);
      const revision = (before.revision ?? 0) + 1;
      const restored = roundTrip(before, mutations, revision);
      expect(projectedFields(restored)).toEqual(projectedFields({ ...next, revision: mutations.length === 0 ? before.revision : revision }));
    });
  }

  it("restores a terminal finalization planned by the daemon", () => {
    const before = baseSession();
    const finalization = finalizeTerminalSession({
      currentSession: before,
      messageSnapshot: {
        journal: before.messages ?? [],
        removedIds: [],
        cancelledIds: [],
        assistantDraft: "done",
        thinkingDraft: "",
      },
      runtimeSnapshot: {
        assistantDraft: "done",
        thinkingDraft: "",
        thinkingActive: false,
        pendingThinkingDelta: "",
        seenToolCallIds: ["tool-a"],
        processedTerminalRun: false,
      },
      event: { type: "status", status: "completed", finalAnswer: "Shipped the reducer." },
      prepared: {
        messages: [
          ...(before.messages ?? []),
          { id: "m3", kind: "agent_text", createdAt: "2026-08-24T00:00:20.000Z", text: "Shipped the reducer." },
        ],
        artifacts: [{ id: "artifact-1", kind: "report", title: "Final", updatedAt: "2026-08-24T00:00:20.000Z" }],
        activitySummary: { read: 2, bash: 0, edit: 1, write: 0, thinking: 2, other: 0 },
      },
      now: "2026-08-24T00:00:20.000Z",
    });
    const revision = (before.revision ?? 0) + 1;
    const restored = roundTrip(before, finalization.mutations, revision);
    expect(projectedFields(restored)).toEqual(projectedFields({ ...finalization.nextSession, revision }));
  });
});
