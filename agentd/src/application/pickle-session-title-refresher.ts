import { piSessionFilePathForSession } from "../domain/pi-session-files.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession } from "../protocol.js";
import { readPiSessionInfoName } from "./pi-session-syncer.js";

export interface PickleSessionTitleRefresherDependencies {
  isPickleSession(sessionId: string): boolean;
  getSession(sessionId: string): PickyAgentSession | undefined;
  patchSession(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
}

/** Synchronizes a Pickle card title with the Pi session-info name without overwriting newer state. */
export class PickleSessionTitleRefresher {
  constructor(private readonly dependencies: PickleSessionTitleRefresherDependencies) {}

  async refresh(sessionId: string): Promise<void> {
    if (!this.dependencies.isPickleSession(sessionId)) return;
    const session = this.dependencies.getSession(sessionId);
    if (!session) return;
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) return;
    try {
      const name = await readPiSessionInfoName(sessionFilePath);
      if (!name) return;
      const current = this.dependencies.getSession(sessionId);
      if (!current || current.title === name) return;
      logAgentd("pickle session title refreshed from pi", { sessionId, previousTitle: current.title, name });
      await this.dependencies.patchSession(sessionId, { title: name });
    } catch (error) {
      logAgentd("pickle session title refresh failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
    }
  }
}
