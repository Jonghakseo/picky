import { randomUUID } from "node:crypto";
import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import type { PickyPointerOverlayRequest } from "../protocol.js";

export type PickyPointerCoordinateSpace = "screenshotPixel" | "displayPoint";

export interface PickyShowPointerRequest {
  x: number;
  y: number;
  coordinateSpace?: PickyPointerCoordinateSpace;
  screenId?: string;
  screenIndex?: number;
  label?: string;
  durationMs?: number;
  sourceSessionId?: string;
}

export interface PickyShowPointerResult {
  request: PickyPointerOverlayRequest;
}

export function createPickyShowPointerTool(onShowPointer: (request: PickyShowPointerRequest) => Promise<PickyShowPointerResult>): ToolDefinition {
  return defineTool({
    name: "picky_show_pointer",
    label: "Picky show pointer",
    description: "Show a visual-only click-through pointer/highlight overlay at a screen coordinate. It never moves, clicks, drags, types, or controls the real macOS cursor.",
    promptSnippet: "picky_show_pointer: visually point to a screen coordinate in Picky's click-through overlay only; no real cursor or input actions.",
    promptGuidelines: [
      "Use picky_show_pointer only to visually indicate a location on the user's screen; it cannot and must not perform clicks, drags, keyboard input, or cursor movement.",
      "Prefer coordinateSpace='screenshotPixel' when using captured screenshot image pixels (top-left origin). Use coordinateSpace='displayPoint' for display points relative to the target screen's top-left.",
      "Specify screenId like 'screen1' or a 1-based screenIndex. If omitted, Picky uses the primary cursor/focus screen from the latest captured context.",
      "For side agents, pass your Picky sourceSessionId when it is available in the prompt so validation uses that session's captured screenshots.",
    ],
    parameters: Type.Object({
      x: Type.Number({ description: "X coordinate in the chosen coordinateSpace; top-left origin." }),
      y: Type.Number({ description: "Y coordinate in the chosen coordinateSpace; top-left origin." }),
      coordinateSpace: Type.Optional(Type.Union([
        Type.Literal("screenshotPixel"),
        Type.Literal("displayPoint"),
      ], { description: "Coordinate basis. Defaults to screenshotPixel." })),
      screenId: Type.Optional(Type.String({ description: "Target screen id from captured context, e.g. screen1." })),
      screenIndex: Type.Optional(Type.Number({ description: "1-based target screen index from captured context." })),
      label: Type.Optional(Type.String({ description: "Optional short label shown next to the pointer." })),
      durationMs: Type.Optional(Type.Number({ description: "Optional highlight hold duration in milliseconds. Picky clamps to 1000-10000ms." })),
      sourceSessionId: Type.Optional(Type.String({ description: "Optional Picky session id whose captured screenshots should be used for validation." })),
    }),
    execute: async (_toolCallId, params) => {
      const result = await onShowPointer(normalizeRequest(params as PickyShowPointerRequest));
      const screen = result.request.screenId ?? (result.request.screenIndex ? `screen${result.request.screenIndex}` : "primary");
      const clampedText = result.request.clamped ? " Coordinates were clamped to the target screen bounds." : "";
      return {
        content: [
          {
            type: "text",
            text: `Picky visual-only pointer overlay requested: ${screen} (${result.request.x}, ${result.request.y}) in ${result.request.coordinateSpace}.${clampedText} No real cursor/input action was performed.`,
          },
        ],
        details: result,
      };
    },
  });
}

export function makePointerOverlayRequest(input: PickyShowPointerRequest, defaults: { contextId?: string; screenId?: string; screenIndex?: number; screenBounds: { x: number; y: number; width: number; height: number }; screenshotSize?: { width: number; height: number } }): PickyPointerOverlayRequest {
  const coordinateSpace = input.coordinateSpace ?? "screenshotPixel";
  const durationMs = clampOptionalInteger(input.durationMs, 1_000, 10_000);
  return {
    id: `pointer-${randomUUID()}`,
    contextId: defaults.contextId,
    sourceSessionId: normalizeOptionalString(input.sourceSessionId),
    screenId: normalizeOptionalString(input.screenId) ?? defaults.screenId,
    screenIndex: normalizeOptionalInteger(input.screenIndex) ?? defaults.screenIndex,
    x: input.x,
    y: input.y,
    coordinateSpace,
    label: normalizeOptionalString(input.label),
    ...(durationMs === undefined ? {} : { durationMs }),
    screenBounds: defaults.screenBounds,
    ...(defaults.screenshotSize ? { screenshotSize: defaults.screenshotSize } : {}),
  };
}

function normalizeRequest(input: PickyShowPointerRequest): PickyShowPointerRequest {
  if (!Number.isFinite(input.x) || !Number.isFinite(input.y)) throw new Error("picky_show_pointer requires finite x and y coordinates.");
  const coordinateSpace = input.coordinateSpace ?? "screenshotPixel";
  if (coordinateSpace !== "screenshotPixel" && coordinateSpace !== "displayPoint") throw new Error(`Unsupported coordinateSpace: ${String(input.coordinateSpace)}`);
  return {
    ...input,
    coordinateSpace,
    screenId: normalizeOptionalString(input.screenId),
    sourceSessionId: normalizeOptionalString(input.sourceSessionId),
    label: normalizeOptionalString(input.label),
    screenIndex: normalizeOptionalInteger(input.screenIndex),
    durationMs: clampOptionalInteger(input.durationMs, 1_000, 10_000),
  };
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function normalizeOptionalInteger(value: number | undefined): number | undefined {
  if (!Number.isFinite(value)) return undefined;
  return Math.max(1, Math.floor(value!));
}

function clampOptionalInteger(value: number | undefined, min: number, max: number): number | undefined {
  if (!Number.isFinite(value)) return undefined;
  return Math.max(min, Math.min(max, Math.floor(value!)));
}

