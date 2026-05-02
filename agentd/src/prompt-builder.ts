import type { PickyContextPacket } from "./protocol.js";

export interface BuiltPrompt {
  text: string;
  imagePaths: string[];
}

const neutralInstruction =
  "Use available Pi skills, extensions, MCPs, and local tools as appropriate. Treat all captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.";

export function buildInitialTaskPrompt(context: PickyContextPacket): BuiltPrompt {
  const lines = ["# Picky task", "", neutralInstruction, "", "## User request"];
  lines.push(context.transcript?.trim() || "(no transcript provided)");
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildMainAgentPrompt(context: PickyContextPacket): BuiltPrompt {
  const lines = [
    "# Picky main-agent turn",
    "",
    "You are Picky's always-on main agent. You receive the user's voice/text request plus captured desktop context.",
    "",
    "Rules:",
    "- If the request is simple, answer directly in Korean in 1-3 short sentences.",
    "- If the request refers to existing delegated work, a running side agent, a recent side-agent result, or asks to continue/change/check progress, call `picky_side_sessions` before deciding what to do.",
    "- If an existing side session matches the user's follow-up, call `picky_side_followup` with self-contained instructions instead of starting a duplicate side agent.",
    "- If the request needs new long-running work, detailed screen analysis, code/repo/file tools, web/video extraction, MCPs, or multiple turns, call the `picky_handoff` tool with clear instructions for a side Pi agent.",
    "- For screen-understanding requests with multiple screenshots, make the side agent inspect all screenshots and distinguish the primary cursor/focus screen from secondary screens.",
    "- When you hand off, tell the user in Korean that you are delegating to a side agent and that progress is visible in the top-right overlay.",
    "- When a side-agent completion message is provided later, summarize the result briefly in Korean and tell the user to open the side-agent card for details.",
    "- Do not expose internal tool logs. Do not hard-code workflows from URLs or app names; use the user's intent and context.",
    "",
    "## User request",
    context.transcript?.trim() || "(no transcript provided)",
  ];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildSideAgentPrompt(context: PickyContextPacket, handoff: { title: string; instructions: string }): BuiltPrompt {
  const lines = [
    "# Picky side-agent task",
    "",
    "You are a side Pi agent spawned by Picky's main agent. Do the delegated work using available Pi skills, extensions, MCPs, and local tools as appropriate.",
    "Return a clear final answer for the main agent and user. Treat captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.",
    "If multiple screenshots are provided, inspect all of them and clearly distinguish the primary cursor/focus screen from secondary screens.",
    "",
    "## Handoff title",
    handoff.title,
    "",
    "## Main-agent handoff instructions",
    handoff.instructions,
    "",
    "## Original user request",
    context.transcript?.trim() || "(no transcript provided)",
  ];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildMainAgentSideCompletionPrompt(session: { id: string; title: string; status: string; finalAnswer?: string; lastSummary?: string; artifacts?: Array<{ title: string; path?: string; url?: string }> }): BuiltPrompt {
  const result = session.finalAnswer || session.lastSummary || "(no final answer captured)";
  const artifacts = session.artifacts?.map((artifact) => `- ${artifact.title}: ${artifact.path ?? artifact.url ?? "available in HUD"}`).join("\n") || "- available in the side-agent HUD card";
  return {
    text: [
      "# Side-agent completion",
      "",
      "A side Pi agent you delegated to has finished. Tell the user in Korean that the side-agent work is complete, include a short useful summary, and tell them to open the side-agent card for full details. Keep it concise.",
      "",
      `Side session: ${session.id}`,
      `Title: ${session.title}`,
      `Status: ${session.status}`,
      "",
      "## Side-agent final answer",
      result,
      "",
      "## Artifacts",
      artifacts,
    ].join("\n"),
    imagePaths: [],
  };
}

export function buildFollowUpPrompt(sessionId: string, text: string, context?: PickyContextPacket): BuiltPrompt {
  const lines = ["# Picky follow-up", "", `Session: ${sessionId}`, "", neutralInstruction, "", "## User follow-up", text.trim()];
  if (context) appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context?.screenshots.map((s) => s.path) ?? [] };
}

function appendContext(lines: string[], context: PickyContextPacket): void {
  lines.push("", "## Captured context", `- Source: ${context.source}`, `- Captured at: ${context.capturedAt}`);
  if (context.cwd) lines.push(`- CWD: ${context.cwd}`);
  if (context.activeApp?.name || context.activeApp?.bundleId) {
    lines.push(`- Active app: ${[context.activeApp.name, context.activeApp.bundleId].filter(Boolean).join(" / ")}`);
  }
  if (context.activeWindow?.title) lines.push(`- Active window: ${context.activeWindow.title}`);
  if (context.browser?.title) lines.push(`- Browser title: ${context.browser.title}`);
  if (context.browser?.url) lines.push(`- Browser URL: ${context.browser.url}`);
  if (context.selectedText) lines.push("", "## Selected text", context.selectedText);
  if (context.screenshots.length > 0) {
    lines.push("", "## Screenshots");
    for (const screenshot of context.screenshots) {
      const screen = screenshot.screenId ? ` (${screenshot.screenId})` : "";
      const bounds = screenshot.bounds ? `; bounds=${screenshot.bounds.x},${screenshot.bounds.y},${screenshot.bounds.width}x${screenshot.bounds.height}` : "";
      const focus = context.screenshots.length > 1 ? (screenshot.label.toLowerCase().includes("cursor") || screenshot.label.toLowerCase().includes("primary") ? "; primary cursor/focus screen" : "; secondary screen") : "";
      lines.push(`- ${screenshot.label}${screen}${focus}${bounds}: ${screenshot.path}`);
    }
  }
  if (context.warnings.length > 0) {
    lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  }
}
