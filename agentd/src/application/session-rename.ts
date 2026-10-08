import { isDeepStrictEqual } from "node:util";
import { piSessionFilePathForSession } from "../domain/pi-session-files.js";
import { isNameSlashCommand } from "../domain/slash-commands.js";
import { isRenameNoOp, isUserAssignedTitle, normalizePickleRenameTitle, userRenameTitlePatch } from "../domain/session-rename-policy.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession } from "../protocol.js";
import type { SessionCommit } from "./session-projection-commit-publisher.js";
import type { SessionStore, StoredSessionRecord } from "../session-store.js";

const NAME_USAGE_LOG = "/name requires a name argument (usage: /name <session name>)";

export interface SessionRenameDependencies {
  getSession(sessionId: string): PickyAgentSession | undefined;
  /** Owner commit with the full aggregate/completion pipeline. */
  commit(sessionId: string, build: (current: PickyAgentSession) => PickyAgentSession): Promise<SessionCommit>;
  /**
   * Same write serialization, persistence, and projection publishing as `commit`,
   * without async-work aggregation or completion side effects. A name change is
   * metadata: it must never fold an async episode or fire a completion notice.
   */
  commitMetadataOnly(sessionId: string, build: (current: PickyAgentSession) => PickyAgentSession): Promise<SessionCommit>;
  /** The owner's existing per-session write serializer. */
  runSessionWrite(sessionId: string, work: () => Promise<void>): Promise<void>;
  setSession(sessionId: string, session: PickyAgentSession): void;
  store: Pick<SessionStore, "readStoredSession" | "writeStoredSession" | "protectAdoptedScopedSession">;
  /** True while this process runs, or is about to run, the session's Pi runtime. */
  hasLocalRuntime(sessionId: string): boolean;
  emitSessionMeta(session: PickyAgentSession): void;
  /** Authoritative full-session projection; resets a client cursor instead of extending it. */
  publishProjectionSnapshot(session: PickyAgentSession): void;
}

/**
 * The single place a Pickle display name changes. The CLI, the app's inline
 * title editing, `/name` typed in a Pickle conversation, and Pi's own auto-name
 * all land here, so one rule decides what is stored and what the HUD shows.
 *
 * Two rename routes exist because a Pickle's metadata has exactly one owner:
 *
 * - `renameLiveSession` runs on the daemon that owns the session and goes
 *   through the normal commit chain, so the rename cannot interleave with turn
 *   state, queue writes, or a terminal commit.
 * - `renameStoredSession` is the offline route. The app confirms the child
 *   daemon is gone before calling it; this class still refuses to write while a
 *   local runtime exists, treats the file on disk as the authoritative base
 *   rather than the primary's possibly stale cache, and rewrites that same file.
 *
 * `applyAutoTitle` is the only path Pi's names may take, and it decides inside
 * the commit, so a rename that is already queued cannot be overwritten by a
 * name that was read before it.
 *
 * No route starts a runtime, runs a turn, or writes Pi's session file.
 */
export class SessionRenameCoordinator {
  constructor(private readonly dependencies: SessionRenameDependencies) {}

  /** After restart, a primary cache is not proof of a live runtime or of flat-file ownership. */
  async renameOwnedSession(sessionId: string, rawTitle: string, validateCaller?: () => void): Promise<PickyAgentSession> {
    if (sessionId === "picky" || !this.dependencies.getSession(sessionId)) throw new Error(`Unknown Pickle: ${sessionId}`);
    return this.dependencies.hasLocalRuntime(sessionId)
      ? this.renameLiveSession(sessionId, rawTitle, validateCaller)
      : this.renameStoredSession(sessionId, rawTitle, validateCaller);
  }

  /**
   * Renames a Pickle this daemon owns. `validateCaller` runs inside the commit
   * so a CLI `--self` binding that went stale while the request was queued fails
   * before anything is persisted.
   */
  async renameLiveSession(sessionId: string, rawTitle: string, validateCaller?: () => void): Promise<PickyAgentSession> {
    if (sessionId === "picky" || !this.dependencies.getSession(sessionId)) throw new Error(`Unknown Pickle: ${sessionId}`);
    const title = normalizePickleRenameTitle(rawTitle);
    const commit = await this.dependencies.commitMetadataOnly(sessionId, (current) => {
      validateCaller?.();
      return isRenameNoOp(current, title)
        ? current
        : { ...current, ...userRenameTitlePatch(title), updatedAt: new Date().toISOString() };
    });
    if (commit.changed) {
      logAgentd("session renamed", { sessionId, titleChars: title.length });
      this.dependencies.emitSessionMeta(commit.after);
    }
    return commit.after;
  }

  /**
   * Applies a name Pi chose for itself. Both conditions are re-evaluated inside
   * the commit: a user-assigned name always wins, and a name read from a Pi
   * session file is dropped when the session has since moved to another file
   * (`/new`), so a slow read cannot name the next conversation.
   */
  async applyAutoTitle(sessionId: string, name: string, expectedPiSessionFilePath?: string): Promise<void> {
    const title = name.trim();
    if (!title) return;
    const commit = await this.dependencies.commit(sessionId, (current) => {
      if (isUserAssignedTitle(current) || current.title === title) return current;
      // Resolve the same way the reader did, so a path that only exists in the logs still matches
      // and a `/new` that moved the session to another Pi file does not.
      if (expectedPiSessionFilePath !== undefined && piSessionFilePathForSession(current) !== expectedPiSessionFilePath) return current;
      return { ...current, title, updatedAt: new Date().toISOString() };
    });
    if (!commit.changed) return;
    logAgentd("session auto title applied", { sessionId, titleChars: title.length });
    this.dependencies.emitSessionMeta(commit.after);
  }

  /**
   * Renames a Pickle whose owning daemon is gone. Metadata only: status, queue,
   * question, archive, and async state are kept exactly as the owner left them
   * on disk, and no runtime is created to perform the write.
   */
  async renameStoredSession(sessionId: string, rawTitle: string, validateCaller?: () => void): Promise<PickyAgentSession> {
    const title = normalizePickleRenameTitle(rawTitle);
    this.assertNoLocalRuntime(sessionId);
    let renamed: PickyAgentSession | undefined;
    await this.dependencies.runSessionWrite(sessionId, async () => {
      // Re-check inside the serializer: a daemon spawn or ownership handover may
      // have started while this request waited for the session's write chain.
      this.assertNoLocalRuntime(sessionId);
      const record = await this.dependencies.store.readStoredSession(sessionId);
      if (!record) throw new Error(`Stored Pickle not found: ${sessionId}`);
      this.assertNoLocalRuntime(sessionId);
      validateCaller?.();
      renamed = await this.commitStoredRename(record, title);
    });
    return renamed!;
  }

  /**
   * Intercepts `/name` typed in a Pickle conversation before any input side
   * effect. The name is Picky metadata, so the command never reaches Pi, never
   * queues a prompt, and never disturbs a running turn or a pending question.
   * Returns `undefined` for input that must follow the normal path.
   */
  async interceptNameSlashCommand(sessionId: string, text: string): Promise<PickyAgentSession | undefined> {
    if (!isNameSlashCommand(text) || sessionId === "picky") return undefined;
    const current = this.dependencies.getSession(sessionId);
    if (!current) return undefined;
    const requested = text.trimStart().replace(/^\/name[ \t]*/, "");
    // Propagate rejection through the normal command error surface, not a hidden log.
    if (!requested.trim()) throw new Error(NAME_USAGE_LOG);
    return await this.renameOwnedSession(sessionId, requested);
  }

  private assertNoLocalRuntime(sessionId: string): void {
    if (!this.dependencies.hasLocalRuntime(sessionId)) return;
    throw new Error(`Pickle ${sessionId} is running here; rename it through its owning daemon and retry.`);
  }

  /**
   * Disk is the base, not this process's cache: the child daemon kept writing
   * after the primary last saw the session, so the cached copy can be behind by
   * any number of commits. Only the name, its origin, revision, and timestamp
   * are written; every other stored field is carried through untouched.
   */
  private async commitStoredRename(record: StoredSessionRecord, title: string): Promise<PickyAgentSession> {
    const stored = record.session;
    const memory = this.dependencies.getSession(stored.id);
    this.dependencies.store.protectAdoptedScopedSession(record);
    const adopted = stored;
    if (isRenameNoOp(stored, title)) {
      // Already stored under this exact user name. Nothing is written, but the
      // cached copy may still be behind the file, so adopt disk before answering.
      return this.adopt(memory, adopted, "stored pickle rename already applied");
    }

    const now = new Date().toISOString();
    // Stay above both chains: the file may already be ahead of anything this
    // process published, and the next loader must still see a forward step.
    const revision = Math.max(stored.revision ?? 0, memory?.revision ?? 0) + 1;
    await this.dependencies.store.writeStoredSession(record, { ...userRenameTitlePatch(title), updatedAt: now, revision });
    return this.adopt(memory, { ...adopted, ...userRenameTitlePatch(title), updatedAt: now, revision }, "stored pickle renamed");
  }

  /**
   * Publishes an offline-adopted session as a snapshot. A delta against the
   * primary's cached copy would be computed from a revision the file has long
   * passed, so the client would stitch a chain that never existed; a snapshot
   * is the recovery-safe form and resets that cursor.
   */
  private adopt(memory: PickyAgentSession | undefined, published: PickyAgentSession, reason: string): PickyAgentSession {
    if (memory && isDeepStrictEqual(memory, published)) return memory;
    this.dependencies.setSession(published.id, published);
    logAgentd(reason, { sessionId: published.id, titleChars: published.title.length, revision: published.revision });
    try {
      // The durable write already succeeded; a publishing failure must not be
      // reported as a failed rename, or the caller retries an applied change.
      this.dependencies.publishProjectionSnapshot(published);
      this.dependencies.emitSessionMeta(published);
    } catch (error) {
      logAgentd("stored pickle rename publish failed", { sessionId: published.id, error: error instanceof Error ? error.message : String(error) });
    }
    return published;
  }
}
