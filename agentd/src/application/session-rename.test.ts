import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { PickyAgentSession } from "../protocol.js";
import { PickleSessionTitleRefresher } from "./pickle-session-title-refresher.js";
import { SessionRenameCoordinator, type SessionRenameDependencies } from "./session-rename.js";
import type { StoredSessionRecord } from "../session-store.js";

/**
 * Boundary checks for the rules that decide a name, independent of the daemon:
 * which commit pipeline a rename uses, when Pi's own name is allowed to win,
 * and what an offline rename takes as its base.
 */

function session(overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  return {
    id: "session-1",
    revision: 3,
    title: "Pi가 지은 이름",
    status: "running",
    createdAt: "2026-05-01T00:00:00.000Z",
    updatedAt: "2026-05-01T00:01:00.000Z",
    lastSummary: "작업 중",
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...overrides,
  };
}

function storedRecord(stored: PickyAgentSession, extraRawFields: Record<string, unknown> = {}): StoredSessionRecord {
  return { session: stored, raw: { ...stored, ...extraRawFields } as unknown as Record<string, unknown>, path: `/sessions/${stored.id}/${stored.id}.json` };
}

function harness(options: { memory?: PickyAgentSession; stored?: StoredSessionRecord; hasLocalRuntime?: boolean } = {}) {
  let current = options.memory;
  const writes: Array<{ path: string; patch: Record<string, unknown> }> = [];
  const snapshots: PickyAgentSession[] = [];
  const metas: PickyAgentSession[] = [];

  const commitWith = (aggregate: (session: PickyAgentSession) => PickyAgentSession) =>
    async (_sessionId: string, build: (session: PickyAgentSession) => PickyAgentSession) => {
      const before = current!;
      const built = build(before);
      const after = built === before ? before : { ...aggregate(built), revision: (before.revision ?? 0) + 1 };
      current = after;
      return { before, after, changed: after !== before };
    };

  const dependencies: SessionRenameDependencies = {
    getSession: () => current,
    // Stands in for the owner pipeline that also folds async work; the marker makes the
    // difference between the two pipelines observable in the committed session.
    commit: commitWith((built) => ({ ...built, lastSummary: "aggregated by async work" })),
    commitMetadataOnly: commitWith((built) => built),
    runSessionWrite: async (_sessionId, work) => { await work(); },
    setSession: (_sessionId, value) => { current = value; },
    store: {
      readStoredSession: async () => options.stored,
      protectAdoptedScopedSession: () => {},
      writeStoredSession: async (record, patch) => { writes.push({ path: record.path, patch }); },
    },
    hasLocalRuntime: () => options.hasLocalRuntime ?? false,
    emitSessionMeta: (value) => metas.push(value),
    publishProjectionSnapshot: (value) => snapshots.push(value),
  };

  return { coordinator: new SessionRenameCoordinator(dependencies), writes, snapshots, metas, read: () => current };
}

describe("renameLiveSession", () => {
  it("writes only the name and its origin, without the async-work aggregate pipeline", async () => {
    const harnessed = harness({ memory: session({ asyncControl: { admissionState: "open" } as unknown as PickyAgentSession["asyncControl"] }) });

    const renamed = await harnessed.coordinator.renameLiveSession("session-1", "사용자 이름");

    expect(renamed).toMatchObject({ title: "사용자 이름", titleOrigin: "user", status: "running" });
    // A name change is metadata: it must not fold an episode or rewrite work state.
    expect(renamed.lastSummary).toBe("작업 중");
    expect(harnessed.read()?.title).toBe("사용자 이름");
  });

  it("refuses to rename the main agent", async () => {
    const harnessed = harness({ memory: session() });

    await expect(harnessed.coordinator.renameLiveSession("picky", "이름")).rejects.toThrow("Unknown Pickle: picky");
    expect(harnessed.read()?.title).toBe("Pi가 지은 이름");
  });
});

describe("applyAutoTitle", () => {
  it("drops a Pi name that was read before a rename landed", async () => {
    // The guard must hold inside the commit: the caller read this session while it still had
    // no user-assigned name, and only then did the rename commit.
    const harnessed = harness({ memory: session() });
    await harnessed.coordinator.renameLiveSession("session-1", "사용자 이름");

    await harnessed.coordinator.applyAutoTitle("session-1", "Pi 자동 이름");

    expect(harnessed.read()?.title).toBe("사용자 이름");
  });

  it("drops a name read from a Pi session file the session has since left", async () => {
    const harnessed = harness({ memory: session({ piSessionFilePath: "/pi/new.jsonl" }) });

    await harnessed.coordinator.applyAutoTitle("session-1", "이전 대화 이름", "/pi/old.jsonl");

    expect(harnessed.read()?.title).toBe("Pi가 지은 이름");
  });

  it("applies a name from the Pi session the card still points at", async () => {
    const harnessed = harness({ memory: session({ piSessionFilePath: "/pi/current.jsonl" }) });

    await harnessed.coordinator.applyAutoTitle("session-1", "현재 대화 이름", "/pi/current.jsonl");

    expect(harnessed.read()?.title).toBe("현재 대화 이름");
    expect(harnessed.read()?.titleOrigin).toBeUndefined();
  });

  it("matches a Pi session path that only exists in the session logs", async () => {
    const harnessed = harness({ memory: session({ logs: ["pi session: /pi/from-logs.jsonl"] }) });

    await harnessed.coordinator.applyAutoTitle("session-1", "로그로 찾은 이름", "/pi/from-logs.jsonl");

    expect(harnessed.read()?.title).toBe("로그로 찾은 이름");
  });
});

describe("renameStoredSession", () => {
  it("renames from the file on disk, not from a stale primary cache", async () => {
    const stored = session({ revision: 11, status: "completed", lastSummary: "작업 완료", finalAnswer: "결과", updatedAt: "2026-05-02T00:00:00.000Z" });
    const harnessed = harness({ memory: session({ revision: 3, status: "running", lastSummary: "작업 중" }), stored: storedRecord(stored, { futureClientField: 1 }) });

    const renamed = await harnessed.coordinator.renameStoredSession("session-1", "보관 이름");

    expect(renamed).toMatchObject({ title: "보관 이름", titleOrigin: "user", status: "completed", lastSummary: "작업 완료", finalAnswer: "결과" });
    expect(renamed.revision).toBe(12);
    // Storage changes by name, revision and time only; every other stored field is untouched.
    expect(harnessed.writes).toHaveLength(1);
    expect(Object.keys(harnessed.writes[0]!.patch).sort()).toEqual(["revision", "title", "titleOrigin", "updatedAt"]);
    expect(harnessed.writes[0]!.patch).toMatchObject({ title: "보관 이름", titleOrigin: "user", revision: 12 });
    // A delta against the stale cursor would describe a chain the file never had.
    expect(harnessed.snapshots.at(-1)).toMatchObject({ title: "보관 이름", revision: 12 });
    expect(harnessed.metas.at(-1)?.title).toBe("보관 이름");
    expect(harnessed.read()).toMatchObject({ title: "보관 이름", revision: 12 });
  });

  it("does not change the stored work state while renaming an unowned session", async () => {
    const harnessed = harness({ stored: storedRecord(session({ status: "running", lastSummary: "작업 중" })) });

    const renamed = await harnessed.coordinator.renameStoredSession("session-1", "이름");

    expect(renamed.status).toBe("running");
    expect(renamed.lastSummary).toBe("작업 중");
    // Only the owner-recovery path, not rename, may change work state.
    expect(Object.keys(harnessed.writes[0]!.patch)).not.toContain("status");
  });

  it("adopts the newer file without writing when it already carries this exact name", async () => {
    const stored = session({ revision: 20, title: "보관 이름", titleOrigin: "user", status: "completed", lastSummary: "작업 완료" });
    const harnessed = harness({ memory: session({ revision: 3, title: "보관 이름", titleOrigin: "user" }), stored: storedRecord(stored) });

    const renamed = await harnessed.coordinator.renameStoredSession("session-1", "보관 이름");

    expect(harnessed.writes).toEqual([]);
    expect(renamed).toMatchObject({ revision: 20, status: "completed", lastSummary: "작업 완료" });
    expect(harnessed.snapshots.at(-1)?.revision).toBe(20);
  });

  it("adopts current messages even if the name and metadata cursor match the cache", async () => {
    const memory = session({ revision: 20, title: "Same name", titleOrigin: "user", status: "completed" });
    const stored = { ...memory, messages: [{ id: "fresh", kind: "agent_text" as const, text: "Latest child message", createdAt: memory.updatedAt }] };
    const harnessed = harness({ memory, stored: storedRecord(stored) });
    const result = await harnessed.coordinator.renameStoredSession("session-1", "Same name");
    expect(result.messages).toEqual(stored.messages);
    expect(harnessed.read()?.messages).toEqual(stored.messages);
    expect(harnessed.snapshots.at(-1)?.messages).toEqual(stored.messages);
    expect(harnessed.writes).toEqual([]);
  });

  it("stays quiet when the cache already shows exactly what the file holds", async () => {
    const stored = session({ revision: 20, title: "보관 이름", titleOrigin: "user", status: "completed", lastSummary: "작업 완료" });
    const harnessed = harness({ memory: stored, stored: storedRecord(stored) });

    await harnessed.coordinator.renameStoredSession("session-1", "보관 이름");

    expect(harnessed.writes).toEqual([]);
    expect(harnessed.snapshots).toEqual([]);
    expect(harnessed.metas).toEqual([]);
  });

  it("refuses to write while this daemon still runs the Pickle", async () => {
    const harnessed = harness({ memory: session(), stored: storedRecord(session()), hasLocalRuntime: true });

    await expect(harnessed.coordinator.renameStoredSession("session-1", "이름")).rejects.toThrow(/running here/);
    expect(harnessed.writes).toEqual([]);
  });
});

describe("PickleSessionTitleRefresher", () => {
  it("hands the name over with the Pi file it came from", async () => {
    const dir = await mkdtemp(join(tmpdir(), "picky-title-refresh-"));
    const sessionFilePath = join(dir, "pi.jsonl");
    await writeFile(sessionFilePath, `${JSON.stringify({ type: "session_info", id: "info-1", name: "Pi가 지은 이름", timestamp: "2026-05-01T00:00:00.000Z" })}\n`);
    const applied: Array<[string, string, string]> = [];
    const refresher = new PickleSessionTitleRefresher({
      isPickleSession: () => true,
      getSession: () => session({ piSessionFilePath: sessionFilePath }),
      applyAutoTitle: async (sessionId, name, expectedPiSessionFilePath) => { applied.push([sessionId, name, expectedPiSessionFilePath]); },
    });

    await refresher.refresh("session-1");

    // The commit, not the reader, decides: it drops the name if `/new` moved the session on.
    expect(applied).toEqual([["session-1", "Pi가 지은 이름", sessionFilePath]]);
  });

  it("never reads Pi for a Pickle the user already named", async () => {
    let applied = 0;
    const refresher = new PickleSessionTitleRefresher({
      isPickleSession: () => true,
      getSession: () => session({ titleOrigin: "user", piSessionFilePath: "/pi/does-not-exist.jsonl" }),
      applyAutoTitle: async () => { applied += 1; },
    });

    await refresher.refresh("session-1");

    expect(applied).toBe(0);
  });
});
