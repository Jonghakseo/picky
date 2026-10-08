/**
 * A Task worker does its own work: it must not start or steer other agents through the `picky`
 * CLI (docs/picky-task-routing-plan.md section 8). Workers carry `PICKY_TASK_WORKER=1`; this is a
 * guard against accidental delegation, not a sandbox, since the worker could unset its environment.
 */
export const TASK_WORKER_ENV_MARKER = "PICKY_TASK_WORKER";

const READ_ONLY_COMMANDS: ReadonlySet<string> = new Set([
  "whoami",
  "pickle-list",
  "pickle-group-list",
  "settings-list",
  "settings-get",
]);

export function taskWorkerCliRefusal(commandName: string, env: Readonly<Record<string, string | undefined>>): string | undefined {
  if (env[TASK_WORKER_ENV_MARKER] !== "1" || READ_ONLY_COMMANDS.has(commandName)) return undefined;
  return `\`picky ${commandName}\` is not available inside a Picky Task. Do the work yourself, or report status blocked with what you need.`;
}
