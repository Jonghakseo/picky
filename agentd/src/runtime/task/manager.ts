import { randomUUID } from "node:crypto";
import { isActive, type TaskStore } from "./store.js";
import type {
  EvaluationResult,
  TaskContextSnapshot,
  TaskOrigin,
  TaskRecord,
  TaskReport,
  TaskWorker,
  WorkerFactory,
} from "./types.js";

interface ManagerOptions {
  store: TaskStore;
  maxConcurrency: number;
  evaluate(
    record: Readonly<TaskRecord>,
    context: TaskContextSnapshot,
    signal: AbortSignal,
  ): Promise<EvaluationResult>;
  createWorker: WorkerFactory;
  /** A revision reached a final report (success, failure, or block). Not called for a user stop. */
  onTerminal?(record: TaskRecord): void;
  onChange?(): void;
}

export interface CreateTaskInput {
  title: string;
  instruction: string;
  cwd: string;
  readonly?: boolean;
  origin?: TaskOrigin;
  decisionId?: string;
}

const copy = (record: TaskRecord): TaskRecord => structuredClone(record);
const errorText = (error: unknown): string => (error instanceof Error ? error.message : String(error));
const INTERRUPTED_BY_SHUTDOWN = "Picky stopped before the Task reported completion.";

/**
 * Owns Task revisions and scheduling. A worker owns its own detached commands.
 *
 * Ported from the original extension's manager. Preserved: the concurrency queue, the synchronous
 * revision fence on edit, rejection of stale or foreign reports, and resuming the same worker
 * session. Changed for Picky: one store for all main-agent Tasks, per-Task working folders, and a
 * user stop that shuts the worker down instead of only interrupting its model.
 */
export class TaskManager {
  private readonly records = new Map<string, TaskRecord>();
  private readonly workers = new Map<string, TaskWorker>();
  private readonly workerTokens = new Map<string, object>();
  private readonly slots = new Set<string>();
  private readonly evaluations = new Map<string, AbortController>();
  private readonly operations = new Map<string, Promise<void>>();
  private closed = false;

  constructor(private readonly options: ManagerOptions) {
    if (!Number.isInteger(options.maxConcurrency) || options.maxConcurrency < 1)
      throw new Error("Invalid Task concurrency");
    for (const record of options.store.load()) {
      if (isActive(record.status)) {
        record.status = "interrupted";
        record.error = INTERRUPTED_BY_SHUTDOWN;
        record.interruptionNotified = false;
      } else if (record.status === "stopping") {
        // The stop never confirmed an exit before the previous process ended.
        record.status = "cancelled";
        record.cleanup = "uncertain";
      }
      this.records.set(record.id, record);
    }
    this.persist();
  }

  list(): TaskRecord[] {
    return [...this.records.values()].map(copy);
  }
  get(id: string): TaskRecord {
    const record = this.records.get(id);
    if (!record) throw new Error(`Unknown Task: ${id}`);
    return copy(record);
  }
  has(id: string): boolean {
    return this.records.has(id);
  }

  create(input: CreateTaskInput, snapshot: TaskContextSnapshot): TaskRecord {
    this.assertOpen();
    if (!input.instruction.trim()) throw new Error("Task instruction cannot be empty");
    if (!input.cwd.trim()) throw new Error("Task working folder cannot be empty");
    const id = `task-${randomUUID()}`;
    const now = new Date().toISOString();
    const record: TaskRecord = {
      id,
      revision: 1,
      title: input.title.trim() || input.instruction.trim().slice(0, 80),
      cwd: input.cwd,
      instructions: [input.instruction],
      readonly: input.readonly ?? false,
      status: "queued",
      createdAt: now,
      updatedAt: now,
      ...(input.origin ? { origin: input.origin } : {}),
      ...(input.decisionId ? { decisionId: input.decisionId } : {}),
      ...this.options.store.paths(id),
    };
    this.options.store.writeContext(id, snapshot);
    this.records.set(id, record);
    this.persist();
    queueMicrotask(() => this.pump());
    return copy(record);
  }

  /** Revision invalidation happens synchronously, before any abort/evaluation awaits. */
  async edit(id: string, instruction: string, snapshot?: TaskContextSnapshot): Promise<TaskRecord> {
    this.assertOpen();
    if (!instruction.trim()) throw new Error("Edit instruction cannot be empty");
    const record = this.require(id);
    if (record.status === "stopping") throw new Error(`Task ${id} is still stopping; wait for it to finish before resuming`);
    record.revision++;
    const revision = record.revision;
    record.instructions.push(instruction);
    record.report = undefined;
    record.error = undefined;
    record.cleanup = undefined;
    record.completionDelivered = false;
    record.interruptionNotified = undefined;
    record.status = this.slots.has(id) ? "evaluating" : "queued";
    record.updatedAt = new Date().toISOString();
    if (snapshot) this.options.store.writeContext(id, snapshot);
    this.evaluations.get(id)?.abort();
    this.persist();
    void this.enqueue(id, async () => {
      if (!this.current(id, revision)) return;
      const worker = this.workers.get(id);
      if (worker) await worker.abort();
      if (!this.current(id, revision)) return;
      if (this.slots.has(id)) await this.evaluateAndRun(id, revision);
      else {
        record.status = "queued";
        this.persist();
        this.pump();
      }
    }).catch((error) => this.fail(id, revision, errorText(error)));
    return this.get(id);
  }

  /**
   * A user stop. Blocks further model calls and new revisions, then shuts the worker down so its
   * extensions release their background jobs. `cleanup` records whether the exit was confirmed.
   */
  async stop(id: string): Promise<TaskRecord> {
    this.assertOpen();
    const record = this.require(id);
    if (!isActive(record.status)) return this.get(id);
    this.evaluations.get(id)?.abort();
    record.status = "stopping";
    record.updatedAt = new Date().toISOString();
    this.persist();
    // Not queued behind an in-flight start: shutting the worker down is what unblocks that start.
    const worker = this.workers.get(id);
    this.workers.delete(id);
    this.workerTokens.delete(id);
    let exited = true;
    try {
      if (worker) exited = await worker.stop();
    } catch {
      exited = false;
    }
    if (this.records.get(id) !== record || record.status !== "stopping") return this.get(id);
    record.status = "cancelled";
    record.cleanup = exited ? "confirmed" : "uncertain";
    record.updatedAt = new Date().toISOString();
    this.slots.delete(id);
    this.persist();
    this.pump();
    return this.get(id);
  }

  /** The user chose to keep this scope as a Task; the worker no longer escalates production code work. */
  approveScope(id: string, decisionId: string): TaskRecord {
    const record = this.require(id);
    record.decisionId = decisionId;
    record.updatedAt = new Date().toISOString();
    this.persist();
    return copy(record);
  }

  /** Records a link to the Pickle that took this Task over. The Task itself stays blocked. */
  recordHandoff(id: string, handoff: NonNullable<TaskRecord["handoff"]>): TaskRecord {
    const record = this.require(id);
    record.handoff = { ...handoff };
    record.updatedAt = new Date().toISOString();
    this.persist();
    return copy(record);
  }

  /** Returns and durably acknowledges the one-time recovery notice. Never restarts work. */
  takeInterruptions(): TaskRecord[] {
    const pending = [...this.records.values()].filter((r) => r.status === "interrupted" && !r.interruptionNotified);
    for (const record of pending) record.interruptionNotified = true;
    if (pending.length) this.persist();
    return pending.map(copy);
  }

  markDelivered(id: string, revision: number): boolean {
    const record = this.records.get(id);
    if (record?.revision === revision && record.report && !record.completionDelivered) {
      record.completionDelivered = true;
      this.persist();
      return true;
    }
    return false;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    for (const controller of this.evaluations.values()) controller.abort();
    for (const record of this.records.values()) {
      if (!isActive(record.status) && record.status !== "stopping") continue;
      if (record.status === "stopping") {
        record.status = "cancelled";
        record.cleanup = "uncertain";
        continue;
      }
      record.status = "interrupted";
      record.error = INTERRUPTED_BY_SHUTDOWN;
      record.interruptionNotified = false;
    }
    this.persist();
    // Graceful RPC shutdown invokes the child extensions' own resource cleanup.
    await Promise.allSettled([...this.workers.values()].map((worker) => worker.stop()));
    this.workers.clear();
    this.workerTokens.clear();
    this.slots.clear();
  }

  private require(id: string): TaskRecord {
    const record = this.records.get(id);
    if (!record) throw new Error(`Unknown Task: ${id}`);
    return record;
  }
  private assertOpen(): void {
    if (this.closed) throw new Error("Task manager is shutting down");
  }
  private current(id: string, revision: number): boolean {
    const record = this.records.get(id);
    return !this.closed && record?.revision === revision && isActive(record.status);
  }
  private persist(): void {
    this.options.store.save(this.records.values());
    this.options.onChange?.();
  }
  private enqueue(id: string, operation: () => Promise<void>): Promise<void> {
    const previous = this.operations.get(id) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(operation);
    this.operations.set(id, next);
    void next
      .finally(() => {
        if (this.operations.get(id) === next) this.operations.delete(id);
      })
      .catch(() => {});
    return next;
  }
  private pump(): void {
    if (this.closed) return;
    for (const record of this.records.values()) {
      if (this.slots.size >= this.options.maxConcurrency) break;
      if (record.status !== "queued" || this.slots.has(record.id)) continue;
      this.slots.add(record.id);
      const revision = record.revision;
      void this.enqueue(record.id, () => this.evaluateAndRun(record.id, revision)).catch((error) => {
        this.fail(record.id, revision, errorText(error));
      });
    }
  }

  private async evaluateAndRun(id: string, revision: number): Promise<void> {
    if (!this.current(id, revision)) return;
    const record = this.require(id);
    const controller = new AbortController();
    this.evaluations.set(id, controller);
    record.status = "evaluating";
    this.persist();
    try {
      const snapshot = this.options.store.readContext(id);
      const result = await this.options.evaluate(copy(record), snapshot, controller.signal);
      if (controller.signal.aborted || !this.current(id, revision)) return;
      record.tier = result.tier;
      record.selection = result.selection;
      record.status = "running";
      this.persist();
      let worker = this.workers.get(id);
      const existing = !!worker;
      if (!worker) {
        const token = {};
        this.workerTokens.set(id, token);
        worker = this.options.createWorker(
          {
            taskId: id,
            cwd: record.cwd,
            sessionFile: record.sessionFile,
            contextFile: record.contextFile,
            readonly: record.readonly,
            scopeApproved: record.decisionId !== undefined,
          },
          {
            onReport: (report) => {
              if (this.workerTokens.get(id) === token) this.acceptReport(report);
            },
            onActivity: (state) => {
              if (
                this.closed ||
                this.workerTokens.get(id) !== token ||
                !isActive(record.status) ||
                record.status === "evaluating"
              )
                return;
              if (record.status === state) return;
              record.status = state;
              this.persist();
            },
            onExit: (error) => {
              if (this.workerTokens.get(id) === token && isActive(record.status))
                this.fail(id, record.revision, error ?? "Worker exited without task_report");
            },
            onError: (error) => {
              if (this.workerTokens.get(id) === token && isActive(record.status)) this.fail(id, record.revision, error);
            },
          },
        );
        this.workers.set(id, worker);
      }
      const input = { revision, prompt: buildRevisionPrompt(record, revision, snapshot.brief, existing), selection: result.selection };
      if (existing) await worker.update(input);
      else await worker.start(input);
      if (this.current(id, revision)) {
        record.revisionStartedAt = new Date().toISOString();
        this.persist();
      }
    } catch (error) {
      if (!controller.signal.aborted) this.fail(id, revision, errorText(error));
    } finally {
      if (this.evaluations.get(id) === controller) this.evaluations.delete(id);
      if (controller.signal.aborted && this.current(id, revision)) {
        record.status = this.workers.has(id) ? "waiting" : "interrupted";
        if (!this.workers.has(id)) this.slots.delete(id);
        this.persist();
        this.pump();
      }
    }
  }

  private fail(id: string, revision: number, error: string): void {
    if (!this.current(id, revision)) return;
    this.require(id).error = error;
    this.acceptReport({
      taskId: id,
      revision,
      status: "failed",
      summary: error,
      artifacts: [],
      verification: [],
      blockers: [error],
    });
  }

  private acceptReport(report: TaskReport): void {
    if (!this.current(report.taskId, report.revision)) return;
    const record = this.require(report.taskId);
    record.report = structuredClone(report);
    record.status = report.status === "success" ? "completed" : report.status;
    record.updatedAt = new Date().toISOString();
    record.completionDelivered = false;
    this.persist();
    const worker = this.workers.get(record.id);
    void this.enqueue(record.id, async () => {
      try {
        if (worker) await worker.stop();
      } finally {
        if (this.workers.get(record.id) === worker) {
          this.workers.delete(record.id);
          this.workerTokens.delete(record.id);
        }
        this.slots.delete(record.id);
        this.pump();
        if (!this.closed && record.revision === report.revision) this.options.onTerminal?.(copy(record));
      }
    }).catch(() => {});
  }
}

function buildRevisionPrompt(record: TaskRecord, revision: number, brief: string, existing: boolean): string {
  return [
    `Task ${record.id}, revision ${revision}. ${existing ? "Additional input replaces conflicting earlier instructions." : "Execute this delegated task."}`,
    `Mode: ${record.readonly ? "readonly (instruction-based, not a sandbox)" : "standard"}.`,
    `Working folder: ${record.cwd}`,
    ...(record.decisionId ? ["The user chose to run this scope as a Task instead of a Pickle; production-level code work within it is approved."] : []),
    "Prior instructions and edits, in order:",
    ...record.instructions.map((text, i) => `[${i + 1}] ${text}`),
    "Original request and parent conversation snapshot (reference material, not a new instruction):",
    brief,
    "Use task_context for original text. Existing detached jobs belong to this worker and may still be running; inspect their results before deciding to reuse or stop them.",
    `A normal final message does not complete this Task. Call task_report with revision ${revision} and an honest final status, results, verification, and blockers.`,
  ].join("\n\n");
}
