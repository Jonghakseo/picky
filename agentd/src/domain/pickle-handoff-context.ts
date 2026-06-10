import type { PickyContextPacket, PickySessionMessage } from "../protocol.js";
import { normalizeOptionalString } from "./strings.js";

export const PINNED_SOURCE_TURN_COUNT = 2;

export function lastTurns(messages: PickySessionMessage[], turnCount: number): PickySessionMessage[] {
  if (messages.length === 0) return [];
  const userIndices = messages.flatMap((message, index) => message.kind === "user_text" ? [index] : []);
  if (userIndices.length === 0) return messages;
  const startIndex = userIndices[Math.max(0, userIndices.length - turnCount)];
  return messages.slice(startIndex);
}

export function isPickyHandoffCommandMessage(message: PickySessionMessage): boolean {
  return message.kind === "user_text" && /^\s*\/handoff-to-picky(\s|$)/.test(message.text ?? "");
}

export function buildPinnedPickleSessionLogs(context: PickyContextPacket): string[] {
  const logs = ["pi-extension handoff pin: completed idle Pi session", `source context id: ${context.id}`];
  if (context.cwd) logs.push(`source cwd: ${context.cwd}`);
  const sessionFile = piSessionFilePathFromHandoffTranscript(context.transcript);
  if (sessionFile) logs.push(`pi session: ${sessionFile}`);
  if (context.transcript?.trim()) logs.push(`source transcript:\n${context.transcript.trim()}`);
  return logs;
}

export function piSessionFilePathFromHandoffTranscript(transcript: string | undefined): string | undefined {
  if (!transcript) return undefined;
  for (const line of transcript.split(/\r?\n/)) {
    const match = line.match(/^\s*-\s*Session file:\s*(.+)$/);
    const path = match?.[1]?.trim();
    if (path && !path.startsWith("(") && path !== "ephemeral" && path !== "unavailable") return path;
  }
  return undefined;
}

export function titleForEmptyPickleSession(context: PickyContextPacket): string {
  const cwd = normalizeOptionalString(context.cwd);
  if (!cwd) return "New Pickle";
  const basename = cwd.split(/[\\/]/).filter(Boolean).at(-1);
  return basename ? `New Pickle · ${basename}` : "New Pickle";
}
