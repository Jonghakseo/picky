/**
 * Coded reasons a Pickle cannot accept user input right now. The code reaches the
 * client in the protocol `error` event so the composer can say why a message did
 * not go out instead of silently dropping it.
 * - `runtimeRestarting`: the daemon is attaching a fresh runtime; retry shortly.
 * - `runtimeUnavailable`: no runtime can be attached; duplicating the Pickle continues it.
 */
export type SessionInputErrorCode = "runtimeRestarting" | "runtimeUnavailable";

export class SessionInputUnavailableError extends Error {
  constructor(readonly code: SessionInputErrorCode, message: string) {
    super(message);
    this.name = "SessionInputUnavailableError";
  }
}
