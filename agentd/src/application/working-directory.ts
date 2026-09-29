import { stat } from "node:fs/promises";
import { isAbsolute } from "node:path";

/**
 * Returns a user-facing reason when `path` cannot be used as a session working
 * directory, or `undefined` when it is an existing folder. Callers check this
 * before creating a session so a bad `--cwd` never leaves a failed Pickle behind.
 */
export async function workingDirectoryProblem(path: string): Promise<string | undefined> {
  if (!isAbsolute(path)) return `Working directory must be an absolute path: ${path}`;
  try {
    if ((await stat(path)).isDirectory()) return undefined;
  } catch {
    // Missing or unreadable paths share the message below.
  }
  return `Working directory does not exist or is not a folder: ${path}`;
}
