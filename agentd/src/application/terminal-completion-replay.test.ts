import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickyContextPacket } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "../runtime/types.js";

const emittedEventTypes = [
  "session",
  "sessionMeta",
  "messageAppended",
  "messagesImported",
  "messageReplaced",
  "messageRemoved",
  "toolActivityUpdated",
  "activityUpdated",
  "todoStateUpdated",
  "artifact",
  "log",
] as const;

type EmittedEventType = (typeof emittedEventTypes)[number];
type FixtureVariant = "withArtifacts" | "withoutArtifacts";
type ReplayBudget = {
  counts: Record<EmittedEventType, number>;
  totalEncodedEventBytes: number;
  maxEncodedEventBytes: number;
};

type RuntimeFixture = Record<FixtureVariant, Array<{ timestamp: string; event: RuntimeEvent }>>;

// v1 terminal replay baselines for W7 comparison. Values are pinned after the
// first deterministic capture; encoded event bytes intentionally include the
// EventEmitter event name plus its ordered payload arguments.
const expectedBudgets: Record<FixtureVariant, ReplayBudget> = {
  withArtifacts: {
    counts: {
      session: 0,
      sessionMeta: 1,
      messageAppended: 3,
      messagesImported: 0,
      messageReplaced: 0,
      messageRemoved: 1,
      toolActivityUpdated: 2,
      activityUpdated: 3,
      todoStateUpdated: 0,
      artifact: 1,
      log: 0,
    },
    // W5 publishes terminal meta from the one committed projection, so the existing artifact
    // is present in that metadata frame as well as its legacy granular artifact event.
    totalEncodedEventBytes: 3_445,
    maxEncodedEventBytes: 1_534,
  },
  withoutArtifacts: {
    counts: {
      session: 0,
      sessionMeta: 1,
      messageAppended: 3,
      messagesImported: 0,
      messageReplaced: 0,
      messageRemoved: 1,
      toolActivityUpdated: 2,
      activityUpdated: 3,
      todoStateUpdated: 0,
      artifact: 0,
      log: 0,
    },
    // The committed terminal metadata normalizes the same projection one byte shorter than the
    // former patch-before-materialization sequence; event kinds and counts are unchanged.
    totalEncodedEventBytes: 3_045,
    maxEncodedEventBytes: 1_347,
  },
};

describe("terminal completion replay budget", () => {
  for (const variant of ["withArtifacts", "withoutArtifacts"] as const) {
    it(`${variant} terminal replay preserves its deterministic emission budget and persisted projection`, async () => {
      const fixture = await loadFixture();
      const result = await replayTerminalCompletion(fixture[variant]);

      expect(result.budget).toEqual(expectedBudgets[variant]);
      expect(result.persisted?.status).toBe("completed");
      expect(result.persisted?.finalAnswer).toContain("Completed the investigation.");
      expect(result.persisted?.messages).toHaveLength(2);
      expect(result.persisted?.artifacts).toHaveLength(variant === "withArtifacts" ? 1 : 0);
      expect(result.reconnectSnapshot?.artifacts).toHaveLength(variant === "withArtifacts" ? 1 : 0);
    });
  }
});

async function replayTerminalCompletion(events: RuntimeFixture[FixtureVariant]): Promise<{
  budget: ReplayBudget;
  persisted: PickyAgentSession | undefined;
  reconnectSnapshot: PickyAgentSession | undefined;
}> {
  const root = await mkdtemp(join(tmpdir(), "picky-terminal-completion-replay-"));
  try {
    const runtime = new TerminalReplayRuntime();
    const store = new SessionStore(root);
    const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => "terminal-session" });
    await supervisor.load();
    const session = await supervisor.create(context());
    const emissionRecorder = new SupervisorEmissionRecorder(supervisor);

    for (const { event } of events) runtime.emit(event);

    const expectsArtifacts = events.some(({ event }) => event.type === "status" && event.finalAnswer?.includes("https://"));
    await waitUntil(() => {
      const current = supervisor.get(session.id);
      return current?.status === "completed"
        && Boolean(current.finalAnswer)
        && (current.messages ?? []).length === 2
        && current.artifacts.length === (expectsArtifacts ? 1 : 0)
        && emissionRecorder.count("sessionMeta") === 1
        && emissionRecorder.count("artifact") === (expectsArtifacts ? 1 : 0);
    });

    const reconnectSupervisor = new SessionSupervisor(new TerminalReplayRuntime(), store);
    await reconnectSupervisor.load();
    return {
      budget: emissionRecorder.budget(),
      persisted: (await store.loadAll()).find((candidate) => candidate.id === session.id),
      reconnectSnapshot: reconnectSupervisor.list().find((candidate) => candidate.id === session.id),
    };
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

async function loadFixture(): Promise<RuntimeFixture> {
  const data = await readFile(new URL("../../../contracts/perf/terminal-completion.runtime.json", import.meta.url), "utf8");
  return JSON.parse(data) as RuntimeFixture;
}

function context(): PickyContextPacket {
  return {
    id: "terminal-replay-context",
    source: "text",
    capturedAt: "2026-08-24T13:06:19.000Z",
    transcript: "Capture the terminal completion baseline.",
    cwd: "/tmp/picky-terminal-replay",
    screenshots: [],
    inkMarks: [],
    warnings: [],
  };
}

class SupervisorEmissionRecorder {
  private readonly counts = Object.fromEntries(emittedEventTypes.map((type) => [type, 0])) as Record<EmittedEventType, number>;
  private totalEncodedEventBytes = 0;
  private maxEncodedEventBytes = 0;

  constructor(supervisor: SessionSupervisor) {
    for (const type of emittedEventTypes) {
      supervisor.on(type, (...args: unknown[]) => this.record(type, args));
    }
  }

  count(type: EmittedEventType): number {
    return this.counts[type];
  }

  budget(): ReplayBudget {
    return {
      counts: { ...this.counts },
      totalEncodedEventBytes: this.totalEncodedEventBytes,
      maxEncodedEventBytes: this.maxEncodedEventBytes,
    };
  }

  private record(type: EmittedEventType, args: unknown[]): void {
    this.counts[type] += 1;
    const encodedBytes = Buffer.byteLength(JSON.stringify({ type, args }), "utf8");
    this.totalEncodedEventBytes += encodedBytes;
    this.maxEncodedEventBytes = Math.max(this.maxEncodedEventBytes, encodedBytes);
  }
}

class TerminalReplayRuntime implements AgentRuntime {
  private listeners = new Set<(event: RuntimeEvent) => void>();

  async create(_prompt: unknown, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    return new TerminalReplayHandle(options.sessionId ?? "terminal-session", this.listeners);
  }

  emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

class TerminalReplayHandle implements RuntimeSessionHandle {
  constructor(readonly id: string, private readonly listeners: Set<(event: RuntimeEvent) => void>) {}

  async followUp(): Promise<void> {}
  async steer(): Promise<{ handledSynchronously: boolean }> { return { handledSynchronously: false }; }
  async abort(): Promise<void> {}
  clearQueue(): { steering: string[]; followUp: string[] } { return { steering: [], followUp: [] }; }
  getSteeringMessages(): readonly string[] { return []; }
  getFollowUpMessages(): readonly string[] { return []; }
  steeringMode: "one-at-a-time" = "one-at-a-time";
  followUpMode: "one-at-a-time" = "one-at-a-time";
  isStreaming = false;
  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for terminal replay to settle");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
