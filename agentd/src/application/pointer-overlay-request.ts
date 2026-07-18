import { randomUUID } from "node:crypto";
import type { PickyPointerOverlayRequest } from "../protocol.js";

export interface PickyShowPointerRequest {
  x: number;
  y: number;
  r?: number;
  screenId?: string;
  label?: string;
}

export interface PickyShowPointerResult {
  request: PickyPointerOverlayRequest;
}

export function makePointerOverlayRequest(input: PickyShowPointerRequest, defaults: { contextId?: string; contextGeneration?: number; screenId?: string; screenBounds: { x: number; y: number; width: number; height: number }; screenshotSize: { width: number; height: number } }): PickyPointerOverlayRequest {
  return {
    id: `pointer-${randomUUID()}`,
    contextId: defaults.contextId,
    contextGeneration: defaults.contextGeneration,
    screenId: normalizeOptionalString(input.screenId) ?? defaults.screenId,
    x: input.x,
    y: input.y,
    r: input.r,
    label: normalizeOptionalString(input.label),
    screenBounds: defaults.screenBounds,
    screenshotSize: defaults.screenshotSize,
  };
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}
