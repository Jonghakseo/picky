import { randomUUID } from "node:crypto";
import type { Dirent } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { isTerminalStatus } from "./domain/session-status.js";
import { PickyAgentSessionSchema, PickyMainAgentStateSchema, type PickyAgentSession, type PickyMainAgentState } from "./protocol.js";

export const ORPHANED_CHILD_SESSION_RECOVERY_LOG = "orphaned child Pickle session recovered from scoped metadata";
export const ORPHANED_CHILD_SESSION_RECOVERY_SUMMARY = "Child Pickle daemon is not attached after Picky restart; send a follow-up or steer message to continue.";

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
    if (this.scopeSessionId && session.id !== this.scopeSessionId) {
      throw new Error(`SessionStore scoped to ${this.scopeSessionId} cannot save session ${session.id}`);
    }
    await mkdir(this.sessionsDir, { recursive: true });
    const targetPath = join(this.sessionsDir, `${safeName(session.id)}.json`);
    const tempPath = join(this.sessionsDir, `.${safeName(session.id)}.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(session, null, 2));
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
      if (migrated.changed && persistMigration) await this.save(session);
      return session;
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
  if (!value || typeof value !== "object" || !Array.isArray((value as { messages?: unknown }).messages)) return { value, changed: false };
  let changed = false;
  const session = value as { messages: unknown[] };
  const messages = session.messages.map((message) => {
    if (!message || typeof message !== "object" || (message as { kind?: unknown }).kind !== "agent_report") return message;
    changed = true;
    return { ...message, kind: "agent_text" };
  });
  return changed ? { value: { ...value, messages }, changed } : { value, changed: false };
}

function safeName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
