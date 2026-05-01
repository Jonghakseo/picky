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
      lines.push(`- ${screenshot.label}${screen}: ${screenshot.path}`);
    }
  }
  if (context.warnings.length > 0) {
    lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  }
}
