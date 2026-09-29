import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import type { AgentSession, InlineExtension } from "@earendil-works/pi-coding-agent";
import { ASYNC_TASK_CONTRACT, AsyncCompletionDeliverySchema, type AgentCycle, type AsyncCompletionDelivery } from "../domain/async-task-contract.js";
import { asyncIdentity, sameAsyncOwner } from "./async-task-state.js";
import type { AsyncTaskHostBridge } from "./async-task-host-bridge.js";
import type { RuntimeAsyncTaskEvent } from "./async-task-types.js";

type RequestObservation = { generation: number; deliveries: AsyncCompletionDelivery[]; invalid: boolean };
/** Uses only public context hooks and agent.streamFunction, before the provider is called. */
export class AsyncTaskModelFence {
  private authorization = new AsyncLocalStorage<number>();
  private observation?: RequestObservation;
  private session?: AgentSession;
  private originalStream?: AgentSession["agent"]["streamFunction"];
  private wrappedStream?: AgentSession["agent"]["streamFunction"];
  private cycle?: AgentCycle;
  private settlingCycleId?: string;
  private deliveries: AsyncCompletionDelivery[] = [];
  private requestDeliveries: AsyncCompletionDelivery[] = [];
  private consumedDeliveries = new Set<string>();
  private settled: Promise<void> = Promise.resolve();
  private pendingPersistence: Array<() => Promise<void>> = [];
  private recovery?: Promise<void>;
  readonly inlineExtension: InlineExtension;
  constructor(private readonly bridge: AsyncTaskHostBridge, private readonly emit: (event: RuntimeAsyncTaskEvent | { type: "log"; line: string }) => void, private readonly send: (data: unknown) => void) {
    bridge.retryPersistence = () => this.retryPersistence();
    this.inlineExtension = { name: "picky-async-task-admission", hidden: true, factory: (api) => {
      api.on("context_with_system", async (event) => {
        // Providers publish ticket identity immediately before sendMessage. Its durable
        // transaction must finish before this hook validates the delivered identity.
        await bridge.drain();
        const generation = bridge.generation;
        const authorized = this.authorization.getStore() === generation;
        const deliveries: AsyncCompletionDelivery[] = [];
        let invalid = this.authorization.getStore() !== undefined && !authorized;
        const messages = event.messages.filter((message) => {
          if (message.role !== "custom") return true;
          const details = (message.details as Record<string, unknown> | undefined)?.asyncTasks;
          const parsed = AsyncCompletionDeliverySchema.safeParse(details);
          if (!parsed.success) { if (details !== undefined) invalid = true; return true; }
          const delivery = parsed.data;
          const current = delivery.sessionId === bridge.sessionId && delivery.runtimeInstanceId === bridge.runtimeInstanceId && delivery.controlGeneration === generation;
          if (!current && authorized) return false;
          const tickets = bridge.snapshot().tickets.filter((ticket) => sameAsyncOwner(ticket, delivery) && delivery.completionIds.includes(ticket.completionId));
          if (tickets.length > 0 && tickets.every((ticket) => ticket.state === "handled")) return true;
          if (!current || tickets.length !== new Set(delivery.completionIds).size || tickets.some((ticket) => ticket.state === "suppressed" || ticket.target !== "model" || ticket.deliveryId !== delivery.deliveryId || ticket.controlGeneration !== delivery.controlGeneration) || !delivery.taskIds.every((id) => bridge.snapshot().tasks.some((task) => sameAsyncOwner(task, delivery) && task.taskId === id))) invalid = true;
          deliveries.push(delivery);
          return true;
        });
        // A passive append never enters this hook. This still is only observation, not processing.
        this.observation = { generation, deliveries, invalid };
        return { messages };
      });
    } };
  }
  get currentCycleId(): string | undefined { return this.cycle?.cycleId; }
  runAuthorized<T>(work: () => T): T { return this.authorization.run(this.bridge.generation, work); }
  bind(session: AgentSession): void {
    if (this.session === session && session.agent.streamFunction === this.wrappedStream) return;
    if (this.session && this.originalStream && this.session.agent.streamFunction === this.wrappedStream) this.session.agent.streamFunction = this.originalStream;
    this.session = session;
    const original = session.agent.streamFunction;
    this.originalStream = original;
    session.agent.streamFunction = async (model, context, options) => {
      const admissionSignal = this.bridge.admissionSignal;
      await this.waitWhileAdmitted(this.settled, admissionSignal, options?.signal);
      await this.waitWhileAdmitted(this.bridge.owner.beforeModelRequest?.() ?? Promise.resolve(), admissionSignal, options?.signal);
      const observed = this.requireCurrentObservation(admissionSignal);
      // This request has not reached the provider. Manual compaction can overlap
      // an extension-triggered prompt; wait for its public end event, not agent idle
      // (the waiting request itself keeps the agent active).
      await this.waitForCompaction(session, admissionSignal, options?.signal);
      await this.waitWhileAdmitted(this.settled, admissionSignal, options?.signal);
      if (options?.signal?.aborted) throw new Error("Async model admission aborted");
      this.requireCurrentObservation(admissionSignal, observed, session.isCompacting);
      const cycle: AgentCycle = this.cycle ?? { cycleId: randomUUID(), runtimeInstanceId: this.bridge.runtimeInstanceId, phase: "responding", controlGeneration: observed.generation };
      const keys = new Set(observed.deliveries.flatMap((delivery) => delivery.completionIds.map((id) => asyncIdentity(delivery, id))));
      const state = await this.bridge.owner.transact((current) => {
        if (!this.bridge.admissionOpen || current.control?.controlGeneration !== observed.generation) throw new Error("Async model admission changed during persistence");
        return { ...current, cycle, tickets: current.tickets.map((ticket) => keys.has(asyncIdentity(ticket, ticket.completionId)) && !["handled", "suppressed"].includes(ticket.state) ? { ...ticket, state: "processing", cycleId: cycle.cycleId } : ticket) };
      });
      this.observation = undefined;
      this.cycle = cycle;
      this.deliveries = [...new Map([...this.deliveries, ...observed.deliveries].map((delivery) => [asyncIdentity(delivery, delivery.deliveryId), delivery])).values()];
      this.requestDeliveries = observed.deliveries;
      this.bridge.publish(state);
      this.emit({ type: "async_task_cycle", cycle, deliveries: observed.deliveries });
      // The durable processing intent is recoverable even if stop wins during save.
      // SDK agent_end leaves tickets pending unless a completed model response
      // later proves that this request already consumed the delivery.
      if (options?.signal?.aborted || admissionSignal.aborted || !this.bridge.admissionOpen || observed.generation !== this.bridge.generation || session.isCompacting) throw new Error("Async model admission invalidated before dispatch");
      return original(model, context, options);
    };
    this.wrappedStream = session.agent.streamFunction;
  }
  private requireCurrentObservation(signal: AbortSignal, observed = this.observation, compacting = false): RequestObservation {
    if (!observed || observed.invalid || observed.generation !== this.bridge.generation || !this.bridge.admissionOpen || signal.aborted || compacting) throw new Error("Async model admission closed or stale");
    return observed;
  }
  private async waitWhileAdmitted(work: Promise<void>, admissionSignal: AbortSignal, signal?: AbortSignal): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const finish = (error?: unknown) => {
        admissionSignal.removeEventListener("abort", abort);
        signal?.removeEventListener("abort", abort);
        if (error) reject(error); else resolve();
      };
      const abort = () => finish(new Error("Async model admission aborted"));
      admissionSignal.addEventListener("abort", abort, { once: true });
      signal?.addEventListener("abort", abort, { once: true });
      void work.then(() => finish(), error => finish(error));
      if (admissionSignal.aborted || signal?.aborted) abort();
    });
  }
  private async waitForCompaction(session: AgentSession, admissionSignal: AbortSignal, signal?: AbortSignal): Promise<void> {
    if (admissionSignal.aborted || signal?.aborted) throw new Error("Async model admission aborted during compaction");
    if (!session.isCompacting) return;
    await new Promise<void>((resolve, reject) => {
      let finished = false;
      const finish = (error?: Error) => {
        if (finished) return;
        finished = true;
        unsubscribe();
        signal?.removeEventListener("abort", abort);
        admissionSignal.removeEventListener("abort", abort);
        if (error) reject(error); else resolve();
      };
      const abort = () => finish(new Error("Async model admission aborted during compaction"));
      const unsubscribe = session.subscribe(event => {
        if (event.type === "compaction_end") finish();
      });
      signal?.addEventListener("abort", abort, { once: true });
      admissionSignal.addEventListener("abort", abort, { once: true });
      if (signal?.aborted || admissionSignal.aborted) abort();
      else if (!session.isCompacting) finish();
    });
  }
  onEvent(event: { type: string; message?: unknown; messages?: unknown[] }): void {
    if (event.type === "compaction_start" || event.type === "compaction_end") { this.recordCompaction(event.type === "compaction_start"); return; }
    if (event.type === "message_end") { this.recordAssistantMessageEnd(event.message); return; }
    if (event.type !== "agent_end" || !this.cycle || this.settlingCycleId === this.cycle.cycleId) return;
    const cycle = this.cycle;
    this.settlingCycleId = cycle.cycleId;
    const deliveries = this.deliveries;
    const consumed = this.consumedDeliveries;
    const last = event.messages?.slice().reverse().find((message) => typeof message === "object" && message !== null && "role" in message && message.role === "assistant") as { stopReason?: string } | undefined;
    const outcome = last?.stopReason === "aborted" ? "cancelled" : last?.stopReason === "error" ? "failed" : "completed";
    const settledCycle: AgentCycle = { ...cycle, phase: "settled", outcome };
    this.enqueuePersistence(() => this.bridge.owner.transact((current) => ({ ...current, cycle: settledCycle, tickets: current.tickets.map((ticket) => ticket.cycleId === cycle.cycleId && ticket.state === "processing" ? { ...ticket, state: (outcome === "completed" || (ticket.deliveryId !== undefined && consumed.has(asyncIdentity(ticket, ticket.deliveryId)))) ? "handled" : "pending" } : ticket) })).then((state) => {
      if (this.cycle === cycle) { this.cycle = undefined; this.deliveries = []; this.requestDeliveries = []; this.consumedDeliveries = new Set(); this.settlingCycleId = undefined; }
      this.bridge.publish(state);
      this.emit({ type: "async_task_cycle", cycle: settledCycle, deliveries });
      for (const delivery of deliveries.filter((item) => outcome === "completed" || consumed.has(asyncIdentity(item, item.deliveryId)))) {
        const { taskIds: _taskIds, ...observed } = delivery;
        this.send({ ...observed, contract: ASYNC_TASK_CONTRACT, type: "completion-observed", requestId: randomUUID(), providerRevision: 0 });
      }
    }));
  }
  private recordAssistantMessageEnd(value: unknown): void {
    if (!this.cycle) return;
    const message = value as { role?: string; stopReason?: string } | undefined;
    if (message?.role !== "assistant") return;
    if (message.stopReason === "stop" || message.stopReason === "toolUse") {
      for (const delivery of this.requestDeliveries) this.consumedDeliveries.add(asyncIdentity(delivery, delivery.deliveryId));
    }
    this.requestDeliveries = [];
  }

  private recordCompaction(started: boolean): void {
    this.enqueuePersistence(() => this.bridge.owner.transact((current) => {
      if (!current.cycle) return current;
      const cycle: AgentCycle = {
        cycleId: current.cycle.cycleId, runtimeInstanceId: this.bridge.runtimeInstanceId,
        controlGeneration: this.bridge.generation, phase: started ? "compacting" : this.cycle ? "responding" : "idle",
      };
      return { ...current, cycle };
    }).then((state) => {
      this.bridge.publish(state);
      if (state.cycle) this.emit({ type: "async_task_cycle", cycle: state.cycle, deliveries: [] });
    }));
  }
  private enqueuePersistence(work: () => Promise<void>): void {
    this.pendingPersistence.push(work);
    this.settled = this.settled.then(() => this.flushPersistence());
    // Keep rejected admission until an explicit persistence-only retry succeeds.
    void this.settled.catch(() => undefined);
  }
  private async flushPersistence(): Promise<void> {
    while (this.pendingPersistence.length) {
      try { await this.pendingPersistence[0]!(); }
      catch (error) {
        this.emit({ type: "log", line: `Async task persistence blocked; retryPersistence required: ${error instanceof Error ? error.message : String(error)}` });
        throw error;
      }
      this.pendingPersistence.shift();
    }
  }
  private retryPersistence(): Promise<void> {
    if (this.recovery) return this.recovery;
    this.settled = this.settled.catch(() => undefined).then(() => this.flushPersistence());
    this.recovery = this.settled.finally(() => { this.recovery = undefined; });
    return this.recovery;
  }
  async drain(): Promise<void> { await this.settled; }
}
