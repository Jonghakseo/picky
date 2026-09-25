import type { AgentCycle, AsyncCompletionDelivery, AsyncControlState, AsyncTaskDetail, AsyncTaskHostMessage, AsyncTaskOwner } from "../domain/async-task-contract.js";

/** Durable state owned by SessionSupervisor, never by an extension event listener. */
export interface RuntimeAsyncTaskState extends AsyncTaskDetail {
  control?: AsyncControlState;
  cycle?: AgentCycle;
}
export interface RuntimeAsyncTaskOwner {
  /** The callback is synchronous and runs inside the existing session write serializer. */
  transact(build: (current: RuntimeAsyncTaskState) => RuntimeAsyncTaskState): Promise<RuntimeAsyncTaskState>;
  read(): RuntimeAsyncTaskState;
}
export interface RuntimeAsyncTaskCoverage {
  runtimeInstanceId: string;
  tracking: "ready" | "reconciling" | "unsupported";
  expectedProviders: string[];
  readyProviders: string[];
}
export type RuntimeAsyncTaskEvent =
  | { type: "async_task_state"; state: RuntimeAsyncTaskState }
  | { type: "async_task_coverage"; coverage: RuntimeAsyncTaskCoverage }
  | { type: "async_task_cycle"; cycle: AgentCycle; deliveries: AsyncCompletionDelivery[] };
export interface RuntimeAsyncTaskControl {
  coverage(): RuntimeAsyncTaskCoverage;
  snapshot(): RuntimeAsyncTaskState;
  control(owner: AsyncTaskOwner, action: Extract<AsyncTaskHostMessage, { type: "control-request" }>["action"], options?: { taskId?: string; deliveryIds?: string[] }): Promise<Extract<AsyncTaskHostMessage, { type: "control-result" }>>;
  /** Closes the local model fence synchronously, then persists the new generation. */
  closeAdmission(): Promise<RuntimeAsyncTaskState>;
  /** New user input must be explicitly authorized after a stop; old tickets stay fenced. */
  reopenAdmission(): Promise<RuntimeAsyncTaskState>;
}
