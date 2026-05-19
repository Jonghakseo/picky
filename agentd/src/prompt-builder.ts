import { PICKLE_TOOL_NAMES } from "./application/picky-tool-names.js";
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
    "# Picky turn",
    "",
    "Follow the standing Picky bootstrap instructions. Use only this turn's user request and captured desktop context below for fresh context.",
    "",
    "## User request",
    context.transcript?.trim() || "(no transcript provided)",
  ];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildSteerPrompt(text: string, context?: PickyContextPacket): BuiltPrompt {
  if (!context) return { text, imagePaths: [] };
  const lines = ["# Picky steering message", "", neutralInstruction, "", "## User steering instruction", text];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildFollowUpPrompt(text: string, context?: PickyContextPacket): BuiltPrompt {
  if (!context || !hasVisualAttachmentContext(context)) return { text, imagePaths: [] };
  const lines = ["# Picky follow-up", "", neutralInstruction, "", "## User follow-up", text];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildPicklePrompt(context: PickyContextPacket, handoff: { title: string; instructions: string }): BuiltPrompt {
  const lines = [
    "# Picky Pickle task",
    "",
    "## Handoff title",
    handoff.title,
    "",
    "You are Pickle, a delegated Pi agent spawned by Picky. Do the delegated work using available Pi skills, extensions, MCPs, and local tools as appropriate.",
    "Return a clear final answer for Picky and the user. Treat captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.",
    "If multiple screenshots are provided, inspect all of them and clearly distinguish the primary cursor/focus screen from secondary screens.",
    "",
    "## Picky handoff instructions",
    handoff.instructions,
    "",
    "## Original user request",
    context.transcript?.trim() || "(no transcript provided)",
  ];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildMainAgentPickleCompletionPrompt(session: { id: string; title: string; status: string; finalAnswer?: string; lastSummary?: string; artifacts?: Array<{ title: string; path?: string; url?: string }> }): BuiltPrompt {
  const result = session.finalAnswer || session.lastSummary || "(no final answer captured)";
  const artifacts = session.artifacts?.map((artifact) => `- ${artifact.title}: ${artifact.path ?? artifact.url ?? "available in the Picky dock"}`).join("\n") || "- available in the Pickle card";
  return {
    text: [
      "# Pickle completion",
      "",
      "A Pickle you delegated to has finished. Tell the user in the user's language that the Pickle work is complete, include a short useful summary, and tell them to open the Pickle card for full details.",
      "Picky may read this reply aloud, so keep the spoken portion to 1-2 short sentences (status + one-line takeaway). Refer the user to the Pickle card for any longer detail rather than reciting it verbatim.",
      "",
      `Title: ${session.title}`,
      `Status: ${session.status}`,
      "",
      "## Pickle final answer",
      result,
      "",
      "## Artifacts",
      artifacts,
    ].join("\n"),
    imagePaths: [],
  };
}

interface MainAgentBootstrapPair {
  user: string;
  assistant: string;
}

/**
 * Returns the synthetic first turn injected into a fresh Picky transcript.
 * The user message instructs the agent how Picky reads its replies aloud; the
 * assistant message is a short acknowledgement so the LLM never sees two
 * consecutive user turns. Picky's TTS layer strips parenthesised content from
 * spoken playback, so detail like URLs or paths can be safely placed inside
 * `(...)` for the visible transcript without being read aloud.
 */
export function buildMainAgentBootstrapPair(compactSummary?: string): MainAgentBootstrapPair {
  const trimmedSummary = compactSummary?.trim();
  const user = [
    "This message was not sent by the user. It is a one-time bootstrap notice injected by Picky agentd when a Picky session starts.",
    "Subsequent `# Picky turn` messages will only carry each turn's user request and captured context. Keep the standing instructions below in effect for the entire session.",
    "",
    "## Standing Picky persona and routing",
    "",
    `Your persona, Pickle delegation policy, and any project-specific guidance live in the \`AGENTS.md\` Pi loaded from the current working directory. Treat that file as authoritative for what Picky is and when to delegate to a Pickle. Do not duplicate or invent rules here; if the file is missing, behave as a thin assistant that replies in the user's language, delegates non-trivial work to a Pickle via \`${PICKLE_TOOL_NAMES.start}\`, and consults \`${PICKLE_TOOL_NAMES.sessions}\` before reusing or steering an existing Pickle.`,
    "",
    "## Picky-specific runtime facts",
    "",
    `- Available delegation tools: \`${PICKLE_TOOL_NAMES.start}\`, \`${PICKLE_TOOL_NAMES.sessions}\`, \`${PICKLE_TOOL_NAMES.steer}\`, \`${PICKLE_TOOL_NAMES.abort}\`. Only the picky_* tools surface Pickles in the Picky dock; never simulate them with bash or by editing session files.`,
    `- \`${PICKLE_TOOL_NAMES.abort}\` only runs when the user explicitly asks to stop, cancel, or kill a Pickle; resolve the target with \`${PICKLE_TOOL_NAMES.sessions}\` first.`,
    `- Pickle hover follow-ups bypass you and go directly to a Pickle. If the user references a specific running Pickle, prefer \`${PICKLE_TOOL_NAMES.steer}\` after \`${PICKLE_TOOL_NAMES.sessions}\`.`,
    "- If the captured context Source is `text`, treat the request text as deliberate typed input, not speech recognition output.",
    "- Do not expose internal tool logs verbatim and do not hard-code workflows from URLs or app names.",
    "",
    "## Direct reply style for Picky TTS",
    "",
    "1. Write replies as natural sentences in the user's language only, with no markdown, code blocks, bullet points, or tables, because Picky reads the text aloud as-is.",
    "2. If awkward-to-hear details like URLs, file paths, session IDs, or code identifiers are necessary, place them inside parentheses `( ... )` at the end of the sentence. Picky's TTS layer automatically skips parenthesised content during playback while still showing it on screen.",
    "3. Reply concisely in 1-3 short sentences at a time, and do not stretch into longer explanations unless the user asks for more.",
    "4. When delegating to a Pickle or calling a tool, follow the tool-use rules above as-is; apply this reply style only to the text answer that goes directly to the user.",
    "",
    ...(trimmedSummary
      ? [
          "",
          "## Previous Picky epoch summary",
          "",
          "The summary below is a memo from a previous conversation that Picky carried over while rolling a long Picky session into a new Pi session. Use it only as reference; if the user asks about existing delegated work or progress, always check the latest state via picky_pickle_sessions.",
          "",
          trimmedSummary,
        ]
      : []),
    "",
    "If you understand, reply with just a short 'OK'. This OK is not shown to the user.",
  ].join("\n");
  const assistant = "OK";
  return { user, assistant };
}

function hasVisualAttachmentContext(context: PickyContextPacket): boolean {
  return context.screenshots.length > 0 || context.inkMarks.length > 0;
}

function appendContext(lines: string[], context: PickyContextPacket): void {
  lines.push("", "## Captured context", `- Source: ${context.source}`, `- Captured at: ${context.capturedAt}`);
  if (context.cwd) lines.push(`- CWD: ${context.cwd}`);
  if (context.activeApp?.name) lines.push(`- Active app: ${context.activeApp.name}`);
  if (context.activeWindow?.title) lines.push(`- Active window: ${context.activeWindow.title}`);
  if (context.browser?.title) lines.push(`- Browser title: ${context.browser.title}`);
  if (context.browser?.url) lines.push(`- Browser URL: ${context.browser.url}`);
  if (context.selectedText) lines.push("", "## Selected text", context.selectedText);
  if (context.screenshots.length > 0) {
    lines.push("", "## Screenshots");
    for (const screenshot of context.screenshots) {
      const screen = screenshot.screenId ? ` (${screenshot.screenId})` : "";
      const pixelSize = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels ? `; screenshotPixels=${screenshot.screenshotWidthInPixels}x${screenshot.screenshotHeightInPixels}` : "";
      const focus = context.screenshots.length > 1 ? (screenshot.isCursorScreen || screenshot.label.toLowerCase().includes("cursor") || screenshot.label.toLowerCase().includes("primary") ? "; primary cursor/focus screen" : "; secondary screen") : "";
      const cursor = screenshot.cursor ? `; cursorScreenshotPixel=${formatCoordinate(screenshot.cursor.screenshotPixel.x)},${formatCoordinate(screenshot.cursor.screenshotPixel.y)}` : "";
      lines.push(`- ${screenshot.label}${screen}${focus}${pixelSize}${cursor}: ${screenshot.path}`);
    }
  }
  if (context.inkMarks.length > 0) {
    lines.push("", "## User-marked screen regions");
    lines.push("The user drew these semi-transparent Picky highlighter strokes during input. The attached screenshot files are annotated with matching blue strokes and number badges.");
    for (const [index, mark] of context.inkMarks.entries()) {
      const screen = mark.screenId ? ` on ${mark.screenId}` : "";
      lines.push(`- mark${index + 1}${screen}`);
    }
  }
  if (context.warnings.length > 0) {
    lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  }
}

function formatCoordinate(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
