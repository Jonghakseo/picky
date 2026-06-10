import type { PickyAgentSession } from "../protocol.js";
import { HANDOFF_PREFIX } from "./log-prefixes.js";
import { normalizeOptionalString } from "./strings.js";

export function piSessionFilePathForSession(session: PickyAgentSession): string | undefined {
  return normalizeOptionalString(session.piSessionFilePath) ?? piSessionFilePathFromLogs(session.logs);
}

export function withPiSessionFileFromLogs(session: PickyAgentSession): PickyAgentSession {
  if (normalizeOptionalString(session.piSessionFilePath)) return session;
  const piSessionFilePath = piSessionFilePathFromLogs(session.logs);
  return piSessionFilePath ? { ...session, piSessionFilePath } : session;
}

export function piSessionFilePathFromLogs(logs: string[]): string | undefined {
  for (const line of [...logs].reverse()) {
    const path = piSessionFilePathFromLogLine(line);
    if (path) return path;
  }
  return undefined;
}

export function piSessionFilePathFromLogLine(line: string): string | undefined {
  const match = line.match(/^pi session:\s*(.+)$/)
    ?? line.match(/^runtime reattached from pi session:\s*(.+)$/)
    ?? line.match(/^\s*-\s*Session file:\s*(.+)$/);
  const path = normalizeOptionalString(match?.[1]);
  if (path && !path.startsWith("(") && path !== "ephemeral" && path !== "unavailable") return path;
  return undefined;
}

export function appendUniqueLog(logs: string[], line: string): string[] {
  return logs.includes(line) ? logs : [...logs, line];
}

export function hasPickleSessionMarkerLog(session: PickyAgentSession): boolean {
  return session.logs.some(
    (line) => line.startsWith(HANDOFF_PREFIX.trimEnd())
      || line.startsWith("Picky handoff cwd:")
      || line.startsWith("pi-extension handoff pin:")
      || line.startsWith("manual pickle:")
      || line.startsWith("manual pickle cwd:"),
  );
}
