import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { PickyAgentSessionSchema, type PickyAgentSession } from "./protocol.js";

export class SessionStore {
  private readonly sessionsDir: string;
  constructor(appSupportDir: string) {
    this.sessionsDir = join(appSupportDir, "sessions");
  }

  async save(session: PickyAgentSession): Promise<void> {
    await mkdir(this.sessionsDir, { recursive: true });
    const targetPath = join(this.sessionsDir, `${safeName(session.id)}.json`);
    const tempPath = join(this.sessionsDir, `.${safeName(session.id)}.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(session, null, 2));
    await rename(tempPath, targetPath);
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
      return PickyAgentSessionSchema.parse(JSON.parse(await readFile(filePath, "utf8")));
    } catch (error) {
      console.warn(`Skipping unreadable Picky session metadata ${filePath}: ${messageOf(error)}`);
      return undefined;
    }
  }
}

function safeName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
