import type { PickyContextPacket } from "../protocol.js";

type ScreenshotContext = PickyContextPacket["screenshots"][number];

export interface PointerScreenRequest {
  screenId?: string;
}

export interface PointerCoordinateRequest {
  x: number;
  y: number;
}

export interface ScreenshotSize {
  width: number;
  height: number;
}

export function selectPointerScreenshot(
  screenshots: readonly ScreenshotContext[],
  request: PointerScreenRequest,
): ScreenshotContext {
  if (screenshots.length === 0) throw new Error("No screenshots are available for pointer overlay validation.");
  const requestedScreenId = request.screenId?.trim();
  if (requestedScreenId) {
    const screenshot = screenshots.find((candidate) => candidate.screenId === requestedScreenId || candidate.id === requestedScreenId);
    if (!screenshot) throw new Error(`Unknown pointer overlay screenId: ${requestedScreenId}`);
    return screenshot;
  }
  const cursorScreenshot = screenshots.find((screenshot) => screenshot.isCursorScreen === true || /cursor|primary|focus/i.test(screenshot.label));
  return cursorScreenshot ?? screenshots[0]!;
}

export function screenshotSizeFromMetadata(screenshot: ScreenshotContext): ScreenshotSize | undefined {
  return screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels
    ? { width: screenshot.screenshotWidthInPixels, height: screenshot.screenshotHeightInPixels }
    : undefined;
}

export function clampPointerCoordinates(
  request: PointerCoordinateRequest,
  screenshotSize: ScreenshotSize,
): { x: number; y: number; clamped?: boolean } {
  const x = clamp(request.x, 0, screenshotSize.width);
  const y = clamp(request.y, 0, screenshotSize.height);
  const clamped = x !== request.x || y !== request.y;
  return { x, y, ...(clamped ? { clamped: true } : {}) };
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}
