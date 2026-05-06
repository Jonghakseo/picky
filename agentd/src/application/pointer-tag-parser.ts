import type { PickyShowPointerRequest } from "./pointer-tool.js";

export interface ParsedPointerTags {
  text: string;
  points: PickyShowPointerRequest[];
  explicitNone: boolean;
}

const POINT_TAG_PATTERN = /\[POINT:(none|([-+]?\d+(?:\.\d+)?)\s*,\s*([-+]?\d+(?:\.\d+)?)(?::([^\]:\n][^\]:\n]*?))?(?::([A-Za-z][A-Za-z0-9_-]*))?)\]/g;

export function parsePointerTags(text: string): ParsedPointerTags {
  const points: PickyShowPointerRequest[] = [];
  let explicitNone = false;

  const stripped = text.replace(POINT_TAG_PATTERN, (_match, mode: string, xText: string | undefined, yText: string | undefined, labelText: string | undefined, screenIdText: string | undefined) => {
    if (mode === "none") {
      explicitNone = true;
      return "";
    }

    const x = Number(xText);
    const y = Number(yText);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return "";

    const label = labelText?.trim();
    const screenId = screenIdText?.trim();
    points.push({
      x,
      y,
      ...(screenId ? { screenId } : {}),
      ...(label ? { label } : {}),
    });
    return "";
  });

  return {
    text: normalizeWhitespaceAroundRemovedTags(stripped),
    points: explicitNone ? [] : points,
    explicitNone,
  };
}

function normalizeWhitespaceAroundRemovedTags(text: string): string {
  return text
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n[ \t]+/g, "\n")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
