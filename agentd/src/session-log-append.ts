import { extractChangedFilesFromExplicitText, extractSessionLinkArtifacts } from "./artifact-store.js";
import { mergeArtifacts } from "./domain/artifacts.js";
import { mergeChangedFiles } from "./domain/changed-files.js";
import { prefixedUserInputFromLogLine } from "./domain/log-prefixes.js";
import { piSessionFilePathFromLogLine } from "./domain/pi-session-files.js";
import type { PickyAgentSession } from "./protocol.js";

/// Derives the session that results from appending one log line: the line
/// itself plus any changed files, link artifacts, and Pi session file path it
/// discloses. Kept free of supervisor state so it stays directly testable.
export function sessionWithAppendedLog(
  session: PickyAgentSession,
  line: string,
  now = new Date().toISOString(),
): PickyAgentSession {
  const piSessionFilePath = piSessionFilePathFromLogLine(line);
  const userInput = prefixedUserInputFromLogLine(line);
  const requestText = userInput?.text.trim();
  const linkArtifacts = userInput
    ? extractSessionLinkArtifacts(userInput.text).filter((artifact) => !session.artifacts.some((existing) => existing.url === artifact.url))
    : [];
  return {
    ...session,
    logs: [...session.logs, line],
    changedFiles: mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(line)),
    artifacts: mergeArtifacts(session.artifacts, linkArtifacts),
    ...(piSessionFilePath ? { piSessionFilePath } : {}),
    ...(userInput && requestText ? { lastRequest: { source: userInput.source, text: requestText } } : {}),
    updatedAt: now,
  };
}
