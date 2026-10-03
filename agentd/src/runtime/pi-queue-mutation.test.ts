import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import * as pi from "@earendil-works/pi-coding-agent";
import type { AgentSession } from "@earendil-works/pi-coding-agent";
import {
  assertPiQueueMutationSupported,
  movePiFollowUpToSteering,
  PiQueueInternalsError,
  removePiQueuedMessage,
  replacePiQueuedFollowUpText,
} from "./pi-queue-mutation.js";

/**
 * Contract test against a real `AgentSession`. Pi exposes no per-item queue API, so these
 * helpers reach into internals; pinning them here makes an SDK bump fail loudly instead of
 * silently disabling (or corrupting) the HUD's queue editing.
 */
async function sessionWithQueuedFollowUps(texts: readonly string[]): Promise<AgentSession> {
  const cwd = await mkdtemp(join(tmpdir(), "picky-queue-mutation-cwd-"));
  const agentDir = await mkdtemp(join(tmpdir(), "picky-queue-mutation-agent-"));
  const { session } = await pi.createAgentSession({ cwd, agentDir });
  for (const text of texts) await session.followUp(text);
  return session;
}

/** `steeringQueue`/`followUpQueue` are private on Pi's Agent; the helpers mutate them by design. */
function agentQueues(session: AgentSession): { steering: unknown[]; followUp: unknown[] } {
  const agent = session.agent as unknown as { steeringQueue: { messages: unknown[] }; followUpQueue: { messages: unknown[] } };
  return { steering: agent.steeringQueue.messages, followUp: agent.followUpQueue.messages };
}

function queueUpdates(session: AgentSession): Array<{ steering: readonly string[]; followUp: readonly string[] }> {
  const updates: Array<{ steering: readonly string[]; followUp: readonly string[] }> = [];
  session.subscribe((event: { type: string; steering?: readonly string[]; followUp?: readonly string[] }) => {
    if (event.type !== "queue_update") return;
    updates.push({ steering: event.steering ?? [], followUp: event.followUp ?? [] });
  });
  return updates;
}

const noop = (): void => undefined;

describe("Pi per-item queue mutation", () => {
  it("removes one queued entry and keeps the agent message queue aligned", async () => {
    const session = await sessionWithQueuedFollowUps(["first", "second", "third"]);
    const updates = queueUpdates(session);

    expect(removePiQueuedMessage(session, "followUp", 1, noop)).toBe(true);

    expect(session.getFollowUpMessages()).toEqual(["first", "third"]);
    expect(agentQueues(session).followUp).toHaveLength(2);
    expect(updates.at(-1)?.followUp).toEqual(["first", "third"]);
  });

  it("rewrites one queued follow-up in place", async () => {
    const session = await sessionWithQueuedFollowUps(["first", "second"]);

    expect(replacePiQueuedFollowUpText(session, 1, "edited", noop)).toBe(true);

    expect(session.getFollowUpMessages()).toEqual(["first", "edited"]);
    const message = agentQueues(session).followUp[1] as { role: string; content: Array<{ type: string; text: string }> };
    expect(message.role).toBe("user");
    expect(message.content[0]).toMatchObject({ type: "text", text: "edited" });
  });

  it("promotes a queued follow-up into the steering queue exactly once", async () => {
    const session = await sessionWithQueuedFollowUps(["first", "second"]);

    expect(movePiFollowUpToSteering(session, 0, noop)).toBe(true);

    expect(session.getFollowUpMessages()).toEqual(["second"]);
    expect(session.getSteeringMessages()).toEqual(["first"]);
    expect(agentQueues(session).steering).toHaveLength(1);
    expect(agentQueues(session).followUp).toHaveLength(1);
  });

  it("reports a lost race instead of touching a neighbouring entry", async () => {
    const session = await sessionWithQueuedFollowUps(["only"]);

    expect(removePiQueuedMessage(session, "followUp", 3, noop)).toBe(false);
    expect(replacePiQueuedFollowUpText(session, -1, "nope", noop)).toBe(false);
    expect(movePiFollowUpToSteering(session, 1, noop)).toBe(false);
    expect(session.getFollowUpMessages()).toEqual(["only"]);
    expect(session.getSteeringMessages()).toEqual([]);
  });

  it("refuses to mutate a session whose internals no longer match", () => {
    expect(() => assertPiQueueMutationSupported({ _steeringMessages: [], _followUpMessages: [] })).toThrow(PiQueueInternalsError);
    expect(() => removePiQueuedMessage({ _followUpMessages: ["a"], agent: { followUpQueue: { messages: [] } }, _emitQueueUpdate: () => undefined }, "followUp", 0, noop))
      .toThrow(PiQueueInternalsError);
  });

  it("confirms the installed Pi still exposes the queue internals Picky edits", async () => {
    const session = await sessionWithQueuedFollowUps([]);
    expect(() => assertPiQueueMutationSupported(session)).not.toThrow();
  });
});
