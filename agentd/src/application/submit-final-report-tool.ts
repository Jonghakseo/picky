import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import type { PickyFinalReport } from "../protocol.js";

export interface PickySubmitFinalReportRequest {
  summary: string;
  body: string;
  status: "success" | "partial" | "blocked";
  artifacts?: Array<{ kind: string; title: string; url?: string }>;
}

export function createPickySubmitFinalReportTool(onSubmit: (report: PickyFinalReport) => Promise<void>): ToolDefinition {
  return defineTool({
    name: "submit_final_report",
    label: "Submit final report",
    description: "Picky side-agent final report tool. Records summary/body/status/artifacts for the HUD before the turn ends.",
    promptSnippet: "submit_final_report: call once when the side-agent task is done. Provide a 1-2 sentence summary and markdown body.",
    promptGuidelines: [
      "Picky-started side agents should call submit_final_report when work is finished.",
      "Use status success, partial, or blocked to describe the outcome.",
      "Include changed files, created PRs, generated documents, or useful links in artifacts when available.",
    ],
    parameters: Type.Object({
      summary: Type.String({ description: "1-2 sentence headline summary." }),
      body: Type.String({ description: "Markdown report body with completed work, verification, and next steps." }),
      status: Type.Union([Type.Literal("success"), Type.Literal("partial"), Type.Literal("blocked")], { description: "Final task outcome." }),
      artifacts: Type.Optional(Type.Array(Type.Object({
        kind: Type.String({ description: "Artifact kind, e.g. file, pr, url, report." }),
        title: Type.String({ description: "Human-readable artifact title." }),
        url: Type.Optional(Type.String({ format: "uri", description: "Optional artifact URL." })),
      }))),
    }),
    execute: async (_toolCallId, params) => {
      const report: PickyFinalReport = {
        summary: params.summary,
        body: params.body,
        status: params.status,
        artifacts: params.artifacts ?? [],
      };
      await onSubmit(report);
      return {
        content: [{ type: "text", text: "Final report recorded." }],
        details: { report },
      };
    },
  });
}
