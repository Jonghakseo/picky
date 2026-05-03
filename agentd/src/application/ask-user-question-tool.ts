import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
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

const TOOL_DESCRIPTION = `인터랙티브 폼으로 사용자에게 하나 이상의 질문을 묻습니다. 지원하는 질문 유형은 다음 세 가지입니다:
- radio: 미리 정의된 보기 중 하나를 고르는 단일 선택
- checkbox: 여러 보기를 동시에 고르는 복수 선택
- text: 자유롭게 입력하는 텍스트 답변

radio/checkbox 질문에는 사용자가 직접 값을 입력할 수 있는 "기타..." 옵션을 포함할 수 있습니다.`;

export function createPickyAskUserQuestionTool(): ToolDefinition {
  return defineTool({
    name: "ask_user_question",
    label: "사용자 질문",
    description: TOOL_DESCRIPTION,
    promptSnippet: "ask_user_question: radio, checkbox, text 입력을 사용하는 인터랙티브 질문 폼 열기",
    promptGuidelines: [
      "구조화된 사용자 입력이 필요하면 일반 텍스트 질문 대신 ask_user_question을 사용하세요.",
      "단일 선택은 radio, 복수 선택은 checkbox, 서술형 답변은 text를 우선 사용하세요.",
      "선택지가 완전히 닫혀 있지 않다면 allowOther: true로 '기타' 입력 경로를 열어두세요.",
      "관련 질문은 여러 번 나누지 말고 한 번의 호출에 묶어 전달하세요.",
    ],
    parameters: AskUserQuestionParamsSchema,
    execute: async (_toolCallId, params, signal, _onUpdate, ctx) => {
      const ui = ctx.ui as unknown as Record<string, unknown>;
      const askUserQuestion = ui.askUserQuestion ?? ui.ask_user_question;

      if (!ctx.hasUI || typeof askUserQuestion !== "function") {
        return errorResult("오류: Picky 입력 UI를 사용할 수 없습니다.");
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
          content: [{ type: "text", text: "사용자가 입력 폼을 취소했습니다" }],
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
    return `사용자 응답: ${String(result)}`;
  }

  const entries = Object.entries(result as Record<string, unknown>);
  if (entries.length === 0) return "사용자 응답: {}";

  return [
    "사용자 응답:",
    "| 항목 | 응답 |",
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
