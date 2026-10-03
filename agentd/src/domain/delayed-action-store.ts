import { homedir } from "node:os";
import { join } from "node:path";
import type { PickyScheduledMessage } from "../protocol.js";

/**
 * Read model for the `@ryan_nookpi/pi-extension-delayed-action` store. The extension owns
 * the schedule (timers, firing, rehydrate-on-resume); Picky only mirrors the file so the
 * HUD can list and manage pending timed messages. Keep these helpers byte-compatible with
 * the extension's `storage.ts`: a drift here silently projects an empty schedule.
 */

export const DELAYED_ACTION_DIR_ENV = "PI_DELAYED_ACTION_DIR";

/** Mirrors the extension's `sanitizeSessionId`. Returns undefined where it would throw. */
export function sanitizeDelayedActionSessionId(sessionId: string): string | undefined {
  const safe = sessionId.replace(/[^a-zA-Z0-9._-]/g, "-").replace(/^\.+/, "");
  return safe.length > 0 ? safe : undefined;
}

export function delayedActionStoreDir(env: NodeJS.ProcessEnv = process.env): string {
  return env[DELAYED_ACTION_DIR_ENV] || join(homedir(), ".pi", "delayed-action");
}

export function delayedActionStoreFileName(sessionId: string): string | undefined {
  const safe = sanitizeDelayedActionSessionId(sessionId);
  return safe === undefined ? undefined : `${safe}.json`;
}

export function delayedActionStorePath(sessionId: string, dir: string): string | undefined {
  const fileName = delayedActionStoreFileName(sessionId);
  return fileName === undefined ? undefined : join(dir, fileName);
}

interface PersistedDelayedActionTask {
  id: string;
  prompt: string;
  createdAt: number;
  dueAt: number;
}

function isPersistedTask(value: unknown): value is PersistedDelayedActionTask {
  if (!value || typeof value !== "object") return false;
  const task = value as Record<string, unknown>;
  return typeof task.id === "string" && task.id.length > 0
    && typeof task.prompt === "string"
    && typeof task.createdAt === "number" && Number.isFinite(task.createdAt)
    && typeof task.dueAt === "number" && Number.isFinite(task.dueAt);
}

/**
 * Parse one store file into the projected schedule, earliest first. A missing, truncated,
 * or half-written file projects an empty schedule instead of throwing: the extension writes
 * atomically through a temp file, so a bad read is transient.
 */
export function parseDelayedActionStore(raw: string): PickyScheduledMessage[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  const tasks = (parsed as { tasks?: unknown } | null)?.tasks;
  if (!Array.isArray(tasks)) return [];
  return tasks
    .filter(isPersistedTask)
    .map((task) => ({
      id: task.id,
      text: task.prompt,
      dueAt: new Date(task.dueAt).toISOString(),
      createdAt: new Date(task.createdAt).toISOString(),
    }))
    .sort((left, right) => (left.dueAt === right.dueAt ? left.id.localeCompare(right.id) : left.dueAt.localeCompare(right.dueAt)));
}

export function sameScheduledMessages(
  left: readonly PickyScheduledMessage[],
  right: readonly PickyScheduledMessage[],
): boolean {
  return left.length === right.length && left.every((message, index) => (
    message.id === right[index]?.id
    && message.text === right[index]?.text
    && message.dueAt === right[index]?.dueAt
    && message.createdAt === right[index]?.createdAt
  ));
}

/**
 * Duration argument the extension's `/delay` parser accepts. Seconds keep the command
 * lossless for the sub-minute delays Picky uses when re-scheduling an edited message.
 */
export function delayedActionDurationArgument(delayMs: number): string {
  return `${Math.max(1, Math.round(delayMs / 1000))}s`;
}
