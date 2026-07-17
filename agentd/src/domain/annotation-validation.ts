import type { ScreenshotSize } from "./pointer-validation.js";

export const ANNOTATION_SHAPES = ["target", "circle", "rect", "line", "spotlight", "label"] as const;
export type AnnotationShape = typeof ANNOTATION_SHAPES[number];
export type AnnotationMode = "replace" | "append" | "clear";
export type SpotlightShape = "rect" | "circle";

export interface AnnotationInput {
  id: string;
  shape: AnnotationShape;
  x?: number;
  y?: number;
  r?: number;
  rx?: number;
  ry?: number;
  w?: number;
  h?: number;
  x1?: number;
  y1?: number;
  x2?: number;
  y2?: number;
  spotlightShape?: SpotlightShape;
  label?: string;
  ttlMs?: number;
  zOrder?: number;
}

export interface ClampedAnnotation extends AnnotationInput {
  clamped?: boolean;
}

export function clampAnnotation(annotation: AnnotationInput, screenshotSize: ScreenshotSize): ClampedAnnotation {
  const input = normalizeAnnotation(annotation);
  const maxRadius = Math.max(screenshotSize.width, screenshotSize.height);
  let clamped = false;
  const coordinate = (value: number | undefined, axis: "x" | "y", field: string): number => {
    const finite = requiredFinite(value, field);
    const bounded = clamp(finite, 0, axis === "x" ? screenshotSize.width : screenshotSize.height);
    clamped ||= bounded !== finite;
    return bounded;
  };
  const radius = (value: number | undefined, field: string): number => {
    const finite = requiredFinite(value, field);
    if (finite < 0) throw new Error(`${field} must be non-negative.`);
    const bounded = clamp(finite, 0, maxRadius);
    clamped ||= bounded !== finite;
    return bounded;
  };

  switch (input.shape) {
    case "target":
      return withClamped(input, { x: coordinate(input.x, "x", "x"), y: coordinate(input.y, "y", "y"), r: radius(input.r, "r") }, clamped);
    case "circle":
      return withClamped(input, {
        x: coordinate(input.x, "x", "x"),
        y: coordinate(input.y, "y", "y"),
        ...(input.r !== undefined ? { r: radius(input.r, "r") } : { rx: radius(input.rx, "rx"), ry: radius(input.ry, "ry") }),
      }, clamped);
    case "rect":
      return clampRect(input, screenshotSize, coordinate, clamped);
    case "line":
      return withClamped(input, {
        x1: coordinate(input.x1, "x", "x1"),
        y1: coordinate(input.y1, "y", "y1"),
        x2: coordinate(input.x2, "x", "x2"),
        y2: coordinate(input.y2, "y", "y2"),
      }, clamped);
    case "spotlight":
      if (!input.spotlightShape) throw new Error("spotlightShape is required for spotlight annotations.");
      if (input.spotlightShape === "rect") return clampRect(input, screenshotSize, coordinate, clamped);
      return withClamped(input, { x: coordinate(input.x, "x", "x"), y: coordinate(input.y, "y", "y"), r: radius(input.r, "r") }, clamped);
    case "label":
      if (!input.label) throw new Error("label annotations need non-empty label text.");
      return withClamped(input, { x: coordinate(input.x, "x", "x"), y: coordinate(input.y, "y", "y") }, clamped);
  }
}

function clampRect(
  input: AnnotationInput,
  screenshotSize: ScreenshotSize,
  coordinate: (value: number | undefined, axis: "x" | "y", field: string) => number,
  initialClamped: boolean,
): ClampedAnnotation {
  const rawX = requiredFinite(input.x, "x");
  const rawY = requiredFinite(input.y, "y");
  const rawWidth = requiredFinite(input.w, "w");
  const rawHeight = requiredFinite(input.h, "h");
  if (rawWidth < 0 || rawHeight < 0) throw new Error("rect and spotlight dimensions must be non-negative.");
  const x = coordinate(rawX, "x", "x");
  const y = coordinate(rawY, "y", "y");
  const endX = coordinate(rawX + rawWidth, "x", "x + w");
  const endY = coordinate(rawY + rawHeight, "y", "y + h");
  const normalizedX = Math.min(x, endX);
  const normalizedY = Math.min(y, endY);
  const w = Math.abs(endX - x);
  const h = Math.abs(endY - y);
  const clamped = initialClamped || normalizedX !== rawX || normalizedY !== rawY || w !== rawWidth || h !== rawHeight;
  return withClamped(input, { x: normalizedX, y: normalizedY, w, h }, clamped);
}

function normalizeAnnotation(annotation: AnnotationInput): AnnotationInput {
  const id = annotation.id.trim();
  if (!id) throw new Error("Annotation id is required.");
  const label = annotation.label?.trim();
  return {
    ...annotation,
    id,
    label: label || undefined,
    ...(annotation.ttlMs !== undefined ? { ttlMs: nonNegativeFinite(annotation.ttlMs, "ttlMs") } : {}),
    ...(annotation.zOrder !== undefined ? { zOrder: requiredFinite(annotation.zOrder, "zOrder") } : {}),
  };
}

function withClamped(input: AnnotationInput, fields: Partial<AnnotationInput>, clamped: boolean): ClampedAnnotation {
  return { ...input, ...fields, ...(clamped ? { clamped: true } : {}) };
}

function requiredFinite(value: number | undefined, field: string): number {
  if (value === undefined || !Number.isFinite(value)) throw new Error(`${field} must be a finite number.`);
  return value;
}

function nonNegativeFinite(value: number, field: string): number {
  const finite = requiredFinite(value, field);
  if (finite < 0) throw new Error(`${field} must be non-negative.`);
  return finite;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}
