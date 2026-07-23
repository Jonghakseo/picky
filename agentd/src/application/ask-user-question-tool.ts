import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const AskUserQuestionOptionSchema = Type.Union([
  Type.String(),
  Type.Object({
    value: Type.String(),
    label: Type.String(),
    description: Type.Optional(Type.String()),
  }),
]);

const AskUserQuestionSchema = Type.Object({
  id: Type.Optional(Type.String()),
  type: Type.Union([Type.Literal("radio"), Type.Literal("checkbox"), Type.Literal("text")]),
  prompt: Type.Optional(Type.String()),
  question: Type.Optional(Type.String()),
  label: Type.Optional(Type.String()),
  options: Type.Optional(Type.Union([Type.Array(AskUserQuestionOptionSchema), Type.String()])),
  allowOther: Type.Optional(Type.Boolean()),
  required: Type.Optional(Type.Boolean()),
  placeholder: Type.Optional(Type.String()),
  default: Type.Optional(Type.Any()),
});

const AskUserQuestionParamsSchema = Type.Object({
  title: Type.Optional(Type.String()),
  description: Type.Optional(Type.String()),
  questions: Type.Union([Type.Array(AskUserQuestionSchema), Type.String()]),
});

const TOOL_DESCRIPTION = `Ask the user one or more questions through an interactive form. Three question types are supported:
- radio: pick one option from a fixed list
- checkbox: pick multiple options from a list
- text: free-form text answer

radio/checkbox questions can include an "Other" option for free-form input.`;

export function createPickyAskUserQuestionTool(): ToolDefinition {
  return defineTool({
    name: "ask_user_question",
    label: "Ask user question",
    description: TOOL_DESCRIPTION,
    promptSnippet: "ask_user_question: open an interactive form (radio/checkbox/text) to collect structured input.",
    promptGuidelines: [
      "Use this tool when you need structured input from the user; do not ask in free-form text.",
      "Single choice: radio. Multiple choice: checkbox. Free-form answer: text.",
      "Set allowOther: true when the option list is not exhaustive.",
      "Batch related questions into one call instead of issuing multiple separate prompts.",
    ],
    parameters: AskUserQuestionParamsSchema,
    execute: async (_toolCallId, params, signal, _onUpdate, ctx) => {
      const ui = ctx.ui as unknown as Record<string, unknown>;
      const askUserQuestion = ui.askUserQuestion ?? ui.ask_user_question;

      if (!ctx.hasUI || typeof askUserQuestion !== "function") {
        return errorResult("Error: Picky input UI is unavailable.");
      }

      const result = await (askUserQuestion as (request: unknown, opts?: { signal?: AbortSignal }) => Promise<unknown>)(
        {
          title: params.title,
          description: params.description,
          questions: params.questions,
        },
        { signal },
      );

      if (!result || (typeof result === "object" && "cancelled" in result && (result as { cancelled?: unknown }).cancelled === true)) {
        return {
          content: [{ type: "text", text: "The question form was dismissed without a submitted answer. Continue with your best judgment; if the user's next message addresses the question, treat it as the answer." }],
          details: { cancelled: true },
        };
      }

      return {
        content: [{ type: "text", text: formatAnswerContent(result) }],
        details: { value: result, cancelled: false },
      };
    },
  });
}

function errorResult(message: string) {
  return {
    content: [{ type: "text" as const, text: message }],
    details: { error: message },
  };
}

function formatAnswerContent(result: unknown): string {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return `User response: ${String(result)}`;
  }

  const entries = Object.entries(result as Record<string, unknown>);
  if (entries.length === 0) return "User response: {}";

  return [
    "User response:",
    "| Field | Answer |",
    "| --- | --- |",
    ...entries.map(([key, value]) => `| ${escapeTableCell(key)} | ${escapeTableCell(formatValue(value))} |`),
  ].join("\n");
}

function formatValue(value: unknown): string {
  if (Array.isArray(value)) return value.map(formatValue).join(", ");
  if (value && typeof value === "object") return JSON.stringify(value);
  return String(value ?? "");
}

function escapeTableCell(value: string): string {
  return value.replace(/\|/g, "\\|").replace(/\n/g, " ");
}
