import {
  createAgentSession,
  createExtensionRuntime,
  SessionManager,
  type ResourceLoader,
} from "@mariozechner/pi-coding-agent";
import type { PickyContextPacket } from "./protocol.js";

export type TaskRouteDecision =
  | { route: "quick_reply"; reply: string }
  | { route: "handoff"; reason?: string };

export interface TaskRouter {
  route(context: PickyContextPacket): Promise<TaskRouteDecision>;
}

export class ConservativeMockTaskRouter implements TaskRouter {
  async route(context: PickyContextPacket): Promise<TaskRouteDecision> {
    const immediate = immediateQuickReply(context);
    if (immediate) return { route: "quick_reply", reply: immediate };
    return { route: "handoff", reason: "Mock router only answers trivial microphone/screen checks." };
  }
}

export class PiQuickTaskRouter implements TaskRouter {
  constructor(private readonly options: { agentDir?: string } = {}) {}

  async route(context: PickyContextPacket): Promise<TaskRouteDecision> {
    const transcript = context.transcript?.trim();
    if (!transcript) return { route: "handoff", reason: "No transcript to answer directly." };
    const immediate = immediateQuickReply(context);
    if (immediate) return { route: "quick_reply", reply: immediate };

    let output = "";
    const cwd = context.cwd ?? process.cwd();
    const { session } = await createAgentSession({
      cwd,
      agentDir: this.options.agentDir,
      noTools: "all",
      resourceLoader: quickReplyResourceLoader(),
      sessionManager: SessionManager.inMemory(cwd),
    });

    const unsubscribe = session.subscribe((event: unknown) => {
      const e = asRecord(event);
      if (e.type !== "message_update") return;
      const assistant = asRecord(e.assistantMessageEvent);
      if (assistant.type === "text_delta" && typeof assistant.delta === "string") output += assistant.delta;
    });

    try {
      await session.prompt(buildRouterPrompt(context), { source: "rpc" });
      return parseDecision(output);
    } catch (error) {
      return { route: "handoff", reason: `Quick router failed: ${messageOf(error)}` };
    } finally {
      unsubscribe();
      session.dispose();
    }
  }
}

function quickReplyResourceLoader(): ResourceLoader {
  return {
    getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
    getSkills: () => ({ skills: [], diagnostics: [] }),
    getPrompts: () => ({ prompts: [], diagnostics: [] }),
    getThemes: () => ({ themes: [], diagnostics: [] }),
    getAgentsFiles: () => ({ agentsFiles: [] }),
    getSystemPrompt: () =>
      "You are Picky's fast voice front desk. You either answer simple requests directly or hand complex work off to a long-running Pi agent. Return only valid JSON.",
    getAppendSystemPrompt: () => [],
    extendResources: () => undefined,
    reload: async () => undefined,
  };
}

function buildRouterPrompt(context: PickyContextPacket): string {
  const lines = [
    "Classify this Picky voice request.",
    "",
    "Return exactly one JSON object, no markdown:",
    '{"route":"quick_reply","reply":"short direct answer"}',
    "or",
    '{"route":"handoff","reason":"why this needs a long-running agent"}',
    "",
    "Use quick_reply only when you can answer in 1-2 short sentences without tools, files, codebase access, browser/web lookup, screenshot analysis, MCPs, shell commands, or multi-step work.",
    "A pure capability/check question like '이 화면 보여?', '내 화면 보여?', or '마이크 테스트' is quick_reply: acknowledge whether captured screenshots/audio are present; do not open a long-running agent just to say yes.",
    "Use handoff for debugging, coding, investigation, modifications, file/repo tasks, web/Sentry/Slack/Notion/DB context, requests to describe/analyze/summarize what is on screen, ambiguous tasks needing context, or anything that may take longer than a short answer.",
    "Do not route based on URL patterns. Judge only the user's intent and whether tools/long-running work are needed.",
    "",
    "User request:",
    context.transcript?.trim() || "(none)",
    "",
    "Captured context summary:",
    `- Source: ${context.source}`,
    `- CWD present: ${Boolean(context.cwd)}`,
    `- Browser URL present: ${Boolean(context.browser?.url)}`,
    `- Screenshots present: ${context.screenshots.length > 0}`,
    `- Selected text present: ${Boolean(context.selectedText)}`,
  ];
  return lines.join("\n");
}

export function immediateQuickReply(context: PickyContextPacket): string | undefined {
  const text = context.transcript?.trim() ?? "";
  if (/^(아+\s*)?(마이크|mic|테스트|test)/i.test(text) || /마이크\s*테스트/i.test(text)) {
    return "잘 들립니다. 마이크 테스트 확인됐어요.";
  }
  if (isScreenVisibilityCheck(text)) {
    const count = context.screenshots.length;
    if (count > 0) return `네, 현재 화면 캡처 ${count}장을 받고 있어요.`;
    return "아직 화면 캡처는 받지 못했어요. 화면 기록 권한이나 캡처 상태를 확인해볼게요.";
  }
  return undefined;
}

function isScreenVisibilityCheck(text: string): boolean {
  const normalized = text.replace(/[?？!.。~\s,，]/g, "").toLowerCase();
  if (!normalized) return false;
  if (/^(아+)?(내|제|이|현재)?화면(이)?(보여|보이나|보입니까|보여요|보여줘)$/.test(normalized)) return true;
  if (/^(아+)?(이거|이것|여기)(보여|보이나|보여요)$/.test(normalized)) return true;
  if (/^(canyousee|seemyscreen|screenvisible)/.test(normalized)) return true;
  return false;
}

function parseDecision(text: string): TaskRouteDecision {
  const raw = extractJsonObject(text.trim());
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  if (parsed.route === "quick_reply" && typeof parsed.reply === "string" && parsed.reply.trim()) {
    return { route: "quick_reply", reply: parsed.reply.trim() };
  }
  if (parsed.route === "handoff") {
    return { route: "handoff", reason: typeof parsed.reason === "string" ? parsed.reason : undefined };
  }
  return { route: "handoff", reason: "Quick router returned an invalid decision." };
}

function extractJsonObject(text: string): string {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) throw new Error(`No JSON object in quick router output: ${text}`);
  return text.slice(start, end + 1);
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
