import { aggregateAsyncWork, asyncOperationResolved, hasAsyncExecutionObligations, isAsyncTracked } from "../domain/async-work-aggregate.js";
import { randomUUID } from "node:crypto";
import type { AsyncTaskCommand, AsyncTaskCommandResult, AsyncTaskOwner } from "../domain/async-task-contract.js";
import type { PickyAgentSession } from "../protocol.js";
import type { RuntimeSessionHandle } from "../runtime/types.js";
import { sameAsyncOwner } from "../runtime/async-task-state.js";
import { KeyedSerialQueue } from "../domain/keyed-serial-queue.js";

type StopCommand = Omit<Extract<AsyncTaskCommand, { type: "prepareSessionArchive" }>, "type" | "archiveIntentId"> & { type: "stopAsyncTasks" };
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

  async input<T>(sessionId: string, effect: () => Promise<T>): Promise<T> {
    const session = this.deps.read(sessionId);
    if (!isAsyncTracked(session)) return effect();
    if (this.deps.runtimeBlocked(sessionId)) throw new Error("Runtime teardown outcome unknown; input remains fenced");
    if (session.archived) throw new Error("Cannot send input to an archived session");
    const control = session.asyncControl;
    if (isAsyncTracked(session) && !control) throw new Error("Async control state requires owner reconciliation");
    if (control?.releasePrepared || control?.operations.some((operation) => operation.outcome === "accepted")) throw new Error("Async input admission is fenced; await the operation result");
    let leased = false;
    if (control && control.admissionState !== "open") {
      const recovered = await this.execute(this.internalCommand(sessionId, "reconcileAsyncControl"));
      if (recovered.outcome !== "settled") throw new Error(recovered.reason ?? recovered.outcome);
      await this.queue.run(sessionId, async () => {
        const current = this.deps.read(sessionId);
        if (current.asyncControl?.releasePrepared) throw new Error("Cancel prepared runtime release before input");
        const command = this.internalCommand(sessionId, "reconcileAsyncControl");
        const handle = this.assertOwner(command);
        this.assertQuiescent(command, handle);
        await handle.asyncTasks!.reopenAdmission();
        this.inputLeases.set(sessionId, (this.inputLeases.get(sessionId) ?? 0) + 1); leased = true;
      });
    }
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

  async archive(sessionId: string, archived: boolean, mode?: "continue" | "stopThenArchive", requestId: string = randomUUID()): Promise<PickyAgentSession> {
    const session = this.deps.read(sessionId);
    if (!isAsyncTracked(session)) {
      await this.deps.patch(sessionId, { archived, archivedAt: archived ? new Date().toISOString() : undefined });
      this.deps.archived(sessionId, archived); return this.deps.read(sessionId);
    }
    if (!archived) return this.unarchive(sessionId, requestId);
    const prior = session.asyncControlJournal?.find((entry) => entry.result.requestId === `${requestId}:execute`);
    if (prior) { const result = await this.execute(JSON.parse(prior.fingerprint) as AsyncTaskCommand); if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome); return this.deps.read(sessionId); }
    if (!mode && this.requiresArchiveChoice(sessionId)) throw new ControlFailure("rejected", "Archive choice required: set archiveMode to continue or stopThenArchive");
    const preparedRecord = session.asyncControlJournal?.find((entry) => entry.result.requestId === `${requestId}:prepare`);
    const preparedCommand: AsyncTaskCommand = preparedRecord ? JSON.parse(preparedRecord.fingerprint) : { ...this.commandContext(sessionId, `${requestId}:prepare`), type: "prepareSessionArchive", archiveIntentId: requestId };
    const prepared = await this.execute(preparedCommand);
    if (prepared.outcome !== "settled") throw new Error(prepared.reason ?? prepared.outcome);
    const result = await this.execute({ ...this.commandContext(sessionId, `${requestId}:execute`), workRevision: prepared.workRevision, controlGeneration: prepared.controlGeneration, type: "executeSessionArchive", archiveIntentId: requestId, preparationId: prepared.preparationId!, mode: mode ?? "continue" });
    if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome);
    return this.deps.read(sessionId);
  }

  private async unarchive(sessionId: string, requestId: string): Promise<PickyAgentSession> {
    await this.deps.patch(sessionId, { archived: false, archivedAt: undefined, asyncArchiveIntentId: undefined });
    const token = this.deps.read(sessionId).asyncControl?.releasePrepared?.releaseToken;
    const prior = this.deps.read(sessionId).asyncControlJournal?.find((entry) => entry.result.requestId === `${requestId}:cancel`);
    if (token || prior) {
      const result = await this.execute(prior ? JSON.parse(prior.fingerprint) as AsyncTaskCommand : { ...this.commandContext(sessionId, `${requestId}:cancel`), type: "cancelRuntimeRelease", releaseToken: token! });
      if (result.outcome !== "settled") throw new Error(result.reason ?? result.outcome);
    }
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
    if (context.workRevision !== command.workRevision || context.controlGeneration !== command.controlGeneration) {
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
      const releaseApproval = result.releaseApproval ? { ...result.releaseApproval, workRevision, controlGeneration: control.controlGeneration } : undefined;
      const saved = { ...result, workRevision, controlGeneration: control.controlGeneration, ...(releaseApproval ? { releaseApproval } : {}) };
      const operations = [...control.operations.filter((entry) => entry.requestId !== command.requestId).map((entry) =>
        result.outcome === "settled" && provesRecovery(command) && ["blocked_cleanup", "blocked_delivery"].includes(entry.outcome)
          ? { ...entry, outcome: "settled" as const, reason: `Reconciled by operation ${result.operationId}` } : entry),
        { requestId: command.requestId, operationId: result.operationId, outcome: result.outcome, controlGeneration: control.controlGeneration, ...(result.reason ? { reason: result.reason } : {}) }];
      return { ...session, ...(archived && command.type === "executeSessionArchive" ? { archived: true, archivedAt: new Date().toISOString(), asyncArchiveIntentId: command.archiveIntentId } : {}),
        asyncControl: { ...control, operations, ...(releaseApproval ? { releasePrepared: releaseApproval } : {}),
          ...(command.type === "cancelRuntimeRelease" && result.outcome === "settled" ? { releasePrepared: undefined } : {}) },
        asyncControlJournal: [...(session.asyncControlJournal ?? []).filter((entry) => entry.result.requestId !== command.requestId).map((entry) =>
          result.outcome === "settled" && provesRecovery(command) && ["blocked_cleanup", "blocked_delivery"].includes(entry.result.outcome)
            ? { ...entry, resolvedBy: result.operationId } : entry), { fingerprint, result: saved }] };
    });
    return committed.after.asyncControlJournal!.find((entry) => entry.result.requestId === command.requestId)!.result;
  }

  private validateCommit(command: Command, result: AsyncTaskCommandResult, session: PickyAgentSession): void {
    const handle = this.assertOwner(command);
    if (result.outcome === "accepted" && (session.asyncWorkSummary?.workRevision !== command.workRevision || session.asyncControl?.controlGeneration !== command.controlGeneration)) throw new ControlFailure("stale", "Async work changed before operation commit");
    if (result.outcome !== "settled") return;
    if (["stopAsyncTasks", "reconcileAsyncControl", "prepareAsyncReplacement"].includes(command.type)) this.assertQuiescent(command, handle);
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
    await this.deps.drain(command.sessionId);
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
    const cancelled = await control.control(command.owner, "cancel", { taskId: command.taskId });
    if (cancelled.outcome !== "settled") throw new ControlFailure("blocked_cleanup", "Async task cleanup unconfirmed");
    await this.deps.drain(command.sessionId);
    this.assertOwner(command);
    // Individual cancel preserves model-target completion tickets for Pi to interpret.
    const current = control.snapshot();
    if (current.tasks.some((entry) => sameAsyncOwner(entry, task) && entry.rootTaskId === task.rootTaskId && (entry.presence !== "settled" || ["queued", "running", "cancelling"].includes(entry.execution)))) throw new ControlFailure("blocked_cleanup", "Task family still has execution obligations");
  }

  private async stopWork(command: Command): Promise<void> {
    const handle = this.assertOwner(command);
    let closureFailure: unknown;
    try { await this.close(command, handle); } catch (error) {
      const control = this.deps.read(command.sessionId).asyncControl;
      if (control?.admissionState !== "closed" || control.controlGeneration <= command.controlGeneration) throw error;
      closureFailure = error;
    }
    const cancellations = await Promise.allSettled(handle.asyncTasks!.snapshot().tasks.map(async (task) => {
      if (task.presence === "settled" && !["queued", "running", "cancelling"].includes(task.execution)) return;
      const cancelled = await handle.asyncTasks!.control(task, "cancel", { taskId: task.taskId });
      if (cancelled.outcome !== "settled") throw new ControlFailure("blocked_cleanup", "Async execution cleanup is not settled");
    }));
    let modelFailure: unknown;
    try { await withTimeout(this.deps.abortModel(command.sessionId, handle)); } catch (error) { modelFailure = error; }
    await this.deps.drain(command.sessionId);
    if (closureFailure) throw closureFailure;
    const failed = cancellations.find((result) => result.status === "rejected");
    if (failed?.status === "rejected") throw failed.reason;
    if (modelFailure) throw modelFailure;
    this.assertQuiescent(command, handle);
  }

  private assertQuiescent(command: Command, handle: RuntimeSessionHandle): void {
    this.owners(command, handle);
    const session = this.deps.read(command.sessionId);
    if (session.asyncControl?.admissionState !== "closed") throw new ControlFailure("stale", "Async admission reopened during control");
    this.assertPhysicalQuiescence(command, handle);
  }

  private assertPhysicalQuiescence(command: Command, handle: RuntimeSessionHandle): void {
    this.owners(command, handle);
    const session = this.deps.read(command.sessionId);
    const ownLease = command.type === "prepareAsyncReplacement" && command.inputLease ? 1 : 0;
    if (this.deps.runtimeBlocked(command.sessionId) || this.deps.handle(command.sessionId) !== handle || (this.inputLeases.get(command.sessionId) ?? 0) > ownLease || this.deps.pendingInput(command.sessionId) || runtimeBusy(handle, session) || outstandingState(session, command.requestId, provesRecovery(command))) {
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
function outstandingState(session: PickyAgentSession, requestId: string, recovering = false): boolean {
  return hasAsyncExecutionObligations(session.asyncTasks ?? [])
    || session.completionTickets?.some((ticket) => !["handled", "suppressed"].includes(ticket.state)) === true
    || session.asyncControl?.operations.some((operation) => operation.requestId !== requestId && !asyncOperationResolved(session, operation.operationId) && (operation.outcome === "accepted" || !recovering && ["blocked_cleanup", "blocked_delivery"].includes(operation.outcome))) === true;
}

async function deliveryControl<T>(effect: () => Promise<T>): Promise<T> {
  try { return await effect(); }
  catch (error) { throw new ControlFailure("blocked_delivery", error instanceof Error ? error.message : String(error)); }
}

function provesRecovery(command: Command): boolean {
  return command.type === "stopAsyncTasks" || command.type === "reconcileAsyncControl" || command.type === "prepareRuntimeRelease" || command.type === "prepareAsyncReplacement" || command.type === "executeSessionArchive" && command.mode === "stopThenArchive";
}
