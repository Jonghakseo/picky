import { mkdtemp, readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession, PickyContextPacket, PickySessionProjectionMutation } from "./protocol.js";
import type { BuiltPrompt } from "./prompt-builder.js";
import type { AgentRuntime, RuntimeCreateOptions, RuntimeEvent, RuntimeSessionHandle, RuntimeSteerResult } from "./runtime/types.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";

/**
 * Contract under test: the Pickle display name lives in Picky metadata only.
 * An explicit rename wins over Pi's auto-name, survives a daemon restart, works
 * while the owning daemon is gone, and never turns into Pi input or a model turn.
 */

class FakeHandle implements RuntimeSessionHandle {
  readonly followUps: BuiltPrompt[] = [];
  readonly steers: string[] = [];
  isStreaming = false;
  steeringMode = "one-at-a-time" as const;
  followUpMode = "one-at-a-time" as const;
  private readonly listeners = new Set<(event: RuntimeEvent) => void>();
  constructor(readonly id: string) {}
  async followUp(prompt: BuiltPrompt): Promise<void> { this.followUps.push(prompt); }
  async steer(prompt: BuiltPrompt): Promise<RuntimeSteerResult> { this.steers.push(prompt.text); return { handledSynchronously: false }; }
  async abort(): Promise<void> {}
  clearQueue(): { steering: string[]; followUp: string[] } { return { steering: [], followUp: [] }; }
  getSteeringMessages(): readonly string[] { return []; }
  getFollowUpMessages(): readonly string[] { return []; }
  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  emit(event: RuntimeEvent): void { for (const listener of [...this.listeners]) listener(event); }
}

class FakeRuntime implements AgentRuntime {
  handle?: FakeHandle;
  async create(_prompt: BuiltPrompt, options: RuntimeCreateOptions): Promise<RuntimeSessionHandle> {
    this.handle = new FakeHandle(options.sessionId ?? "fake");
    return this.handle;
  }
}

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

async function makeSupervisor(dir: string): Promise<{ supervisor: SessionSupervisor; runtime: FakeRuntime }> {
  const runtime = new FakeRuntime();
  const supervisor = new SessionSupervisor(runtime, new SessionStore(dir));
  await supervisor.load();
  return { supervisor, runtime };
}

async function createPickle(supervisor: SessionSupervisor, title = "피클 조사"): Promise<PickyAgentSession> {
  return supervisor.createPickleFromHandoff(context("pickle request"), { title, instructions: "Investigate the request" });
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

describe("Pickle rename", () => {
  it("stores the user name as the canonical title and keeps it across a daemon restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-persist-"));
    const { supervisor } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);

    const renamed = await supervisor.renamePickleSession(pickle.id, "  조사 결과 정리  ");

    expect(renamed.title).toBe("조사 결과 정리");
    expect(renamed.titleOrigin).toBe("user");

    const { supervisor: restarted } = await makeSupervisor(dir);
    expect(restarted.get(pickle.id)?.title).toBe("조사 결과 정리");
    expect(restarted.get(pickle.id)?.titleOrigin).toBe("user");
  });

  it("stops following Pi auto-names once the user named the Pickle", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-immunity-"));
    const { supervisor, runtime } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);

    runtime.handle!.emit({ type: "session_info", name: "Pi가 지은 이름" });
    await waitUntil(() => supervisor.get(pickle.id)?.title === "Pi가 지은 이름");

    await supervisor.renamePickleSession(pickle.id, "사용자가 지은 이름");
    runtime.handle!.emit({ type: "session_info", name: "Pi가 다시 지은 이름" });
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(supervisor.get(pickle.id)?.title).toBe("사용자가 지은 이름");
  });

  it("renames on /name without sending anything to Pi or disturbing the turn", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-slash-"));
    const { supervisor, runtime } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);
    runtime.handle!.emit({ type: "status", status: "running", summary: "Still working" });
    await waitUntil(() => supervisor.get(pickle.id)?.lastSummary === "Still working");

    const afterFollowUp = await supervisor.followUp(pickle.id, "/name 새 이름");
    runtime.handle!.isStreaming = true;
    const afterSteer = await supervisor.steer(pickle.id, "/name 더 새 이름");

    expect(afterFollowUp.title).toBe("새 이름");
    expect(afterSteer.title).toBe("더 새 이름");
    expect(afterSteer.titleOrigin).toBe("user");
    // No Pi input: no prompt queued, no turn state touched, Pi keeps its own session name.
    expect(runtime.handle!.followUps).toEqual([]);
    expect(runtime.handle!.steers).toEqual([]);
    expect(supervisor.get(pickle.id)?.status).toBe("running");
    expect(supervisor.get(pickle.id)?.lastSummary).toBe("Still working");
  });

  it("rejects invalid /name through the command error surface without changing session state", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-slash-invalid-"));
    const { supervisor, runtime } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);

    const before = structuredClone(supervisor.get(pickle.id));
    await expect(supervisor.followUp(pickle.id, "/name")).rejects.toThrow("/name requires a name argument");
    await expect(supervisor.followUp(pickle.id, `/name ${"가".repeat(201)}`)).rejects.toThrow("1 to 200");
    expect(supervisor.get(pickle.id)).toEqual(before);
    expect(runtime.handle!.followUps).toEqual([]);
  });

  it("keeps the user name when a Pi auto-name is handled while the rename is still saving", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-race-"));
    const runtime = new FakeRuntime();
    const store = new SessionStore(dir);
    const supervisor = new SessionSupervisor(runtime, store);
    await supervisor.load();
    const pickle = await createPickle(supervisor);

    // Hold the rename inside its durable write so Pi's name is observed against the old session.
    let releaseSave: (() => void) | undefined;
    const blocked = new Promise<void>((resolve) => { releaseSave = () => resolve(); });
    const save = store.save.bind(store);
    let gate: Promise<void> | undefined = blocked;
    store.save = async (saved) => { const held = gate; gate = undefined; await held; await save(saved); };

    const renaming = supervisor.renamePickleSession(pickle.id, "사용자 이름");
    await new Promise((resolve) => setTimeout(resolve, 10));
    runtime.handle!.emit({ type: "session_info", name: "Pi 자동 이름" });
    await new Promise((resolve) => setTimeout(resolve, 10));
    releaseSave!();
    await renaming;
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(supervisor.get(pickle.id)?.title).toBe("사용자 이름");
    expect(supervisor.get(pickle.id)?.titleOrigin).toBe("user");
    const { supervisor: restarted } = await makeSupervisor(dir);
    expect(restarted.get(pickle.id)?.title).toBe("사용자 이름");
  });

  it("preserves title editing for older dock sessions without the manual-Pickle marker", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-not-pickle-"));
    const { supervisor } = await makeSupervisor(dir);
    const plain = await supervisor.create(context("plain task"));

    await supervisor.renamePickleSession(plain.id, "새 이름");
    expect(supervisor.get(plain.id)).toMatchObject({ title: "새 이름", titleOrigin: "user" });
    await expect(supervisor.renamePickleSession("picky", "Main name")).rejects.toThrow("Unknown Pickle");
    await expect(supervisor.renamePickleSession("missing-session", "Ghost name")).rejects.toThrow("Unknown Pickle");
  });

  it("rejects a stale caller before anything is persisted", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-caller-"));
    const { supervisor } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);

    await expect(supervisor.renamePickleSession(pickle.id, "다른 이름", () => {
      throw new Error("Unknown Picky CLI caller context");
    })).rejects.toThrow("Unknown Picky CLI caller context");

    expect(supervisor.get(pickle.id)?.title).toBe("피클 조사");
    expect(supervisor.get(pickle.id)?.titleOrigin).toBeUndefined();
    const { supervisor: restarted } = await makeSupervisor(dir);
    expect(restarted.get(pickle.id)?.title).toBe("피클 조사");
  });

  it("repeats the same name without producing another projection change", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-noop-"));
    const { supervisor } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);
    await supervisor.renamePickleSession(pickle.id, "같은 이름");
    const first = supervisor.get(pickle.id)!;

    const transactions: PickySessionProjectionMutation[][] = [];
    supervisor.on("sessionProjectionTransaction", (_id: string, _before: PickyAgentSession, _after: PickyAgentSession, mutations: PickySessionProjectionMutation[]) => transactions.push(mutations));
    const second = await supervisor.renamePickleSession(pickle.id, "같은 이름");

    expect(second.title).toBe("같은 이름");
    expect(second.revision).toBe(first.revision);
    expect(transactions).toEqual([]);
  });

  it.each([true, false])("drops the custom name on /new for a marked or legacy dock session (marker=%s)", async (hasPickleMarker) => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-new-"));
    const { supervisor, runtime } = await makeSupervisor(dir);
    const pickle = hasPickleMarker ? await createPickle(supervisor) : await supervisor.create(context("legacy task"));
    await supervisor.renamePickleSession(pickle.id, "사용자가 지은 이름");

    runtime.handle!.emit({ type: "session_replaced", reason: "new", cwd: "/tmp/project", sessionFilePath: "/tmp/new-session.jsonl" });
    await waitUntil(() => supervisor.get(pickle.id)?.title !== "사용자가 지은 이름");

    expect(supervisor.get(pickle.id)?.titleOrigin).toBeUndefined();
    runtime.handle!.emit({ type: "session_info", name: "새 대화의 Pi 이름" });
    await waitUntil(() => supervisor.get(pickle.id)?.title === "새 대화의 Pi 이름");
  });
});

describe("Pickle rename while the owning daemon is gone", () => {
  const storedSession = (id: string, piSessionFilePath: string): Record<string, unknown> => ({
    id,
    revision: 7,
    title: "Pi가 지은 이름",
    status: "completed",
    cwd: "/tmp/project",
    createdAt: "2026-05-01T00:00:00.000Z",
    updatedAt: "2026-05-01T00:10:00.000Z",
    lastSummary: "작업 완료",
    finalAnswer: "결과 보고",
    archived: true,
    archivedAt: new Date().toISOString(),
    // Set exactly as a child daemon left them, so loading the primary neither migrates nor
    // rewrites this session and the only write under test is the rename itself.
    notifyMainOnCompletion: true,
    notifyMacOSOnCompletion: false,
    piSessionFilePath,
    logs: ["manual pickle: waiting for first instruction", `pi session: ${piSessionFilePath}`],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    queuedFollowUps: [],
    activitySummary: { read: 1, bash: 2, edit: 0, write: 0, thinking: 0, other: 0 },
    // A field only a newer client knows about must survive a metadata-only rewrite.
    futureClientField: { keep: true },
  });

  async function seedScopedChildSession(dir: string, id: string): Promise<string> {
    const scopedDir = join(dir, "sessions", id);
    await mkdir(scopedDir, { recursive: true });
    const path = join(scopedDir, `${id}.json`);
    // A Pi session file that never exists, so the title refresher cannot race the rename.
    await writeFile(path, JSON.stringify(storedSession(id, join(dir, `${id}.jsonl`)), null, 2));
    return path;
  }

  it("rewrites the scoped child file in place and keeps every other field", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-offline-"));
    const id = "session-offline";
    const path = await seedScopedChildSession(dir, id);
    const { supervisor } = await makeSupervisor(dir);

    const renamed = await supervisor.renameStoredPickleSession(id, "보관 피클 새 이름");

    expect(renamed.title).toBe("보관 피클 새 이름");
    expect(renamed.titleOrigin).toBe("user");
    const persisted = JSON.parse(await readFile(path, "utf8"));
    expect(persisted.title).toBe("보관 피클 새 이름");
    expect(persisted.titleOrigin).toBe("user");
    expect(persisted.status).toBe("completed");
    expect(persisted.archived).toBe(true);
    expect(persisted.finalAnswer).toBe("결과 보고");
    expect(persisted.notifyMainOnCompletion).toBe(true);
    expect(persisted.futureClientField).toEqual({ keep: true });
    expect(persisted.revision).toBeGreaterThan(7);
    // No flat primary copy: a later child daemon must not load a forked session.
    expect((await readdir(join(dir, "sessions"))).filter((entry) => entry.endsWith(".json"))).toEqual([]);
  });

  it("routes a primary owner command after restart to fresher scoped metadata without forking it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-offline-stale-"));
    const id = "session-fresher-child";
    const path = await seedScopedChildSession(dir, id);
    const { supervisor } = await makeSupervisor(dir);
    const fresher = { ...storedSession(id, join(dir, `${id}.jsonl`)), revision: 50, status: "waiting_for_input", lastSummary: "New question", archived: false, messages: [{ id: "fresh-message", kind: "agent_text", text: "Fresh child answer", createdAt: "2026-05-01T00:20:00.000Z" }] };
    await writeFile(path, JSON.stringify(fresher));
    const snapshots: PickyAgentSession[] = [];
    supervisor.on("sessionProjectionSnapshot", session => snapshots.push(session));
    const renamed = await supervisor.renamePickleSession(id, "Fresh name");
    expect(renamed).toMatchObject({ title: "Fresh name", titleOrigin: "user", revision: 51, status: "waiting_for_input", lastSummary: "New question", messages: fresher.messages });
    expect(snapshots.at(-1)).toEqual(renamed);
    expect(supervisor.get(id)).toEqual(renamed);
    const persisted = JSON.parse(await readFile(path, "utf8"));
    expect(persisted).toEqual({ ...fresher, title: "Fresh name", titleOrigin: "user", revision: 51, updatedAt: renamed.updatedAt });
    const next = await supervisor.renamePickleSession(id, "Next name");
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ ...persisted, title: "Next name", revision: 52, updatedAt: next.updatedAt });
    expect((await readdir(join(dir, "sessions"))).filter(entry => entry.endsWith(".json"))).toEqual([]);
  });

  it("shows the renamed Pickle after reconnect and after a restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-offline-visible-"));
    const id = "session-offline-visible";
    await seedScopedChildSession(dir, id);
    const { supervisor } = await makeSupervisor(dir);
    const metaEvents: PickyAgentSession[] = [];
    supervisor.on("sessionMeta", (session: PickyAgentSession) => metaEvents.push(session));

    await supervisor.renameStoredPickleSession(id, "재접속 후에도 보이는 이름");

    expect(metaEvents.at(-1)?.title).toBe("재접속 후에도 보이는 이름");
    expect(supervisor.get(id)?.title).toBe("재접속 후에도 보이는 이름");
    expect(supervisor.get(id)?.status).toBe("completed");

    const { supervisor: restarted } = await makeSupervisor(dir);
    expect(restarted.get(id)?.title).toBe("재접속 후에도 보이는 이름");
    expect(restarted.get(id)?.titleOrigin).toBe("user");
  });

  it("refuses the offline write when the Pickle is running in this daemon", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-offline-live-"));
    const { supervisor } = await makeSupervisor(dir);
    const pickle = await createPickle(supervisor);

    await expect(supervisor.renameStoredPickleSession(pickle.id, "가로챈 이름")).rejects.toThrow(/running here/);
    expect(supervisor.get(pickle.id)?.title).toBe("피클 조사");
  });

  it("fails explicitly when no stored Pickle exists", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-offline-missing-"));
    const { supervisor } = await makeSupervisor(dir);

    await expect(supervisor.renameStoredPickleSession("session-unknown", "이름")).rejects.toThrow("Stored Pickle not found: session-unknown");
  });

  it("rejects an invalid name before touching storage", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-rename-offline-invalid-"));
    const id = "session-offline-invalid";
    const path = await seedScopedChildSession(dir, id);
    const { supervisor } = await makeSupervisor(dir);

    await expect(supervisor.renameStoredPickleSession(id, "  ")).rejects.toThrow(/1 to 200 Unicode characters/);
    expect(JSON.parse(await readFile(path, "utf8")).title).toBe("Pi가 지은 이름");
  });
});
