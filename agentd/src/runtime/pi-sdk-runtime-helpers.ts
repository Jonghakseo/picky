import { accessSync, constants as fsConstants } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join } from "node:path";
import type { AgentSession } from "@earendil-works/pi-coding-agent";
import type { RewindBranchMessage, RuntimeBashExecutionResult, RuntimeEvent } from "./types.js";
import type { PiUserBashEvent } from "./pi-capabilities.js";

// Pure helpers extracted from pi-sdk-runtime.ts to keep that file focused on the
// runtime/session classes. These are stateless (aside from the cached fd path)
// transcript/message/bash normalization utilities used by PiSdkRuntimeSession.

let cachedAutocompleteFdPath: string | null | undefined;

export function resolveAutocompleteFdPath(): string | null {
  if (cachedAutocompleteFdPath !== undefined) return cachedAutocompleteFdPath;
  const candidates = [
    process.env.PICKY_FD_PATH,
    join(homedir(), ".pi", "agent", "bin", "fd"),
    "/opt/homebrew/bin/fd",
    "/usr/local/bin/fd",
    "/usr/bin/fd",
  ].filter((candidate): candidate is string => Boolean(candidate));
  cachedAutocompleteFdPath = candidates.find((candidate) => {
    try {
      accessSync(candidate, fsConstants.X_OK);
      return true;
    } catch {
      return false;
    }
  }) ?? null;
  return cachedAutocompleteFdPath;
}

export function queueKindFromStreamingBehavior(streamingBehavior?: "steer" | "followUp"): "steering" | "followUp" | undefined {
  if (streamingBehavior === "steer") return "steering";
  if (streamingBehavior === "followUp") return "followUp";
  return undefined;
}

export async function imageOptions(imagePaths: string[] | undefined): Promise<Array<{ type: "image"; data: string; mimeType: string }> | undefined> {
  if (!imagePaths || imagePaths.length === 0) return undefined;
  return Promise.all(
    imagePaths.map(async (imagePath) => ({
      type: "image" as const,
      mimeType: mediaTypeFromPath(imagePath),
      data: await readFile(imagePath, "base64"),
    })),
  );
}

function mediaTypeFromPath(path: string): string {
  const extension = extname(path).toLowerCase();
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".webp") return "image/webp";
  return "image/png";
}

export async function emitUserBash(bash: { emitUserBash?: (event: PiUserBashEvent) => Promise<{ result?: unknown; operations?: unknown } | undefined> }, event: PiUserBashEvent): Promise<{ result?: RuntimeBashExecutionResult; operations?: unknown } | undefined> {
  if (typeof bash.emitUserBash !== "function") return undefined;
  const result = await bash.emitUserBash(event);
  if (!result) return undefined;
  const normalized = normalizeBashExecutionResult(result.result);
  return {
    ...(normalized ? { result: normalized } : {}),
    ...(result.operations ? { operations: result.operations } : {}),
  };
}

export function normalizeBashExecutionResult(value: unknown): RuntimeBashExecutionResult | undefined {
  const record = asRecord(value);
  if (!record || typeof record.output !== "string") return undefined;
  return {
    output: record.output,
    exitCode: typeof record.exitCode === "number" ? record.exitCode : undefined,
    cancelled: record.cancelled === true,
    truncated: record.truncated === true,
    ...(typeof record.fullOutputPath === "string" ? { fullOutputPath: record.fullOutputPath } : {}),
  };
}

export function bashResultPreview(result: RuntimeBashExecutionResult): string {
  const prefix = result.cancelled ? "cancelled" : result.exitCode && result.exitCode !== 0 ? `exit ${result.exitCode}` : "ok";
  const output = result.output.trim();
  return output ? `${prefix}: ${sliceUtf16(output, 500)}` : prefix;
}

export function sliceUtf16(value: string, maxChars: number): string {
  if (value.length <= maxChars) return value;
  return `${value.slice(0, Math.max(0, maxChars - 1))}…`;
}

export function shouldEmitContextUsageSnapshotAfterPiEvent(event: unknown, runtimeEvent: RuntimeEvent | undefined): boolean {
  if (runtimeEvent?.type === "status" && ["completed", "failed", "cancelled", "waiting_for_input"].includes(runtimeEvent.status)) return true;

  const record = asRecord(event);
  if (record.type !== "message_end") return false;
  const role = stringValue(asRecord(record.message).role);
  return role === "assistant" || role === "toolResult" || role === "custom" || role === "bashExecution";
}

export function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

/**
 * Map raw Pi session entries (as returned by SessionManager.getBranch(), already root->leaf order)
 * to the rewind transcript, preserving order. Only user/assistant message entries with non-empty
 * text are kept. Exported so a test can assert ordering against a real SessionManager branch and
 * guard against an accidental reverse.
 */
export function branchTranscriptFromEntries(entries: readonly unknown[]): RewindBranchMessage[] {
  return entries.flatMap((entry): RewindBranchMessage[] => {
    const record = asRecord(entry);
    if (record.type !== "message") return [];
    const message = asRecord(record.message);
    const role = stringValue(message.role);
    if (role !== "user" && role !== "assistant") return [];
    const text = textFromPiMessageContent(message.content).trim();
    return text.length > 0 ? [{ role, text }] : [];
  });
}

export function textFromPiMessageContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) {
    if (content === undefined || content === null) return "";
    return typeof content === "object" ? JSON.stringify(content) : String(content);
  }
  return content
    .map((block) => {
      const record = asRecord(block);
      if (record.type === "text" && typeof record.text === "string") return record.text;
      return "";
    })
    .join("");
}

export function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

export function numberValue(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

export function lastAssistantStopReason(messages: unknown): string | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = asRecord(messages[index]);
    if (message.role === "assistant") return stringValue(message.stopReason);
  }
  return undefined;
}

export function isAbortedTerminalPiEvent(record: Record<string, unknown>): boolean {
  if (record.type === "turn_end") return stringValue(asRecord(record.message).stopReason) === "aborted";
  if (record.type === "agent_end") return lastAssistantStopReason(record.messages) === "aborted";
  return false;
}

export function repairDanglingToolCalls(session: AgentSession): string | undefined {
  const messages = (session.state.messages ?? []) as unknown[];
  const repair = repairDanglingToolCallsInMessages(messages);
  if (repair.count === 0) return undefined;
  const names = [...new Set(repair.toolNames)].join(", ");
  return `pi transcript repaired: skipped ${repair.count} interrupted tool call(s)${names ? ` (${names})` : ""} from a previous runtime`;
}

function repairDanglingToolCallsInMessages(messages: unknown[]): { count: number; toolNames: string[] } {
  let pending: { message: Record<string, unknown>; calls: Array<{ id: string; name: string }>; matchedIds: Set<string> } | undefined;
  let count = 0;
  const toolNames: string[] = [];

  const repairPending = () => {
    if (!pending) return;
    const missing = pending.calls.filter((call) => !pending!.matchedIds.has(call.id));
    if (missing.length === 0) return;
    repairAssistantMessageWithDanglingToolCalls(pending.message, pending.matchedIds, missing);
    count += missing.length;
    toolNames.push(...missing.map((call) => call.name));
  };

  for (const value of messages) {
    const message = asRecord(value);
    if (pending) {
      const toolCallId = message.role === "toolResult" ? stringValue(message.toolCallId) : undefined;
      if (toolCallId && pending.calls.some((call) => call.id === toolCallId)) {
        pending.matchedIds.add(toolCallId);
        if (pending.calls.every((call) => pending!.matchedIds.has(call.id))) pending = undefined;
        continue;
      }
      repairPending();
      pending = undefined;
    }

    if (message.role !== "assistant") continue;
    const calls = toolCallsFromContent(message.content);
    if (calls.length > 0) pending = { message, calls, matchedIds: new Set() };
  }

  if (pending) repairPending();
  return { count, toolNames };
}

function repairAssistantMessageWithDanglingToolCalls(message: Record<string, unknown>, matchedIds: Set<string>, missing: Array<{ id: string; name: string }>): void {
  const content = Array.isArray(message.content) ? message.content : [];
  const textBlocks = content.filter((block) => asRecord(block).type === "text");
  const matchedToolCallBlocks = content.filter((block) => {
    const record = asRecord(block);
    return record.type === "toolCall" && typeof record.id === "string" && matchedIds.has(record.id);
  });
  const names = [...new Set(missing.map((call) => call.name))].join(", ") || "tool";
  const note = {
    type: "text",
    text: `[Picky note: previous ${names} tool call${missing.length === 1 ? "" : "s"} did not finish because the local Picky runtime restarted. Continue from the current filesystem state and rerun any needed checks.]`,
  };
  message.content = [...textBlocks, note, ...matchedToolCallBlocks];
  if (matchedToolCallBlocks.length === 0 && message.stopReason === "toolUse") message.stopReason = "end_turn";
}

function toolCallsFromContent(content: unknown): Array<{ id: string; name: string }> {
  if (!Array.isArray(content)) return [];
  return content.flatMap((block) => {
    const record = asRecord(block);
    const id = stringValue(record.id);
    if (record.type !== "toolCall" || !id) return [];
    return [{ id, name: stringValue(record.name) ?? "tool" }];
  });
}

export function normalizeAnswer(value: unknown): { value?: unknown; confirmed?: boolean; cancelled?: boolean } {
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if ("value" in record || "confirmed" in record || "cancelled" in record) {
      return record as { value?: unknown; confirmed?: boolean; cancelled?: boolean };
    }
  }
  return { value };
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
