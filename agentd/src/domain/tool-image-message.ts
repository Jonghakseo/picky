import type { PickySessionMessage, PickyToolImage } from "../protocol.js";

/**
 * Journal entry for an image a tool handed to the model. It is a `system` message so older
 * daemons still parse the journal; `text` is the fallback older apps render.
 */
export function toolImageMessage(id: string, createdAt: string, toolImage: PickyToolImage): PickySessionMessage {
  return {
    id,
    kind: "system",
    createdAt,
    text: `Read image: ${toolImage.path}`,
    toolImage,
  };
}
