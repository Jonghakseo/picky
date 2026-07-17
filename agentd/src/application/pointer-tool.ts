import { randomUUID } from "node:crypto";
import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { PickyPointerOverlayRequest } from "../protocol.js";

export const PICKY_SHOW_POINTER_TOOL_NAME = "picky_show_pointer";

export interface PickyShowPointerRequest {
  x: number;
  y: number;
  screenId?: string;
  label?: string;
}

export interface PickyShowPointerResult {
  request: PickyPointerOverlayRequest;
}

interface PickyShowPointerToolDetails {
  request?: PickyPointerOverlayRequest;
  error?: string;
}

const PickyShowPointerParameters = Type.Object({
  x: Type.Number({ description: "Horizontal screenshot-pixel coordinate, measured from the left edge." }),
  y: Type.Number({ description: "Vertical screenshot-pixel coordinate, measured from the top edge." }),
  label: Type.Optional(Type.String({ description: "Optional short label shown beside the pointer." })),
  screenId: Type.Optional(Type.String({ description: "Optional captured screen ID. Omit to use the cursor or primary captured screen." })),
});

export function createPickyShowPointerTool(
  onShowPointer: (request: PickyShowPointerRequest) => Promise<PickyShowPointerResult>,
): ToolDefinition {
  return defineTool<typeof PickyShowPointerParameters, PickyShowPointerToolDetails>({
    name: PICKY_SHOW_POINTER_TOOL_NAME,
    label: "Show screen pointer",
    description: "Show a transient pointer overlay at a concrete location in a captured screenshot. Coordinates use screenshot pixels with a top-left origin.",
    promptSnippet: `${PICKY_SHOW_POINTER_TOOL_NAME}: point to a concrete location in a captured screenshot using screenshot-pixel coordinates.`,
    promptGuidelines: [
      `Use ${PICKY_SHOW_POINTER_TOOL_NAME} only when identifying a concrete on-screen location helps the user.`,
      "Use screenshot-pixel coordinates with a top-left origin and include a short label when useful.",
      "Do not use text tags or call this tool when there is no concrete screen location to point to.",
    ],
    parameters: PickyShowPointerParameters,
    execute: async (_toolCallId, params) => {
      try {
        const result = await onShowPointer({
          x: params.x,
          y: params.y,
          label: params.label,
          screenId: params.screenId,
        });
        const request = result.request;
        const screen = request.screenId ? ` on ${request.screenId}` : "";
        const clamped = request.clamped ? " Coordinates were clamped to the screenshot bounds." : "";
        return {
          content: [{ type: "text", text: `Pointer shown at screenshot pixel (${request.x}, ${request.y})${screen}.${clamped}` }],
          details: { request },
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return {
          content: [{ type: "text", text: `Pointer overlay unavailable: ${message}` }],
          details: { error: message },
        };
      }
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

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}
