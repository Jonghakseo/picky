import { randomUUID } from "node:crypto";
import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import type { PickyPointerOverlayRequest } from "../protocol.js";

export interface PickyShowPointerRequest {
  x: number;
  y: number;
  screenId?: string;
  label?: string;
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
      "Coordinates are always screenshot pixels from the attached captured screenshot image, with top-left origin: x increases rightward, y increases downward.",
      "Specify screenId like 'screen1' from the screenshot metadata. If omitted, Picky uses the primary cursor/focus screen from the latest captured context.",
      "The overlay is shown for a fixed one second.",
    ],
    parameters: Type.Object({
      x: Type.Number({ description: "X coordinate in captured screenshot image pixels; top-left origin." }),
      y: Type.Number({ description: "Y coordinate in captured screenshot image pixels; top-left origin." }),
      screenId: Type.Optional(Type.String({ description: "Target screen id from captured context, e.g. screen1." })),
      label: Type.Optional(Type.String({ description: "Optional short label shown next to the pointer." })),
    }),
    execute: async (_toolCallId, params) => {
      const result = await onShowPointer(normalizeRequest(params as PickyShowPointerRequest));
      const screen = result.request.screenId ?? "primary";
      const clampedText = result.request.clamped ? " Coordinates were clamped to the target screen bounds." : "";
      return {
        content: [
          {
            type: "text",
            text: `Picky visual-only pointer overlay requested: ${screen} (${result.request.x}, ${result.request.y}) in screenshot pixels.${clampedText} No real cursor/input action was performed.`,
          },
        ],
        details: result,
      };
    },
  });
}

export function makePointerOverlayRequest(input: PickyShowPointerRequest, defaults: { contextId?: string; screenId?: string; screenBounds: { x: number; y: number; width: number; height: number }; screenshotSize: { width: number; height: number } }): PickyPointerOverlayRequest {
  return {
    id: `pointer-${randomUUID()}`,
    contextId: defaults.contextId,
    screenId: normalizeOptionalString(input.screenId) ?? defaults.screenId,
    x: input.x,
    y: input.y,
    label: normalizeOptionalString(input.label),
    screenBounds: defaults.screenBounds,
    screenshotSize: defaults.screenshotSize,
  };
}

function normalizeRequest(input: PickyShowPointerRequest): PickyShowPointerRequest {
  if (!Number.isFinite(input.x) || !Number.isFinite(input.y)) throw new Error("picky_show_pointer requires finite x and y coordinates.");
  return {
    x: input.x,
    y: input.y,
    screenId: normalizeOptionalString(input.screenId),
    label: normalizeOptionalString(input.label),
  };
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}


