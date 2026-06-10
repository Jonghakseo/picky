import type { RuntimeBashExecutionResult } from "../runtime/types.js";

export type UserBashInput = { command: string; excludeFromContext: boolean };

const LIVE_USER_BASH_OUTPUT_MAX_CHARS = 8000;

export function parseUserBashInput(text: string): UserBashInput | undefined {
  const trimmed = text.trim();
  if (!trimmed.startsWith("!")) return undefined;
  const excludeFromContext = trimmed.startsWith("!!");
  const command = (excludeFromContext ? trimmed.slice(2) : trimmed.slice(1)).trim();
  return command ? { command, excludeFromContext } : undefined;
}

export function formatUserBashSystemMessage(input: UserBashInput, result: RuntimeBashExecutionResult): string {
  const output = result.output.trimEnd() || "(no output)";
  const status = result.cancelled
    ? "⚠️ Cancelled"
    : result.exitCode && result.exitCode !== 0
      ? `❌ Failed · exit ${result.exitCode}`
      : "✅ Completed · exit 0";
  const contextVisibility = input.excludeFromContext ? "hidden from Pi context" : "added to Pi context";
  const truncated = result.truncated ? `\n\n⚠️ Output truncated${result.fullOutputPath ? `; full output: ${result.fullOutputPath}` : ""}.` : "";
  return formatUserBashMessage(input.command, `${status} · ${contextVisibility}`, output, truncated);
}

export function formatUserBashRunningSystemMessage(input: UserBashInput, output: string, elapsedMs: number): string {
  const contextVisibility = input.excludeFromContext ? "hidden from Pi context" : "will be added to Pi context";
  const elapsed = Math.max(0, Math.floor(elapsedMs / 1000));
  const preview = output.trimEnd() || "(waiting for output…)";
  return formatUserBashMessage(input.command, `⏳ Running · ${elapsed}s elapsed · ${contextVisibility}`, preview);
}

export function formatUserBashFailureSystemMessage(input: UserBashInput, errorMessage: string, output: string): string {
  const contextVisibility = input.excludeFromContext ? "hidden from Pi context" : "would be added to Pi context";
  const preview = output.trimEnd() || "(no output before failure)";
  return formatUserBashMessage(input.command, `❌ Failed · ${contextVisibility}`, `${preview}\n\nError: ${errorMessage}`);
}

function formatUserBashMessage(command: string, statusLine: string, output: string, suffix = ""): string {
  return `### 🖥️ ${command}\n\n${statusLine}\n\n\`\`\`console\n${output}\n\`\`\`${suffix}`;
}

export function appendLiveBashOutput(current: string, chunk: string): string {
  if (!chunk) return current;
  const next = current + chunk;
  return next.length > LIVE_USER_BASH_OUTPUT_MAX_CHARS ? next.slice(-LIVE_USER_BASH_OUTPUT_MAX_CHARS) : next;
}

export function userBashSummary(command: string, result: RuntimeBashExecutionResult): string {
  if (result.cancelled) return `Bash cancelled: ${command}`;
  if (result.exitCode && result.exitCode !== 0) return `Bash exited ${result.exitCode}: ${command}`;
  return `Bash finished: ${command}`;
}
