import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";

export interface PendingExtensionUiCancellationDeps {
  session(sessionId: string): PickyAgentSession;
  cancelExtensionQuestion(sessionId: string, requestId: string): Promise<void>;
  patch(sessionId: string, patch: Partial<PickyAgentSession>): Promise<void>;
}

/** Cancels an open extension dialog before new user input reaches the runtime. */
export async function cancelPendingExtensionUiForUserInput(deps: PendingExtensionUiCancellationDeps, sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
  const pending = deps.session(sessionId).pendingExtensionUiRequest;
  if (!pending) return;
  // Best-effort cancel of the runtime-side dialog. The bridge may have already
  // discarded this id (turn completed, runtime resume, timeout, etc.) and would
  // throw "Unknown extension UI request"; previously that failure propagated out
  // of supervisor.followUp and got reported to the HUD as `command failed`,
  // which made the user's next message look like it had been silently dropped.
  // Use ignoreUnknown so stale cleanup never blocks new user input, and always
  // run the supervisor-side state reconciliation below.
  if (handle.answerExtensionUi) {
    await handle.answerExtensionUi(pending.id, { cancelled: true }, { ignoreUnknown: true });
  }
  await deps.cancelExtensionQuestion(sessionId, pending.id);
  if (deps.session(sessionId).pendingExtensionUiRequest?.id === pending.id) {
    await deps.patch(sessionId, { pendingExtensionUiRequest: undefined, thinkingPreview: undefined });
  }
}
