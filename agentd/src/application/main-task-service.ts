import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type { MainTasksSnapshot } from "../features/main-tasks/schema.js";
import type { PickyContextPacket } from "../protocol.js";
import {
  buildPickleHandoffInstructions,
  buildTaskCompletionPrompt,
  buildTaskInterruptionPrompt,
  delegationChoiceOutcome,
  deriveTaskTitle,
  isActiveTaskStatus,
  isOpenDecision,
  projectMainTasksSnapshot,
  type DelegationChoice,
  type DelegationDecisionRecord,
} from "../domain/main-task-policy.js";
import { buildContextSnapshot, type TaskRequestContext } from "../runtime/task/context.js";
import { TaskManager } from "../runtime/task/manager.js";
import { TaskStore, writePrivateJson } from "../runtime/task/store.js";
import type { EvaluationResult, TaskContextSnapshot, TaskOrigin, TaskRecord, WorkerFactory } from "../runtime/task/types.js";

/** Who is answering a delegation decision. Only real user actions may execute one. */
export type DelegationActor = "form" | "app" | "model";
export type MainTurnOrigin = "user" | "internal";

/** Read-only view of the live main conversation, attached by MainAgentCoordinator. */
export interface MainAgentTaskHost {
  currentContext(): PickyContextPacket | undefined;
  /** Whether the running main turn was started by the user's own input. */
  turnOrigin(): MainTurnOrigin;
}

export interface MainTaskCompletion {
  taskId: string;
  revision: number;
  prompt: string;
  cwd: string;
  origin?: TaskOrigin;
  /** The notice about Tasks a quit stopped, rather than one Task's result. */
  interruption?: true;
}

export interface MainTaskServiceDependencies {
  /** Private folder under the app support directory. */
  directory: string;
  maxConcurrency: number;
  createWorker: WorkerFactory;
  evaluate(record: Readonly<TaskRecord>, snapshot: TaskContextSnapshot, signal: AbortSignal): Promise<EvaluationResult>;
  /** Creates a visible Pickle through the app-owned creation path. */
  createPickle(request: { title: string; instructions: string; cwd?: string; context?: PickyContextPacket }): Promise<{ sessionId: string }>;
  defaultCwd(): string;
  log(message: string, fields?: Record<string, string | number | boolean | undefined>): void;
}

export interface CreateMainTaskInput {
  title?: string;
  instruction: string;
  cwd?: string;
  readonly?: boolean;
  /** Parent branch entries the snapshot is built from (the main Pi session's active branch). */
  branch?: readonly unknown[];
  decisionId?: string;
}

export interface AskDelegationInput {
  title: string;
  instructions: string;
  cwd?: string;
  question?: string;
  fromTaskId?: string;
  branch?: readonly unknown[];
}

const RESUME_INSTRUCTION = "Resume the task from the preserved context and report the final outcome.";
const SCOPE_APPROVED_INSTRUCTION = "The user chose to continue this work as a Task instead of handing it to a Pickle. Production-level code work within this scope is approved; continue and report the outcome.";
const DECISION_ID = /^delegation-[a-f0-9-]+$/;

/**
 * Owner of the main Picky agent's Tasks and Pickle delegation decisions. It is the single durable
 * source for both (the Task engine's store and `decisions.json` in the same private folder), the
 * only place a delegation choice executes, and the queue of results waiting for the main agent.
 */
export class MainTaskService {
  private readonly manager: TaskManager;
  private readonly decisions = new Map<string, DelegationDecisionRecord>();
  private readonly decisionChains = new Map<string, Promise<unknown>>();
  private readonly changeListeners = new Set<(snapshot: MainTasksSnapshot) => void>();
  private readonly completionListeners = new Set<() => void>();
  private host?: MainAgentTaskHost;
  private changeTimer?: ReturnType<typeof setTimeout>;
  private closed = false;

  constructor(private readonly deps: MainTaskServiceDependencies) {
    this.loadDecisions();
    this.manager = new TaskManager({
      store: new TaskStore(deps.directory),
      maxConcurrency: deps.maxConcurrency,
      evaluate: (record, snapshot, signal) => deps.evaluate(record, snapshot, signal),
      createWorker: deps.createWorker,
      onTerminal: (record) => {
        deps.log("main task reported", { taskId: record.id, revision: record.revision, status: record.status });
        this.notifyCompletionAvailable();
      },
      onChange: () => this.scheduleChange(),
    });
  }

  attachMainAgent(host: MainAgentTaskHost): void {
    this.host = host;
  }

  onChange(listener: (snapshot: MainTasksSnapshot) => void): () => void {
    this.changeListeners.add(listener);
    return () => this.changeListeners.delete(listener);
  }

  onCompletionAvailable(listener: () => void): () => void {
    this.completionListeners.add(listener);
    return () => this.completionListeners.delete(listener);
  }

  snapshot(): MainTasksSnapshot {
    return projectMainTasksSnapshot(this.manager.list(), [...this.decisions.values()]);
  }

  listTasks(): TaskRecord[] {
    return this.manager.list();
  }

  getTask(taskId: string): TaskRecord {
    return this.manager.get(taskId);
  }

  listDecisions(): DelegationDecisionRecord[] {
    return [...this.decisions.values()].map((decision) => structuredClone(decision));
  }

  getDecision(decisionId: string): DelegationDecisionRecord {
    const decision = this.decisions.get(decisionId);
    if (!decision) throw new Error(`Unknown delegation decision: ${decisionId}`);
    return structuredClone(decision);
  }

  createTask(input: CreateMainTaskInput): TaskRecord {
    const context = this.host?.currentContext();
    const origin = originFromContext(context);
    const record = this.manager.create(
      {
        title: deriveTaskTitle(input.title, input.instruction),
        instruction: input.instruction,
        cwd: requireWorkingFolder(input.cwd?.trim() || this.deps.defaultCwd()),
        readonly: input.readonly,
        ...(origin ? { origin } : {}),
        ...(input.decisionId ? { decisionId: input.decisionId } : {}),
      },
      buildContextSnapshot(input.branch ?? [], requestContextFromPacket(context)),
    );
    this.deps.log("main task created", { taskId: record.id, readonly: record.readonly, approvedScope: record.decisionId !== undefined });
    return record;
  }

  /**
   * Adds an instruction as a new revision of the same worker. The original request snapshot stays
   * fixed; later conversation reaches the worker only through instructions like this one.
   */
  reviseTask(taskId: string, instruction: string): Promise<TaskRecord> {
    return this.manager.edit(taskId, instruction);
  }

  async resumeTask(taskId: string, instruction?: string): Promise<TaskRecord> {
    const record = this.manager.get(taskId);
    if (isActiveTaskStatus(record.status) || record.status === "stopping") throw new Error(`Task ${taskId} is still running`);
    if (record.handoff?.pickleSessionId) throw new Error(`Task ${taskId} was handed to Pickle ${record.handoff.pickleSessionId}; continue it there`);
    return this.manager.edit(taskId, instruction?.trim() || RESUME_INSTRUCTION);
  }

  stopTask(taskId: string): Promise<TaskRecord> {
    return this.manager.stop(taskId);
  }

  /** Records a pending decision. Nothing runs until a user choice resolves it. */
  createDecision(input: AskDelegationInput): DelegationDecisionRecord {
    if (!input.title.trim() || !input.instructions.trim()) throw new Error("A delegation decision needs a title and instructions");
    if (input.fromTaskId) {
      const task = this.manager.get(input.fromTaskId);
      if (task.handoff?.pickleSessionId) throw new Error(`Task ${task.id} was already handed to Pickle ${task.handoff.pickleSessionId}`);
      // One open question per Task: asking again returns it instead of risking a second Pickle.
      const open = [...this.decisions.values()].find((decision) => decision.fromTaskId === task.id && isOpenDecision(decision));
      if (open) return structuredClone(open);
    }
    const now = new Date().toISOString();
    const context = this.host?.currentContext();
    const origin = originFromContext(context);
    const decision: DelegationDecisionRecord = {
      id: `delegation-${randomUUID()}`,
      state: "pending",
      title: deriveTaskTitle(input.title, input.instructions),
      instructions: input.instructions.trim(),
      ...(input.cwd?.trim() ? { cwd: input.cwd.trim() } : {}),
      ...(input.question?.trim() ? { question: input.question.trim() } : {}),
      ...(origin ? { origin } : {}),
      createdAt: now,
      updatedAt: now,
      ...(input.fromTaskId ? { fromTaskId: input.fromTaskId } : {}),
    };
    // The request snapshot is fixed now, so a later unrelated turn cannot become this scope's context.
    writePrivateJson(this.decisionContextFile(decision.id), {
      snapshot: buildContextSnapshot(input.branch ?? [], requestContextFromPacket(context)),
      ...(context ? { context } : {}),
    });
    this.decisions.set(decision.id, decision);
    this.persistDecisions();
    this.deps.log("delegation decision pending", { decisionId: decision.id, fromTask: input.fromTaskId !== undefined });
    return structuredClone(decision);
  }

  /**
   * Applies a user's choice exactly once. A repeated or stale answer returns the existing outcome;
   * a model may only answer during a turn the user's own input started.
   */
  resolveDecision(decisionId: string, choice: DelegationChoice, actor: DelegationActor): Promise<DelegationDecisionRecord> {
    const previous = this.decisionChains.get(decisionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(() => this.applyChoice(decisionId, choice, actor));
    this.decisionChains.set(decisionId, next);
    void next.finally(() => {
      if (this.decisionChains.get(decisionId) === next) this.decisionChains.delete(decisionId);
    }).catch(() => undefined);
    return next;
  }

  /**
   * The oldest finished Task revision whose result the main agent has not received yet, then one
   * notice covering every Task a quit stopped that the main agent has not heard about.
   */
  nextCompletion(): MainTaskCompletion | undefined {
    const records = this.manager.list();
    const pending = records
      .filter((record) => record.report && !record.completionDelivered && !record.handoff?.pickleSessionId)
      .sort((left, right) => left.updatedAt.localeCompare(right.updatedAt))[0];
    if (pending) {
      return {
        taskId: pending.id,
        revision: pending.revision,
        prompt: buildTaskCompletionPrompt(pending),
        cwd: pending.cwd,
        ...(pending.origin ? { origin: pending.origin } : {}),
      };
    }
    // During shutdown the notice would reach a main agent that is going away; the next start sends it.
    if (this.closed) return undefined;
    const interrupted = records
      .filter((record) => record.status === "interrupted" && !record.interruptionNotified)
      .sort((left, right) => left.updatedAt.localeCompare(right.updatedAt));
    const latest = interrupted.at(-1);
    if (!latest) return undefined;
    return {
      taskId: latest.id,
      revision: latest.revision,
      prompt: buildTaskInterruptionPrompt(interrupted),
      cwd: latest.cwd,
      ...(latest.origin ? { origin: latest.origin } : {}),
      interruption: true,
    };
  }

  /** Records that the main agent received a result or notice, so it is never delivered again. */
  markCompletionDelivered(completion: Pick<MainTaskCompletion, "taskId" | "revision" | "interruption">): void {
    // Tasks become interrupted only when a process starts or ends, so the set this acknowledges is
    // the one the notice listed (minus any the user resumed meanwhile, which are no longer pending).
    if (completion.interruption) {
      this.manager.takeInterruptions();
      return;
    }
    if (this.manager.has(completion.taskId)) this.manager.markDelivered(completion.taskId, completion.revision);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    if (this.changeTimer) clearTimeout(this.changeTimer);
    await this.manager.close();
    this.emitChange();
  }

  private async applyChoice(decisionId: string, choice: DelegationChoice, actor: DelegationActor): Promise<DelegationDecisionRecord> {
    const decision = this.decisions.get(decisionId);
    if (!decision) throw new Error(`Unknown delegation decision: ${decisionId}`);
    if (actor === "model" && this.host?.turnOrigin() !== "user") {
      throw new Error("Only the user can answer a delegation decision. Ask the user, or wait for their reply.");
    }
    const outcome = delegationChoiceOutcome(decision, choice);
    if (outcome === "already") return structuredClone(decision);
    if (outcome === "rejected") throw new Error(`Delegation ${decisionId} is already ${decision.state === "task" ? "running as a Task" : decision.state === "cancelled" ? "cancelled" : "handed to a Pickle"}`);
    this.deps.log("delegation decision answered", { decisionId, choice, actor });
    if (choice === "cancel") return this.updateDecision(decision, { state: "cancelled", pickle: undefined });
    if (choice === "task") return this.runDecisionAsTask(decision);
    return this.handDecisionToPickle(decision);
  }

  private async runDecisionAsTask(decision: DelegationDecisionRecord): Promise<DelegationDecisionRecord> {
    if (decision.fromTaskId) {
      const task = this.manager.get(decision.fromTaskId);
      this.manager.approveScope(task.id, decision.id);
      await this.manager.edit(task.id, SCOPE_APPROVED_INSTRUCTION);
      return this.updateDecision(decision, { state: "task", taskId: task.id, pickle: undefined });
    }
    const stored = this.readDecisionContext(decision.id);
    const record = this.manager.create(
      {
        title: decision.title,
        instruction: decision.instructions,
        cwd: requireWorkingFolder(decision.cwd ?? this.deps.defaultCwd()),
        ...(decision.origin ? { origin: decision.origin } : {}),
        decisionId: decision.id,
      },
      stored.snapshot,
    );
    return this.updateDecision(decision, { state: "task", taskId: record.id, pickle: undefined });
  }

  private async handDecisionToPickle(decision: DelegationDecisionRecord): Promise<DelegationDecisionRecord> {
    let task: TaskRecord | undefined;
    if (decision.fromTaskId) {
      task = this.manager.get(decision.fromTaskId);
      // The Task must be confirmed stopped first, so a worker and the Pickle never write together.
      if (task.status === "stopping") throw new Error(`Task ${task.id} is still stopping; try again in a moment`);
      if (isActiveTaskStatus(task.status)) task = await this.manager.stop(task.id);
      if (task.status === "cancelled" && task.cleanup === "uncertain") {
        return this.updateDecision(decision, { state: "pickle", pickle: { state: "failed", error: "The Task could not be confirmed stopped, so no Pickle was created. Check the working folder before retrying." } });
      }
    }
    await this.updateDecision(decision, { state: "pickle", pickle: { state: "creating" } });
    const stored = this.readDecisionContext(decision.id);
    try {
      const created = await this.deps.createPickle({
        title: decision.title,
        instructions: buildPickleHandoffInstructions(decision, task),
        ...(decision.cwd ?? task?.cwd ? { cwd: decision.cwd ?? task?.cwd } : {}),
        ...(stored.context ? { context: stored.context } : {}),
      });
      if (task) this.manager.recordHandoff(task.id, { decisionId: decision.id, pickleSessionId: created.sessionId });
      return this.updateDecision(decision, { state: "pickle", pickle: { state: "created", sessionId: created.sessionId } });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.deps.log("delegation pickle creation failed", { decisionId: decision.id, error: message });
      return this.updateDecision(decision, { state: "pickle", pickle: { state: "failed", error: message } });
    }
  }

  private async updateDecision(decision: DelegationDecisionRecord, patch: Partial<DelegationDecisionRecord>): Promise<DelegationDecisionRecord> {
    Object.assign(decision, patch, { updatedAt: new Date().toISOString() });
    for (const key of Object.keys(patch) as (keyof DelegationDecisionRecord)[]) {
      if (patch[key] === undefined) delete decision[key];
    }
    this.persistDecisions();
    return structuredClone(decision);
  }

  private decisionContextFile(decisionId: string): string {
    if (!DECISION_ID.test(decisionId)) throw new Error("Invalid delegation decision ID");
    return path.join(this.deps.directory, "decisions", `${decisionId}.json`);
  }

  private readDecisionContext(decisionId: string): { snapshot: TaskContextSnapshot; context?: PickyContextPacket } {
    try {
      const value = JSON.parse(readFileSync(this.decisionContextFile(decisionId), "utf8")) as { snapshot?: TaskContextSnapshot; context?: PickyContextPacket };
      if (value.snapshot && typeof value.snapshot.brief === "string" && Array.isArray(value.snapshot.entries)) return { snapshot: value.snapshot, ...(value.context ? { context: value.context } : {}) };
    } catch {
      // Fall through to an empty snapshot; the decision's own instructions still carry the scope.
    }
    return { snapshot: { brief: "", entries: [] } };
  }

  private get decisionsFile(): string {
    return path.join(this.deps.directory, "decisions.json");
  }

  private loadDecisions(): void {
    if (!existsSync(this.decisionsFile)) return;
    let value: unknown;
    try {
      value = JSON.parse(readFileSync(this.decisionsFile, "utf8"));
    } catch (error) {
      this.deps.log("delegation decisions unreadable", { error: error instanceof Error ? error.message : String(error) });
      return;
    }
    if (!Array.isArray(value)) return;
    let repaired = false;
    for (const item of value as DelegationDecisionRecord[]) {
      if (!item || typeof item !== "object" || typeof item.id !== "string" || !DECISION_ID.test(item.id)) continue;
      if (!["pending", "pickle", "task", "cancelled"].includes(item.state)) continue;
      if (item.pickle?.state === "creating") {
        // The previous process ended before the app confirmed the Pickle. Never retry silently.
        item.pickle = { state: "failed", error: "Picky stopped before the Pickle was confirmed. Check the Pickle list before trying again." };
        repaired = true;
      }
      this.decisions.set(item.id, item);
    }
    if (repaired) this.persistDecisions();
  }

  private persistDecisions(): void {
    writePrivateJson(this.decisionsFile, [...this.decisions.values()]);
    this.scheduleChange();
  }

  private notifyCompletionAvailable(): void {
    for (const listener of this.completionListeners) {
      try { listener(); } catch (error) {
        this.deps.log("main task completion listener failed", { error: error instanceof Error ? error.message : String(error) });
      }
    }
  }

  /** Coalesces bursts (a worker flipping running/waiting) into one app update. */
  private scheduleChange(): void {
    if (this.changeTimer || this.changeListeners.size === 0) return;
    this.changeTimer = setTimeout(() => {
      this.changeTimer = undefined;
      this.emitChange();
    }, 100);
    this.changeTimer.unref?.();
  }

  private emitChange(): void {
    if (this.changeListeners.size === 0) return;
    const snapshot = this.snapshot();
    for (const listener of this.changeListeners) listener(snapshot);
  }
}

/** A worker spawned in a missing folder would fail opaquely; reject the request with the reason instead. */
function requireWorkingFolder(cwd: string): string {
  if (!path.isAbsolute(cwd)) throw new Error(`The Task working folder must be an absolute path: ${cwd}`);
  let isDirectory = false;
  try {
    isDirectory = statSync(cwd).isDirectory();
  } catch {
    isDirectory = false;
  }
  if (!isDirectory) throw new Error(`The Task working folder does not exist: ${cwd}`);
  return cwd;
}

function originFromContext(context: PickyContextPacket | undefined): TaskOrigin | undefined {
  if (!context) return undefined;
  const text = context.transcript?.trim();
  return {
    contextId: context.id,
    ...(context.source ? { source: context.source } : {}),
    ...(text ? { text } : {}),
  };
}

/** Neutral desktop context only; the worker reads screenshots as files if it needs them. */
export function requestContextFromPacket(context: PickyContextPacket | undefined): TaskRequestContext | undefined {
  if (!context) return undefined;
  const request = context.transcript?.trim();
  return {
    ...(request ? { request } : {}),
    desktop: desktopLines(context),
    attachments: (context.screenshots ?? []).map((shot) => `${shot.path} (${shot.label})`),
  };
}

function desktopLines(context: PickyContextPacket): string[] {
  const selected = context.selectedText?.trim() || context.browser?.selectedText?.trim();
  const lines: Array<[string, string | undefined]> = [
    ["App", context.activeApp?.name],
    ["Window", context.activeWindow?.title],
    ["URL", context.browser?.url],
    ["Page title", context.browser?.title],
    ["Selected text", selected],
    ["Working folder at request time", context.cwd],
  ];
  return lines.filter((entry): entry is [string, string] => Boolean(entry[1])).map(([label, value]) => `${label}: ${value}`);
}
