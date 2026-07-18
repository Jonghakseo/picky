import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { readPiTerminalSessionMessages } from "./pi-session-syncer.js";
import { isPickyHandoffCommandMessage, lastTurns, PINNED_SOURCE_TURN_COUNT } from "../domain/pickle-handoff-context.js";
import type { PickyAgentSession, PickySessionMessage } from "../protocol.js";

export async function readRecentPinnedSourceState(
  sessionFilePath: string | undefined,
): Promise<{ messages: PickySessionMessage[]; todoState?: PickyAgentSession["todoState"] } | undefined> {
  if (!sessionFilePath) return undefined;
  try {
    const result = await readPiTerminalSessionMessages(sessionFilePath);
    const conversationMessages = result.messages.filter((message) => !isPickyHandoffCommandMessage(message));
    return {
      messages: lastTurns(conversationMessages, PINNED_SOURCE_TURN_COUNT),
      ...(result.todoState ? { todoState: result.todoState } : {}),
    };
  } catch {
    return undefined;
  }
}

/**
 * Copy a stable JSONL snapshot to a sibling file for a duplicated/resumed session.
 * A trailing partial record is dropped so the fork never starts with malformed JSON.
 */
export async function snapshotPiSessionFile(sourcePath: string, newSessionId: string): Promise<string> {
  const data = await readFile(sourcePath);
  const lastNewline = data.lastIndexOf(0x0a /* \n */);
  const trimmed = lastNewline >= 0 ? data.subarray(0, lastNewline + 1) : data;
  const directory = dirname(sourcePath);
  await mkdir(directory, { recursive: true });
  const extension = extname(sourcePath) || ".jsonl";
  const destinationPath = join(directory, `${newSessionId}${extension}`);
  await writeFile(destinationPath, trimmed);
  return destinationPath;
}
