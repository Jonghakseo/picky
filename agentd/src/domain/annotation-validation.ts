import type { ScreenshotSize } from "./pointer-validation.js";

export const ANNOTATION_SHAPES = ["rect", "line"] as const;
export type AnnotationShape = typeof ANNOTATION_SHAPES[number];
export type AnnotationMode = "replace" | "append" | "clear";

export interface AnnotationInput {
  id: string;
  shape: AnnotationShape;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
  x1?: number;
  y1?: number;
  x2?: number;
  y2?: number;
  spotlight?: boolean;
  label?: string;
}

export interface ClampedAnnotation extends AnnotationInput {
  clamped?: boolean;
}

export function clampAnnotation(annotation: AnnotationInput, screenshotSize: ScreenshotSize): ClampedAnnotation {
  const input = normalizeAnnotation(annotation);
  let clamped = false;
  const coordinate = (value: number | undefined, axis: "x" | "y", field: string): number => {
    const finite = requiredFinite(value, field);
    const bounded = clamp(finite, 0, axis === "x" ? screenshotSize.width : screenshotSize.height);
    clamped ||= bounded !== finite;
    return bounded;
  };
  switch (input.shape) {
    case "rect":
      return clampRect(input, screenshotSize, coordinate, clamped);
    case "line":
      return withClamped(input, {
        x1: coordinate(input.x1, "x", "x1"),
        y1: coordinate(input.y1, "y", "y1"),
        x2: coordinate(input.x2, "x", "x2"),
        y2: coordinate(input.y2, "y", "y2"),
      }, clamped);
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
  if (rawWidth < 0 || rawHeight < 0) throw new Error("rect dimensions must be non-negative.");
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
  };
}

function withClamped(input: AnnotationInput, fields: Partial<AnnotationInput>, clamped: boolean): ClampedAnnotation {
  return { ...input, ...fields, ...(clamped ? { clamped: true } : {}) };
}

function requiredFinite(value: number | undefined, field: string): number {
  if (value === undefined || !Number.isFinite(value)) throw new Error(`${field} must be a finite number.`);
  return value;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}
