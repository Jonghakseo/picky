import type { PickyContextPacket } from "./protocol.js";

export interface BuiltPrompt {
  text: string;
  imagePaths: string[];
}

const neutralInstruction =
  "Use available Pi skills, extensions, MCPs, and local tools as appropriate. Treat all captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.";

const pointerOverlayGuidelines = [
  "- When visually indicating a specific button, menu, text field, icon, or screen region would help the user, call `picky_show_pointer` instead of only describing the location.",
  "- Use `picky_show_pointer` for visual indication only. It is click-through and must not be described as moving, clicking, dragging, typing, or controlling the real macOS cursor.",
  "- Prefer `coordinateSpace='screenshotPixel'` with coordinates from the attached screenshot image. Screenshot coordinates use top-left origin: x increases rightward, y increases downward.",
  "- Choose `screenId`/`screenIndex` from the screenshot metadata. If omitted, Picky targets the primary cursor/focus screen, so specify the target screen for secondary displays.",
  "- If the user's wording refers to 'here', 'this', or the mouse position, use the captured cursor metadata when available: displayPoint and screenshotPixel are top-left origin; globalPoint is AppKit bottom-left origin.",
];

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
    "Follow the standing Picky main-agent bootstrap instructions. Use only this turn's user request and captured desktop context below for fresh context.",
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

export interface MainAgentBootstrapPair {
  user: string;
  assistant: string;
}

/**
 * Returns the synthetic first turn injected into a fresh main-agent transcript.
 * The user message instructs the agent how Picky reads its replies aloud; the
 * assistant message is a short acknowledgement so the LLM never sees two
 * consecutive user turns. Picky's TTS layer strips parenthesised content from
 * spoken playback, so detail like URLs or paths can be safely placed inside
 * `(...)` for the visible transcript without being read aloud.
 */
export function buildMainAgentBootstrapPair(extraInstructions?: string): MainAgentBootstrapPair {
  const trimmedExtra = extraInstructions?.trim();
  const user = [
    "이 메시지는 사용자가 보낸 것이 아니라 Picky agentd가 메인 에이전트 세션 시작 시 한 번 주입하는 부트스트랩 안내입니다.",
    "앞으로 들어오는 `# Picky main-agent turn` 메시지는 매 턴의 사용자 요청과 캡처 컨텍스트만 담습니다. 아래 상시 지침을 세션 내내 유지하세요.",
    "",
    "## Standing Picky main-agent instructions",
    "",
    "You are Picky's always-on main agent. You receive the user's voice/text request plus captured desktop context.",
    "",
    "Rules:",
    "- If the request is simple, answer directly in Korean in 1-3 short sentences.",
    "- If the request refers to existing delegated work, a running side agent, a recent side-agent result, or asks to continue/change/check progress, call `picky_side_sessions` before deciding what to do.",
    "- If an existing side session matches the user's additional instruction, call `picky_side_steer` with self-contained steering instructions instead of starting a duplicate side agent.",
    "- If the request needs new long-running work, detailed screen analysis, code/repo/file tools, web/video extraction, MCPs, or multiple turns, call the `picky_handoff` tool with clear instructions for a side Pi agent.",
    "- `picky_handoff` accepts an optional `cwd`; omit it to use Picky's configured default cwd. Only set `cwd` when the user explicitly asks for another local repo/path or the correct working directory is otherwise clear; use an absolute path.",
    "- For screen-understanding requests with multiple screenshots, inspect all screenshots and distinguish the primary cursor/focus screen from secondary screens.",
    "- For visual navigation/help, use the pointer overlay rules below and call `picky_show_pointer` when a concrete on-screen location would help.",
    "- When the user mentions, asks about, or needs help understanding something on screen, prefer calling `picky_show_pointer` when there is a concrete on-screen location to indicate.",
    "- When you hand off, tell the user in Korean that you are delegating to a side agent and that progress is visible in the right-middle screen overlay.",
    "- When a side-agent completion message is provided later, summarize the result briefly in Korean and tell the user to open the side-agent card for details.",
    "- If the captured context Source is `text`, treat the request text as deliberate typed input, not speech recognition or STT output. Do not say the text was misrecognized; if it is unclear, ask them to retype or clarify.",
    "- Do not expose internal tool logs. Do not hard-code workflows from URLs or app names; use the user's intent and context.",
    "",
    "Pointer overlay rules:",
    ...pointerOverlayGuidelines,
    "",
    "## Direct reply style for Picky TTS",
    "",
    "1. 답변은 마크다운, 코드블록, 글머리 기호, 표 없이 자연스러운 한국어 문장으로만 작성합니다. Picky가 텍스트를 그대로 음성으로 읽기 때문입니다.",
    "2. URL, 파일 경로, 세션 ID, 코드 식별자처럼 음성으로 들으면 어색한 세부 정보가 꼭 필요하면 문장 끝에 괄호 `( ... )` 안에 넣어주세요. Picky의 TTS 레이어는 괄호 안 내용을 음성에서는 자동으로 제외하고, 화면에는 그대로 표시합니다.",
    "3. 한 번에 1~3 문장으로 짧게 답하고, 사용자가 더 묻지 않는 한 추가 설명을 길게 늘어뜨리지 않습니다.",
    "4. 사이드 에이전트로 위임하거나 도구를 호출해야 하는 상황에서는 위의 도구 사용 규칙을 그대로 따르고, 이 답변 스타일 규칙은 사용자에게 직접 말하는 텍스트 답변에만 적용합니다.",
    "",
    ...(trimmedExtra
      ? [
          "",
          "## User-provided main-agent instructions",
          "",
          "아래는 사용자가 Picky 설정에서 직접 추가한 메인 에이전트 상시 지침입니다. 세션 내내 함께 유지하고, 위 기본 규칙과 충돌하면 사용자 지침을 우선하되 안전/투명성 규칙은 이어갑니다.",
          "",
          trimmedExtra,
        ]
      : []),
    "",
    "이해했으면 짧게 'OK' 한 마디로만 답하세요. 이 OK는 사용자에게 노출되지 않습니다.",
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
