import { randomUUID } from "node:crypto";
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
  const snapshot = rewritePiSessionHeaderId(trimmed);
  const directory = dirname(sourcePath);
  await mkdir(directory, { recursive: true });
  const extension = extname(sourcePath) || ".jsonl";
  const destinationPath = join(directory, `${newSessionId}${extension}`);
  await writeFile(destinationPath, snapshot);
  return destinationPath;
}

/**
 * Pi derives a resumed session's ownership from its JSONL `session` header, not
 * from its filename. Give forked snapshots a new UUID without touching their
 * branch entries, which intentionally retain the original session's history.
 *
 * Old or non-Pi JSONL fixtures may not have a session header. Leave those
 * byte-for-byte intact rather than deriving an invalid Pi ID from Picky's
 * opaque session ID.
 */
function rewritePiSessionHeaderId(data: Buffer): Buffer {
  const text = data.toString("utf8");
  const lines = text.split(/(?<=\n)/u);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    const body = line.endsWith("\n") ? line.slice(0, -1) : line;
    try {
      const entry = JSON.parse(body) as unknown;
      if (!isPiSessionHeader(entry)) continue;
      lines[index] = `${JSON.stringify({ ...entry, id: randomUUID() })}${line.endsWith("\n") ? "\n" : ""}`;
      return Buffer.from(lines.join(""), "utf8");
    } catch {
      // A malformed trailing record was already removed above. Other lines are
      // Pi extension payloads or legacy content and must remain untouched.
    }
  }
  return data;
}

function isPiSessionHeader(entry: unknown): entry is Record<string, unknown> {
  return typeof entry === "object" && entry !== null
    && (entry as Record<string, unknown>).type === "session"
    && typeof (entry as Record<string, unknown>).id === "string";
}
