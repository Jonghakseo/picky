import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { PICKY_NARRATE_PROGRESS_TOOL_NAME } from "./picky-tool-names.js";

export interface PickyNarrateProgressRequest {
  text: string;
}

const MAX_NARRATION_CHARS = 80;

export function createPickyNarrateProgressTool(
  onNarrate: (request: PickyNarrateProgressRequest) => Promise<void> | void,
): ToolDefinition {
  return defineTool({
    name: PICKY_NARRATE_PROGRESS_TOOL_NAME,
    label: "Picky narrate progress",
    description: "Speak a brief filler line via Picky's companion voice before a long step runs; prefer calling it before starting other long-running tool calls.",
    promptSnippet: `${PICKY_NARRATE_PROGRESS_TOOL_NAME}: speak a brief filler line before a long step is in flight, ideally before other tool calls for that step.`,
    promptGuidelines: [
      "Use only for steps likely to take more than a few seconds.",
      "When a long step will call other tools, call this first whenever practical so the user hears progress before waiting.",
      "One short present-continuous sentence in the user's language (e.g. \"Now checking the logs\"); aim for ~40 chars.",
      "Describe the activity only; never include final answers, code, paths, or sensitive identifiers.",
      "One narration per long step.",
      "Returns silently if narration is disabled — do not retry.",
    ],
    parameters: Type.Object({
      text: Type.String({ description: "Short present-continuous filler line in the user's language. Ideally <=40 characters, max 80." }),
    }),
    execute: async (_toolCallId, params) => {
      const text = params.text.trim();
      if (!text) throw new Error("text must not be empty");
      const truncated = text.length > MAX_NARRATION_CHARS ? `${text.slice(0, MAX_NARRATION_CHARS - 1)}…` : text;
      await onNarrate({ text: truncated });
      return {
        content: [{ type: "text", text: `Narration dispatched (${truncated.length} chars). Continue the underlying work; do not narrate the same step again.` }],
        details: { text: truncated },
      };
    },
  });
}
