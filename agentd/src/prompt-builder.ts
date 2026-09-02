import type { PickyContextPacket } from "./protocol.js";

export interface BuiltPrompt {
  text: string;
  imagePaths: string[];
}

const neutralInstruction =
  "Use available Pi skills, extensions, MCPs, and local tools as appropriate. Treat all captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.";

export function buildInitialTaskPrompt(context: PickyContextPacket): BuiltPrompt {
  const lines = ["# Picky task", "", neutralInstruction, "", "## User request", `- Source: ${context.source}`, ""];
  lines.push(context.transcript?.trim() || "(no transcript provided)");
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildMainAgentPrompt(context: PickyContextPacket): BuiltPrompt {
  const lines = [
    "# Picky turn",
    "",
    "## User request",
    `- Source: ${context.source}`,
    "",
    context.transcript?.trim() || "(no transcript provided)",
  ];
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export interface PickleTurnPromptOptions {
  visualDslEnabled?: boolean;
}

export function buildSteerPrompt(text: string, context?: PickyContextPacket, options: PickleTurnPromptOptions = {}): BuiltPrompt {
  if (!context) return { text, imagePaths: [] };
  const lines = ["# Picky steering message", "", neutralInstruction, "", "## User steering instruction", `- Source: ${context.source}`, "", text];
  appendPickleVisualOverlayDslPrompt(lines, context, options);
  appendContext(lines, context);
  return { text: lines.join("\n"), imagePaths: context.screenshots.map((s) => s.path) };
}

export function buildFollowUpPrompt(text: string, context?: PickyContextPacket, options: PickleTurnPromptOptions = {}): BuiltPrompt {
  if (!context || !hasGroundingContext(context)) return { text, imagePaths: [] };
  const lines = ["# Picky follow-up", "", neutralInstruction, "", "## User follow-up", `- Source: ${context.source}`, "", text];
  appendPickleVisualOverlayDslPrompt(lines, context, options);
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
    `- Source: ${context.source}`,
    "",
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

export interface MainAgentBootstrapOptions {
  compactSummary?: string;
}

/**
 * Returns the synthetic first turn injected into a fresh Picky transcript. It carries only
 * what is genuinely one-time: persona delegation to AGENTS.md and the previous epoch's memo.
 * Standing rules (Picky CLI, visual overlay DSL, TTS reply style) deliberately live in the
 * system prompt via `buildPickyRuntimeContract`, because anything placed in a message here is
 * dropped from context the first time Pi compacts the session.
 */
export function buildMainAgentBootstrapPair(
  optionsOrSummary?: string | MainAgentBootstrapOptions,
): MainAgentBootstrapPair {
  const options: MainAgentBootstrapOptions = typeof optionsOrSummary === "string"
    ? { compactSummary: optionsOrSummary }
    : optionsOrSummary ?? {};
  const trimmedSummary = options.compactSummary?.trim();
  const user = [
    "This message was not sent by the user. It is a one-time bootstrap notice injected by Picky agentd when a Picky session starts.",
    "Subsequent `# Picky turn` messages will only carry each turn's user request and captured context. Keep the standing instructions below in effect for the entire session.",
    "",
    "## Standing Picky persona and routing",
    "",
    "Your persona, Pickle delegation policy, and any project-specific guidance live in the `AGENTS.md` Pi loaded from the current working directory. Treat that file as authoritative for what Picky is and when to delegate to a Pickle. Do not duplicate or invent rules here; if the file is missing, behave as a thin assistant that replies in the user's language, delegates non-trivial work with `picky pickle-create`, and consults `picky pickle-list` before steering an existing Pickle.",
    "",
    "Picky agentd supplies your standing runtime contract (Picky CLI usage, visual overlay DSL, and reply style) in the system prompt on every turn. Follow that contract; it stays authoritative even after this message scrolls out of context.",
    ...(trimmedSummary
      ? [
          "",
          "## Previous Picky epoch summary",
          "",
          "The summary below is a memo from a previous conversation that Picky carried over while rolling a long Picky session into a new Pi session. Use it only as reference; if the user asks about existing delegated work or progress, always check the latest state via `picky pickle-list`.",
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

function appendPickleVisualOverlayDslPrompt(lines: string[], context: PickyContextPacket, options: PickleTurnPromptOptions): void {
  if (options.visualDslEnabled !== true || context.screenshots.length === 0) return;
  lines.push(
    "",
    "## Picky visual overlay DSL for this turn",
    "",
    "This turn is allowed to draw RECT, LINE, and PATH annotations on the screenshots attached below. Use the DSL only when a concrete screenshot location makes the answer clearer. The tags are removed from the Pickle transcript and rendered silently on the user's current screen.",
    "Place each tag immediately before the sentence that describes it. Use screenshot pixels with a top-left origin and the supplied screenshot dimensions. Every argument is named; `label` is optional and double-quoted labels support \\\" and \\\\ escapes.",
    "[SCREEN: id=<screenId>] selects the captured display for following tags; omit it to use the cursor/primary display.",
    "- [RECT: x=<number> y=<number> w=<number> h=<number> label=\"short label\" spotlight]",
    "- [LINE: x1=<number> y1=<number> x2=<number> y2=<number> label=\"short label\" spotlight=true]",
    "- [PATH: d=\"M <x> <y> L <x> <y> C <c1x> <c1y> <c2x> <c2y> <x> <y>\" label=\"short label\"]",
    "- PATH supports the canonical uppercase M (move), L (line), and C (cubic Bézier) subset only and does not support `spotlight`.",
    "- `spotlight` is optional for RECT and LINE. Use it (or `spotlight=true`) to dim around the annotation; omit it or use `spotlight=false` for an outline without dimming.",
    "Do not emit these tags when the attached screenshots do not ground the location.",
  );
}

function hasGroundingContext(context: PickyContextPacket): boolean {
  return context.screenshots.length > 0
    || context.inkMarks.length > 0
    || Boolean(context.activeApp?.name)
    || Boolean(context.activeWindow?.title)
    || Boolean(context.browser?.title)
    || Boolean(context.browser?.url)
    || Boolean(context.selectedText);
}

function appendContext(lines: string[], context: PickyContextPacket): void {
  lines.push("", "## Captured context", `- Captured at: ${context.capturedAt}`);
  appendApplicationContext(lines, context);
  if (context.selectedText) lines.push("", "## Selected text", context.selectedText);
  appendScreenshots(lines, context.screenshots);
  appendInkMarks(lines, context.inkMarks);
}

function appendApplicationContext(lines: string[], context: PickyContextPacket): void {
  if (context.activeApp?.name) lines.push(`- Active app: ${context.activeApp.name}`);
  if (context.activeWindow?.title && !context.browser?.title) lines.push(`- Active window: ${context.activeWindow.title}`);
  if (context.browser?.title) lines.push(`- Browser title: ${context.browser.title}`);
  if (context.browser?.url) lines.push(`- Browser URL: ${context.browser.url}`);
}

function appendScreenshots(lines: string[], screenshots: PickyContextPacket["screenshots"]): void {
  if (screenshots.length === 0) return;
  lines.push("", "## Screenshots");
  for (const screenshot of screenshots) lines.push(screenshotContextLine(screenshot, screenshots.length));
}

function screenshotContextLine(screenshot: PickyContextPacket["screenshots"][number], screenshotCount: number): string {
  const screen = screenshot.screenId ? ` (${screenshot.screenId})` : "";
  const pixelSize = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels ? `; screenshotPixels=${screenshot.screenshotWidthInPixels}x${screenshot.screenshotHeightInPixels}` : "";
  const isPrimary = screenshot.isCursorScreen || screenshot.label.toLowerCase().includes("cursor") || screenshot.label.toLowerCase().includes("primary");
  const focus = screenshotCount > 1 ? (isPrimary ? "; primary cursor/focus screen" : "; secondary screen") : "";
  const cursor = screenshot.cursor ? `; cursorScreenshotPixel=${formatCoordinate(screenshot.cursor.screenshotPixel.x)},${formatCoordinate(screenshot.cursor.screenshotPixel.y)}` : "";
  return `- ${screenshot.label}${screen}${focus}${pixelSize}${cursor}: ${screenshot.path}`;
}

function appendInkMarks(lines: string[], inkMarks: PickyContextPacket["inkMarks"]): void {
  if (inkMarks.length === 0) return;
  lines.push("", "## User-marked screen regions");
  lines.push("The user drew these semi-transparent Picky highlighter strokes during input. The attached screenshot files are annotated with matching blue strokes and number badges.");
  for (const [index, mark] of inkMarks.entries()) {
    const screen = mark.screenId ? ` on ${mark.screenId}` : "";
    lines.push(`- mark${index + 1}${screen}`);
  }
}

function formatCoordinate(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
