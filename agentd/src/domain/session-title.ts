import type { PickyContextPacket } from "../protocol.js";

export function titleFromContext(context: PickyContextPacket): string {
  const text = context.transcript?.trim();
  if (!text) return "Untitled Picky task";
  return text.length > 60 ? `${text.slice(0, 57)}...` : text;
}
