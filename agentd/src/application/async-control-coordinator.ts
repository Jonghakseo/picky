import { aggregateAsyncWork, asyncExecutionIsActive, asyncOperationResolved, hasAsyncExecutionObligations, isAcknowledgedAsyncWork, isAsyncTracked, isPreviousOwnerAsyncTask } from "../domain/async-work-aggregate.js";
import { randomUUID } from "node:crypto";
import type { AsyncTaskCommand, AsyncTaskCommandResult, AsyncTaskOwner } from "../domain/async-task-contract.js";
import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";
import { sameAsyncOwner } from "../runtime/async-task-state.js";
import { KeyedSerialQueue } from "../domain/keyed-serial-queue.js";
import { hasQuiescentReleasedAsyncOwner } from "../domain/session-supervisor-projection-policy.js";
import { logAgentd } from "../local-log.js";
import { SessionInputUnavailableError } from "../domain/session-input-errors.js";

type StopCommand = Omit<Extract<AsyncTaskCommand, { type: "prepareSessionArchive" }>, "type" | "archiveIntentId" | "requireQuiescence"> & { type: "stopAsyncTasks" };
type LifecycleCommand = Omit<StopCommand, "type"> & { type: "prepareAsyncReplacement" | "reconcileAsyncControl"; inputLease?: boolean };
type Command = AsyncTaskCommand | StopCommand | LifecycleCommand;
type Outcome = AsyncTaskCommandResult["outcome"];
interface Dependencies {
  read(id: string): PickyAgentSession;
  handle(id: string): RuntimeSessionHandle | undefined;
  pendingInput(id: string): boolean;
  runtimeBlocked(id: string): boolean;
  patch(id: string, patch: Partial<PickyAgentSession>): Promise<void>;
  commit(id: string, build: (session: PickyAgentSession) => PickyAgentSession): Promise<{ after: PickyAgentSession }>;
  abortModel(id: string, handle: RuntimeSessionHandle): Promise<void>;
  drain(id: string): Promise<void>;
  archived(id: string, archived: boolean): void;
  resumeReleased(id: string): Promise<RuntimeSessionHandle | undefined>;
  resumeDetached(id: string): Promise<RuntimeSessionHandle | undefined>;
  pendingRuntimeHandle(id: string, action: string): Promise<RuntimeSessionHandle | undefined>;
}
function hasUnsettledAttachedAsyncWork(handle: RuntimeSessionHandle, session: PickyAgentSession): boolean {
  const unsettled = (task: NonNullable<PickyAgentSession["asyncTasks"]>[number]) =>
    task.presence !== "settled" || ["queued", "running", "cancelling"].includes(task.execution);
  return handle.isStreaming === true || handle.isCompacting === true || handle.hasPendingAsyncWork === true
    || session.asyncTasks?.some(unsettled) === true || handle.asyncTasks?.snapshot().tasks.some(unsettled) === true;
}

/**
 * Fences a command against the work the user saw. A stop is built by the daemon from
 * its own context and means "stop whatever runs now", so a running Pickle or a
 * concurrent clearQueue advancing the work revision must not reject it. Owner and
 * control-generation (archive cut) checks still apply.
 */
function sameControlWork(command: Command, workRevision: number | undefined, controlGeneration: number | undefined): boolean {
  return (command.type === "stopAsyncTasks" || command.workRevision === workRevision) && command.controlGeneration === controlGeneration;
}

export class ControlFailure extends Error {
  readonly code = "async_control_blocked";
  constructor(readonly outcome: Outcome, message: string) { super(message); }
}

/** Operation records use the session's existing durable writer; slow controls never hold it. */
export class AsyncControlCoordinator {
  readonly daemonInstanceId = randomUUID();
  private readonly queue = new KeyedSerialQueue();
  private readonly inputLeases = new Map<string, number>();
  constructor(private readonly deps: Dependencies) {}

  context(sessionId: string) {
    const session = this.deps.read(sessionId);
    const coverage = this.deps.handle(sessionId)?.asyncTasks?.coverage();
    return { sessionId, requiresArchiveChoice: this.requiresArchiveChoice(sessionId), archiveIntentId: session.asyncArchiveIntentId, releasePrepared: session.asyncControl?.releasePrepared, daemonInstanceId: this.daemonInstanceId, runtimeInstanceId: coverage?.runtimeInstanceId,
      workRevision: session.asyncWorkSummary?.workRevision ?? 0, controlGeneration: session.asyncControl?.controlGeneration ?? 0,
      admissionState: session.asyncControl?.admissionState ?? "closed" as const,
      tracking: coverage?.tracking ?? "unsupported" as const, expectedProviders: coverage?.expectedProviders ?? [], readyProviders: coverage?.readyProviders ?? [] };
  }

  /**
   * A tracked Pickle can lose its owner while visible and idle (e.g. terminal sync
   * invalidated a stale branch). User actions reattach a fresh owner from the Pi
   * session file, mirroring startup resume, instead of failing closed forever.
   * Archived and released owners keep their explicit restore path.
   */
  async attachDetachedOwner(sessionId: string, coverageWaitMs = 5_000): Promise<void> {
    const session = this.deps.read(sessionId);
    if (!isAsyncTracked(session) || session.archived === true || session.asyncControl?.releasePrepared) return;
    if (this.deps.handle(sessionId) || this.deps.runtimeBlocked(sessionId)) return;
    const handle = await this.deps.resumeDetached(sessionId).catch(() => undefined);
    if (!handle?.asyncTasks) return;
    await this.awaitCoverage(sessionId, handle, coverageWaitMs);
  }

  /**
   * Startup resume and plugin reloads close admission without a matching reopen. Input
   * that does not pass through `input()` (for example a Pi extension injecting a user
   * message) would otherwise be rejected by the model fence until the next Picky input.
   * Reopen only when the owner is already provably quiescent and no plugin reload is
   * pending (that reload would close admission again mid-turn); the precheck keeps a
   * failed attempt out of the durable control journal.
   */
  async reopenIdleAdmission(sessionId: string, trigger: "restart" | "plugin reload", coverageWaitMs = 5_000): Promise<boolean> {
    try {
      const handle = this.deps.handle(sessionId);
      // Only idle re-entry candidates; a session with a turn in flight reopens through its input.
      if (!handle?.asyncTasks || !["completed", "waiting_for_input"].includes(this.deps.read(sessionId).status)) return false;
      await this.awaitCoverage(sessionId, handle, coverageWaitMs);
      const session = this.deps.read(sessionId);
      if (!isAsyncTracked(session) || session.archived || session.asyncControl?.admissionState !== "closed") return false;
      if (session.asyncControl.releasePrepared || session.asyncControl.operations.some((operation) => operation.outcome === "accepted")) return false;
      const reloadPending = () => this.deps.handle(sessionId)?.hasPendingResourceReload === true;
      if (reloadPending()) return false;
      const probe = this.internalCommand(sessionId, "reconcileAsyncControl");
      this.assertPhysicalQuiescence(probe, this.assertOwner(probe));
      return await this.reopenIfQuiescent(sessionId, false, reloadPending);
    } catch (error) {
      logAgentd("async admission stays closed after idle reopen attempt", { sessionId, trigger, error: error instanceof Error ? error.message : String(error) });
      return false;
    }
  }

  private async awaitCoverage(sessionId: string, handle: RuntimeSessionHandle, coverageWaitMs: number): Promise<void> {
    const control = handle.asyncTasks!;
    // Provider readiness arrives shortly after resume; callers need a settled coverage answer.
    const deadline = Date.now() + coverageWaitMs;
    while (control.coverage().tracking === "reconciling" && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    await this.deps.drain(sessionId);
  }

  /** Runs the journaled reconcile, then reopens admission only if the owner is still quiescent. */
  private async reopenIfQuiescent(sessionId: string, lease: boolean, deferReopen?: () => boolean): Promise<boolean> {
    // A user input lease accepts that work lost with a previous runtime stays unknown.
    const recovered = await this.execute(this.internalCommand(sessionId, "reconcileAsyncControl", lease));
    if (recovered.outcome !== "settled") throw new Error(recovered.reason ?? recovered.outcome);
    let reopened = false;
    await this.queue.run(sessionId, async () => {
      const current = this.deps.read(sessionId);
      if (current.asyncControl?.releasePrepared) throw new Error("Cancel prepared runtime release before input");
      // Startup reopen and a user input can race; whoever loses joins the already open admission.
      if (current.asyncControl?.admissionState !== "open") {
        if (deferReopen?.()) return;
        const command = this.internalCommand(sessionId, "reconcileAsyncControl", lease);
        const handle = this.assertOwner(command);
        this.assertQuiescent(command, handle);
        await handle.asyncTasks!.reopenAdmission();
      } else if (!lease) return;
      if (lease) this.inputLeases.set(sessionId, (this.inputLeases.get(sessionId) ?? 0) + 1);
      reopened = true;
    });
    return reopened;
  }

  async input<T>(sessionId: string, effect: () => Promise<T>): Promise<T> {
    if (!isAsyncTracked(this.deps.read(sessionId))) return effect();
    await this.attachDetachedOwner(sessionId);
    const session = this.deps.read(sessionId);
    if (this.deps.runtimeBlocked(sessionId)) throw new SessionInputUnavailableError("runtimeUnavailable", "Runtime teardown outcome unknown; input remains fenced");
    if (session.archived) throw new Error("Cannot send input to an archived session");
    const control = session.asyncControl;
    if (isAsyncTracked(session) && !control) throw new Error("Async control state requires owner reconciliation");
    if (control?.releasePrepared || control?.operations.some((operation) => operation.outcome === "accepted")) throw new Error("Async input admission is fenced; await the operation result");
    let leased = false;
    if (control && control.admissionState !== "open") leased = await this.reopenIfQuiescent(sessionId, true);
    if (!leased) this.inputLeases.set(sessionId, (this.inputLeases.get(sessionId) ?? 0) + 1);
    try { return await effect(); }
    finally {
      const remaining = this.inputLeases.get(sessionId)! - 1;
      if (remaining) this.inputLeases.set(sessionId, remaining); else this.inputLeases.delete(sessionId);
    }
  }

  private internalCommand(sessionId: string, type: LifecycleCommand["type"], inputLease = false): LifecycleCommand {
    const context = this.context(sessionId);
    if (!context.runtimeInstanceId) throw new Error("Async owner unavailable; retained for reconciliation");
    return { type, sessionId, requestId: randomUUID(), daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: context.runtimeInstanceId,
      workRevision: context.workRevision, controlGeneration: context.controlGeneration, inputLease };
  }

  private requiresArchiveChoice(sessionId: string): boolean {
    return this.deps.handle(sessionId)?.asyncTasks?.coverage().tracking !== "ready" || this.retained(sessionId);
  }

  retained(sessionId: string): boolean {
    const session = this.deps.read(sessionId);
    if (!isAsyncTracked(session)) return false;
    const handle = this.deps.handle(sessionId);
    if (this.deps.runtimeBlocked(sessionId) || !handle?.asyncTasks || handle.asyncTasks.coverage().tracking !== "ready") return true;
    return !aggregateAsyncWork(session, session, { tracking: "ready", runtimeBusy: runtimeBusy(handle, session), queuedInput: this.deps.pendingInput(sessionId) || (this.inputLeases.get(sessionId) ?? 0) > 0 }).asyncWorkSummary?.canReleaseRuntime;
  }

  async dispose(sessionId: string, effect: () => Promise<void>): Promise<void> {
    try { await effect(); }
    catch (error) {
      const command = this.internalCommand(sessionId, "prepareAsyncReplacement");
      await this.save(command, stableCommand(command), this.result(command, "blocked_cleanup", "Runtime teardown failed; outcome remains unknown"));
      throw error;
    }
  }

  async prepareReplacement(sessionId: string, inputLease = false): Promise<void> {
    if (!isAsyncTracked(this.deps.read(sessionId))) return;
    const result = await this.execute(this.internalCommand(sessionId, "prepareAsyncReplacement", inputLease));
    if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome);
  }

  /** Explicit deletion settles an attached owner, without requiring automatic release approval. */
  async prepareExplicitDeletion(sessionId: string): Promise<void> {
    // A prewarm must attach or fail before its archived metadata can be removed.
    await this.deps.pendingRuntimeHandle(sessionId, "delete session");
    const session = this.deps.read(sessionId);
    if (session.archived !== true) throw new Error(`Cannot delete a session that is not archived: ${sessionId}`);
    const handle = this.deps.handle(sessionId);
    if (handle && isAsyncTracked(session)) {
      if (handle.asyncTasks?.coverage().tracking === "ready" && !session.asyncControl?.releasePrepared) {
        const stopped = await this.stop(sessionId, randomUUID());
        if (stopped.outcome !== "settled") throw new Error(stopped.reason ?? stopped.outcome);
      } else if (hasUnsettledAttachedAsyncWork(handle, session)) {
        throw new Error("Async provider cleanup is unavailable for attached work");
      }
    }
    if (this.deps.read(sessionId).archived !== true) throw new Error(`Cannot delete a session that is not archived: ${sessionId}`);
  }

  async archive(sessionId: string, archived: boolean, mode?: "continue" | "stopThenArchive", requestId: string = randomUUID()): Promise<PickyAgentSession> {
    const session = this.deps.read(sessionId);
    if (!isAsyncTracked(session)) {
      await this.deps.patch(sessionId, { archived, archivedAt: archived ? new Date().toISOString() : undefined });
      this.deps.archived(sessionId, archived); return this.deps.read(sessionId);
    }
    if (!archived) return this.unarchive(sessionId, requestId);
    await this.attachDetachedOwner(sessionId);
    const prior = session.asyncControlJournal?.find((entry) => entry.result.requestId === `${requestId}:execute`);
    if (prior) { const result = await this.execute(JSON.parse(prior.fingerprint) as AsyncTaskCommand); if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome); return this.deps.read(sessionId); }
    if (!mode && this.requiresArchiveChoice(sessionId)) throw new ControlFailure("rejected", "Archive choice required: set archiveMode to continue or stopThenArchive");
    const preparedRecord = session.asyncControlJournal?.find((entry) => entry.result.requestId === `${requestId}:prepare`);
    const preparedCommand: Extract<AsyncTaskCommand, { type: "prepareSessionArchive" }> = preparedRecord ? JSON.parse(preparedRecord.fingerprint) : { ...this.commandContext(sessionId, `${requestId}:prepare`), type: "prepareSessionArchive", archiveIntentId: requestId, requireQuiescence: !mode };
    const prepared = await this.execute(preparedCommand);
    if (prepared.outcome !== "settled") throw new Error(prepared.reason ?? prepared.outcome);
    const result = await this.execute({ ...this.commandContext(sessionId, `${requestId}:execute`), workRevision: prepared.workRevision, controlGeneration: prepared.controlGeneration, type: "executeSessionArchive", archiveIntentId: requestId, preparationId: prepared.preparationId!, mode: mode ?? "continue", requireQuiescence: preparedCommand.requireQuiescence });
    if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome);
    return this.deps.read(sessionId);
  }

  private async unarchive(sessionId: string, requestId: string): Promise<PickyAgentSession> {
    const released = this.deps.read(sessionId);
    const approval = released.asyncControl?.releasePrepared;
    if (approval && !this.deps.handle(sessionId)) {
      if (!hasQuiescentReleasedAsyncOwner(released)) throw new Error("Released async owner requires reconciliation");
      const handle = await this.deps.resumeReleased(sessionId);
      if (!handle?.asyncTasks || handle.asyncTasks.coverage().runtimeInstanceId === approval.runtimeInstanceId) {
        throw new Error("Fresh async runtime owner unavailable; retained for reconciliation");
      }
    }
    const token = this.deps.read(sessionId).asyncControl?.releasePrepared?.releaseToken;
    const prior = this.deps.read(sessionId).asyncControlJournal?.find((entry) => entry.result.requestId === `${requestId}:cancel`);
    if (token || prior) {
      const result = await this.execute(prior ? JSON.parse(prior.fingerprint) as AsyncTaskCommand : { ...this.commandContext(sessionId, `${requestId}:cancel`), type: "cancelRuntimeRelease", releaseToken: token! });
      if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome);
    }
    await this.deps.patch(sessionId, { archived: false, archivedAt: undefined, asyncArchiveIntentId: undefined });
    this.deps.archived(sessionId, false); return this.deps.read(sessionId);
  }

  private commandContext(sessionId: string, requestId: string) {
    const context = this.internalCommand(sessionId, "reconcileAsyncControl");
    return { sessionId, requestId, daemonInstanceId: context.daemonInstanceId, runtimeInstanceId: context.runtimeInstanceId, workRevision: context.workRevision, controlGeneration: context.controlGeneration };
  }

  async abort(sessionId: string, pending: Map<string, Promise<PickyAgentSession>>, legacy: () => Promise<PickyAgentSession>): Promise<PickyAgentSession> {
    const existing = pending.get(sessionId);
    if (existing) return existing;
    const operation = isAsyncTracked(this.deps.read(sessionId)) ? this.stop(sessionId, randomUUID()).then((result) => {
      if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome);
      return this.deps.read(sessionId);
    }) : legacy();
    pending.set(sessionId, operation);
    try { return await operation; }
    finally { if (pending.get(sessionId) === operation) pending.delete(sessionId); }
  }

  async stop(sessionId: string, requestId: string): Promise<AsyncTaskCommandResult> {
    // A retry must retain the original context, even after the operation advanced its generation.
    const previous = this.deps.read(sessionId).asyncControlJournal?.find((entry) => entry.result.requestId === requestId);
    if (previous) {
      const original: Command = JSON.parse(previous.fingerprint);
      if (original.type !== "stopAsyncTasks") throw new Error("Async request ID reused for another command");
      return this.execute(original);
    }
    const context = this.context(sessionId);
    if (!context.runtimeInstanceId) throw new Error("Async runtime owner unavailable");
    return this.execute({ type: "stopAsyncTasks", requestId, sessionId, daemonInstanceId: context.daemonInstanceId,
      runtimeInstanceId: context.runtimeInstanceId, workRevision: context.workRevision, controlGeneration: context.controlGeneration });
  }

  async execute(command: Command): Promise<AsyncTaskCommandResult> {
    let result!: AsyncTaskCommandResult;
    await this.queue.run(command.sessionId, async () => { result = await this.perform(command); });
    return result;
  }

  private async perform(command: Command): Promise<AsyncTaskCommandResult> {
    // Owner fields participate in identity as well as the outer command.
    const identity = stableCommand(command);
    const prior = this.deps.read(command.sessionId).asyncControlJournal?.find((entry) => entry.result.requestId === command.requestId);
    if (prior) {
      if (prior.fingerprint !== identity) throw new Error("Async request ID reused with different input");
      // Old-owner queries are not authority for a replacement daemon/runtime.
      this.assertOwner(command);
      return prior.result;
    }
    this.assertOwner(command);
    const context = this.context(command.sessionId);
    if (!sameControlWork(command, context.workRevision, context.controlGeneration)) {
      return this.result(command, "stale", "Async work changed; refresh control context");
    }
    if (command.type === "asyncTaskDetail") return this.detail(command);
    if ((this.deps.read(command.sessionId).asyncControlJournal?.length ?? 0) >= 1024) throw new Error("Async operation journal capacity reached");
    if (this.deps.read(command.sessionId).asyncControl?.releasePrepared && command.type !== "cancelRuntimeRelease") return this.result(command, "rejected", "Cancel prepared runtime release before another mutation");
    const operationId = randomUUID();
    await this.save(command, identity, this.result(command, "accepted", undefined, operationId));
    try {
      const extras = await this.effects(command);
      this.assertOwner(command);
      const settled = await this.save(command, identity, this.result(command, "settled", undefined, operationId, extras), command.type === "executeSessionArchive" ? true : undefined);
      if (command.type === "executeSessionArchive") this.deps.archived(command.sessionId, true);
      return settled;
    } catch (error) {
      return this.save(command, identity, this.result(command, error instanceof ControlFailure ? error.outcome : "blocked_cleanup",
        (error instanceof Error ? error.message : String(error)).slice(0, 4096), operationId));
    }
  }

  private assertOwner(command: Command): RuntimeSessionHandle {
    const handle = this.deps.handle(command.sessionId);
    if (command.daemonInstanceId !== this.daemonInstanceId || !handle?.asyncTasks || handle.asyncTasks.coverage().runtimeInstanceId !== command.runtimeInstanceId) {
      throw new ControlFailure("stale", "Async daemon/runtime owner changed");
    }
    return handle;
  }

  private result(command: Command, outcome: Outcome, reason?: string, operationId = randomUUID(), extras: Partial<AsyncTaskCommandResult> = {}): AsyncTaskCommandResult {
    const context = this.context(command.sessionId);
    return { type: "asyncTaskCommandResult", requestId: command.requestId, sessionId: command.sessionId,
      daemonInstanceId: command.daemonInstanceId, runtimeInstanceId: command.runtimeInstanceId,
      workRevision: context.workRevision, controlGeneration: context.controlGeneration, operationId, outcome, ...(reason ? { reason } : {}), ...extras };
  }

  private async save(command: Command, fingerprint: string, result: AsyncTaskCommandResult, archived?: boolean): Promise<AsyncTaskCommandResult> {
    const committed = await this.deps.commit(command.sessionId, (session) => {
      this.validateCommit(command, result, session);
      const control = session.asyncControl;
      if (!control) throw new Error("Async control state unavailable");
      // Changing this projected operation advances the aggregate work revision once.
      const workRevision = (session.asyncWorkSummary?.workRevision ?? 0) + 1;
      // Archive membership and its admission cut must become durable in one write.
      // Registrations queued behind this writer must see the new generation before granting.
      const quiescentArchive = archived && command.type === "executeSessionArchive" && command.requireQuiescence === true;
      const controlGeneration = control.controlGeneration + (quiescentArchive ? 1 : 0);
      const releaseApproval = result.releaseApproval ? { ...result.releaseApproval, workRevision, controlGeneration } : undefined;
      const saved = { ...result, workRevision, controlGeneration, ...(releaseApproval ? { releaseApproval } : {}) };
      const operations = [...control.operations.filter((entry) => entry.requestId !== command.requestId).map((entry) =>
        result.outcome === "settled" && provesRecovery(command) && ["blocked_cleanup", "blocked_delivery"].includes(entry.outcome)
          ? { ...entry, outcome: "settled" as const, reason: `Reconciled by operation ${result.operationId}` } : entry),
        { requestId: command.requestId, operationId: result.operationId, outcome: result.outcome, controlGeneration, ...(result.reason ? { reason: result.reason } : {}) }];
      return { ...session, ...(archived && command.type === "executeSessionArchive" ? { archived: true, archivedAt: new Date().toISOString(), asyncArchiveIntentId: command.archiveIntentId } : {}),
        asyncControl: { ...control, controlGeneration, ...(quiescentArchive ? { admissionState: "closed" as const } : {}), operations, ...(releaseApproval ? { releasePrepared: releaseApproval } : {}),
          ...(command.type === "cancelRuntimeRelease" && result.outcome === "settled" ? { releasePrepared: undefined } : {}) },
        asyncControlJournal: [...(session.asyncControlJournal ?? []).filter((entry) => entry.result.requestId !== command.requestId).map((entry) =>
          result.outcome === "settled" && provesRecovery(command) && ["blocked_cleanup", "blocked_delivery"].includes(entry.result.outcome)
            ? { ...entry, resolvedBy: result.operationId } : entry), { fingerprint, result: saved }] };
    });
    return committed.after.asyncControlJournal!.find((entry) => entry.result.requestId === command.requestId)!.result;
  }

  private validateCommit(command: Command, result: AsyncTaskCommandResult, session: PickyAgentSession): void {
    const handle = this.assertOwner(command);
    if (result.outcome === "accepted" && !sameControlWork(command, session.asyncWorkSummary?.workRevision, session.asyncControl?.controlGeneration)) throw new ControlFailure("stale", "Async work changed before operation commit");
    if (result.outcome !== "settled") return;
    if (["stopAsyncTasks", "reconcileAsyncControl", "prepareAsyncReplacement"].includes(command.type)) this.assertQuiescent(command, handle);
    this.assertArchiveQuiescence(command, handle, session);
    if (command.type === "executeSessionArchive") {
      if (command.mode === "continue") {
        const accepted = session.asyncControlJournal?.find((entry) => entry.result.requestId === command.requestId)?.result;
        if (session.asyncWorkSummary?.workRevision !== accepted?.workRevision) throw new ControlFailure("stale", "Async work changed during archive confirmation");
      } else this.assertQuiescent(command, handle);
    }
    if (command.type === "prepareRuntimeRelease") {
      this.assertQuiescent(command, handle);
      if (!session.archived || session.asyncArchiveIntentId !== command.archiveIntentId) throw new ControlFailure("stale", "Archive intent was withdrawn");
    }
  }

  private assertArchiveQuiescence(command: Command, handle: RuntimeSessionHandle, session: PickyAgentSession): void {
    if ((command.type === "prepareSessionArchive" || command.type === "executeSessionArchive") && command.requireQuiescence) {
      try { this.assertPhysicalQuiescence(command, handle, session); }
      catch { throw new ControlFailure("rejected", "Archive choice required: async work is no longer quiescent"); }
    }
  }

  private async detail(command: Extract<AsyncTaskCommand, { type: "asyncTaskDetail" }>): Promise<AsyncTaskCommandResult> {
    const handle = this.assertOwner(command);
    const snapshot = handle.asyncTasks!.snapshot();
    const task = snapshot.tasks.find((entry) => entry.taskId === command.taskId && sameAsyncOwner(entry, command.owner));
    if (!task) return this.result(command, "rejected", "Unknown async task owner or task");
    const tasks = snapshot.tasks.filter((entry) => sameAsyncOwner(entry, task) && entry.rootTaskId === task.rootTaskId);
    const tickets = snapshot.tickets.filter((entry) => sameAsyncOwner(entry, task) && entry.rootTaskId === task.rootTaskId);
    // A root family is atomic in W1 detail; truncation could produce an invalid parent graph.
    if (command.cursor || tasks.length > command.limit) return this.result(command, "unsupported", "Task family exceeds requested detail page");
    return this.result(command, "settled", undefined, undefined, { detail: { tasks, tickets } });
  }

  private async effects(command: Command): Promise<Partial<AsyncTaskCommandResult>> {
    if (command.type === "prepareSessionArchive") return { preparationId: randomUUID() };
    if (command.type === "executeSessionArchive") return this.executeArchive(command);
    if (command.type === "stopAsyncTasks") { await this.stopWork(command); return {}; }
    if (command.type === "reconcileAsyncControl") {
      if (this.continuesPastFailedStop(command)) { await this.continuePastFailedStop(command); return {}; }
      this.assertPhysicalQuiescence(command, this.assertOwner(command));
      await this.stopWork(command); return {};
    }
    if (command.type === "prepareAsyncReplacement") {
      const handle = this.assertOwner(command);
      try { this.assertPhysicalQuiescence(command, handle); } catch (error) { throw new ControlFailure("rejected", error instanceof Error ? error.message : String(error)); }
      await this.close(command, handle); this.assertQuiescent(command, handle); return {};
    }
    if (command.type === "cancelAsyncTask") { await this.cancelTask(command); return {}; }
    if (command.type === "cancelRuntimeRelease") {
      const approval = this.deps.read(command.sessionId).asyncControl?.releasePrepared;
      if (!approval || approval.releaseToken !== command.releaseToken) throw new ControlFailure("stale", "Runtime release token changed");
      // Cancellation revokes authority. Input reopening is a separate explicit action after this ACK.
      return {};
    }
    if (command.type === "prepareRuntimeRelease") return this.prepareRelease(command);

    throw new ControlFailure("unsupported", "Unsupported async operation");
  }

  private async executeArchive(command: Extract<AsyncTaskCommand, { type: "executeSessionArchive" }>): Promise<Partial<AsyncTaskCommandResult>> {
    const preparation = this.deps.read(command.sessionId).asyncControlJournal?.find((entry) => entry.result.preparationId === command.preparationId);
    if (!preparation || preparation.result.outcome !== "settled") throw new ControlFailure("stale", "Archive preparation missing");
    const prepared: Command = JSON.parse(preparation.fingerprint);
    if (prepared.type !== "prepareSessionArchive" || prepared.archiveIntentId !== command.archiveIntentId || preparation.result.workRevision !== command.workRevision) throw new ControlFailure("stale", "Archive intent or work revision changed");
    if (prepared.requireQuiescence && !command.requireQuiescence) throw new ControlFailure("rejected", "Archive preparation requires quiescence; refresh archive choice");
    if (command.mode === "stopThenArchive") await this.stopWork(command);
    return {};
  }

  private async prepareRelease(command: Extract<AsyncTaskCommand, { type: "prepareRuntimeRelease" }>): Promise<Partial<AsyncTaskCommandResult>> {
    if (!this.deps.read(command.sessionId).archived) throw new ControlFailure("rejected", "Runtime release requires archived intent");
    if (this.deps.read(command.sessionId).asyncArchiveIntentId !== command.archiveIntentId) throw new ControlFailure("stale", "Archive intent is not owner-confirmed");
    const handle = this.assertOwner(command);
    try { this.assertPhysicalQuiescence(command, handle); }
    catch (error) { throw new ControlFailure("rejected", error instanceof Error ? error.message : String(error)); }
    await this.close(command, handle);
    await this.deps.drain(command.sessionId);
    this.assertQuiescent(command, handle);
    const context = this.context(command.sessionId);
    return { releaseApproval: { operationId: this.deps.read(command.sessionId).asyncControlJournal!.find((entry) => entry.result.requestId === command.requestId)!.result.operationId,
      releaseToken: randomUUID(), sessionId: command.sessionId, daemonInstanceId: command.daemonInstanceId,
      runtimeInstanceId: command.runtimeInstanceId, childGeneration: command.childGeneration, archiveIntentId: command.archiveIntentId,
      workRevision: context.workRevision + 1, controlGeneration: context.controlGeneration } };
  }

  private owners(command: Command, handle: RuntimeSessionHandle): AsyncTaskOwner[] {
    this.assertOwner(command);
    const control = handle.asyncTasks!;
    const coverage = control.coverage();
    const owners = control.owners?.() ?? [];
    if (coverage.tracking !== "ready" || !coverage.expectedProviders.every((id) => coverage.readyProviders.includes(id) && owners.some((owner) => owner.providerId === id && owner.runtimeInstanceId === command.runtimeInstanceId))) {
      throw new ControlFailure("blocked_cleanup", "Expected async provider coverage is incomplete");
    }
    return owners;
  }

  private async close(command: Command, handle: RuntimeSessionHandle): Promise<void> {
    await handle.asyncTasks!.closeAdmission();
    let coverageFailure: unknown;
    try { this.owners(command, handle); } catch (error) { coverageFailure = error; }
    // Provider close suppresses pending completions. Never use it to make release quiescent.
    if (command.type === "prepareRuntimeRelease") this.assertQuiescent(command, handle);
    const results = await Promise.allSettled((handle.asyncTasks!.owners?.() ?? []).map(async (owner) => {
      const closed = await deliveryControl(() => handle.asyncTasks!.control(owner, "closeAdmission"));
      if (closed.outcome !== "settled" || !closed.admissionClosed) throw new ControlFailure("blocked_delivery", "Provider admission closure unconfirmed");
      if (closed.submittedDeliveryIds.length && command.type !== "prepareRuntimeRelease") {
        const suppressed = await deliveryControl(() => handle.asyncTasks!.control(owner, "suppressDelivery", { deliveryIds: closed.submittedDeliveryIds }));
        if (suppressed.outcome !== "settled") throw new ControlFailure("blocked_delivery", "Submitted async delivery suppression unconfirmed");
      }
    }));
    await withTimeout(this.deps.drain(command.sessionId));
    const failed = results.find((result) => result.status === "rejected");
    if (failed?.status === "rejected") throw failed.reason;
    if (coverageFailure) throw coverageFailure;
  }

  private async cancelTask(command: Extract<AsyncTaskCommand, { type: "cancelAsyncTask" }>): Promise<void> {
    const handle = this.assertOwner(command);
    const control = handle.asyncTasks!;
    this.owners(command, handle);
    const task = control.snapshot().tasks.find((entry) => sameAsyncOwner(entry, command.owner) && entry.taskId === command.taskId);
    if (!task) throw new ControlFailure("rejected", "Unknown async task owner or task");
    const root = control.snapshot().tasks.find((entry) => sameAsyncOwner(entry, task) && entry.taskId === task.rootTaskId);
    if (!root) throw new ControlFailure("blocked_cleanup", "Task family root is missing");
    const cancelled = await control.control(root, "cancel", { taskId: root.taskId });
    if (!["settled", "accepted"].includes(cancelled.outcome)) throw new ControlFailure("blocked_cleanup", cancelled.reason ?? "Async task cleanup unconfirmed");
    // Individual cancel preserves model-target completion tickets for Pi to interpret.
    await this.awaitPhysicalSettlement(command, handle, () => !control.snapshot().tasks.some((entry) => sameAsyncOwner(entry, root) && entry.rootTaskId === root.taskId && (entry.presence !== "settled" || ["queued", "running", "cancelling"].includes(entry.execution))));
  }

  private async stopWork(command: Command): Promise<void> {
    const handle = this.assertOwner(command);
    let closureFailure: unknown;
    try { await this.close(command, handle); } catch (error) {
      const control = this.deps.read(command.sessionId).asyncControl;
      if (control?.admissionState !== "closed" || control.controlGeneration <= command.controlGeneration) throw error;
      closureFailure = error;
    }
    // No live provider can control a previous runtime's tasks; the user's input or stop
    // acknowledges them as interrupted history instead.
    if (acknowledgesPreviousOwner(command)) await handle.asyncTasks!.acknowledgeLostWork?.();
    const tasks = handle.asyncTasks!.snapshot().tasks.filter((task) => !acknowledgesPreviousOwner(command) || !isPreviousOwnerAsyncTask(task, command.runtimeInstanceId));
    const cancellations = await Promise.allSettled(tasks.filter((task) => task.taskId === task.rootTaskId && tasks.some((member) => sameAsyncOwner(member, task) && member.rootTaskId === task.taskId && (member.presence !== "settled" || ["queued", "running", "cancelling"].includes(member.execution)))).map(async (root) => {
      const cancelled = await handle.asyncTasks!.control(root, "cancel", { taskId: root.taskId });
      if (!["settled", "accepted"].includes(cancelled.outcome)) throw new ControlFailure("blocked_cleanup", cancelled.reason ?? "Async execution cleanup is not settled");
    }));
    let modelFailure: unknown;
    try { await withTimeout(this.deps.abortModel(command.sessionId, handle)); } catch (error) { modelFailure = error; }
    await withTimeout(this.deps.drain(command.sessionId));
    if (closureFailure) throw closureFailure;
    const failed = cancellations.find((result) => result.status === "rejected");
    if (failed?.status === "rejected") throw failed.reason;
    if (modelFailure) throw modelFailure;
    await this.awaitPhysicalSettlement(command, handle, () => { this.assertQuiescent(command, handle); return true; });
  }

  /**
   * The user asked to stop everything and that stop could not confirm cleanup. Their next
   * input means "continue anyway": requiring proof the stop already failed to produce would
   * fence the Pickle until the daemon restarts.
   */
  private continuesPastFailedStop(command: Command): boolean {
    if (command.type !== "reconcileAsyncControl" || command.inputLease !== true) return false;
    const session = this.deps.read(command.sessionId);
    return session.asyncControl?.operations.some((operation) => ["blocked_cleanup", "blocked_delivery"].includes(operation.outcome)
      && !asyncOperationResolved(session, operation.operationId)
      && journalCommandType(session, operation.operationId) === "stopAsyncTasks") === true;
  }

  /**
   * Repeats the cleanup that can still succeed (admission cut, delivery suppression, cancel,
   * model abort), then records whatever remains unproven as acknowledged work. It stays
   * visible as uncertain and keeps withholding release; live turns, queued input and other
   * controls still fence the input.
   */
  private async continuePastFailedStop(command: LifecycleCommand): Promise<void> {
    const handle = this.assertOwner(command);
    this.assertPhysicalQuiescence(command, handle, this.deps.read(command.sessionId), { ignoreCurrentAsyncWork: true });
    const failures: string[] = [];
    const attempt = async (effect: () => Promise<unknown>) => {
      try { await effect(); } catch (error) { failures.push(error instanceof Error ? error.message : String(error)); }
    };
    await attempt(() => this.close(command, handle));
    const tasks = handle.asyncTasks!.snapshot().tasks.filter((task) => task.runtimeInstanceId === command.runtimeInstanceId);
    // A root whose presence is already unknown has no provider evidence left to collect.
    const cancellable = tasks.filter((task) => task.taskId === task.rootTaskId && task.presence !== "unknown"
      && tasks.some((member) => sameAsyncOwner(member, task) && member.rootTaskId === task.taskId && asyncExecutionIsActive(member)));
    await Promise.all(cancellable.map((root) => attempt(() => handle.asyncTasks!.control(root, "cancel", { taskId: root.taskId }))));
    await attempt(() => withTimeout(this.deps.abortModel(command.sessionId, handle)));
    await attempt(() => withTimeout(this.deps.drain(command.sessionId)));
    const session = this.deps.read(command.sessionId);
    const current = (entry: { runtimeInstanceId: string }) => entry.runtimeInstanceId === command.runtimeInstanceId;
    const unresolved = [
      ...(session.asyncTasks ?? []).filter((task) => current(task) && (asyncExecutionIsActive(task) || task.presence === "unknown")),
      ...(session.completionTickets ?? []).filter((ticket) => current(ticket) && !["handled", "suppressed"].includes(ticket.state)),
    ];
    const roots = new Map(unresolved.map(({ runtimeInstanceId, providerId, providerInstanceId, rootTaskId }) =>
      [JSON.stringify([runtimeInstanceId, providerId, providerInstanceId, rootTaskId]), { runtimeInstanceId, providerId, providerInstanceId, rootTaskId }]));
    if (roots.size > 0) {
      await this.deps.commit(command.sessionId, (latest) => {
        const control = latest.asyncControl;
        if (!control) throw new Error("Async control state unavailable");
        const known = control.acknowledgedRoots ?? [];
        const added = [...roots.values()].filter((root) => !isAcknowledgedAsyncWork(latest, root));
        return added.length ? { ...latest, asyncControl: { ...control, acknowledgedRoots: [...known, ...added].slice(-256) } } : latest;
      });
    }
    logAgentd("async work acknowledged by user input after failed stop", { sessionId: command.sessionId, acknowledgedRoots: roots.size, cleanupFailures: failures.length });
    this.assertQuiescent(command, handle);
  }

  private async awaitPhysicalSettlement(command: Command, handle: RuntimeSessionHandle, settled: () => boolean): Promise<void> {
    const control = handle.asyncTasks!;
    // Native subagents first escalate an ignored SIGTERM, then publish exit evidence.
    // Give that bounded teardown time to finish before declaring cleanup unknown.
    const deadline = Date.now() + 12_000;
    for (;;) {
      this.assertOwner(command);
      const previous = control.snapshot();
      await withTimeout(this.deps.drain(command.sessionId));
      try { if (settled()) return; } catch (error) {
        if (!(error instanceof ControlFailure) || error.outcome !== "blocked_cleanup") throw error;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0 || !control.waitForChange) throw new ControlFailure("blocked_cleanup", "Async execution cleanup timed out; outcome remains unknown");
      try { await control.waitForChange(previous, remaining); }
      catch { this.assertOwner(command); throw new ControlFailure("blocked_cleanup", "Async execution cleanup timed out; outcome remains unknown"); }
    }
  }

  private assertQuiescent(command: Command, handle: RuntimeSessionHandle): void {
    this.owners(command, handle);
    const session = this.deps.read(command.sessionId);
    if (session.asyncControl?.admissionState !== "closed") throw new ControlFailure("stale", "Async admission reopened during control");
    this.assertPhysicalQuiescence(command, handle);
  }

  private assertPhysicalQuiescence(command: Command, handle: RuntimeSessionHandle, session = this.deps.read(command.sessionId), options: { ignoreCurrentAsyncWork?: boolean } = {}): void {
    this.owners(command, handle);
    const ownLease = command.type === "prepareAsyncReplacement" && command.inputLease ? 1 : 0;
    if (this.deps.runtimeBlocked(command.sessionId) || this.deps.handle(command.sessionId) !== handle || (this.inputLeases.get(command.sessionId) ?? 0) > ownLease || this.deps.pendingInput(command.sessionId) || runtimeBusy(handle, session) || outstandingState(session, command.requestId, provesRecovery(command), acknowledgesPreviousOwner(command) ? command.runtimeInstanceId : undefined, options.ignoreCurrentAsyncWork)) {
      throw new ControlFailure("blocked_cleanup", "Async work still has execution, delivery or control obligations");
    }
  }
}

function stableCommand(command: Command): string {
  return JSON.stringify(command, (_key, value: unknown) => value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value).sort(([left], [right]) => left.localeCompare(right))) : value);
}

async function withTimeout<T>(effect: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([effect, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new ControlFailure("blocked_cleanup", "Runtime cleanup timed out; outcome remains unknown")), 5_000);
    })]);
  } finally { if (timer) clearTimeout(timer); }
}

function runtimeBusy(handle: RuntimeSessionHandle, session: PickyAgentSession): boolean {
  return handle.isStreaming === true || handle.isCompacting === true || handle.hasPendingAsyncWork === true
    || session.agentCycle?.phase === "responding" || session.agentCycle?.phase === "compacting"
    || !!session.pendingExtensionUiRequest || !!session.queuedSteers?.length || !!session.queuedFollowUps?.length
    || handle.getSteeringMessages().length > 0 || handle.getFollowUpMessages().length > 0;
}
/**
 * Explicit user input and the user's stop may continue past work a previous runtime left
 * unknown: no live provider can control it. Release, archive and startup reopen stay fenced.
 */
function acknowledgesPreviousOwner(command: Command): boolean {
  return command.type === "stopAsyncTasks" || command.type === "reconcileAsyncControl" && command.inputLease === true;
}
function outstandingState(session: PickyAgentSession, requestId: string, recovering = false, acknowledgedRuntimeInstanceId?: string, ignoreCurrentAsyncWork = false): boolean {
  const current = <T extends { runtimeInstanceId: string }>(entry: T) => acknowledgedRuntimeInstanceId === undefined || entry.runtimeInstanceId === acknowledgedRuntimeInstanceId;
  // Acknowledged work fences no one; ignoreCurrentAsyncWork previews a continuation that is about to acknowledge it.
  const fences = (entry: { runtimeInstanceId: string; providerId: string; providerInstanceId: string; rootTaskId: string }) =>
    !isAcknowledgedAsyncWork(session, entry) && !(ignoreCurrentAsyncWork && current(entry));
  return hasAsyncExecutionObligations((session.asyncTasks ?? []).filter((task) => fences(task) && (acknowledgedRuntimeInstanceId === undefined || !isPreviousOwnerAsyncTask(task, acknowledgedRuntimeInstanceId))))
    || session.completionTickets?.some((ticket) => fences(ticket) && current(ticket) && !["handled", "suppressed"].includes(ticket.state)) === true
    || session.asyncControl?.operations.some((operation) => operation.requestId !== requestId && !asyncOperationResolved(session, operation.operationId) && (operation.outcome === "accepted" || !recovering && ["blocked_cleanup", "blocked_delivery"].includes(operation.outcome))) === true;
}

function journalCommandType(session: PickyAgentSession, operationId: string): string | undefined {
  const entry = session.asyncControlJournal?.find((record) => record.result.operationId === operationId);
  if (!entry) return undefined;
  try { return (JSON.parse(entry.fingerprint) as { type?: string }).type; } catch { return undefined; }
}

async function deliveryControl<T>(effect: () => Promise<T>): Promise<T> {
  try { return await effect(); }
  catch (error) { throw new ControlFailure("blocked_delivery", error instanceof Error ? error.message : String(error)); }
}

function provesRecovery(command: Command): boolean {
  return command.type === "stopAsyncTasks" || command.type === "reconcileAsyncControl" || command.type === "prepareRuntimeRelease" || command.type === "prepareAsyncReplacement" || command.type === "executeSessionArchive" && command.mode === "stopThenArchive";
}
