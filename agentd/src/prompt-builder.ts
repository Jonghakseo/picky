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
    `Input modality: ${inputModalityLabel(context.source)}`,
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
      "A Pickle you delegated to has finished. Tell the user in Korean that the Pickle work is complete, include a short useful summary, and tell them to open the Pickle card for full details. Keep it concise.",
      "",
      `Pickle session: ${session.id}`,
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

export interface MainAgentBootstrapPair {
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
export function buildMainAgentBootstrapPair(extraInstructions?: string, compactSummary?: string): MainAgentBootstrapPair {
  const trimmedExtra = extraInstructions?.trim();
  const trimmedSummary = compactSummary?.trim();
  const user = [
    "This message was not sent by the user. It is a one-time bootstrap notice injected by Picky agentd when a Picky session starts.",
    "Subsequent `# Picky turn` messages will only carry each turn's user request and captured context. Keep the standing instructions below in effect for the entire session.",
    "",
    "## Standing Picky instructions",
    "",
    "You are Picky, the always-on assistant. You receive the user's voice/text request plus captured desktop context.",
    "",
    "Rules:",
    "- If the request is simple, answer directly in Korean in 1-3 short sentences.",
    "- If the request refers to existing delegated work, a running Pickle, a recent Pickle result, or asks to continue/change/check progress, call `picky_pickle_sessions` before deciding what to do.",
    "- If an existing Pickle session matches the user's additional instruction, call `picky_steer_pickle` instead of starting a duplicate Pickle. Keep the steer message delta-only: the new instruction plus essential references, not a restatement of the whole task or prior logs.",
    "- If the request needs new long-running work, detailed screen analysis, code/repo/file tools, web/video extraction, MCPs, or multiple turns, call the `picky_start_pickle` tool with clear instructions for a Pickle Pi agent.",
    "- Keep `picky_start_pickle.instructions` compact and action-oriented, ideally about 300 Korean characters: goal, essential constraints, known decisions, key paths/URLs/IDs, and expected output. Do not paste the full current prompt, captured context, screenshot metadata, prior transcript, or tool logs.",
    "- `picky_start_pickle` accepts an optional `cwd`; omit it to use Picky's configured Pickle default cwd. Only set `cwd` when the user explicitly asks for another local repo/path or the correct working directory is otherwise clear; use an absolute path.",
    "- For screen-understanding requests with multiple screenshots, inspect all screenshots and distinguish the primary cursor/focus screen from secondary screens.",
    "- When you hand off, tell the user in Korean that you are delegating to a Pickle and that progress can be checked in the Picky dock.",
    "- When a Pickle completion message is provided later, summarize the result briefly in Korean and tell the user to open the Pickle card for details.",
    "- If the captured context Source is `text`, treat the request text as deliberate typed input, not speech recognition or STT output. Do not say the text was misrecognized; if it is unclear, ask them to retype or clarify.",
    "- Do not expose internal tool logs. Do not hard-code workflows from URLs or app names; use the user's intent and context.",
    "",
    "## Direct reply style for Picky TTS",
    "",
    "1. Write replies as natural user's language sentences only, with no markdown, code blocks, bullet points, or tables, because Picky reads the text aloud as-is.",
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
    ...(trimmedExtra
      ? [
          "",
          "## User-provided Picky instructions",
          "",
          "The following are standing Picky instructions the user added directly in Picky settings. Keep them in effect throughout the session; if they conflict with the base rules above, prefer the user's instructions while still honouring the safety and transparency rules.",
          "",
          trimmedExtra,
        ]
      : []),
    "",
    "If you understand, reply with just a short 'OK'. This OK is not shown to the user.",
  ].join("\n");
  const assistant = "OK";
  return { user, assistant };
}

function inputModalityLabel(source: PickyContextPacket["source"]): string {
  switch (source) {
    case "text":
    case "text-follow-up":
      return "typed text";
    case "voice":
    case "voice-follow-up":
      return "voice transcription";
    case "system":
      return "system event";
  }
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
      const pixelSize = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels ? `; screenshotPixels=${screenshot.screenshotWidthInPixels}x${screenshot.screenshotHeightInPixels}` : "";
      const focus = context.screenshots.length > 1 ? (screenshot.isCursorScreen || screenshot.label.toLowerCase().includes("cursor") || screenshot.label.toLowerCase().includes("primary") ? "; primary cursor/focus screen" : "; secondary screen") : "";
      const cursor = screenshot.cursor ? `; cursorDisplayPoint=${formatPoint(screenshot.cursor.displayPoint)}; cursorScreenshotPixel=${formatPoint(screenshot.cursor.screenshotPixel)}; cursorGlobalAppKit=${formatPoint(screenshot.cursor.globalPoint)}` : "";
      lines.push(`- ${screenshot.label}${screen}${focus}${bounds}${pixelSize}${cursor}: ${screenshot.path}`);
    }
  }
  if (context.inkMarks.length > 0) {
    lines.push("", "## User-marked screen regions");
    lines.push("The user drew these semi-transparent Picky highlighter strokes during input. The attached screenshot files are annotated with matching blue strokes and number badges.");
    for (const [index, mark] of context.inkMarks.entries()) {
      const screen = mark.screenId ? ` on ${mark.screenId}` : "";
      const bounds = `${formatCoordinate(mark.bounds.x)},${formatCoordinate(mark.bounds.y)},${formatCoordinate(mark.bounds.width)}x${formatCoordinate(mark.bounds.height)}`;
      const samplePoints = mark.points.slice(0, 8).map(formatPoint).join(" -> ");
      const suffix = mark.points.length > 8 ? ` -> … (${mark.points.length} points)` : ` (${mark.points.length} points)`;
      lines.push(`- mark${index + 1}${screen}: ${mark.kind}; bbox=${bounds}; strokeWidth=${formatCoordinate(mark.strokeWidth)}; opacity=${formatCoordinate(mark.opacity)}; points=${samplePoints}${suffix}`);
    }
  }
  if (context.warnings.length > 0) {
    lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  }
}

function formatPoint(point: { x: number; y: number }): string {
  return `${formatCoordinate(point.x)},${formatCoordinate(point.y)}`;
}

function formatCoordinate(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
