import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { makePointerOverlayRequest, type PickyShowPointerRequest, type PickyShowPointerResult } from "./pointer-overlay-request.js";
import type { PickyShowAnnotationsRequest } from "./annotation-overlay-request.js";
import { clampAnnotation } from "../domain/annotation-validation.js";
import { readImageSizeFromBuffer } from "../domain/image-size.js";
import { clampPointerCoordinates, screenshotSizeFromMetadata, selectPointerScreenshot } from "../domain/pointer-validation.js";
import type { PickyAnnotationOverlayRequest, PickyContextPacket } from "../protocol.js";

export interface MainTurnOverlayContext {
  context: PickyContextPacket;
  generation: number;
}

export function makePointerOverlayRequestForContext(
  context: PickyContextPacket,
  request: PickyShowPointerRequest,
  contextGeneration: number,
): PickyShowPointerResult["request"] {
  const screenshot = selectPointerScreenshot(context.screenshots, request);
  if (!screenshot.bounds) throw new Error(`No display bounds are available for ${screenshot.screenId ?? screenshot.id}.`);
  const screenshotSize = screenshotSizeFromMetadata(screenshot) ?? readImageSize(screenshot.path);
  if (!screenshotSize) {
    throw new Error(`Screenshot pixel coordinates require screenshot dimensions for ${screenshot.screenId ?? screenshot.id}.`);
  }

  const bounded = clampPointerCoordinates(request, screenshotSize);
  return {
    ...makePointerOverlayRequest({ ...request, ...bounded }, {
      contextId: context.id,
      contextGeneration,
      screenId: screenshot.screenId,
      screenBounds: screenshot.bounds,
      screenshotSize,
    }),
    ...(bounded.clamped ? { clamped: true } : {}),
  };
}

export function makeAnnotationOverlayRequestForContext(
  context: PickyContextPacket,
  request: PickyShowAnnotationsRequest,
  contextGeneration: number,
): PickyAnnotationOverlayRequest {
  const screenshot = selectPointerScreenshot(context.screenshots, { screenId: request.screenId });
  if (!screenshot.bounds) throw new Error(`No display bounds are available for ${screenshot.screenId ?? screenshot.id}.`);
  const screenshotSize = screenshotSizeFromMetadata(screenshot) ?? readImageSize(screenshot.path);
  if (!screenshotSize) {
    throw new Error(`Screenshot pixel coordinates require screenshot dimensions for ${screenshot.screenId ?? screenshot.id}.`);
  }
  const annotations = request.annotations.map((annotation) => clampAnnotation(annotation, screenshotSize));
  if (request.mode !== "clear" && annotations.length === 0) throw new Error("Annotations are required unless mode is clear.");
  return {
    id: `annotations-${randomUUID()}`,
    mode: request.mode,
    annotations,
    contextId: context.id,
    contextGeneration,
    screenId: screenshot.screenId ?? screenshot.id,
    screenBounds: screenshot.bounds,
    screenshotSize,
  };
}

function readImageSize(path: string): { width: number; height: number } | undefined {
  try {
    return readImageSizeFromBuffer(readFileSync(path));
  } catch {
    return undefined;
  }
}
