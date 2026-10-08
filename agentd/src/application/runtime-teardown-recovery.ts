import { randomUUID } from "node:crypto";
import { logAgentd } from "../local-log.js";
import { SessionInputUnavailableError } from "../domain/session-input-errors.js";
import type { PickyAgentSession } from "../protocol.js";

export interface RuntimeTeardownRecoveryDeps {
  session(sessionId: string): PickyAgentSession | undefined;
  /** Pi session file the abandoned runtime was bound to. */
  sourcePiSessionFile(sessionId: string): string | undefined;
  /** Copies the Pi session file under a new name and Pi session id. */
  forkPiSessionFile(sourcePath: string, name: string): Promise<string>;
  /** Drops the runtime whose teardown failed and lifts its disposal fence. */
  abandonRuntime(sessionId: string): Promise<void>;
  /** Re-applies the disposal fence after a failed recovery. */
  fenceRuntime(sessionId: string): void;
  /** Attaches a fresh runtime on the given Pi session file; false when it could not. */
  resume(sessionId: string, piSessionFilePath: string): Promise<boolean>;
  /** Lets async control acknowledge the abandoned owner's work so admission can reopen. */
  continueAsyncWork(sessionId: string): Promise<void>;
  patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
}

/**
 * Recovers a Pickle whose runtime the daemon could not tear down. Without it the
 * disposal fence rejects every later input until the daemon restarts.
 *
 * The abandoned runtime may still hold its Pi session file, so the replacement runs
 * on a fork of that file under the same Pickle id: two runtimes never write one file.
 * Work the abandoned runtime had in flight does not continue in the replacement.
 */
export class RuntimeTeardownRecovery {
  private readonly active = new Map<string, Promise<void>>();

  constructor(private readonly deps: RuntimeTeardownRecoveryDeps) {}

  isRecovering(sessionId: string): boolean {
    return this.active.has(sessionId);
  }

  /** Runs a teardown; when it fails for a visible Pickle, restarts that Pickle in the background. */
  async guardTeardown(sessionId: string, teardown: () => Promise<void>): Promise<void> {
    try { await teardown(); } catch (error) {
      if (this.deps.session(sessionId)?.archived !== true) void this.start(sessionId);
      throw error;
    }
  }

  /** Marks a Pickle that has no runtime to take input and returns the coded rejection. */
  async unavailable(sessionId: string, reason: string): Promise<SessionInputUnavailableError> {
    await this.deps.patch(sessionId, { status: "blocked", lastSummary: reason, runtimeRecovery: { phase: "failed", updatedAt: new Date().toISOString() } });
    return new SessionInputUnavailableError("runtimeUnavailable", reason);
  }

  /**
   * Input does not wait for a restart: it is rejected with a code the composer explains.
   * The first input after a finished restart clears the restart notice.
   */
  async admitInput(sessionId: string): Promise<void> {
    if (this.isRecovering(sessionId)) throw new SessionInputUnavailableError("runtimeRestarting", "Pickle runtime is restarting");
    if (this.deps.session(sessionId)?.runtimeRecovery?.phase === "restarted") await this.deps.patch(sessionId, { runtimeRecovery: undefined });
  }

  start(sessionId: string): Promise<void> {
    const running = this.active.get(sessionId);
    if (running) return running;
    const recovery = this.run(sessionId).finally(() => { this.active.delete(sessionId); });
    this.active.set(sessionId, recovery);
    return recovery;
  }

  private async run(sessionId: string): Promise<void> {
    const now = () => new Date().toISOString();
    try {
      await this.deps.patch(sessionId, { runtimeRecovery: { phase: "restarting", updatedAt: now() } });
      const source = this.deps.sourcePiSessionFile(sessionId);
      if (!source) throw new Error("No Pi session file to restart from");
      const forked = await this.deps.forkPiSessionFile(source, `${sessionId}-restart-${randomUUID().slice(0, 8)}`);
      await this.deps.abandonRuntime(sessionId);
      // The session file now points at the fork, so no later resume reopens the abandoned file.
      await this.deps.patch(sessionId, { piSessionFilePath: forked });
      if (!await this.deps.resume(sessionId, forked)) throw new Error("Fresh runtime could not be attached");
      await this.deps.continueAsyncWork(sessionId).catch((error: unknown) => {
        logAgentd("runtime restart left async admission closed", { sessionId, error: error instanceof Error ? error.message : String(error) });
      });
      const session = this.deps.session(sessionId);
      await this.deps.patch(sessionId, {
        runtimeRecovery: { phase: "restarted", updatedAt: now() },
        status: session?.finalAnswer ? "completed" : "waiting_for_input",
        lastSummary: "Pickle runtime restarted",
      });
      logAgentd("runtime restarted after teardown failure", { sessionId, piSessionFilePath: forked });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.deps.fenceRuntime(sessionId);
      logAgentd("runtime restart after teardown failure failed", { sessionId, error: message });
      await this.deps.patch(sessionId, {
        runtimeRecovery: { phase: "failed", updatedAt: now() },
        status: "blocked",
        lastSummary: "Pickle runtime could not be restarted",
      }).catch(() => undefined);
    }
  }
}
