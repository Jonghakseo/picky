import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ORPHANED_CHILD_SESSION_RECOVERY_LOG, ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY, SessionStore } from "./session-store.js";
import type { PickyAgentSession } from "./protocol.js";

function tmpRoot(): string {
  return mkdtempSync(join(tmpdir(), "picky-session-store-"));
}

function makeSession(overrides: Partial<PickyAgentSession> = {}): PickyAgentSession {
  const now = new Date().toISOString();
  return {
    id: "session-test",
    revision: 0,
    title: "Test",
    status: "queued",
    cwd: "/tmp",
    createdAt: now,
    updatedAt: now,
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...overrides,
  };
}

describe("SessionStore (legacy / primary layout)", () => {
  it("saves sessions directly under sessions/", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root);
    await store.save(makeSession({ id: "alpha" }));
    await store.save(makeSession({ id: "beta" }));
    expect(readdirSync(join(root, "sessions")).sort()).toEqual(["alpha.json", "beta.json"]);
    const all = await store.loadAll();
    expect(all.map((session) => session.id).sort()).toEqual(["alpha", "beta"]);
  });

  it("compatibility matrix legacy persistence: normalizes a session without revision to zero", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root);
    const { revision: _revision, ...legacy } = makeSession({ id: "legacy-revision" });
    const sessionsDir = join(root, "sessions");
    mkdirSync(sessionsDir, { recursive: true });
    writeFileSync(join(sessionsDir, "legacy-revision.json"), JSON.stringify(legacy));

    const [loaded] = await store.loadAll();

    expect(loaded?.revision).toBe(0);
    expect(JSON.parse(readFileSync(join(sessionsDir, "legacy-revision.json"), "utf8"))).toMatchObject({ revision: 0 });
  });

  it("preserves revision across save and reload", async () => {
    const store = new SessionStore(tmpRoot());
    await store.save(makeSession({ id: "revision-round-trip", revision: 7 }));

    expect((await store.loadAll())[0]?.revision).toBe(7);
  });

  it("backfills absent lastRequest from the most recent nonempty recognized legacy log and persists it", async () => {
    const root = tmpRoot();
    const sessionsDir = join(root, "sessions");
    mkdirSync(sessionsDir, { recursive: true });
    const sources = [
      ["steer", "  steer: focus the failing test  ", { source: "steer", text: "focus the failing test" }],
      ["follow-up", "follow-up: add a regression", { source: "followUp", text: "add a regression" }],
      ["handoff", "Picky handoff: continue the investigation", { source: "handoff", text: "continue the investigation" }],
      ["extension", "extension ui answer: Scope?: Project", { source: "extensionAnswer", text: "Scope?: Project" }],
      ["transcript", "source transcript:  Original user request  ", { source: "transcript", text: "Original user request" }],
    ] as const;
    for (const [id, log, lastRequest] of sources) {
      writeFileSync(join(sessionsDir, `${id}.json`), JSON.stringify(makeSession({ id, revision: 7, logs: ["follow-up: older request", log, "unrecognized newer noise"] })));
    }

    const loaded = await new SessionStore(root).loadAll();

    for (const [id, _log, lastRequest] of sources) {
      expect(loaded.find((session) => session.id === id)?.lastRequest).toEqual(lastRequest);
      expect(JSON.parse(readFileSync(join(sessionsDir, `${id}.json`), "utf8"))).toMatchObject({ lastRequest, revision: 7 });
    }
    const persisted = sources.map(([id]) => readFileSync(join(sessionsDir, `${id}.json`), "utf8"));
    expect((await new SessionStore(root).loadAll()).map((session) => session.lastRequest)).toEqual(expect.arrayContaining(sources.map(([, , lastRequest]) => lastRequest)));
    expect(sources.map(([id]) => readFileSync(join(sessionsDir, `${id}.json`), "utf8"))).toEqual(persisted);
  });

  it("preserves every present typed lastRequest source without rewriting it", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root);
    const sources = ["steer", "followUp", "handoff", "extensionAnswer", "transcript"] as const;
    for (const source of sources) {
      await store.save(makeSession({ id: `typed-${source}`, logs: ["follow-up: legacy replacement"], lastRequest: { source, text: `typed ${source}` } }));
    }

    const loaded = await store.loadAll();

    for (const source of sources) {
      expect(loaded.find((session) => session.id === `typed-${source}`)?.lastRequest).toEqual({ source, text: `typed ${source}` });
    }
  });

  it("ignores blank recognized logs and newer noise when backfilling a legacy request", async () => {
    const root = tmpRoot();
    const sessionsDir = join(root, "sessions");
    mkdirSync(sessionsDir, { recursive: true });
    writeFileSync(join(sessionsDir, "legacy-fallback.json"), JSON.stringify(makeSession({
      id: "legacy-fallback",
      logs: ["follow-up: durable request  ", "Picky handoff:   ", " source transcript: not a legacy transcript prefix", "later unrecognized noise"],
    })));
    writeFileSync(join(sessionsDir, "legacy-empty.json"), JSON.stringify(makeSession({ id: "legacy-empty", logs: ["steer:  ", "unrecognized"] })));

    const loaded = await new SessionStore(root).loadAll();

    expect(loaded.find((session) => session.id === "legacy-fallback")?.lastRequest).toEqual({ source: "followUp", text: "durable request" });
    expect(loaded.find((session) => session.id === "legacy-empty")?.lastRequest).toBeUndefined();
    expect(JSON.parse(readFileSync(join(sessionsDir, "legacy-empty.json"), "utf8"))).not.toHaveProperty("lastRequest");
  });

  it("does not persist a nested legacy migration into the primary flat layout", async () => {
    const root = tmpRoot();
    const scoped = new SessionStore(root, { scopeSessionId: "nested-legacy" });
    await scoped.save(makeSession({ id: "nested-legacy", logs: ["steer: scoped request"] }));
    const nestedPath = join(root, "sessions", "nested-legacy", "nested-legacy.json");
    const raw = JSON.parse(readFileSync(nestedPath, "utf8")) as Record<string, unknown>;
    delete raw.lastRequest;
    writeFileSync(nestedPath, JSON.stringify(raw));

    const [loaded] = await new SessionStore(root).loadAll();

    expect(loaded?.lastRequest).toEqual({ source: "steer", text: "scoped request" });
    expect(JSON.parse(readFileSync(nestedPath, "utf8"))).not.toHaveProperty("lastRequest");
    expect(existsSync(join(root, "sessions", "nested-legacy.json"))).toBe(false);

    const [owned] = await scoped.loadAll();
    expect(owned?.lastRequest).toEqual({ source: "steer", text: "scoped request" });
    expect(JSON.parse(readFileSync(nestedPath, "utf8"))).toMatchObject({ lastRequest: owned?.lastRequest });
    expect(existsSync(join(root, "sessions", "nested-legacy.json"))).toBe(false);
  });

  it.each(["flat", "scoped"] as const)("compatibility matrix rollback: preserves unknown fields while backfilling requests in %s storage", async (layout) => {
    const root = tmpRoot();
    const store = new SessionStore(root, layout === "scoped" ? { scopeSessionId: "future-revision" } : {});
    const sessionsDir = join(root, "sessions", ...(layout === "scoped" ? ["future-revision"] : []));
    mkdirSync(sessionsDir, { recursive: true });
    const futureSession = {
      ...makeSession({ id: "future-revision", revision: 9, status: "completed", lastSummary: "Durable result", logs: ["steer: retry"] }),
      projectionEpoch: "future-daemon-epoch",
      revisionMetadata: { source: "projection-v2", cursor: 9 },
      messages: [{
        id: "future-message", kind: "user_text", createdAt: "2026-09-07T00:00:00.000Z", text: "retry",
        futureMetadata: { nested: { source: "future-client" } },
      }],
    };
    const filePath = join(sessionsDir, "future-revision.json");
    writeFileSync(filePath, JSON.stringify(futureSession));

    const [loaded] = await store.loadAll();

    expect(loaded).toMatchObject({
      id: "future-revision",
      revision: 9,
      status: "completed",
      lastSummary: "Durable result",
      lastRequest: { source: "steer", text: "retry" },
    });
    const expected = { ...futureSession, lastRequest: { source: "steer", text: "retry" } };
    expect(JSON.parse(readFileSync(filePath, "utf8"))).toEqual(expected);
    await store.loadAll();
    expect(JSON.parse(readFileSync(filePath, "utf8"))).toEqual(expected);
  });

  it("projects legacy truncated JSON tool previews without rewriting session files", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root);
    const prefix = '{"content":[{"type":"text","text":"';
    const legacyPreview = `${prefix}${"x".repeat(500 - prefix.length - 3)}...`;
    await store.save(makeSession({
      id: "legacy-json-preview",
      tools: [{
        toolCallId: "tool-legacy-json",
        name: "bash",
        status: "failed",
        preview: legacyPreview,
        resultPreview: legacyPreview,
      }],
    }));

    const [loaded] = await store.loadAll();
    const tool = loaded?.tools[0];
    expect(tool?.preview).toBe(legacyPreview);
    expect(tool?.resultPreview).toBe(legacyPreview);
    expect(tool?.resultPreviewTruncated).toBe(true);
    expect(tool?.resultPreviewRepaired).toBe(true);
    expect(tool!.resultJSONPreview!.length).toBeLessThanOrEqual(500);
    expect(() => JSON.parse(tool!.resultJSONPreview!)).not.toThrow();

    const stored = JSON.parse(readFileSync(join(root, "sessions", "legacy-json-preview.json"), "utf8")) as PickyAgentSession;
    expect(stored.tools[0]?.preview).toBe(legacyPreview);
    expect(stored.tools[0]?.resultPreview).toBe(legacyPreview);
    expect(stored.tools[0]?.resultJSONPreview).toBeUndefined();
    expect(stored.tools[0]?.resultPreviewTruncated).toBeUndefined();
    expect(stored.tools[0]?.resultPreviewRepaired).toBeUndefined();
  });

  it("deletes a flat session JSON file", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root);
    await store.save(makeSession({ id: "alpha" }));

    await store.deleteSession("alpha");

    expect(existsSync(join(root, "sessions", "alpha.json"))).toBe(false);
  });

  it("deleteSession is idempotent when no session files exist", async () => {
    const store = new SessionStore(tmpRoot());

    await expect(store.deleteSession("missing")).resolves.toBeUndefined();
  });

  it("deleteSession rejects empty session id", async () => {
    const store = new SessionStore(tmpRoot());

    await expect(store.deleteSession("")).rejects.toThrow(/Invalid sessionId/);
  });

  it("deleteSession rejects \".\" session id", async () => {
    const store = new SessionStore(tmpRoot());

    await expect(store.deleteSession(".")).rejects.toThrow(/Invalid sessionId/);
  });

  it("deleteSession rejects \"..\" session id", async () => {
    const store = new SessionStore(tmpRoot());

    await expect(store.deleteSession("..")).rejects.toThrow(/Invalid sessionId/);
  });

  it("deletes flat JSON and nested scoped directory for a session", async () => {
    const root = tmpRoot();
    const primary = new SessionStore(root);
    await primary.save(makeSession({ id: "pickle-completed", status: "completed" }));
    const scoped = new SessionStore(root, { scopeSessionId: "pickle-completed" });
    await scoped.save(makeSession({ id: "pickle-completed", status: "completed" }));

    await primary.deleteSession("pickle-completed");

    expect(existsSync(join(root, "sessions", "pickle-completed.json"))).toBe(false);
    expect(existsSync(join(root, "sessions", "pickle-completed"))).toBe(false);
  });

  it("loads terminal sessions from scoped child directories", async () => {
    const root = tmpRoot();
    const scoped = new SessionStore(root, { scopeSessionId: "pickle-completed" });
    await scoped.save(makeSession({ id: "pickle-completed", status: "completed" }));

    const all = await new SessionStore(root).loadAll();

    expect(all.map((session) => session.id)).toEqual(["pickle-completed"]);
  });

  it("loads non-archived non-terminal sessions from scoped child directories as blocked recovery candidates", async () => {
    const root = tmpRoot();
    const scoped = new SessionStore(root, { scopeSessionId: "pickle-running" });
    await scoped.save(makeSession({ id: "pickle-running", status: "running", logs: ["pi session: /tmp/pi-session.jsonl"] }));

    const all = await new SessionStore(root).loadAll();

    expect(all).toHaveLength(1);
    expect(all[0]).toMatchObject({
      id: "pickle-running",
      status: "blocked",
      lastSummary: ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY,
      logs: ["pi session: /tmp/pi-session.jsonl", ORPHANED_CHILD_SESSION_RECOVERY_LOG],
    });
  });

  it("deduplicates flat and scoped child sessions by updatedAt", async () => {
    const root = tmpRoot();
    const primary = new SessionStore(root);
    await primary.save(makeSession({ id: "pickle-dup", status: "completed", title: "Flat", updatedAt: "2026-05-11T10:00:00.000Z" }));
    const scoped = new SessionStore(root, { scopeSessionId: "pickle-dup" });
    await scoped.save(makeSession({ id: "pickle-dup", status: "completed", title: "Nested latest", updatedAt: "2026-05-11T11:00:00.000Z" }));

    const all = await primary.loadAll();

    expect(all.map((session) => [session.id, session.title])).toEqual([["pickle-dup", "Nested latest"]]);
  });
});

describe("SessionStore (child / scoped layout)", () => {
  it("nests session metadata under sessions/<scopeSessionId>/", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root, { scopeSessionId: "pickle-xyz" });
    await store.save(makeSession({ id: "pickle-xyz" }));
    expect(existsSync(join(root, "sessions", "pickle-xyz", "pickle-xyz.json"))).toBe(true);
    expect(existsSync(join(root, "sessions", "pickle-xyz.json"))).toBe(false);
  });

  it("rejects saves for any session id other than the scope", async () => {
    const store = new SessionStore(tmpRoot(), { scopeSessionId: "pickle-xyz" });
    await expect(store.save(makeSession({ id: "session-random" }))).rejects.toThrow(/scoped to pickle-xyz/);
  });

  it("loadAll returns only the scoped session", async () => {
    const root = tmpRoot();
    // Pretend a primary wrote a peer session into the shared sessions/ root; the scoped store
    // must ignore it.
    const primary = new SessionStore(root);
    await primary.save(makeSession({ id: "peer-from-primary" }));
    const scoped = new SessionStore(root, { scopeSessionId: "pickle-xyz" });
    await scoped.save(makeSession({ id: "pickle-xyz" }));
    const all = await scoped.loadAll();
    expect(all.map((session) => session.id)).toEqual(["pickle-xyz"]);
  });

  it("scopeSessionId with slashes is sanitized so it cannot escape sessions/", async () => {
    const root = tmpRoot();
    const store = new SessionStore(root, { scopeSessionId: "../escape" });
    await store.save(makeSession({ id: "../escape" }));
    // safeName replaces every non-[a-zA-Z0-9._-] character with "_". `../escape` -> `.._escape`.
    expect(existsSync(join(root, "sessions", ".._escape", ".._escape.json"))).toBe(true);
  });

  it("rejects degenerate dot scopeSessionId values that would resolve to the parent directory", () => {
    expect(() => new SessionStore(tmpRoot(), { scopeSessionId: "." })).toThrow(/Invalid scopeSessionId/);
    expect(() => new SessionStore(tmpRoot(), { scopeSessionId: ".." })).toThrow(/Invalid scopeSessionId/);
    expect(() => new SessionStore(tmpRoot(), { scopeSessionId: "" })).toThrow(/Invalid scopeSessionId/);
  });
});
