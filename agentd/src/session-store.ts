import { randomUUID } from "node:crypto";
import type { Dirent } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { prefixedUserInputFromLogLine } from "./domain/log-prefixes.js";
import { isTerminalStatus } from "./domain/session-status.js";
import { buildToolResultPreview } from "./domain/tool-result-preview.js";
import { PickyAgentSessionSchema, PickyMainAgentStateSchema, type PickyAgentSession, type PickyMainAgentState, type PickyToolActivity } from "./protocol.js";

export const ORPHANED_CHILD_SESSION_RECOVERY_LOG = "orphaned child Pickle session recovered from scoped metadata";
export const ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY = "Child Pickle daemon is not attached after Picky restart; send a follow-up or steer message to continue.";

/**
 * One session file exactly as it sits on disk, together with the path it was
 * read from. Metadata-only rewrites (an offline rename) persist back to that
 * same file, so a primary daemon can never leave a stale flat copy next to the
 * scoped child file that owns the session.
 */
export interface StoredSessionRecord {
  readonly session: PickyAgentSession;
  /** Minimally migrated raw JSON; unknown fields from newer clients survive a rewrite. */
  readonly raw: Record<string, unknown>;
  readonly path: string;
}

interface SessionStoreOptions {
  // When set, the store reads/writes session JSON under `sessions/<scopeSessionId>/` instead
  // of the shared `sessions/` directory. Phase 1 of the per-Pickle agentd plan uses this to
  // isolate each child daemon's metadata so concurrent processes do not race on writes in
  // the shared root. Primary daemons leave it unset and retain the legacy flat layout.
  scopeSessionId?: string;
}

export class SessionStore {
  private readonly sessionsDir: string;
  private readonly pickyStatePath: string;
  private readonly scopeSessionId?: string;
  // Offline adoption does not transfer write ownership to the primary. Refuse later
  // full-cache saves rather than overwriting a child's file or forking a flat copy.
  private readonly adoptedScopedSessions = new Set<string>();
  constructor(private readonly appSupportDir: string, options: SessionStoreOptions = {}) {
    this.scopeSessionId = options.scopeSessionId;
    if (this.scopeSessionId !== undefined) {
      const sanitized = safeName(this.scopeSessionId);
      // safeName rewrites traversal characters to `_` but leaves dots intact, so `.` / `..`
      // would otherwise resolve to the appSupportRoot itself or its parent. Reject the
      // degenerate cases so the scoped subdir is always a real child of `sessions/`.
      if (!sanitized || sanitized === "." || sanitized === "..") {
        throw new Error(`Invalid scopeSessionId: ${JSON.stringify(this.scopeSessionId)}`);
      }
      this.sessionsDir = join(appSupportDir, "sessions", sanitized);
    } else {
      this.sessionsDir = join(appSupportDir, "sessions");
    }
    this.pickyStatePath = join(appSupportDir, "picky.json");
  }

  async save(session: PickyAgentSession): Promise<void> {
    await this.persistSessionValue(session.id, session);
  }

  private async persistSessionValue(sessionId: string, value: unknown): Promise<void> {
    if (this.scopeSessionId && sessionId !== this.scopeSessionId) {
      throw new Error(`SessionStore scoped to ${this.scopeSessionId} cannot save session ${sessionId}`);
    }
    if (this.adoptedScopedSessions.has(sessionId)) throw new Error(`Session ${sessionId} requires its owning child daemon for further writes`);
    await this.persistValueAtPath(join(this.sessionsDir, `${safeName(sessionId)}.json`), value);
  }

  private async persistValueAtPath(targetPath: string, value: unknown): Promise<void> {
    const directory = dirname(targetPath);
    await mkdir(directory, { recursive: true });
    const tempPath = join(directory, `.${safeName(basename(targetPath))}.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(value, null, 2));
    await rename(tempPath, targetPath);
  }

  async deleteSession(sessionId: string): Promise<void> {
    if (this.scopeSessionId && sessionId !== this.scopeSessionId) {
      throw new Error(`SessionStore scoped to ${this.scopeSessionId} cannot delete session ${sessionId}`);
    }
    const safe = safeName(sessionId);
    // Reject degenerate names. Empty / "." / ".." would resolve to the
    // sessions directory itself or its parent (appSupportDir), causing the
    // recursive rm to wipe unrelated Picky metadata. Mirrors the guard in
    // the SessionStore constructor for scopeSessionId.
    if (!safe || safe === "." || safe === "..") {
      throw new Error(`Invalid sessionId for deleteSession: ${JSON.stringify(sessionId)}`);
    }
    const jsonPath = join(this.sessionsDir, `${safe}.json`);
    const nestedDir = join(this.sessionsDir, safe);
    await rm(jsonPath, { force: true });
    await rm(nestedDir, { recursive: true, force: true });
    this.adoptedScopedSessions.delete(sessionId);
  }

  async saveMainAgentState(state: PickyMainAgentState): Promise<void> {
    await mkdir(this.appSupportDir, { recursive: true });
    const tempPath = join(this.appSupportDir, `.picky.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(state, null, 2));
    await rename(tempPath, this.pickyStatePath);
  }

  async loadMainAgentState(): Promise<PickyMainAgentState> {
    try {
      return PickyMainAgentStateSchema.parse(JSON.parse(await readFile(this.pickyStatePath, "utf8")));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        console.warn(`Skipping unreadable Picky metadata ${this.pickyStatePath}: ${messageOf(error)}`);
      }
      return { messages: [] };
    }
  }

  /** Fresh single-session lookup. Never migrates files or applies orphan recovery state. */
  async loadReadOnly(sessionId: string): Promise<PickyAgentSession | undefined> {
    return (await this.readStoredSession(sessionId))?.session;
  }

  /**
   * Every file this store may read or write for one session, most authoritative
   * first. Empty for a name that cannot address a session file at all.
   */
  private sessionFilePaths(sessionId: string): string[] {
    const safe = safeName(sessionId);
    if (!safe || safe === "." || safe === ".." || safe !== sessionId) return [];
    if (this.scopeSessionId) return sessionId === this.scopeSessionId ? [join(this.sessionsDir, `${safe}.json`)] : [];
    return [join(this.sessionsDir, safe, `${safe}.json`), join(this.sessionsDir, `${safe}.json`)];
  }

  /** `loadReadOnly` plus the originating file, for callers that must write back in place. */
  async readStoredSession(sessionId: string): Promise<StoredSessionRecord | undefined> {
    // Scoped child metadata is authoritative even when an older flat copy remains.
    for (const path of this.sessionFilePaths(sessionId)) {
      try {
        const migrated = migrateLegacySession(JSON.parse(await readFile(path, "utf8"))).value;
        const parsed = PickyAgentSessionSchema.safeParse(migrated);
        if (!parsed.success || parsed.data.id !== sessionId) return undefined;
        if (!migrated || typeof migrated !== "object" || Array.isArray(migrated)) return undefined;
        return { session: parsed.data, raw: migrated as Record<string, unknown>, path };
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") return undefined;
      }
    }
    return undefined;
  }

  /** A display-name edit never grants the primary ongoing write ownership. */
  protectAdoptedScopedSession(record: StoredSessionRecord): void {
    if (!this.scopeSessionId && record.path === join(this.sessionsDir, safeName(record.session.id), `${safeName(record.session.id)}.json`)) {
      this.adoptedScopedSessions.add(record.session.id);
    }
  }

  /**
   * Atomically rewrites the exact file a record came from, keeping every field
   * the reader did not touch. Used for metadata-only edits of a session this
   * process does not run; `save()` would relocate a scoped child session into
   * the primary's flat layout and silently fork its state.
   *
   * The record's path and identity are re-derived here rather than trusted: a
   * caller must not be able to aim a metadata patch at another file or rewrite
   * the session id stored inside it.
   */
  async writeStoredSession(record: StoredSessionRecord, patch: Record<string, unknown>): Promise<void> {
    const sessionId = record.session.id;
    if (!this.sessionFilePaths(sessionId).includes(record.path)) {
      throw new Error(`Refusing to write session ${sessionId} outside its session files: ${record.path}`);
    }
    if ("id" in patch && patch.id !== sessionId) throw new Error(`Refusing to change stored session id: ${sessionId}`);
    await this.persistValueAtPath(record.path, { ...record.raw, ...patch, id: sessionId });
  }

  async loadAll(): Promise<PickyAgentSession[]> {
    let entries: Dirent[];
    try {
      entries = await readdir(this.sessionsDir, { withFileTypes: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }

    const flatSessions = await Promise.all(
      entries
        .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
        .map(async (entry) => this.loadOne(join(this.sessionsDir, entry.name))),
    );
    const nestedSessions = this.scopeSessionId
      ? []
      : await Promise.all(
          entries
            .filter((entry) => entry.isDirectory())
            .map(async (entry) => this.loadNestedSession(entry.name)),
        );
    return dedupeLatestSessions([...flatSessions, ...nestedSessions])
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  private async loadOne(filePath: string, options: { persistMigration?: boolean } = {}): Promise<PickyAgentSession | undefined> {
    const persistMigration = options.persistMigration ?? true;
    try {
      const raw = JSON.parse(await readFile(filePath, "utf8"));
      const migrated = migrateLegacySession(raw);
      const session = PickyAgentSessionSchema.parse(migrated.value);
      // Validate known fields, but write the minimally migrated raw value:
      // Zod strips unknown fields, including nested metadata from newer clients.
      // Migrate the file that was read, never the session's authoritative path: an old flat
      // copy must not be promoted over the scoped file a child daemon owns.
      if (migrated.changed && persistMigration) await this.persistValueAtPath(filePath, migrated.value);
      return projectLegacyToolResultJSONPreviews(session);
    } catch (error) {
      console.warn(`Skipping unreadable Picky session metadata ${filePath}: ${messageOf(error)}`);
      return undefined;
    }
  }

  private async loadNestedSession(directoryName: string): Promise<PickyAgentSession | undefined> {
    const filePath = join(this.sessionsDir, directoryName, `${directoryName}.json`);
    const session = await this.loadOne(filePath, { persistMigration: false });
    if (!session) return undefined;
    if (safeName(session.id) !== directoryName) return undefined;
    if (isTerminalStatus(session.status) || session.archived === true) return session;
    return {
      ...session,
      status: "blocked",
      lastSummary: ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY,
      logs: appendUniqueLog(session.logs, ORPHANED_CHILD_SESSION_RECOVERY_LOG),
    };
  }
}

function dedupeLatestSessions(sessions: Array<PickyAgentSession | undefined>): PickyAgentSession[] {
  const byId = new Map<string, PickyAgentSession>();
  for (const session of sessions) {
    if (!session) continue;
    const previous = byId.get(session.id);
    if (!previous || session.updatedAt.localeCompare(previous.updatedAt) > 0) byId.set(session.id, session);
  }
  return [...byId.values()];
}

function appendUniqueLog(logs: string[], line: string): string[] {
  return logs.includes(line) ? logs : [...logs, line];
}

function migrateLegacySession(value: unknown): { value: unknown; changed: boolean } {
  if (!value || typeof value !== "object" || Array.isArray(value)) return { value, changed: false };

  const session = value as { revision?: unknown; messages?: unknown; logs?: unknown; lastRequest?: unknown };
  let changed = false;
  const migrated: Record<string, unknown> = { ...session };
  if (!("revision" in session)) {
    migrated.revision = 0;
    changed = true;
  }

  if (Array.isArray(session.messages)) {
    const messages = session.messages.map((message) => {
      if (!message || typeof message !== "object" || (message as { kind?: unknown }).kind !== "agent_report") return message;
      changed = true;
      return { ...message, kind: "agent_text" };
    });
    migrated.messages = messages;
  }

  if (!("lastRequest" in session)) {
    const lastRequest = lastRequestFromLegacyLogs(session.logs);
    if (lastRequest) {
      migrated.lastRequest = lastRequest;
      changed = true;
    }
  }

  return changed ? { value: migrated, changed: true } : { value, changed: false };
}

function lastRequestFromLegacyLogs(logs: unknown): PickyAgentSession["lastRequest"] | undefined {
  if (!Array.isArray(logs)) return undefined;
  for (let index = logs.length - 1; index >= 0; index -= 1) {
    const line = logs[index];
    if (typeof line !== "string") continue;
    // Match the retired Swift log reader only during legacy migration. Live
    // journal parsing remains strict, and transcript lines keep their raw prefix.
    const transcriptPrefix = "source transcript:";
    const input = prefixedUserInputFromLogLine(line.trim())
      ?? (line.startsWith(transcriptPrefix) ? { source: "transcript" as const, text: line.slice(transcriptPrefix.length) } : undefined);
    const text = input?.text.trim();
    if (input && text) return { source: input.source, text };
  }
  return undefined;
}

function projectLegacyToolResultJSONPreviews(session: PickyAgentSession): PickyAgentSession {
  let changed = false;
  const tools = session.tools.map((tool) => {
    const projected = projectLegacyToolResultJSONPreview(tool);
    if (projected !== tool) changed = true;
    return projected;
  });
  return changed ? { ...session, tools } : session;
}

function projectLegacyToolResultJSONPreview(tool: PickyToolActivity): PickyToolActivity {
  const original = tool.resultPreview;
  if (!original || tool.resultJSONPreview) return tool;

  const result = buildToolResultPreview(original);
  if (!result.jsonText || !result.repaired) return tool;

  return {
    ...tool,
    resultJSONPreview: result.jsonText,
    ...(result.truncated || tool.resultPreviewTruncated ? { resultPreviewTruncated: true } : {}),
    resultPreviewRepaired: true,
  };
}

function safeName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
