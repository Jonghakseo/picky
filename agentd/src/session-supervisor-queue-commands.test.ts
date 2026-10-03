import { mkdtemp, readFile, writeFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import type { BuiltPrompt } from "./prompt-builder.js";
import type { PickyContextPacket } from "./protocol.js";
import type { AgentRuntime, RuntimeEvent, RuntimeExtensionCommandResult, RuntimeExtensionToolResult, RuntimeSessionHandle } from "./runtime/types.js";
import { SessionQueueCommandError } from "./domain/session-queue-commands.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

const context = (text: string): PickyContextPacket => ({
  id: `context-${text}`,
  source: "text",
  capturedAt: "2026-05-01T00:00:00.000Z",
  transcript: text,
  cwd: "/tmp/project",
  screenshots: [],
  inkMarks: [],
  warnings: [],
});

interface PersistedTask { id: string; prompt: string; createdAt: number; dueAt: number }

/**
 * Runtime double that mirrors the parts of Pi this feature depends on: an index-addressable
 * queue and a delayed-action extension that persists its schedule to the store file Picky
 * projects. Everything else is the real supervisor.
 */
class QueueHandle implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  steering: string[] = [];
  followUpQueue: string[] = [];
  isStreaming = false;
  steeringMode = "one-at-a-time" as const;
  followUpMode = "one-at-a-time" as const;
  delayedActionInstalled = true;
  scheduleCalls: Array<{ delay: string; prompt: string; id?: string }> = [];
  cancelCalls: string[] = [];
  /** Makes the extension's tool reject for one prompt, like an invalid duration or a taken id. */
  rejectScheduleFor: string | undefined;
  /** Reports the cancel as done without removing the task, like a store write that never lands. */
  ignoreCancels = false;
  /** Makes `steer` reject for one text, like Pi refusing the prompt. */
  rejectSteerFor: string | undefined;
  /** Runs just before a cancel reaches the extension: lets a test fire the timer in that window. */
  beforeCancel: (() => Promise<void>) | undefined;
  private nextDelayId = 1;

  constructor(readonly id: string, readonly storeDir: string) {}

  async followUp(prompt: BuiltPrompt): Promise<void> {
    if (!this.isStreaming) return;
    this.followUpQueue.push(prompt.text);
    this.emitQueueUpdate();
  }
  async steer(prompt: BuiltPrompt): Promise<{ handledSynchronously: boolean }> {
    if (prompt.text.includes(this.rejectSteerFor ?? "\u0000")) throw new Error(`steer rejected: ${this.rejectSteerFor}`);
    if (this.isStreaming) {
      this.steering.push(prompt.text);
      this.emitQueueUpdate();
    }
    return { handledSynchronously: false };
  }
  async abort(): Promise<void> { /* no agent run in these tests */ }
  clearQueue(): { steering: string[]; followUp: string[] } {
    const cleared = { steering: [...this.steering], followUp: [...this.followUpQueue] };
    this.steering = [];
    this.followUpQueue = [];
    this.emitQueueUpdate();
    return cleared;
  }
  getSteeringMessages(): readonly string[] { return this.steering; }
  getFollowUpMessages(): readonly string[] { return this.followUpQueue; }
  getPiSessionId(): string { return `pi-${this.id}`; }

  removeQueuedMessage(kind: "steering" | "followUp", index: number): boolean {
    const queue = kind === "steering" ? this.steering : this.followUpQueue;
    if (index < 0 || index >= queue.length) return false;
    queue.splice(index, 1);
    this.emitQueueUpdate();
    return true;
  }
  replaceQueuedFollowUpText(index: number, text: string): boolean {
    if (index < 0 || index >= this.followUpQueue.length) return false;
    this.followUpQueue[index] = text;
    this.emitQueueUpdate();
    return true;
  }
  moveFollowUpToSteering(index: number): boolean {
    if (index < 0 || index >= this.followUpQueue.length) return false;
    const [text] = this.followUpQueue.splice(index, 1);
    this.steering.push(text!);
    this.emitQueueUpdate();
    return true;
  }

  hasExtensionTool(name: string): boolean { return this.delayedActionInstalled && name === "delay"; }
  hasExtensionCommand(name: string): boolean { return this.delayedActionInstalled && name === "delay-cancel"; }

  async runExtensionToolSilently(name: string, params: Record<string, unknown>): Promise<RuntimeExtensionToolResult> {
    expect(name).toBe("delay");
    const delay = String(params.delay);
    const prompt = String(params.prompt);
    if (prompt === this.rejectScheduleFor) throw new Error(`delay rejected: ${prompt}`);
    const id = params.id === undefined ? `delay-${this.nextDelayId++}` : String(params.id);
    this.scheduleCalls.push({ delay, prompt, ...(params.id === undefined ? {} : { id }) });
    const delayMs = Number(delay.replace(/s$/, "")) * 1000;
    const tasks = await this.readStore();
    tasks.push({ id, prompt, createdAt: 1_000, dueAt: 1_000 + delayMs });
    await this.writeStore(tasks);
    return { isError: false, text: `scheduled ${id}` };
  }

  /** Mirrors the extension, which answers a cancel only through `ctx.ui.notify`. */
  async runExtensionCommandSilently(name: string, args: string): Promise<RuntimeExtensionCommandResult> {
    expect(name).toBe("delay-cancel");
    await this.beforeCancel?.();
    this.cancelCalls.push(args);
    if (this.ignoreCancels) return { notifications: [`\u2713 ${args} \uc608\uc57d\uc744 \ucde8\uc18c\ud588\uc5b4\uc694.`] };
    const tasks = await this.readStore();
    if (!tasks.some((task) => task.id === args)) {
      return { notifications: [`\uc608\uc57d\uc744 \ucc3e\uc744 \uc218 \uc5c6\uc5b4\uc694: ${args}`] };
    }
    await this.writeStore(tasks.filter((task) => task.id !== args));
    return { notifications: [`\u2713 ${args} \uc608\uc57d\uc744 \ucde8\uc18c\ud588\uc5b4\uc694.`] };
  }

  private storePath(): string { return join(this.storeDir, `${this.getPiSessionId()}.json`); }
  private async readStore(): Promise<PersistedTask[]> {
    try {
      return JSON.parse(await readFile(this.storePath(), "utf8")).tasks as PersistedTask[];
    } catch {
      return [];
    }
  }
  private async writeStore(tasks: PersistedTask[]): Promise<void> {
    if (tasks.length === 0) {
      await unlink(this.storePath()).catch(() => undefined);
      return;
    }
    await writeFile(this.storePath(), JSON.stringify({ version: 1, sessionId: this.getPiSessionId(), tasks }), "utf8");
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  emit(event: RuntimeEvent): void { for (const listener of this.listeners) listener(event); }
  emitQueueUpdate(): void { this.emit({ type: "queue_update", steering: [...this.steering], followUp: [...this.followUpQueue] }); }
}

class QueueRuntime implements AgentRuntime {
  handle?: QueueHandle;
  constructor(private readonly storeDir: string) {}
  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new QueueHandle(options.sessionId ?? "manual", this.storeDir);
    return this.handle;
  }
}

async function supervisorWithQueuedFollowUps(texts: readonly string[]): Promise<{ supervisor: SessionSupervisor; handle: QueueHandle; sessionId: string; storeDir: string }> {
  const storeDir = await mkdtemp(join(tmpdir(), "picky-queue-command-store-"));
  const stateDir = await mkdtemp(join(tmpdir(), "picky-queue-command-state-"));
  const runtime = new QueueRuntime(storeDir);
  const supervisor = new SessionSupervisor(runtime, new SessionStore(stateDir), {
    scheduledMessageProjector: { dir: () => storeDir, watchDir: () => () => undefined },
  });
  await supervisor.load();
  const session = await supervisor.create(context("initial"));
  const handle = runtime.handle!;
  handle.isStreaming = true;
  // Wait on the count, not on the text: two identical follow-ups are a case these tests cover.
  for (const [index, text] of texts.entries()) {
    await supervisor.followUp(session.id, text);
    await vi.waitFor(() => expect(supervisor.get(session.id)?.queuedFollowUps?.length).toBe(index + 1));
  }
  return { supervisor, handle, sessionId: session.id, storeDir };
}

function userTexts(supervisor: SessionSupervisor, sessionId: string): string[] {
  return (supervisor.get(sessionId)?.messages ?? []).filter((message) => message.kind === "user_text").map((message) => message.text ?? "");
}

describe("per-item queue commands", () => {
  it("removes one queued follow-up and never journals it as a sent message", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps(["keep me", "drop me"]);
    const target = supervisor.get(sessionId)!.queuedFollowUps!.find((item) => item.text === "drop me")!;

    await supervisor.removeQueuedInput(sessionId, target.id!);

    expect(supervisor.get(sessionId)?.queuedFollowUps?.map((item) => item.text)).toEqual(["keep me"]);
    // Pi now consumes what is left; the discarded entry must not resurface as a user bubble.
    handle.followUpQueue = [];
    handle.emitQueueUpdate();
    await vi.waitFor(() => expect(userTexts(supervisor, sessionId)).toContain("keep me"));
    expect(userTexts(supervisor, sessionId)).not.toContain("drop me");
  });

  it("reports queueItemNotFound when the agent already drained the entry", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps(["already gone"]);
    const target = supervisor.get(sessionId)!.queuedFollowUps![0]!;
    // Pi drains the queue, but the app still holds the row the user clicked.
    handle.followUpQueue = [];

    await expect(supervisor.removeQueuedInput(sessionId, target.id!)).rejects.toMatchObject({ code: "queueItemNotFound" });
    await expect(supervisor.removeQueuedInput(sessionId, target.id!)).rejects.toBeInstanceOf(SessionQueueCommandError);
  });

  it("edits a queued follow-up in place and journals the edited text when it is delivered", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps(["original text"]);
    const target = supervisor.get(sessionId)!.queuedFollowUps![0]!;

    await supervisor.editQueuedFollowUp(sessionId, target.id!, "edited text");

    const edited = supervisor.get(sessionId)!.queuedFollowUps![0]!;
    expect(edited.text).toBe("edited text");
    expect(edited.id).toBe(target.id);
    // Rewriting the entry is not a delivery: the message is still waiting in Pi's queue.
    expect(userTexts(supervisor, sessionId)).toEqual([]);
    handle.followUpQueue = [];
    handle.emitQueueUpdate();
    await vi.waitFor(() => expect(userTexts(supervisor, sessionId)).toEqual(["edited text"]));
  });

  // Two queued messages reading the same thing is ordinary ("continue", "ok"). Reconciling the
  // queue by text then mistakes the untouched twin for a delivered message and journals it.
  it("edits the second of two identical follow-ups without journaling the first", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps(["continue", "continue"]);
    const [first, second] = supervisor.get(sessionId)!.queuedFollowUps!;

    await supervisor.editQueuedFollowUp(sessionId, second!.id!, "continue with the deploy");

    expect(userTexts(supervisor, sessionId)).toEqual([]);
    const queued = supervisor.get(sessionId)!.queuedFollowUps!;
    expect(queued.map((item) => item.text)).toEqual(["continue", "continue with the deploy"]);
    expect(queued.map((item) => item.id)).toEqual([first!.id, second!.id]);

    // The row the user did not touch must still be the one a later delete removes.
    await supervisor.removeQueuedInput(sessionId, first!.id!);
    expect(supervisor.get(sessionId)!.queuedFollowUps!.map((item) => item.text)).toEqual(["continue with the deploy"]);
    expect(userTexts(supervisor, sessionId)).toEqual([]);
  });

  it("promotes the second of two identical follow-ups without journaling the first", async () => {
    const { supervisor, sessionId } = await supervisorWithQueuedFollowUps(["continue", "continue"]);
    const [first, second] = supervisor.get(sessionId)!.queuedFollowUps!;

    await supervisor.sendQueuedFollowUpNow(sessionId, second!.id!);

    expect(userTexts(supervisor, sessionId)).toEqual([]);
    expect(supervisor.get(sessionId)!.queuedSteers!.map((item) => item.id)).toEqual([second!.id]);
    expect(supervisor.get(sessionId)!.queuedFollowUps!.map((item) => item.id)).toEqual([first!.id]);
  });

  it("promotes a queued follow-up to steering and materializes it exactly once", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps(["answer now"]);
    const target = supervisor.get(sessionId)!.queuedFollowUps![0]!;

    await supervisor.sendQueuedFollowUpNow(sessionId, target.id!);

    expect(supervisor.get(sessionId)?.queuedFollowUps).toEqual([]);
    expect(supervisor.get(sessionId)?.queuedSteers?.map((item) => item.text)).toEqual(["answer now"]);
    // Moving between queues is not a delivery either.
    expect(userTexts(supervisor, sessionId)).toEqual([]);
    handle.steering = [];
    handle.emitQueueUpdate();
    await vi.waitFor(() => expect(userTexts(supervisor, sessionId)).toEqual(["answer now"]));
    expect(userTexts(supervisor, sessionId)).toEqual(["answer now"]);
  });
});

describe("scheduled message commands", () => {
  it("projects the delayed-action schedule after scheduling and cancelling", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);

    await supervisor.scheduleMessage(sessionId, "check the deploy", 300_000);

    expect(handle.scheduleCalls).toEqual([{ delay: "300s", prompt: "check the deploy" }]);
    const scheduled = supervisor.get(sessionId)!.scheduledMessages!;
    expect(scheduled.map((message) => message.text)).toEqual(["check the deploy"]);

    await supervisor.cancelScheduledMessage(sessionId, scheduled[0]!.id);

    expect(handle.cancelCalls).toEqual([scheduled[0]!.id]);
    expect(supervisor.get(sessionId)?.scheduledMessages).toEqual([]);
  });

  it("keeps the original due time and id when the text is edited", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "first draft", 600_000);
    const original = supervisor.get(sessionId)!.scheduledMessages![0]!;
    const remainingSeconds = Math.max(1, Math.round((Date.parse(original.dueAt) - Date.now()) / 1000));

    await supervisor.editScheduledMessage(sessionId, original.id, "second draft");

    expect(handle.cancelCalls).toEqual([original.id]);
    expect(handle.scheduleCalls.at(-1)).toMatchObject({ prompt: "second draft", id: original.id });
    // Re-scheduled with the time that was left, not the original delay.
    const rescheduledSeconds = Number(handle.scheduleCalls.at(-1)!.delay.replace(/s$/, ""));
    expect(Math.abs(rescheduledSeconds - remainingSeconds)).toBeLessThanOrEqual(2);
    expect(supervisor.get(sessionId)?.scheduledMessages?.map((message) => ({ id: message.id, text: message.text })))
      .toEqual([{ id: original.id, text: "second draft" }]);
  });

  it("sending a scheduled message now cancels the schedule and delivers it like a composer send", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "ship it", 600_000);
    const scheduled = supervisor.get(sessionId)!.scheduledMessages![0]!;
    handle.isStreaming = true;

    await supervisor.sendScheduledMessageNow(sessionId, scheduled.id);

    expect(handle.cancelCalls).toEqual([scheduled.id]);
    expect(supervisor.get(sessionId)?.scheduledMessages).toEqual([]);
    expect(supervisor.get(sessionId)?.queuedSteers?.map((item) => item.text)).toEqual(["ship it"]);
  });

  it("keeps the original scheduled message when the re-schedule of an edit fails", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "first draft", 600_000);
    const original = supervisor.get(sessionId)!.scheduledMessages![0]!;
    handle.rejectScheduleFor = "second draft";

    await expect(supervisor.editScheduledMessage(sessionId, original.id, "second draft")).rejects.toThrow(/delay rejected/);

    expect(supervisor.get(sessionId)?.scheduledMessages?.map((message) => ({ id: message.id, text: message.text })))
      .toEqual([{ id: original.id, text: "first draft" }]);
  });

  it("refuses to send a scheduled message that already fired", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "ship it", 600_000);
    const scheduled = supervisor.get(sessionId)!.scheduledMessages![0]!;
    handle.isStreaming = true;
    // The extension fired and removed it while the HUD still showed the row.
    await unlink(join(handle.storeDir, `${handle.getPiSessionId()}.json`));

    await expect(supervisor.sendScheduledMessageNow(sessionId, scheduled.id)).rejects.toMatchObject({ code: "queueItemNotFound" });

    expect(handle.cancelCalls).toEqual([]);
    expect(supervisor.get(sessionId)?.queuedSteers ?? []).toEqual([]);
  });

  it("does not send when the cancel leaves the schedule in place", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "ship it", 600_000);
    const scheduled = supervisor.get(sessionId)!.scheduledMessages![0]!;
    handle.isStreaming = true;
    handle.ignoreCancels = true;

    await expect(supervisor.sendScheduledMessageNow(sessionId, scheduled.id)).rejects.toThrow(/Cancelling the scheduled message failed/);

    expect(supervisor.get(sessionId)?.queuedSteers ?? []).toEqual([]);
    expect(supervisor.get(sessionId)?.scheduledMessages?.map((message) => message.id)).toEqual([scheduled.id]);
  });

  /**
   * The timer can fire between the row being read and the cancel reaching the extension. The
   * message is delivered at that point, so re-scheduling it would send it a second time.
   */
  it("does not re-schedule an edit whose message fired while the cancel was in flight", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "first draft", 600_000);
    const original = supervisor.get(sessionId)!.scheduledMessages![0]!;
    const scheduleCallsBefore = handle.scheduleCalls.length;
    handle.beforeCancel = async () => { await unlink(join(handle.storeDir, `${handle.getPiSessionId()}.json`)); };

    await expect(supervisor.editScheduledMessage(sessionId, original.id, "second draft")).rejects.toMatchObject({ code: "queueItemNotFound" });

    expect(handle.scheduleCalls.length).toBe(scheduleCallsBefore);
    expect(supervisor.get(sessionId)?.scheduledMessages ?? []).toEqual([]);
  });

  it("does not send a scheduled message that fired while the cancel was in flight", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "ship it", 600_000);
    const scheduled = supervisor.get(sessionId)!.scheduledMessages![0]!;
    handle.isStreaming = true;
    handle.beforeCancel = async () => { await unlink(join(handle.storeDir, `${handle.getPiSessionId()}.json`)); };

    await expect(supervisor.sendScheduledMessageNow(sessionId, scheduled.id)).rejects.toMatchObject({ code: "queueItemNotFound" });

    expect(supervisor.get(sessionId)?.queuedSteers ?? []).toEqual([]);
  });

  /** The schedule is already cancelled when the send runs, so a failed send must put it back. */
  it("restores the schedule when sending it now fails", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "ship it", 600_000);
    const scheduled = supervisor.get(sessionId)!.scheduledMessages![0]!;
    handle.isStreaming = true;
    handle.rejectSteerFor = "ship it";

    await expect(supervisor.sendScheduledMessageNow(sessionId, scheduled.id)).rejects.toThrow(/steer rejected/);

    expect(supervisor.get(sessionId)?.scheduledMessages?.map((message) => ({ id: message.id, text: message.text })))
      .toEqual([{ id: scheduled.id, text: "ship it" }]);
  });

  it("reports the message text when a failed edit cannot be rolled back either", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    await supervisor.scheduleMessage(sessionId, "first draft", 600_000);
    const original = supervisor.get(sessionId)!.scheduledMessages![0]!;
    // Neither the edit nor the restore can be scheduled.
    handle.rejectScheduleFor = undefined;
    const originalRunTool = handle.runExtensionToolSilently.bind(handle);
    handle.runExtensionToolSilently = async () => { throw new Error("delay rejected"); };

    await expect(supervisor.editScheduledMessage(sessionId, original.id, "second draft"))
      .rejects.toThrow('could not be restored either: "first draft"');

    handle.runExtensionToolSilently = originalRunTool;
  });

  it("reports delayedActionUnavailable when the plugin is not installed", async () => {
    const { supervisor, handle, sessionId } = await supervisorWithQueuedFollowUps([]);
    handle.delayedActionInstalled = false;

    await expect(supervisor.scheduleMessage(sessionId, "later", 60_000)).rejects.toMatchObject({ code: "delayedActionUnavailable" });
    expect(handle.scheduleCalls).toEqual([]);
  });
});
