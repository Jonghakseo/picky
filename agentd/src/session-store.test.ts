import { mkdtempSync, readdirSync, existsSync } from "node:fs";
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
