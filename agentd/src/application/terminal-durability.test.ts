import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import type { PickyAgentSession, PickyContextPacket } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import type { AgentRuntime, RuntimeEvent, RuntimeSessionHandle } from "../runtime/types.js";

const context: PickyContextPacket = {
  id: "terminal-durability-context",
  source: "text",
  capturedAt: "2026-08-24T13:06:19.000Z",
  transcript: "Characterize terminal durability before W5.4.",
  cwd: "/tmp/picky-terminal-durability",
  screenshots: [],
  inkMarks: [],
  warnings: [],
};

type SupervisorInternals = {
  applyRuntimeEvent(sessionId: string, event: RuntimeEvent): Promise<void>;
  messageBuilder: {
    terminalSnapshot(sessionId: string): { journal: readonly { kind: string; text?: string }[] };
    appendThinkingDelta(sessionId: string, delta: string): Promise<void>;
    runOperation(sessionId: string, operation: () => Promise<void>): Promise<void>;
    states: Map<string, unknown>;
    operationChains: Map<string, Promise<void>>;
  };
  runtimeEventHandler: {
    terminalSnapshot(sessionId: string): unknown;
    assistantDrafts: Map<string, string>;
    thinkingDrafts: Map<string, string>;
    thinkingActive: Map<string, boolean>;
    pendingThinkingFlushes: Map<string, unknown>;
    activeThinkingFlushes: Map<string, Promise<void>>;
    processedTerminalRuns: Set<string>;
    seenToolCallIds: Map<string, Set<string>>;
    manualTerminalCompactionStatuses: Map<string, string>;
  };
  turnActivity: Map<string, unknown>;
  patchChains: { has(key: string): boolean };
  emitChains: Map<string, Promise<void>>;
  sessionSeq: Map<string, number>;
  pickleCompletionNotified: Set<string>;
  pickleCompletionInFlight: Set<string>;
  pendingPickleCompletions: string[];
  applyQueueUpdateWithModes(sessionId: string, steering: readonly string[], followUp: readonly string[], steeringMode: "one-at-a-time", followUpMode: "one-at-a-time"): Promise<void>;
};

/** W5.4–W5.5 terminal transaction contracts. */
describe("terminal durability", () => {
  it("leaves every terminal transient untouched when the one staged save fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-durability-"));
    try {
      const store = new SessionStore(root);
      const notifications: string[] = [];
      const supervisor = new SessionSupervisor(new ManualRuntime(), store, {
        sessionIdFactory: () => "durability-session",
        forwardPickleCompletionToPrimary: async ({ sessionId }) => { notifications.push(sessionId); },
      });
      await supervisor.load();
      const session = await supervisor.create(context);
      (supervisor as unknown as { pickleSessionIds: Set<string> }).pickleSessionIds.add(session.id);
      const internals = supervisor as unknown as SupervisorInternals;
      const frames: unknown[] = [];
      supervisor.on("sessionMeta", (frame) => frames.push(frame));

      await internals.applyRuntimeEvent(session.id, { type: "assistant_delta", delta: "draft answer" });
      await internals.messageBuilder.runOperation(session.id, async () => {});
      const transientsBefore = transientSnapshot(internals, session.id);
      vi.spyOn(store, "save").mockRejectedValueOnce(new Error("disk full"));

      await expect(internals.applyRuntimeEvent(session.id, {
        type: "status",
        status: "completed",
        finalAnswer: "draft answer",
      })).rejects.toThrow("disk full");

      expect(store.save).toHaveBeenCalledTimes(1);
      expect(supervisor.get(session.id)).toMatchObject({ status: "running", revision: session.revision });
      expect((await store.loadAll()).find((candidate) => candidate.id === session.id)).toMatchObject({ status: "running", revision: session.revision });
      expect(frames).toEqual([]);
      expect(notifications).toEqual([]);
      expect(transientSnapshot(internals, session.id)).toEqual(transientsBefore);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps the committed terminal projection when completion notification delivery fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-notification-failure-"));
    try {
      const store = new SessionStore(root);
      const notifications: string[] = [];
      const supervisor = new SessionSupervisor(new ManualRuntime(), store, {
        sessionIdFactory: () => "notification-failure-session",
        forwardPickleCompletionToPrimary: async ({ sessionId }) => {
          notifications.push(sessionId);
          throw new Error("bridge unavailable");
        },
      });
      await supervisor.load();
      const session = await supervisor.create(context);
      (supervisor as unknown as { pickleSessionIds: Set<string> }).pickleSessionIds.add(session.id);
      const internals = supervisor as unknown as SupervisorInternals;

      await internals.applyRuntimeEvent(session.id, { type: "assistant_delta", delta: "committed answer" });
      await internals.applyRuntimeEvent(session.id, { type: "status", status: "completed", finalAnswer: "committed answer" });

      expect(notifications).toEqual([session.id]);
      expect(supervisor.get(session.id)).toMatchObject({ status: "completed", finalAnswer: "committed answer", revision: (session.revision ?? 0) + 1 });
      expect((await store.loadAll()).find((candidate) => candidate.id === session.id)).toMatchObject({ status: "completed", finalAnswer: "committed answer" });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("persists a successful terminal status exactly once with one revision increment", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-save-once-"));
    try {
      const store = new SessionStore(root);
      const supervisor = new SessionSupervisor(new ManualRuntime(), store, { sessionIdFactory: () => "save-once-session" });
      await supervisor.load();
      const session = await supervisor.create(context);
      const internals = supervisor as unknown as SupervisorInternals;
      const save = vi.spyOn(store, "save");

      await internals.applyRuntimeEvent(session.id, { type: "assistant_delta", delta: "durable answer" });
      await internals.applyRuntimeEvent(session.id, { type: "status", status: "completed", finalAnswer: "durable answer" });

      expect(save).toHaveBeenCalledTimes(1);
      expect(supervisor.get(session.id)).toMatchObject({ status: "completed", revision: (session.revision ?? 0) + 1 });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("queues a thinking journal operation behind a terminal save so it cannot restore a stale journal", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-message-race-"));
    try {
      const store = new SessionStore(root);
      const supervisor = new SessionSupervisor(new ManualRuntime(), store, { sessionIdFactory: () => "message-race-session" });
      await supervisor.load();
      const session = await supervisor.create(context);
      const internals = supervisor as unknown as SupervisorInternals;
      const saved: PickyAgentSession[] = [];
      let releaseTerminalSave: (() => void) | undefined;
      let holdFirstTerminalSave = true;
      const terminalSaveStarted = new Promise<void>((resolve) => {
        vi.spyOn(store, "save").mockImplementation(async (candidate) => {
          saved.push(structuredClone(candidate));
          if (candidate.status !== "completed" || !holdFirstTerminalSave) return;
          holdFirstTerminalSave = false;
          resolve();
          await new Promise<void>((release) => { releaseTerminalSave = release; });
        });
      });

      await internals.applyRuntimeEvent(session.id, { type: "assistant_delta", delta: "terminal answer" });
      const terminal = internals.applyRuntimeEvent(session.id, { type: "status", status: "completed", finalAnswer: "terminal answer" });
      await terminalSaveStarted;
      const thinkingFlush = internals.messageBuilder.appendThinkingDelta(session.id, "late thinking");
      releaseTerminalSave?.();
      await Promise.all([terminal, thinkingFlush]);

      expect(saved).toHaveLength(2);
      expect(saved[0]?.messages).toMatchObject([{ kind: "agent_text", text: "terminal answer" }]);
      expect(saved[1]?.messages).toMatchObject([
        { kind: "agent_text", text: "terminal answer" },
        { kind: "agent_thinking", text: "late thinking" },
      ]);
      expect(supervisor.get(session.id)?.messages).toMatchObject([
        { kind: "agent_text", text: "terminal answer" },
        { kind: "agent_thinking", text: "late thinking" },
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("serializes concurrent follow-up, archive, and queue writes after the terminal save", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-serialization-"));
    try {
      const store = new SessionStore(root);
      const runtime = new ManualRuntime();
      const supervisor = new SessionSupervisor(runtime, store, { sessionIdFactory: () => "serialization-session" });
      await supervisor.load();
      const session = await supervisor.create(context);
      const internals = supervisor as unknown as SupervisorInternals;
      const saved: PickyAgentSession[] = [];
      let releaseTerminalSave: (() => void) | undefined;
      let holdFirstTerminalSave = true;
      const terminalSaveStarted = new Promise<void>((resolve) => {
        vi.spyOn(store, "save").mockImplementation(async (candidate) => {
          saved.push(structuredClone(candidate));
          if (candidate.status === "completed" && holdFirstTerminalSave) {
            holdFirstTerminalSave = false;
            resolve();
            await new Promise<void>((release) => { releaseTerminalSave = release; });
          }
        });
      });

      const terminal = internals.applyRuntimeEvent(session.id, {
        type: "status",
        status: "completed",
        finalAnswer: "terminal answer",
      });
      await terminalSaveStarted;
      const followUp = supervisor.followUp(session.id, "follow-up after terminal", context);
      const archive = supervisor.setSessionArchived(session.id, true);
      const queue = internals.applyQueueUpdateWithModes(session.id, ["queued steer"], ["queued follow-up"], "one-at-a-time", "one-at-a-time");
      releaseTerminalSave?.();
      await Promise.all([terminal, followUp, archive, queue]);

      expect(saved[0]?.revision).toBe((session.revision ?? 0) + 1);
      // The held terminal commit saw none of the concurrent command state. Each later write is
      // serialized on the supervisor chain and therefore cannot be absorbed into its snapshot.
      expect(saved[0]).toMatchObject({ status: "completed", finalAnswer: "terminal answer", queuedSteers: [] });
      expect(saved[0]?.archived).toBeUndefined();
      expect(supervisor.get(session.id)).toMatchObject({
        status: "running",
        archived: true,
        queuedSteers: [expect.objectContaining({ text: "queued steer" })],
        queuedFollowUps: [expect.objectContaining({ text: "queued follow-up" })],
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("persists only complete JSON at the atomic-rename boundary", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-rename-"));
    try {
      const store = new SessionStore(root);
      const initial = makeSession("rename-session", "running");
      const completed = { ...initial, status: "completed" as const, revision: 1, updatedAt: "2026-08-24T13:06:20.000Z" };
      await store.save(initial);
      await store.save(completed);

      const files = await readdir(join(root, "sessions"));
      expect(files).toEqual(["rename-session.json"]);
      expect(JSON.parse(await readFile(join(root, "sessions", "rename-session.json"), "utf8"))).toMatchObject(completed);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

function transientSnapshot(internals: SupervisorInternals, sessionId: string): unknown {
  return {
    messageBuilder: {
      state: internals.messageBuilder.terminalSnapshot(sessionId),
      operationChainPending: internals.messageBuilder.operationChains.has(sessionId),
    },
    runtimeEventHandler: {
      terminal: internals.runtimeEventHandler.terminalSnapshot(sessionId),
      assistantDraft: internals.runtimeEventHandler.assistantDrafts.get(sessionId),
      thinkingDraft: internals.runtimeEventHandler.thinkingDrafts.get(sessionId),
      thinkingActive: internals.runtimeEventHandler.thinkingActive.get(sessionId),
      pendingThinkingFlush: internals.runtimeEventHandler.pendingThinkingFlushes.get(sessionId),
      activeThinkingFlushPending: internals.runtimeEventHandler.activeThinkingFlushes.has(sessionId),
      processedTerminalRun: internals.runtimeEventHandler.processedTerminalRuns.has(sessionId),
      seenToolCallIds: [...(internals.runtimeEventHandler.seenToolCallIds.get(sessionId) ?? [])],
      manualTerminalCompactionStatus: internals.runtimeEventHandler.manualTerminalCompactionStatuses.get(sessionId),
    },
    supervisor: {
      turnActivity: internals.turnActivity.get(sessionId),
      patchChainPending: internals.patchChains.has(sessionId),
      emitChainPending: internals.emitChains.has(sessionId),
      sequence: internals.sessionSeq.get(sessionId),
      completionNotified: internals.pickleCompletionNotified.has(sessionId),
      completionInFlight: internals.pickleCompletionInFlight.has(sessionId),
      pendingCompletions: [...internals.pendingPickleCompletions],
    },
  };
}

function makeSession(id: string, status: "running" | "completed"): PickyAgentSession {
  return {
    id,
    revision: 0,
    title: "Terminal durability",
    status,
    createdAt: "2026-08-24T13:06:19.000Z",
    updatedAt: "2026-08-24T13:06:19.000Z",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    queuedSteers: [],
    queuedFollowUps: [],
  };
}

class ManualRuntime implements AgentRuntime {
  private handle?: ManualHandle;

  async create(_prompt: unknown, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new ManualHandle(options.sessionId ?? "durability-session");
    return this.handle;
  }

  setQueues(steering: string[], followUp: string[]): void {
    this.handle?.setQueues(steering, followUp);
  }
}

class ManualHandle implements RuntimeSessionHandle {
  private steering: string[] = [];
  private followUpQueue: string[] = [];

  constructor(readonly id: string) {}
  async followUp(): Promise<void> {}
  async steer(): Promise<{ handledSynchronously: boolean }> { return { handledSynchronously: false }; }
  async abort(): Promise<void> {}
  clearQueue(): { steering: string[]; followUp: string[] } {
    const queues = { steering: this.steering, followUp: this.followUpQueue };
    this.steering = [];
    this.followUpQueue = []; 
    return queues;
  }
  getSteeringMessages(): readonly string[] { return this.steering; }
  getFollowUpMessages(): readonly string[] { return this.followUpQueue; }
  setQueues(steering: string[], followUp: string[]): void {
    this.steering = [...steering];
    this.followUpQueue = [...followUp];
  }
  steeringMode: "one-at-a-time" = "one-at-a-time";
  followUpMode: "one-at-a-time" = "one-at-a-time";
  isStreaming = false;
  subscribe(_listener: (event: RuntimeEvent) => void): () => void { return () => {}; }
}
