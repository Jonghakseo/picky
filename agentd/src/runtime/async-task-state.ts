import { createHash, randomUUID } from "node:crypto";
import { AsyncTaskDetailSchema, type AsyncTaskHostMessage, type AsyncTaskOwner } from "../domain/async-task-contract.js";
import type { RuntimeAsyncTaskState } from "./async-task-types.js";

export function sameAsyncOwner(a: AsyncTaskOwner, b: AsyncTaskOwner): boolean {
  return a.sessionId === b.sessionId && a.piSessionId === b.piSessionId && a.runtimeInstanceId === b.runtimeInstanceId && a.providerId === b.providerId && a.providerInstanceId === b.providerInstanceId;
}
export function asyncIdentity(owner: AsyncTaskOwner, id: string): string {
  return createHash("sha256").update(JSON.stringify([owner.sessionId, owner.piSessionId, owner.runtimeInstanceId, owner.providerId, owner.providerInstanceId, id])).digest("hex");
}
export type RegistrationRequest = Extract<AsyncTaskHostMessage, { type: "task-register" | "registration-query" | "registration-abandon" }>;
export function registrationTaskId(message: RegistrationRequest): string {
  return message.type === "task-register" ? message.task.taskId : message.taskId;
}
export function registrationState(state: RuntimeAsyncTaskState, message: RegistrationRequest): { registration: "approved" | "starting" | "spawned" | "reserved" | "abandoned"; grantId?: string } {
  const taskId = registrationTaskId(message);
  const task = state.tasks.find((task) => task.taskId === taskId && sameAsyncOwner(task, message));
  if (task) return { registration: task.registration, ...(task.grantId ? { grantId: task.grantId } : {}) };
  const abandoned = state.control?.operations.some((op) => op.operationId === `abandon-${asyncIdentity(message, taskId)}`);
  return { registration: abandoned ? "abandoned" : "reserved" };
}
export function registerAsyncTask(state: RuntimeAsyncTaskState, message: RegistrationRequest): RuntimeAsyncTaskState {
  const prior = registrationState(state, message);
  if (message.type === "registration-query" || prior.registration === "abandoned") return state;
  const taskId = registrationTaskId(message);
  if (message.type === "registration-abandon") {
    // Never accept a claimed neverSpawned after the provider reported a live resource.
    if (prior.registration === "spawned" || prior.registration === "starting") return state;
    const control = state.control ?? { controlGeneration: 0, admissionState: "open" as const, operations: [] };
    return { ...state, tasks: state.tasks.map((task) => task.taskId === taskId && sameAsyncOwner(task, message) ? { ...task, registration: "abandoned", execution: "cancelled", presence: "settled" } : task), control: { ...control, operations: [...control.operations, { requestId: message.requestId, operationId: `abandon-${asyncIdentity(message, taskId)}`, outcome: "settled", controlGeneration: control.controlGeneration }] } };
  }
  if (prior.registration !== "reserved" || state.tasks.some((task) => task.taskId === taskId && sameAsyncOwner(task, message))) return state;
  if (state.control?.admissionState !== "open" || message.controlGeneration !== state.control.controlGeneration) return state;
  if (message.task.controlGeneration !== message.controlGeneration || message.task.providerRevision > message.providerRevision) return state;
  if (message.task.registration !== "reserved" || message.task.execution !== "queued" || message.task.presence !== "settled") return state;
  const task = { ...message.task, registration: "approved" as const, grantId: randomUUID(), presence: "unknown" as const };
  const tasks = [...state.tasks, task];
  AsyncTaskDetailSchema.parse({ tasks, tickets: state.tickets });
  return { ...state, tasks };
}

/** A replay can add provider evidence, never undo host consumption or remove obligations. */
export function mergeAsyncDetail(state: RuntimeAsyncTaskState, message: Extract<AsyncTaskHostMessage, { type: "task-update" | "snapshot" }>): RuntimeAsyncTaskState {
  const tasks = state.tasks.map((task) => message.type === "snapshot" && sameAsyncOwner(task, message) && task.presence !== "settled" && !message.detail.tasks.some((incoming) => incoming.taskId === task.taskId) ? { ...task, presence: "unknown" as const } : task);
  for (const incoming of message.detail.tasks) {
    const index = tasks.findIndex((task) => task.taskId === incoming.taskId && sameAsyncOwner(task, incoming));
    if (index < 0) throw new Error("Unregistered async task in provider detail");
    const current = tasks[index]!;
    if (incoming.providerRevision <= current.providerRevision || current.registration === "abandoned") continue;
    if (incoming.grantId !== current.grantId || incoming.controlGeneration !== current.controlGeneration) throw new Error("Async task grant mismatch");
    const terminal = ["succeeded", "failed", "cancelled", "interrupted"].includes(current.execution);
    tasks[index] = { ...incoming, ...(terminal ? { execution: current.execution } : {}), ...(terminal && current.presence === "settled" ? { presence: "settled" } : {}), ...(current.registration === "spawned" ? { registration: "spawned" } : {}) };
  }
  const tickets = mergeAsyncTickets(state, tasks, message);
  AsyncTaskDetailSchema.parse({ tasks, tickets });
  return { ...state, tasks, tickets };
}

function mergeAsyncTickets(state: RuntimeAsyncTaskState, tasks: RuntimeAsyncTaskState["tasks"], message: Extract<AsyncTaskHostMessage, { type: "task-update" | "snapshot" }>): RuntimeAsyncTaskState["tickets"] {
  const tickets = [...state.tickets];
  for (const incoming of message.detail.tickets) {
    const root = tasks.find((task) => task.taskId === incoming.rootTaskId && sameAsyncOwner(task, incoming));
    if (!root || root.controlGeneration !== incoming.controlGeneration) throw new Error("Completion root generation mismatch");
    if (["observed", "processing", "handled"].includes(incoming.state)) throw new Error("Provider cannot assert host consumption");
    const index = tickets.findIndex((ticket) => ticket.completionId === incoming.completionId && sameAsyncOwner(ticket, incoming));
    if (index < 0) tickets.push(incoming);
    else if (!["observed", "processing", "handled", "suppressed"].includes(tickets[index]!.state) && !(tickets[index]!.state === "submitted" && incoming.state === "pending")) tickets[index] = incoming;
  }
  return tickets;
}
