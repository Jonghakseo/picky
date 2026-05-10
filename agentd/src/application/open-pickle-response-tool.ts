import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import type { PickyAgentSession } from "../protocol.js";

export interface PickyOpenPickleResponseRequest {
  sessionId: string;
}

export interface PickyOpenPickleResponseResult {
  sessionId: string;
  messageId: string;
  source: "finalAnswer" | "agentText";
  status: PickyAgentSession["status"];
  charCount: number;
}

const TOOL_NAME = "picky_open_pickle_response";

export function createPickyOpenPickleResponseTool(
  onOpen: (request: PickyOpenPickleResponseRequest) => Promise<PickyOpenPickleResponseResult>,
): ToolDefinition {
  return defineTool({
    name: TOOL_NAME,
    label: "Picky open Pickle response",
    description: "Open a Pickle's last response in Picky's built-in markdown viewer window.",
    promptSnippet: `${TOOL_NAME}: open a Pickle's last response in Picky's markdown viewer when the user explicitly asks to see it.`,
    promptGuidelines: [
      `Only call ${TOOL_NAME} when the user explicitly asks to open, view, expand, or pop out a Pickle's response in a markdown viewer (e.g. "마지막 응답 열어줘", "마크다운으로 보여줘", "결과 펼쳐줘").`,
      "Do not call this tool to summarise, quote, or inspect a Pickle's response on your own initiative; quoting in chat is preferred for normal answers.",
      "Resolve the target Pickle with picky_pickle_sessions first if the user did not name a specific session.",
      `If the Pickle has no response yet, ${TOOL_NAME} will fail; tell the user the Pickle has not produced a response yet instead of retrying.`,
      `After ${TOOL_NAME} succeeds, briefly tell the user in Korean that the response was opened in the markdown viewer.`,
    ],
    parameters: Type.Object({
      sessionId: Type.String({ description: "ID of the Pickle session whose last response should be opened, as returned by picky_pickle_sessions." }),
    }),
    execute: async (_toolCallId, params) => {
      const result = await onOpen({ sessionId: params.sessionId });
      return {
        content: [
          {
            type: "text",
            text: `Opened Pickle response in markdown viewer (session=${result.sessionId}, source=${result.source}, chars=${result.charCount}). Now tell the user in Korean that the response was opened in the markdown viewer.`,
          },
        ],
        details: result,
      };
    },
  });
}
