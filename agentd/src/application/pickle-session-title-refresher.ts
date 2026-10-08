import { piSessionFilePathForSession } from "../domain/pi-session-files.js";
import { isUserAssignedTitle } from "../domain/session-rename-policy.js";
import { logAgentd } from "../local-log.js";
import type { PickyAgentSession } from "../protocol.js";
import { readPiSessionInfoName } from "./pi-session-syncer.js";

export interface PickleSessionTitleRefresherDependencies {
  isPickleSession(sessionId: string): boolean;
  getSession(sessionId: string): PickyAgentSession | undefined;
  /** Atomic conditional write: skips a user-assigned name or a session that moved files. */
  applyAutoTitle(sessionId: string, name: string, expectedPiSessionFilePath: string): Promise<void>;
}

/**
 * Synchronizes a Pickle card title with the Pi session-info name without overwriting newer state.
 * A name the user chose in Picky wins: Picky stores the display name, Pi keeps its own session
 * name, and the two are allowed to differ after an explicit rename.
 */
export class PickleSessionTitleRefresher {
  constructor(private readonly dependencies: PickleSessionTitleRefresherDependencies) {}

  async refresh(sessionId: string): Promise<void> {
    if (!this.dependencies.isPickleSession(sessionId)) return;
    const session = this.dependencies.getSession(sessionId);
    if (!session || isUserAssignedTitle(session)) return;
    const sessionFilePath = piSessionFilePathForSession(session);
    if (!sessionFilePath) return;
    try {
      const name = await readPiSessionInfoName(sessionFilePath);
      if (!name) return;
      // Reading the file is slow enough for `/new` to land in between. Pass the file this name
      // came from so the commit drops it unless the session is still on that Pi session.
      logAgentd("pickle session title refresh from pi", { sessionId, sessionFilePath });
      await this.dependencies.applyAutoTitle(sessionId, name, sessionFilePath);
    } catch (error) {
      logAgentd("pickle session title refresh failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
    }
  }
}
