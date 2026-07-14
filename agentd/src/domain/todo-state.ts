import type { PickyTodoState, PickyTodoTask } from "../protocol.js";

export const TODO_WRITE_STATE_ENTRY_TYPE = "todo-write-overlay-state";

export interface PickyTodoStateResolution {
  resolved: boolean;
  todoState?: PickyTodoState;
}

export function todoStateFromPiSessionEntry(entry: unknown): PickyTodoState | undefined {
  const record = asRecord(entry);
  if (!isTodoStateEntry(record)) return undefined;
  const data = asRecord(record.data);
  const tasks = parseTodoTasks(data.tasks);
  const updatedAt = isoTimestamp(data.updatedAt);
  return tasks && updatedAt ? { tasks, updatedAt } : undefined;
}

export function resolveTodoStateFromPiSessionEntries(entries: readonly unknown[]): PickyTodoStateResolution {
  const latestTodoEntry = [...entries].reverse().map(asRecord).find(isTodoStateEntry);
  if (!latestTodoEntry) return { resolved: true };
  const todoState = todoStateFromPiSessionEntry(latestTodoEntry);
  return todoState ? { resolved: true, todoState } : { resolved: false };
}

function isTodoStateEntry(record: Record<string, unknown>): boolean {
  return record.type === "custom" && record.customType === TODO_WRITE_STATE_ENTRY_TYPE;
}

function parseTodoTasks(value: unknown): PickyTodoTask[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const tasks: PickyTodoTask[] = [];
  for (const rawTask of value) {
    const task = asRecord(rawTask);
    if (typeof task.id !== "string" || typeof task.content !== "string") return undefined;
    const status = todoStatus(task.status);
    if (!status) return undefined;
    if (task.activeForm !== undefined && typeof task.activeForm !== "string") return undefined;
    if (task.notes !== undefined && typeof task.notes !== "string") return undefined;
    tasks.push({
      id: task.id,
      content: task.content,
      status,
      ...(typeof task.activeForm === "string" ? { activeForm: task.activeForm } : {}),
      ...(typeof task.notes === "string" ? { notes: task.notes } : {}),
    });
  }
  return tasks;
}

function todoStatus(value: unknown): PickyTodoTask["status"] | undefined {
  if (value === "pending" || value === "in_progress" || value === "completed") return value;
  if (value === "abandoned") return "completed";
  return undefined;
}

function isoTimestamp(value: unknown): string | undefined {
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
