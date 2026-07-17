import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { PickyAnnotationOverlayRequest } from "../protocol.js";
import { ANNOTATION_SHAPES, type AnnotationInput, type AnnotationMode, type SpotlightShape } from "../domain/annotation-validation.js";

export const PICKY_SHOW_ANNOTATIONS_TOOL_NAME = "picky_show_annotations";

export interface PickyShowAnnotationsRequest {
  mode: AnnotationMode;
  screenId?: string;
  annotations: AnnotationInput[];
}

export interface PickyShowAnnotationsResult {
  request: PickyAnnotationOverlayRequest;
}

interface PickyShowAnnotationsToolDetails {
  request?: PickyAnnotationOverlayRequest;
  error?: string;
}

const AnnotationShapeParameter = Type.Union(ANNOTATION_SHAPES.map((shape) => Type.Literal(shape)));
const AnnotationParameter = Type.Object({
  id: Type.String({ minLength: 1, description: "Stable annotation identifier used for replacement and expiry." }),
  shape: AnnotationShapeParameter,
  x: Type.Optional(Type.Number({ description: "Screenshot-pixel horizontal coordinate from the left edge." })),
  y: Type.Optional(Type.Number({ description: "Screenshot-pixel vertical coordinate from the top edge." })),
  r: Type.Optional(Type.Number({ minimum: 0, description: "Radius in screenshot pixels." })),
  rx: Type.Optional(Type.Number({ minimum: 0, description: "Horizontal ellipse radius in screenshot pixels." })),
  ry: Type.Optional(Type.Number({ minimum: 0, description: "Vertical ellipse radius in screenshot pixels." })),
  w: Type.Optional(Type.Number({ minimum: 0, description: "Rectangle width in screenshot pixels." })),
  h: Type.Optional(Type.Number({ minimum: 0, description: "Rectangle height in screenshot pixels." })),
  x1: Type.Optional(Type.Number({ description: "Line start horizontal screenshot-pixel coordinate." })),
  y1: Type.Optional(Type.Number({ description: "Line start vertical screenshot-pixel coordinate." })),
  x2: Type.Optional(Type.Number({ description: "Line end horizontal screenshot-pixel coordinate." })),
  y2: Type.Optional(Type.Number({ description: "Line end vertical screenshot-pixel coordinate." })),
  spotlightShape: Type.Optional(Type.Union([Type.Literal("rect"), Type.Literal("circle")])),
  label: Type.Optional(Type.String({ maxLength: 120, description: "Short label text." })),
  ttlMs: Type.Optional(Type.Number({ minimum: 0, maximum: 60_000, description: "Optional visibility duration in milliseconds." })),
  zOrder: Type.Optional(Type.Number({ description: "Optional drawing order; larger values render above smaller values." })),
});
const PickyShowAnnotationsParameters = Type.Object({
  mode: Type.Optional(Type.Union([Type.Literal("replace"), Type.Literal("append"), Type.Literal("clear")], { description: "replace discards current annotations, append merges by id, clear removes all annotations." })),
  screenId: Type.Optional(Type.String({ description: "Optional captured screen ID. Omit to use the cursor or primary captured screen." })),
  annotations: Type.Array(AnnotationParameter, { maxItems: 24, description: "Annotations to display on one captured screen. Use an empty array only with mode clear." }),
});

export function createPickyShowAnnotationsTool(
  onShowAnnotations: (request: PickyShowAnnotationsRequest) => Promise<PickyShowAnnotationsResult>,
): ToolDefinition {
  return defineTool<typeof PickyShowAnnotationsParameters, PickyShowAnnotationsToolDetails>({
    name: PICKY_SHOW_ANNOTATIONS_TOOL_NAME,
    label: "Show screen annotations",
    description: "Show transient structured annotations at concrete locations in a captured screenshot. Coordinates use screenshot pixels with a top-left origin.",
    promptSnippet: `${PICKY_SHOW_ANNOTATIONS_TOOL_NAME}: draw structured annotations in screenshot-pixel coordinates.`,
    promptGuidelines: [
      `Use ${PICKY_SHOW_ANNOTATIONS_TOOL_NAME} to group related visual guidance; use picky_show_pointer for a single location.`,
      "Each call targets one captured screen. To annotate a second display, call this tool again with that screenId.",
      "Use screenshot-pixel coordinates with a top-left origin, concise labels, and mode clear to remove annotations.",
      "Do not use text tags, arrows, or freehand paths.",
    ],
    parameters: PickyShowAnnotationsParameters,
    execute: async (_toolCallId, params) => {
      try {
        const mode = params.mode ?? "replace";
        const annotations = params.annotations.map((annotation) => ({ ...annotation }));
        if (mode !== "clear" && annotations.length === 0) throw new Error("Annotations are required unless mode is clear.");
        const result = await onShowAnnotations({ mode, screenId: normalizedOptionalString(params.screenId), annotations });
        const request = result.request;
        const clampedCount = request.annotations.filter((annotation) => annotation.clamped).length;
        const summary = request.mode === "clear"
          ? "Screen annotations cleared."
          : `${request.annotations.length} screen annotation${request.annotations.length === 1 ? "" : "s"} shown at screenshot-pixel coordinates.${clampedCount ? ` ${clampedCount} coordinate set${clampedCount === 1 ? " was" : "s were"} clamped to screenshot bounds.` : ""}`;
        return { content: [{ type: "text", text: summary }], details: { request } };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return {
          content: [{ type: "text", text: `Screen annotations unavailable: ${message}` }],
          details: { error: message },
        };
      }
    },
  });
}

function normalizedOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

export type { AnnotationInput, AnnotationMode, SpotlightShape };
