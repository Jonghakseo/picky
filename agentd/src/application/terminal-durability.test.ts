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
  messageBuilder: { terminalSnapshot(sessionId: string): { journal: readonly { kind: string; text?: string }[] } };
  runtimeEventHandler: { terminalSnapshot(sessionId: string): { assistantDraft: string } };
  applyQueueUpdateWithModes(sessionId: string, steering: readonly string[], followUp: readonly string[], steeringMode: "one-at-a-time", followUpMode: "one-at-a-time"): Promise<void>;
};

/** W5.1 characterization tests: these pins intentionally describe the unsafe v1 terminal path. */
describe("terminal durability characterization", () => {
  it("TODAY leaks staged message-builder state when the terminal status save fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-terminal-durability-"));
    try {
      const store = new SessionStore(root);
      const supervisor = new SessionSupervisor(new ManualRuntime(), store, { sessionIdFactory: () => "durability-session" });
      await supervisor.load();
      const session = await supervisor.create(context);
      const internals = supervisor as unknown as SupervisorInternals;
      const frames: unknown[] = [];
      supervisor.on("sessionMeta", (frame) => frames.push(frame));

      await internals.applyRuntimeEvent(session.id, { type: "assistant_delta", delta: "draft answer" });
      vi.spyOn(store, "save").mockRejectedValueOnce(new Error("disk full"));

      // TODO(W5.4): one staged terminal operation must leave all these values unchanged on
      // failure. v1 flushes the message builder before the terminal session patch commits.
      await expect(internals.applyRuntimeEvent(session.id, {
        type: "status",
        status: "completed",
        finalAnswer: "draft answer",
      })).rejects.toThrow("disk full");

      expect(supervisor.get(session.id)).toMatchObject({ status: "running", revision: session.revision });
      expect((await store.loadAll()).find((candidate) => candidate.id === session.id)).toMatchObject({ status: "running", revision: session.revision });
      expect(frames).toEqual([]);
      expect(internals.messageBuilder.terminalSnapshot(session.id).journal).toMatchObject([{ kind: "agent_text", text: "draft answer" }]);
      expect(internals.runtimeEventHandler.terminalSnapshot(session.id).assistantDraft).toBe("draft answer");
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
