import type { PickyContextPacket } from "../protocol.js";
import { sliceUtf16Safe } from "./safe-truncate.js";

export function titleFromContext(context: PickyContextPacket): string {
  const text = context.transcript?.trim();
  if (!text) return "Untitled Picky task";
  return text.length > 60 ? `${sliceUtf16Safe(text, 57)}...` : text;
}

/** An explicit handoff title also names the Pi session, so Pi's auto-name never overwrites it. */
export function withExplicitSessionName<T extends object>(defaults: T | undefined, title: string): T & { sessionName?: string } {
  const explicit = title.trim();
  return { ...defaults, ...(explicit ? { sessionName: explicit } : {}) } as T & { sessionName?: string };
}
