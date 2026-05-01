import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { PickyAgentSessionSchema, type PickyAgentSession } from "./protocol.js";

export class SessionStore {
  private readonly sessionsDir: string;
  constructor(appSupportDir: string) {
    this.sessionsDir = join(appSupportDir, "sessions");
  }

  async save(session: PickyAgentSession): Promise<void> {
    await mkdir(this.sessionsDir, { recursive: true });
    await writeFile(join(this.sessionsDir, `${safeName(session.id)}.json`), JSON.stringify(session, null, 2));
  }

  async loadAll(): Promise<PickyAgentSession[]> {
    try {
      const names = await readdir(this.sessionsDir);
      const sessions = await Promise.all(
        names
          .filter((name) => name.endsWith(".json"))
          .map(async (name) => PickyAgentSessionSchema.parse(JSON.parse(await readFile(join(this.sessionsDir, name), "utf8")))),
      );
      return sessions.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
  }
}

function safeName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}
