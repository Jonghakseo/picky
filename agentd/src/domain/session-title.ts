import type { PickyContextPacket } from "../protocol.js";
import { sliceUtf16Safe } from "./safe-truncate.js";

export function titleFromContext(context: PickyContextPacket): string {
  const text = context.transcript?.trim();
  if (!text) return "Untitled Picky task";
  return text.length > 60 ? `${sliceUtf16Safe(text, 57)}...` : text;
}
