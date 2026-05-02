import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";

export interface PickyHandoffRequest {
  title: string;
  instructions: string;
  userMessage?: string;
}

export function createPickyHandoffTool(onHandoff: (request: PickyHandoffRequest) => Promise<{ sessionId: string; title: string }>): ToolDefinition {
  return defineTool({
    name: "picky_handoff",
    label: "Picky handoff",
    description: "Delegate complex, long-running, tool-heavy, or multi-turn work to a side Pi agent shown in Picky's top-right overlay.",
    promptSnippet: "picky_handoff: delegate complex or long-running work to a side Pi agent in the Picky HUD.",
    promptGuidelines: [
      "Use picky_handoff when the user's request needs detailed screen analysis, code/repo/file work, web/video extraction, MCPs, or multiple turns.",
      "After calling picky_handoff, tell the user in Korean that a side agent has been started and progress is visible in the top-right overlay.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Short Korean title for the side-agent HUD card." }),
      instructions: Type.String({ description: "Detailed instructions for the side Pi agent, including what to inspect, what output to produce, and any constraints." }),
      userMessage: Type.Optional(Type.String({ description: "Optional short Korean message you intend to tell the user after handoff." })),
    }),
    execute: async (_toolCallId, params) => {
      const session = await onHandoff({
        title: params.title,
        instructions: params.instructions,
        userMessage: params.userMessage,
      });
      return {
        content: [
          {
            type: "text",
            text: `Side agent started: ${session.title} (${session.sessionId}). Now tell the user in Korean that you delegated this work and that they can watch progress in the top-right overlay.`,
          },
        ],
        details: session,
      };
    },
  });
}
