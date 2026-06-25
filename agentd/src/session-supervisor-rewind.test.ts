import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { BuiltPrompt } from "./prompt-builder.js";
import type { PickyContextPacket } from "./protocol.js";
import type { AgentRuntime, RewindBranchMessage, RewindResult, RewindTarget, RuntimeEvent, RuntimeSessionHandle, RuntimeSteerResult } from "./runtime/types.js";
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

describe("SessionSupervisor rewind", () => {
  it("removes journal messages after the rewound active branch", async () => {
    const runtime = new RewindRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-rewind-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("seed"));
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Initial done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");

    await supervisor.followUp(session.id, "A");
    runtime.handle!.emit({ type: "assistant_delta", delta: "a" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "a" });
    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).some((message) => message.kind === "agent_text" && message.text === "a"));
    await supervisor.followUp(session.id, "B");
    runtime.handle!.emit({ type: "assistant_delta", delta: "b" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "b" });
    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).some((message) => message.kind === "agent_text" && message.text === "b"));

    const rewoundEvents: Array<{ editorText?: string; removedIds: string[] }> = [];
    supervisor.on("sessionRewound", (_sessionId, editorText, removedIds) => rewoundEvents.push({ editorText, removedIds }));
    runtime.handle!.rewindBranches.set("entry-b", [{ role: "user", text: "A" }, { role: "assistant", text: "a" }]);
    runtime.handle!.rewindEditorTexts.set("entry-b", "B");

    await supervisor.rewindToEntry(session.id, "entry-b");

    expect((supervisor.get(session.id)?.messages ?? []).map((message) => [message.kind, message.text])).toEqual([
      ["user_text", "A"],
      ["agent_text", "a"],
    ]);
    expect(rewoundEvents.at(-1)).toMatchObject({ editorText: "B" });
    expect(rewoundEvents.at(-1)?.removedIds).toHaveLength(2);

    runtime.handle!.rewindBranches.set("entry-a", []);
    runtime.handle!.rewindEditorTexts.set("entry-a", "A");
    await supervisor.rewindToEntry(session.id, "entry-a");

    expect(supervisor.get(session.id)?.messages ?? []).toEqual([]);
    expect(rewoundEvents.at(-1)).toMatchObject({ editorText: "A" });
  });

  it("reconciles when the Pi branch carries leading entries the journal never recorded", async () => {
    const runtime = new RewindRuntime();
    const dir = await mkdtemp(join(tmpdir(), "picky-agentd-rewind-test-"));
    const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
    await supervisor.load();
    const session = await supervisor.create(context("seed"));
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Initial done" });
    await waitUntil(() => supervisor.get(session.id)?.status === "completed");

    await supervisor.followUp(session.id, "A");
    runtime.handle!.emit({ type: "assistant_delta", delta: "a" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "a" });
    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).some((message) => message.kind === "agent_text" && message.text === "a"));
    await supervisor.followUp(session.id, "B");
    runtime.handle!.emit({ type: "assistant_delta", delta: "b" });
    runtime.handle!.emit({ type: "status", status: "completed", summary: "Completed", finalAnswer: "b" });
    await waitUntil(() => (supervisor.get(session.id)?.messages ?? []).some((message) => message.kind === "agent_text" && message.text === "b"));

    const rewoundEvents: Array<{ editorText?: string; removedIds: string[] }> = [];
    supervisor.on("sessionRewound", (_sessionId, editorText, removedIds) => rewoundEvents.push({ editorText, removedIds }));
    // The real Pi branch includes a kickoff/handoff entry the HUD journal never recorded. The
    // reconcile must anchor on the last branch message (assistant "a"), not require a 1:1 match.
    runtime.handle!.rewindBranches.set("entry-b", [
      { role: "user", text: "kickoff-not-in-journal" },
      { role: "user", text: "A" },
      { role: "assistant", text: "a" },
    ]);
    runtime.handle!.rewindEditorTexts.set("entry-b", "B");

    await supervisor.rewindToEntry(session.id, "entry-b");

    expect((supervisor.get(session.id)?.messages ?? []).map((message) => [message.kind, message.text])).toEqual([
      ["user_text", "A"],
      ["agent_text", "a"],
    ]);
    expect(rewoundEvents.at(-1)).toMatchObject({ editorText: "B" });
    expect(rewoundEvents.at(-1)?.removedIds).toHaveLength(2);
  });
});

class RewindRuntime implements AgentRuntime {
  handle?: RewindHandle;

  async create(_prompt: BuiltPrompt, options: { sessionId?: string }): Promise<RuntimeSessionHandle> {
    this.handle = new RewindHandle(options.sessionId ?? "rewind-session");
    return this.handle;
  }
}

class RewindHandle implements RuntimeSessionHandle {
  private listeners = new Set<(event: RuntimeEvent) => void>();
  rewindTargets: RewindTarget[] = [];
  rewindBranches = new Map<string, RewindBranchMessage[]>();
  rewindEditorTexts = new Map<string, string>();
  rewoundEntryIds: string[] = [];
  steeringMode = "one-at-a-time" as const;
  followUpMode = "one-at-a-time" as const;
  isStreaming = false;

  constructor(readonly id: string) {}

  async followUp(_prompt: BuiltPrompt): Promise<void> {}
  async steer(_prompt: BuiltPrompt): Promise<RuntimeSteerResult> { return { handledSynchronously: false }; }
  async abort(): Promise<void> {}
  clearQueue(): { steering: string[]; followUp: string[] } { return { steering: [], followUp: [] }; }
  getSteeringMessages(): readonly string[] { return []; }
  getFollowUpMessages(): readonly string[] { return []; }
  listRewindTargets(): RewindTarget[] { return this.rewindTargets; }
  async rewindToEntry(entryId: string): Promise<RewindResult> {
    this.rewoundEntryIds.push(entryId);
    return { editorText: this.rewindEditorTexts.get(entryId), cancelled: false };
  }
  getActiveBranchTranscript(): RewindBranchMessage[] {
    const entryId = this.rewoundEntryIds.at(-1);
    return entryId ? (this.rewindBranches.get(entryId) ?? []) : [];
  }
  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  emit(event: RuntimeEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
