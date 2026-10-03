/**
 * Per-item edits on Pi's steering / follow-up queues.
 *
 * Pi 0.87 exposes queue mutation only as "append" (`steer`/`followUp`) and "drop everything"
 * (`clearQueue`). Picky's messenger UX needs to remove, rewrite, and promote a single queued
 * message, so this module reaches into two internals that must stay aligned:
 *
 *   - `AgentSession._steeringMessages` / `_followUpMessages`: the display strings Pi reports
 *     through `getSteeringMessages()` / `getFollowUpMessages()`.
 *   - `AgentSession.agent.steeringQueue.messages` / `followUpQueue.messages`: the real
 *     `AgentMessage` entries (text plus image content) the agent loop drains.
 *
 * Every helper validates the shape first and refuses to touch a session whose internals no
 * longer match, so an SDK bump degrades to "per-item edit unavailable" instead of corrupting
 * the queue. `pi-queue-mutation.test.ts` pins the contract against a real `AgentSession`.
 */

export type PiQueueKind = "steering" | "followUp";

interface PiQueueInternals {
  texts: string[];
  messages: unknown[];
  emitQueueUpdate: () => void;
  session: Record<string, unknown>;
}

export class PiQueueInternalsError extends Error {
  constructor(detail: string) {
    super(`Pi queue internals are not in the expected shape: ${detail}`);
    this.name = "PiQueueInternalsError";
  }
}

const TEXT_FIELD: Record<PiQueueKind, string> = {
  steering: "_steeringMessages",
  followUp: "_followUpMessages",
};
const QUEUE_FIELD: Record<PiQueueKind, string> = {
  steering: "steeringQueue",
  followUp: "followUpQueue",
};

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((entry) => typeof entry === "string");
}

function readInternals(session: unknown, kind: PiQueueKind): PiQueueInternals {
  if (!session || typeof session !== "object") throw new PiQueueInternalsError("session is not an object");
  const record = session as Record<string, unknown>;
  const texts = record[TEXT_FIELD[kind]];
  if (!isStringArray(texts)) throw new PiQueueInternalsError(`${TEXT_FIELD[kind]} is not a string array`);
  const agent = record.agent;
  if (!agent || typeof agent !== "object") throw new PiQueueInternalsError("session.agent is not an object");
  const queue = (agent as Record<string, unknown>)[QUEUE_FIELD[kind]];
  if (!queue || typeof queue !== "object") throw new PiQueueInternalsError(`agent.${QUEUE_FIELD[kind]} is not an object`);
  const messages = (queue as Record<string, unknown>).messages;
  if (!Array.isArray(messages)) throw new PiQueueInternalsError(`agent.${QUEUE_FIELD[kind]}.messages is not an array`);
  if (messages.length !== texts.length) {
    throw new PiQueueInternalsError(`${TEXT_FIELD[kind]} (${texts.length}) and agent.${QUEUE_FIELD[kind]}.messages (${messages.length}) are misaligned`);
  }
  const emitQueueUpdate = record._emitQueueUpdate;
  if (typeof emitQueueUpdate !== "function") throw new PiQueueInternalsError("_emitQueueUpdate is not a function");
  return { texts, messages, emitQueueUpdate: () => (emitQueueUpdate as () => void).call(session), session: record };
}

/**
 * Reads both queues without mutating them. Only the contract test uses it, to assert that the
 * installed Pi still exposes the internals the per-item edits require.
 */
export function assertPiQueueMutationSupported(session: unknown): void {
  readInternals(session, "steering");
  readInternals(session, "followUp");
}

/**
 * Removes one queued entry. Returns false when the index is no longer in the queue, which is
 * how a lost race against the agent draining that entry is reported.
 */
export function removePiQueuedMessage(session: unknown, kind: PiQueueKind, index: number, onChanged: () => void): boolean {
  const internals = readInternals(session, kind);
  if (index < 0 || index >= internals.texts.length) return false;
  internals.texts.splice(index, 1);
  internals.messages.splice(index, 1);
  internals.emitQueueUpdate();
  onChanged();
  return true;
}

/**
 * Rewrites one queued follow-up in place. Image attachments of the original submission are
 * dropped: the replacement carries only the new text, which matches the HUD's edit affordance
 * (a text field) and avoids re-sending screenshots the user can no longer see.
 */
export function replacePiQueuedFollowUpText(session: unknown, index: number, text: string, onChanged: () => void): boolean {
  const internals = readInternals(session, "followUp");
  if (index < 0 || index >= internals.texts.length) return false;
  internals.texts[index] = text;
  internals.messages[index] = { role: "user", content: [{ type: "text", text }], timestamp: Date.now() };
  internals.emitQueueUpdate();
  onChanged();
  return true;
}

/**
 * Moves one queued follow-up to the end of the steering queue so Pi delivers it at the next
 * tool boundary instead of after the current reply. The original `AgentMessage` moves intact,
 * so image attachments survive.
 */
export function movePiFollowUpToSteering(session: unknown, index: number, onChanged: () => void): boolean {
  const followUp = readInternals(session, "followUp");
  const steering = readInternals(session, "steering");
  if (index < 0 || index >= followUp.texts.length) return false;
  const [text] = followUp.texts.splice(index, 1);
  const [message] = followUp.messages.splice(index, 1);
  steering.texts.push(text!);
  steering.messages.push(message);
  steering.emitQueueUpdate();
  onChanged();
  return true;
}
