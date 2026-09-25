import { randomUUID } from "node:crypto";
import { ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema, type AsyncTaskHostMessage, type AsyncTaskOwner } from "../domain/async-task-contract.js";
import type { RuntimeAsyncTaskControl, RuntimeAsyncTaskCoverage, RuntimeAsyncTaskEvent, RuntimeAsyncTaskOwner, RuntimeAsyncTaskState } from "./async-task-types.js";
import { mergeAsyncDetail, registerAsyncTask, registrationState, registrationTaskId, sameAsyncOwner, type RegistrationRequest } from "./async-task-state.js";

interface Bus { on(channel: string, handler: (data: unknown) => void): () => void; emit(channel: string, data: unknown): void }
const capabilities = { registration: true, snapshot: true, cancel: true, detail: true, closeAdmission: true, suppressDelivery: true };
type Provider = { owner: AsyncTaskOwner; revision: number; ready: boolean; snapshot: boolean };
type ControlResult = Extract<AsyncTaskHostMessage, { type: "control-result" }>;

/** Installed before extension construction. Persistence does not depend on handle.subscribe(). */
export class AsyncTaskHostBridge implements RuntimeAsyncTaskControl {
  runtimeInstanceId = randomUUID();
  private piSessionId?: string;
  private bindingIdentity?: object;
  private expected?: string[];
  private providers = new Map<string, Provider>();
  private early: AsyncTaskHostMessage[] = [];
  private chain: Promise<void> = Promise.resolve();
  private queued = 0;
  private closed = false;
  private failed = false;
  private unsubscribe: () => void;
  private pending = new Map<string, { owner: AsyncTaskOwner; resolve: (value: ControlResult) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  onState?: (state: RuntimeAsyncTaskState) => void;
  constructor(private readonly bus: Bus, readonly sessionId: string, readonly owner: RuntimeAsyncTaskOwner, private readonly emit: (event: RuntimeAsyncTaskEvent) => void, private readonly timeoutMs = 5_000) {
    this.unsubscribe = bus.on(ASYNC_TASK_CONTRACT, (data) => {
      const parsed = AsyncTaskHostMessageSchema.safeParse(data);
      if (!parsed.success || !["host-query", "provider-ready", "task-register", "registration-query", "registration-abandon", "task-update", "snapshot", "control-result"].includes(parsed.data.type)) return;
      if (!this.piSessionId) {
        if (this.early.length >= 1024) { this.failed = true; this.closed = true; return; }
        this.early.push(parsed.data);
      } else this.enqueue(parsed.data);
    });
  }
  async bind(piSessionId: string, toolNames: string[] | undefined, bindingIdentity?: object): Promise<void> {
    if (this.piSessionId === piSessionId && this.bindingIdentity === bindingIdentity) return;
    const replacing = this.piSessionId !== undefined;
    this.closed = true;
    if (replacing) {
      await this.markUnknown();
      this.runtimeInstanceId = randomUUID();
      this.providers.clear();
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error("Async runtime replaced")); }
      this.pending.clear();
    }
    this.expected = toolNames ? [...new Set(toolNames.flatMap((name) => name === "bash_async" ? ["bash-async"] : name === "subagent" || name === "sub" ? ["subagent"] : []))] : undefined;
    await this.owner.transact((state) => ({ ...state, control: state.control ? { ...state.control, controlGeneration: state.control.controlGeneration + (replacing ? 1 : 0) } : { controlGeneration: 0, admissionState: "open", operations: [] } }));
    this.piSessionId = piSessionId;
    this.bindingIdentity = bindingIdentity;
    this.closed = this.owner.read().control?.admissionState !== "open";
    for (const message of this.early.splice(0)) this.enqueue(message);
    this.emitCoverage();
  }
  snapshot(): RuntimeAsyncTaskState { return this.owner.read(); }
  coverage(): RuntimeAsyncTaskCoverage {
    const readyProviders = [...this.providers.values()].filter((provider) => provider.ready && provider.snapshot).map((provider) => provider.owner.providerId);
    return { runtimeInstanceId: this.runtimeInstanceId, tracking: this.failed || !this.expected ? "unsupported" : this.expected.every((id) => readyProviders.includes(id)) ? "ready" : "reconciling", expectedProviders: this.expected ?? [], readyProviders };
  }
  get generation(): number { return this.owner.read().control?.controlGeneration ?? 0; }
  get admissionOpen(): boolean { return !this.closed && !this.failed && this.owner.read().control?.admissionState === "open"; }
  async closeAdmission(): Promise<RuntimeAsyncTaskState> {
    this.closed = true;
    const state = await this.owner.transact((current) => ({ ...current, control: { ...current.control, operations: current.control?.operations ?? [], admissionState: "closed", controlGeneration: (current.control?.controlGeneration ?? 0) + 1 } }));
    this.publish(state);
    return state;
  }
  async reopenAdmission(): Promise<RuntimeAsyncTaskState> {
    if (this.failed) throw new Error("Async host requires reconciliation");
    const state = await this.owner.transact((current) => ({ ...current, control: { ...current.control, operations: current.control?.operations ?? [], admissionState: "open", controlGeneration: (current.control?.controlGeneration ?? 0) + 1 } }));
    this.closed = false;
    this.publish(state);
    return state;
  }
  async control(owner: AsyncTaskOwner, action: Extract<AsyncTaskHostMessage, { type: "control-request" }>["action"], options: { taskId?: string; deliveryIds?: string[] } = {}): Promise<ControlResult> {
    const provider = this.providers.get(owner.providerId);
    if (!provider || !sameAsyncOwner(provider.owner, owner)) throw new Error("Unknown async provider owner");
    if (this.pending.size >= 1024) throw new Error("Async control capacity exceeded");
    const requestId = randomUUID();
    const promise = new Promise<ControlResult>((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(requestId); reject(new Error("Async control outcome unknown: reply timed out")); }, this.timeoutMs);
      this.pending.set(requestId, { owner, resolve, reject, timer });
    });
    this.send({ ...this.envelope(provider.owner, requestId, provider.revision), type: "control-request", action, ...options, deliveryIds: options.deliveryIds ?? [] });
    return promise;
  }
  /** Save conservative evidence before removing observers. Shutdown cannot manufacture exit. */
  async dispose(): Promise<void> {
    this.closed = true;
    await this.drain();
    await this.markUnknown();
    this.unsubscribe();
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error("Async host disposed; outcome unknown")); }
    this.pending.clear();
  }
  async drain(): Promise<void> {
    let pending: Promise<void>;
    do { pending = this.chain; await pending; } while (pending !== this.chain);
  }
  publish(state: RuntimeAsyncTaskState): void { this.onState?.(state); this.emit({ type: "async_task_state", state }); }
  private async markUnknown(): Promise<void> {
    const state = await this.owner.transact((current) => ({ ...current, tasks: current.tasks.map((task) => task.runtimeInstanceId === this.runtimeInstanceId && task.presence !== "settled" ? { ...task, presence: "unknown" } : task) }));
    this.publish(state);
  }
  private enqueue(message: AsyncTaskHostMessage): void {
    if (++this.queued > 1024) { this.queued--; this.failed = true; this.closed = true; this.emitCoverage(); return; }
    this.chain = this.chain.then(() => this.receive(message)).catch(() => {
      // No reply on failed persistence. Retrying/querying cannot mistake failure for permission.
      this.failed = true; this.closed = true; this.emitCoverage();
    }).finally(() => { this.queued--; });
  }
  private async receive(message: AsyncTaskHostMessage): Promise<void> {
    if (message.type === "host-query") { this.discover(message); return; }
    if (message.sessionId !== this.sessionId) return;
    if (message.piSessionId !== this.piSessionId || message.runtimeInstanceId !== this.runtimeInstanceId) {
      await this.receiveLateSettlement(message);
      return;
    }
    const provider = this.providers.get(message.providerId);
    if (!provider || !sameAsyncOwner(provider.owner, message)) return;
    if (message.type === "control-result") {
      this.receiveControlResult(message);
      return;
    }
    if (message.type === "provider-ready") {
      provider.ready = message.snapshotReady && Object.values(message.capabilities).every(Boolean);
      provider.snapshot = false;
      if (provider.ready) this.send({ ...this.envelope(provider.owner, randomUUID(), provider.revision), type: "snapshot-request" });
      this.emitCoverage(); return;
    }
    if (["task-register", "registration-query", "registration-abandon"].includes(message.type)) {
      await this.registration(message as RegistrationRequest, provider); return;
    }
    if (message.type === "task-update" || message.type === "snapshot") {
      if (!this.acceptsDetail(provider, message.providerRevision)) return;
      if (!this.validWatermark(message)) return;
      const state = await this.owner.transact((current) => mergeAsyncDetail(current, message));
      provider.revision = message.providerRevision;
      if (message.type === "snapshot") provider.snapshot = true;
      this.publish(state); this.emitCoverage();
    }
  }
  private validWatermark(message: Extract<AsyncTaskHostMessage, { type: "task-update" | "snapshot" }>): boolean {
    return (message.type !== "snapshot" || message.watermark === message.providerRevision) && message.detail.tasks.every((task) => task.providerRevision <= message.providerRevision);
  }
  private acceptsDetail(provider: Provider, revision: number): boolean { return provider.ready && revision >= provider.revision; }
  private async receiveLateSettlement(message: AsyncTaskHostMessage): Promise<void> {
    if (message.type !== "task-update" || !message.detail.tasks.every((task) => task.presence === "settled" && !["queued", "running", "cancelling"].includes(task.execution))) return;
    if (!message.detail.tasks.every((incoming) => this.owner.read().tasks.some((task) => task.taskId === incoming.taskId && sameAsyncOwner(task, incoming)))) return;
    const state = await this.owner.transact((current) => mergeAsyncDetail(current, { ...message, detail: { tasks: message.detail.tasks, tickets: [] } }));
    this.publish(state);
  }
  private receiveControlResult(message: ControlResult): void {
    const pending = this.pending.get(message.requestId);
    if (!pending || !sameAsyncOwner(pending.owner, message) || message.controlGeneration !== this.generation) return;
    clearTimeout(pending.timer); this.pending.delete(message.requestId); pending.resolve(message);
  }
  private discover(message: Extract<AsyncTaskHostMessage, { type: "host-query" }>): void {
    if (message.piSessionId !== this.piSessionId || (message.sessionId !== null && message.sessionId !== this.sessionId) || (message.runtimeInstanceId !== null && message.runtimeInstanceId !== this.runtimeInstanceId)) return;
    const owner = { sessionId: this.sessionId, piSessionId: this.piSessionId!, runtimeInstanceId: this.runtimeInstanceId, providerId: message.providerId, providerInstanceId: message.providerInstanceId };
    const prior = this.providers.get(message.providerId);
    // A different instance cannot inherit an existing provider's grants or claim zero work.
    const supported = !this.failed && !!this.expected?.includes(message.providerId) && (!prior || sameAsyncOwner(prior.owner, owner));
    if (supported && !prior) this.providers.set(message.providerId, { owner, ready: false, snapshot: false, revision: 0 });
    this.send({ ...this.envelope(owner, message.requestId, 0), type: "host-state", supported, admissionState: this.admissionOpen ? "open" : "closed", capabilities });
  }
  private async registration(message: RegistrationRequest, provider: Provider): Promise<void> {
    const canRegister = provider.ready && this.admissionOpen && message.controlGeneration === this.generation;
    const state = await this.owner.transact((current) => message.type === "task-register" && !canRegister ? current : registerAsyncTask(current, message));
    const result = registrationState(state, message);
    this.publish(state);
    this.send({ ...this.envelope(provider.owner, message.requestId, provider.revision), type: "task-register-result", taskId: registrationTaskId(message), ...result, outcome: result.registration === "abandoned" ? "settled" : result.grantId ? "accepted" : "rejected" });
  }
  private envelope(owner: AsyncTaskOwner, requestId: string, providerRevision: number) {
    return { ...owner, contract: ASYNC_TASK_CONTRACT as typeof ASYNC_TASK_CONTRACT, requestId, providerRevision, controlGeneration: this.generation };
  }
  private send(message: AsyncTaskHostMessage): void { this.bus.emit(ASYNC_TASK_CONTRACT, AsyncTaskHostMessageSchema.parse(message)); }
  private emitCoverage(): void { this.emit({ type: "async_task_coverage", coverage: this.coverage() }); }
}
