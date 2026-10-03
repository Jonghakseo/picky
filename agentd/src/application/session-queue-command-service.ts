import type { PickyAgentSession, PickyScheduledMessage } from "../protocol.js";
import type { MaterializedQueueDeliveryIdentity, PendingQueueDelivery } from "../domain/queue-policy.js";
import type { RuntimeExtensionToolResult, RuntimeSessionHandle } from "../runtime/types.js";
import { delayedActionDurationArgument } from "../domain/delayed-action-store.js";
import {
  delayedActionCancelOutcome,
  findScheduledMessage,
  locateRuntimeQueueItem,
  remainingDelayMs,
  SessionQueueCommandError,
  type SelfQueueMutation,
} from "../domain/session-queue-commands.js";
import type { ScheduledMessageProjector } from "./scheduled-message-projector.js";

/** Registered by `@ryan_nookpi/pi-extension-delayed-action`. */
const DELAYED_ACTION_TOOL = "delay";
const DELAYED_ACTION_CANCEL_COMMAND = "delay-cancel";

/**
 * The extension persists its schedule on a serialized write chain, so the store file lands a
 * moment after its tool or command returns. Picky re-reads until the file agrees rather than
 * publishing a snapshot that still shows the previous schedule.
 */
const STORE_SETTLE_TIMEOUT_MS = 1_000;
const STORE_SETTLE_POLL_MS = 25;

export interface SessionQueueCommandDeps {
  session(sessionId: string): PickyAgentSession;
  handle(sessionId: string, action: string): Promise<RuntimeSessionHandle>;
  /** Pending deliveries for this session, mutated in place to keep delivery bookkeeping aligned. */
  pendingDeliveries(sessionId: string): PendingQueueDelivery[] | undefined;
  /** Deliveries already journaled as user bubbles while still sitting in the runtime queue snapshot. */
  materializedDeliveries(sessionId: string): MaterializedQueueDeliveryIdentity[] | undefined;
  dropPendingDelivery(sessionId: string, itemId: string): void;
  /** Announces a per-item edit so the queue update it causes is not read as a delivery. */
  beginSelfMutation(sessionId: string, mutation: SelfQueueMutation): void;
  endSelfMutation(sessionId: string): void;
  waitForQueuedStateToSettle(sessionId: string): Promise<void>;
  applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void>;
  scheduledMessages: ScheduledMessageProjector;
  /** Delivers text through the session's ordinary input path, exactly like a composer send. */
  send(sessionId: string, text: string): Promise<unknown>;
}

function queueItemGone(itemId: string): SessionQueueCommandError {
  return new SessionQueueCommandError("queueItemNotFound", `Queued message is no longer pending: ${itemId}`);
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Per-item edits on a session's queued input, and the timed messages the delayed-action
 * extension holds for it.
 *
 * Queue edits apply to the runtime first: only after Pi confirms the entry is gone does the
 * matching pending delivery change, which is what keeps a removed message from later
 * materializing as a user bubble and a promoted one from materializing twice.
 */
export class SessionQueueCommandService {
  constructor(private readonly deps: SessionQueueCommandDeps) {}

  async removeQueuedInput(sessionId: string, itemId: string): Promise<void> {
    const { handle, location } = await this.locate(sessionId, itemId, "remove queued input");
    await this.asSelfMutation(sessionId, { action: "remove", itemId }, async () => {
      if (!handle.removeQueuedMessage?.(location.kind, location.index)) throw queueItemGone(itemId);
      this.deps.dropPendingDelivery(sessionId, itemId);
      await this.republishQueue(sessionId, handle);
    });
  }

  /**
   * Rewrites one queued follow-up in place. Rewriting the pending delivery too keeps the queue
   * item's id (so the HUD row does not flicker as delete-then-add) and makes the user bubble Pi
   * eventually journals show the edited text. Screenshots attached to the original submission
   * are dropped: the edit affordance is text-only.
   */
  async editQueuedFollowUp(sessionId: string, itemId: string, text: string): Promise<void> {
    const { handle, location } = await this.locate(sessionId, itemId, "edit queued follow-up");
    if (location.kind !== "followUp") throw queueItemGone(itemId);
    await this.asSelfMutation(sessionId, { action: "rewrite", itemId, text }, async () => {
      if (!handle.replaceQueuedFollowUpText?.(location.index, text)) throw queueItemGone(itemId);
      const pending = this.pending(sessionId, itemId);
      if (pending) {
        pending.text = text;
        delete pending.queueText;
        delete pending.attachedImagesCount;
      }
      await this.republishQueue(sessionId, handle);
    });
  }

  /** Promotes one queued follow-up into the steering queue so the agent takes it at the next tool boundary. */
  async sendQueuedFollowUpNow(sessionId: string, itemId: string): Promise<void> {
    const { handle, location } = await this.locate(sessionId, itemId, "send queued follow-up now");
    if (location.kind !== "followUp") throw queueItemGone(itemId);
    await this.asSelfMutation(sessionId, { action: "promote", itemId }, async () => {
      if (!handle.moveFollowUpToSteering?.(location.index)) throw queueItemGone(itemId);
      const pending = this.pending(sessionId, itemId);
      if (pending) pending.kind = "steering";
      await this.republishQueue(sessionId, handle);
    });
  }

  async scheduleMessage(sessionId: string, text: string, delayMs: number): Promise<void> {
    const handle = await this.delayedActionHandle(sessionId, "schedule message");
    const before = (this.deps.session(sessionId).scheduledMessages ?? []).length;
    const result = await this.schedule(handle, delayMs, text);
    const scheduledId = typeof result.details?.id === "string" ? result.details.id : undefined;
    await this.settleSchedule(sessionId, (messages) => (scheduledId
      ? messages.some((message) => message.id === scheduledId)
      : messages.length > before));
  }

  async cancelScheduledMessage(sessionId: string, scheduledId: string): Promise<void> {
    const handle = await this.delayedActionHandle(sessionId, "cancel scheduled message");
    await handle.runExtensionCommandSilently!(DELAYED_ACTION_CANCEL_COMMAND, scheduledId);
    await this.settleSchedule(sessionId, (messages) => !findScheduledMessage(messages, scheduledId));
  }

  /**
   * Cancels one task and reports whether the extension actually held it. A task whose timer
   * fired just before the cancel arrived is already delivered, so the caller must not
   * re-schedule or re-send it.
   */
  private async cancelScheduled(sessionId: string, handle: RuntimeSessionHandle, scheduledId: string): Promise<void> {
    const result = await handle.runExtensionCommandSilently!(DELAYED_ACTION_CANCEL_COMMAND, scheduledId);
    if (delayedActionCancelOutcome(result?.notifications ?? []) === "missing") {
      await this.deps.scheduledMessages.refresh(sessionId);
      throw queueItemGone(scheduledId);
    }
    const settled = await this.settleSchedule(sessionId, (messages) => !findScheduledMessage(messages, scheduledId));
    if (findScheduledMessage(settled, scheduledId)) {
      throw new Error(`Cancelling the scheduled message failed, so it was left untouched: ${scheduledId}`);
    }
  }

  /**
   * Rewrites a scheduled message while keeping its due time: the extension has no edit API,
   * so Picky cancels and re-schedules the remaining delay under the same id. A failed
   * re-schedule puts the original message back, so a rejected edit never silently drops it.
   */
  async editScheduledMessage(sessionId: string, scheduledId: string, text: string): Promise<void> {
    const handle = await this.delayedActionHandle(sessionId, "edit scheduled message");
    const existing = await this.requireScheduled(sessionId, scheduledId);
    await this.cancelScheduled(sessionId, handle, scheduledId);
    try {
      await this.schedule(handle, remainingDelayMs(existing.dueAt, Date.now()), text, scheduledId);
    } catch (error) {
      await this.restoreScheduled(sessionId, handle, existing, error);
      throw error;
    }
    await this.settleSchedule(sessionId, (messages) => findScheduledMessage(messages, scheduledId)?.text === text);
  }

  /**
   * Cancels the schedule and delivers the message exactly like a composer send would. The send
   * waits for the cancel to land on disk: a message that already fired, or whose cancel did not
   * take, must not be delivered a second time.
   */
  async sendScheduledMessageNow(sessionId: string, scheduledId: string): Promise<void> {
    const handle = await this.delayedActionHandle(sessionId, "send scheduled message now");
    const existing = await this.requireScheduled(sessionId, scheduledId);
    await this.cancelScheduled(sessionId, handle, scheduledId);
    try {
      await this.deps.send(sessionId, existing.text);
    } catch (error) {
      // The schedule is already gone, so a failed send would drop the message entirely.
      await this.restoreScheduled(sessionId, handle, existing, error);
      throw error;
    }
  }

  /**
   * Puts a cancelled schedule back after the operation that replaced it failed, keeping its id
   * and what was left of its delay. A failed restore is reported with the message text, so a
   * user whose message Picky could not put back can still see and resend it.
   */
  private async restoreScheduled(
    sessionId: string,
    handle: RuntimeSessionHandle,
    original: PickyScheduledMessage,
    cause: unknown,
  ): Promise<void> {
    try {
      await this.schedule(handle, remainingDelayMs(original.dueAt, Date.now()), original.text, original.id);
    } catch {
      throw new Error(`${errorText(cause)} The scheduled message could not be restored either: "${original.text}"`);
    } finally {
      await this.deps.scheduledMessages.refresh(sessionId).catch(() => undefined);
    }
  }

  private pending(sessionId: string, itemId: string): PendingQueueDelivery | undefined {
    return this.deps.pendingDeliveries(sessionId)?.find((entry) => entry.id === itemId);
  }

  /**
   * Runs a queue edit with the mutation announced to the supervisor. It has to be announced
   * before the runtime call, because Pi publishes its queue update synchronously from inside
   * that call, and withdrawn once the republished queue has settled.
   */
  private async asSelfMutation(sessionId: string, mutation: SelfQueueMutation, edit: () => Promise<void>): Promise<void> {
    this.deps.beginSelfMutation(sessionId, mutation);
    try {
      await edit();
    } finally {
      this.deps.endSelfMutation(sessionId);
    }
  }

  /**
   * Re-reads the extension's store before mutating it. The projected row the user clicked can
   * be one refresh behind a message that already fired or was cancelled elsewhere.
   */
  private async requireScheduled(sessionId: string, scheduledId: string): Promise<PickyScheduledMessage> {
    const existing = findScheduledMessage(await this.deps.scheduledMessages.refresh(sessionId), scheduledId);
    if (!existing) throw queueItemGone(scheduledId);
    return existing;
  }

  /** Re-reads the store until it reflects the mutation, or until the settle window elapses. */
  private async settleSchedule(
    sessionId: string,
    settled: (messages: readonly PickyScheduledMessage[]) => boolean,
  ): Promise<PickyScheduledMessage[]> {
    const deadline = Date.now() + STORE_SETTLE_TIMEOUT_MS;
    let messages = await this.deps.scheduledMessages.refresh(sessionId);
    while (!settled(messages) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, STORE_SETTLE_POLL_MS));
      messages = await this.deps.scheduledMessages.refresh(sessionId);
    }
    return messages;
  }

  private async republishQueue(sessionId: string, handle: RuntimeSessionHandle): Promise<void> {
    await this.deps.applyQueueUpdate(sessionId, handle.getSteeringMessages(), handle.getFollowUpMessages());
  }

  private async locate(sessionId: string, itemId: string, action: string): Promise<{ handle: RuntimeSessionHandle; location: NonNullable<ReturnType<typeof locateRuntimeQueueItem>> }> {
    const handle = await this.deps.handle(sessionId, action);
    if (!handle.removeQueuedMessage || !handle.replaceQueuedFollowUpText || !handle.moveFollowUpToSteering) {
      throw new Error("Runtime does not support per-item queue edits");
    }
    await this.deps.waitForQueuedStateToSettle(sessionId);
    const session = this.deps.session(sessionId);
    const location = locateRuntimeQueueItem(
      { steering: session.queuedSteers ?? [], followUp: session.queuedFollowUps ?? [] },
      { steering: handle.getSteeringMessages(), followUp: handle.getFollowUpMessages() },
      itemId,
      {
        pending: this.deps.pendingDeliveries(sessionId) ?? [],
        materialized: this.deps.materializedDeliveries(sessionId) ?? [],
      },
    );
    if (!location) throw queueItemGone(itemId);
    return { handle, location };
  }

  private async delayedActionHandle(sessionId: string, action: string): Promise<RuntimeSessionHandle> {
    const handle = await this.deps.handle(sessionId, action);
    const available = handle.hasExtensionTool?.(DELAYED_ACTION_TOOL) === true
      && handle.hasExtensionCommand?.(DELAYED_ACTION_CANCEL_COMMAND) === true
      && Boolean(handle.runExtensionToolSilently)
      && Boolean(handle.runExtensionCommandSilently);
    if (!available) {
      throw new SessionQueueCommandError("delayedActionUnavailable", "The delayed action plugin is not installed for this session");
    }
    await this.deps.scheduledMessages.track(sessionId, handle.getPiSessionId?.());
    return handle;
  }

  /**
   * Uses the extension's tool rather than its `/delay` command: the command parses the duration
   * out of free text, so a message that starts with something like "5m" would be swallowed as
   * part of the delay.
   */
  private async schedule(handle: RuntimeSessionHandle, delayMs: number, text: string, id?: string): Promise<RuntimeExtensionToolResult> {
    const result = await handle.runExtensionToolSilently!(DELAYED_ACTION_TOOL, {
      delay: delayedActionDurationArgument(delayMs),
      prompt: text,
      ...(id ? { id } : {}),
    });
    if (result.isError) throw new Error(result.text || "Scheduling the message failed");
    return result;
  }
}
