import { asRecord, stringValue } from "./pi-sdk-runtime-helpers.js";
import type { RuntimeEvent } from "./types.js";
import { writeFilePathFromRawArgs } from "./write-file-path.js";

export interface ReadImageMetadata {
  imagePath: string;
  imageMimeType?: string;
}

/**
 * Remembers the target path of each `read` call so that, when Pi returns the file as an image
 * content block, the finished tool event can point the HUD at the image on disk.
 */
export class ReadImageTracker {
  private readonly pathByToolCallId = new Map<string, string>();

  forToolEvent(event: Record<string, unknown>, runtimeEvent: Extract<RuntimeEvent, { type: "tool" }>, cwd: string): ReadImageMetadata | undefined {
    if (runtimeEvent.name !== "read") return undefined;
    if (runtimeEvent.status === "running") {
      if (event.type !== "tool_execution_start") return undefined;
      const path = writeFilePathFromRawArgs(event.args, cwd);
      if (path) this.pathByToolCallId.set(runtimeEvent.toolCallId, path);
      return undefined;
    }
    const path = this.pathByToolCallId.get(runtimeEvent.toolCallId);
    this.pathByToolCallId.delete(runtimeEvent.toolCallId);
    if (!path || runtimeEvent.status !== "succeeded") return undefined;
    const image = firstImageBlock(asRecord(event.result).content);
    if (!image) return undefined;
    return { imagePath: path, ...(image.mimeType ? { imageMimeType: image.mimeType } : {}) };
  }
}

export function firstImageBlock(content: unknown): { mimeType?: string } | undefined {
  if (!Array.isArray(content)) return undefined;
  for (const block of content) {
    const record = asRecord(block);
    if (record.type === "image") return { mimeType: stringValue(record.mimeType) };
  }
  return undefined;
}
