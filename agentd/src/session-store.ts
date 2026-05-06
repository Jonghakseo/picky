import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { PickyAgentSessionSchema, PickyMainAgentStateSchema, type PickyAgentSession, type PickyMainAgentState } from "./protocol.js";

export class SessionStore {
  private readonly sessionsDir: string;
  private readonly mainAgentPath: string;
  constructor(private readonly appSupportDir: string) {
    this.sessionsDir = join(appSupportDir, "sessions");
    this.mainAgentPath = join(appSupportDir, "main-agent.json");
  }

  async save(session: PickyAgentSession): Promise<void> {
    await mkdir(this.sessionsDir, { recursive: true });
    const targetPath = join(this.sessionsDir, `${safeName(session.id)}.json`);
    const tempPath = join(this.sessionsDir, `.${safeName(session.id)}.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(session, null, 2));
    await rename(tempPath, targetPath);
  }

  async saveMainAgentState(state: PickyMainAgentState): Promise<void> {
    await mkdir(this.appSupportDir, { recursive: true });
    const tempPath = join(this.appSupportDir, `.main-agent.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(state, null, 2));
    await rename(tempPath, this.mainAgentPath);
  }

  async loadMainAgentState(): Promise<PickyMainAgentState> {
    try {
      return PickyMainAgentStateSchema.parse(JSON.parse(await readFile(this.mainAgentPath, "utf8")));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        console.warn(`Skipping unreadable Picky main-agent metadata ${this.mainAgentPath}: ${messageOf(error)}`);
      }
      return { messages: [] };
    }
  }

  async loadAll(): Promise<PickyAgentSession[]> {
    let names: string[];
    try {
      names = await readdir(this.sessionsDir);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }

    const sessions = await Promise.all(
      names
        .filter((name) => name.endsWith(".json"))
        .map(async (name) => this.loadOne(name)),
    );
    return sessions.filter((session): session is PickyAgentSession => Boolean(session)).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  private async loadOne(name: string): Promise<PickyAgentSession | undefined> {
    const filePath = join(this.sessionsDir, name);
    try {
      const raw = JSON.parse(await readFile(filePath, "utf8"));
      const migrated = migrateLegacySession(raw);
      const session = PickyAgentSessionSchema.parse(migrated.value);
      if (migrated.changed) await this.save(session);
      return session;
    } catch (error) {
      console.warn(`Skipping unreadable Picky session metadata ${filePath}: ${messageOf(error)}`);
      return undefined;
    }
  }
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
