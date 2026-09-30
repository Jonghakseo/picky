import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { asRecord, stringValue } from "./pi-sdk-runtime-helpers.js";
import type { RuntimeEvent } from "./types.js";

export function writeFilePathFromRawArgs(args: unknown, cwd: string): string | undefined {
  const rawArgs = asRecord(args);
  const rawPath = stringValue(rawArgs.path)
    ?? stringValue(rawArgs.file_path)
    ?? stringValue(rawArgs.filePath)
    ?? stringValue(rawArgs.file);
  if (!rawPath || rawPath.includes("\0")) return undefined;
  const expanded = rawPath === "~" || rawPath.startsWith("~/")
    ? `${homedir()}${rawPath.slice(1)}`
    : rawPath;
  return resolve(isAbsolute(expanded) ? expanded : cwd, expanded);
}

export interface WriteFileMetadata {
  filePath: string;
  fileExistedBefore: boolean;
}

/**
 * Remembers, per `write` tool call, which file it targets and whether that file existed when the
 * call started, so the finished call can report a created or modified file.
 */
export class WriteFileMetadataTracker {
  private readonly byToolCallId = new Map<string, WriteFileMetadata>();

  forToolEvent(event: Record<string, unknown>, runtimeEvent: Extract<RuntimeEvent, { type: "tool" }>, cwd: string): WriteFileMetadata | undefined {
    if (runtimeEvent.name !== "write") return undefined;
    if (runtimeEvent.status === "running") {
      const existing = this.byToolCallId.get(runtimeEvent.toolCallId);
      if (event.type !== "tool_execution_start") return existing;
      const filePath = writeFilePathFromRawArgs(event.args, cwd);
      if (!filePath) return undefined;
      const metadata = { filePath, fileExistedBefore: existsSync(filePath) };
      this.byToolCallId.set(runtimeEvent.toolCallId, metadata);
      return metadata;
    }
    const metadata = this.byToolCallId.get(runtimeEvent.toolCallId);
    this.byToolCallId.delete(runtimeEvent.toolCallId);
    return metadata;
  }
}
