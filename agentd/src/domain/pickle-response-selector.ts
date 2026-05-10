import type { PickyAgentSession } from "../protocol.js";

export interface PickleResponseSelection {
  markdown: string;
  messageId: string;
  source: "finalAnswer" | "agentText";
}

/**
 * Choose which markdown body to open in Picky's report viewer for a Pickle session.
 *
 * Preference order:
 * 1. `session.finalAnswer` (the completed assistant final), so a finished Pickle
 *    always shows the canonical reply that the dock card surfaces.
 * 2. The most recent non-empty `agent_text` message, so an in-progress Pickle
 *    can still be opened with its latest streamed reply.
 *
 * Returns `undefined` when neither is available; callers should surface a
 * "no response yet" error rather than opening an empty viewer.
 */
export function selectPickleResponseForReport(session: PickyAgentSession): PickleResponseSelection | undefined {
  const finalAnswer = session.finalAnswer?.trim();
  if (finalAnswer) {
    return { markdown: finalAnswer, messageId: "final-answer", source: "finalAnswer" };
  }
  const messages = session.messages ?? [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.kind !== "agent_text") continue;
    const text = typeof message.text === "string" ? message.text.trim() : "";
    if (text.length === 0) continue;
    return { markdown: text, messageId: message.id, source: "agentText" };
  }
  return undefined;
}
