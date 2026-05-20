// All model-facing prompt strings for the OpenAI Realtime main runtime.
// Extracted from `openai-realtime-main-runtime.ts` so reviewers can read the
// instructions, context envelope, tool descriptions, and transcription prompt
// in one place without scrolling through runtime/session machinery.
//
// Contents:
//   1. PICKY_TRANSCRIPTION_PROMPT - input audio transcription prompt
//   2. buildRealtimeInstructions  - top-level session.instructions
//   3. buildRealtimeContextText   - per-turn captured-context envelope
//   4. realtimeTools              - function-tool schemas + descriptions
//
// Nothing here owns runtime state. Keep prompt logic pure and side-effect free
// so it stays diffable.

import { buildMainAgentBootstrapPair } from "../prompt-builder.js";
import type { PickyContextPacket } from "../protocol.js";
import { PICKY_USER_GUIDE_SECTIONS } from "../application/user-guide-tool.js";
import type { MainRealtimeHistoryMessage, MainRealtimeUserMemoryItem } from "./types.js";

// Per-line truncation budget for instruction-level history rendering. Long
// monologues would otherwise blow the session.update payload past a comfortable
// size when the agent gets chatty.
const MAIN_REALTIME_HISTORY_INSTRUCTIONS_LINE_LIMIT = 400;

// ---------------------------------------------------------------------------
// 1. Input audio transcription prompt (OpenAI Realtime input_audio_transcription)
// ---------------------------------------------------------------------------
export const PICKY_TRANSCRIPTION_PROMPT = [
  "This audio is a voice command for controlling the Picky macOS app. Users may speak in any language or mix languages, including English, Korean, Japanese, Chinese, Spanish, and developer jargon.",
  "Transcribe in the original spoken language. Do not translate, summarize, or rewrite the speech.",
  "Preserve product names and developer terms exactly in Latin characters when the context fits.",
  "Picky is the app name and may be pronounced in many ways, including Picky, Picky-ya, 피키, or ピッキー. If it sounds like Bicky, Vicky, Mickey, 비키, or 미키, transcribe it as Picky when the context fits.",
  "Pickle is the name for a task session inside Picky and may be pronounced like 피클 or ピックル. Pi is the local coding agent name and may sound like pie, 파이, or パイ.",
  "Key terms: Picky, Pickle, Pi, HUD, dock, agentd, repo, branch, cwd, Codex, SwiftUI, Xcode, Vercel, Next.js, localhost.",
].join("\n");

// ---------------------------------------------------------------------------
// 2. session.instructions - top-level system prompt for Realtime main
// ---------------------------------------------------------------------------
export function buildRealtimeInstructions(
  userMemories: MainRealtimeUserMemoryItem[] = [],
  recentHistory: MainRealtimeHistoryMessage[] = [],
): string {
  const baseLines = [
    buildMainAgentBootstrapPair({ omitTtsParenthesisHint: true }).user,
    "",
    "## Realtime voice mode overrides",
    "- You are speaking directly to the user. Keep spoken replies concise, natural, and in the user's language.",
    "- Never speak or emit [POINT:...] tags. Realtime main has no pointing tool; describe UI locations verbally when needed.",
    `- Use \`read_picky_user_guide\` before answering questions about how to use Picky. Prefer its \`section\` parameter when the question maps to one of these manual sections: ${PICKY_USER_GUIDE_SECTIONS.join("; ")}.`,
    "- You cannot execute Pi skills directly. If the user names a Pi skill that is relevant, include the skill name and the essential details in `picky_start_pickle.instructions` or `picky_steer_pickle.message` for the Pickle to follow.",
    "- Pickle hover follow-ups bypass you and go directly to the Pickle. If the user refers to delegated work during a Picky turn, call `picky_pickle_sessions` before deciding whether to use `picky_steer_pickle`. To check progress on one specific Pickle without spawning another, call `picky_inspect_active_pickle`. To stop a Pickle when the user explicitly asks (\"멈춰\", \"cancel that\"), call `picky_abort_pickle`.",
    "- To find an archived Pickle the user wants to revisit (\"그거 다시 살려\", \"the one I archived\"), call `picky_pickle_sessions({ includeArchive: true })` first to locate it, then `picky_unarchive_pickle` to restore its dock card. The archived flag is the only thing flipped — once it's back on the dock, use `picky_steer_pickle` to continue (if status is still running) or `picky_start_pickle` to spawn a fresh Pickle when the previous one was completed/cancelled.",
    "- When the user references an earlier turn's page, screen, selection, or file (\"방금 그 페이지\", \"5분 전\", \"the PR you saw\"), or when a stored memory rule depends on the current browser/cwd, call `picky_recall_recent_context` first. The single \"captured context\" you saw at the start of THIS turn is gone by the next one; that tool is how you look further back.",
    "",
    "## Filesystem / shell tools (one-shot only)",
    "- `picky_read_file` / `picky_run_bash` / `picky_write_file` are for SHORT, low-latency 1-shot ops (e.g. `git status`, peek at one config line, write a one-line patch). Outputs are hard-capped at ~2 KB; the rest is auto-summarized by a small model — useful, but lossy.",
    "- DO NOT loop these tools. If answering would need 3+ calls (recursive grep, multi-file inspection, repeated reads, long builds), call `picky_start_pickle` and let a Pickle do the multi-step work with full context.",
    "- `picky_run_bash` is unsandboxed and runs as the user. Refuse destructive commands (`rm -rf`, `git push -f`, `git reset --hard`, overwriting redirects) unless the user explicitly asked for that exact action in this turn.",
    "- `picky_write_file` overwrites by default (mode=\"append\" to append). The body is NOT echoed back — you cannot verify by reading the same file immediately after. Assume success unless `ok` is false.",
    "",
    "## Long-term user memory",
    "- When the user asks you to remember a fact, rule, or preference (e.g. \"remember that X\", \"기억해놓아\", \"from now on, when I do X, do Y\"), call `picky_remember` with a short content describing exactly what to remember. Store at most one idea per item.",
    "- When the user wants to revise or drop a previously stored memory, look it up with `picky_list_memories` first to obtain the id, then call `picky_update_memory` or `picky_forget`.",
    "- Memories below are always in scope; apply the relevant ones to your reply without being asked. Do not recite them back unless the user explicitly asks what you remember.",
  ];
  if (userMemories.length === 0) {
    baseLines.push("- (No long-term memories stored yet.)");
  } else {
    baseLines.push("", "### Stored memories");
    for (const memory of userMemories) {
      baseLines.push(`- (id=${memory.id}) ${memory.content}`);
    }
  }
  appendRecentConversationSection(baseLines, recentHistory);
  return baseLines.join("\n");
}

function appendRecentConversationSection(lines: string[], recentHistory: MainRealtimeHistoryMessage[]): void {
  if (recentHistory.length === 0) return;
  lines.push(
    "",
    "## Recent conversation (your own memory)",
    "The lines below are the most recent turns of your ongoing Picky conversation with this user. Treat each `User:` line as something the user actually said earlier and each `Picky (you):` line as something you actually replied. This is your own memory of what just happened, not background documentation. Apply it when answering follow-ups (especially when the user says \"earlier\", \"before\", \"이전\", \"방금\", \"내 이름\", \"우리 대화\"). Do not recite these lines verbatim, do not re-answer them line by line, and never tell the user you cannot see earlier turns when this section is present.",
  );
  for (const message of recentHistory) {
    const label = message.role === "user" ? "User" : "Picky (you)";
    const text = truncateConversationLineForInstructions(message.text);
    lines.push(`- ${label}: ${text}`);
  }
}

function truncateConversationLineForInstructions(text: string): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  if (collapsed.length <= MAIN_REALTIME_HISTORY_INSTRUCTIONS_LINE_LIMIT) return collapsed;
  return `${collapsed.slice(0, MAIN_REALTIME_HISTORY_INSTRUCTIONS_LINE_LIMIT - 1)}…`;
}

// ---------------------------------------------------------------------------
// 3. Per-turn captured-context envelope (sent as a system-role message before
//    the audio commit so the model can ground its answer in neutral desktop
//    state: cwd, active app/window, browser, selection, screenshots, ink marks).
// ---------------------------------------------------------------------------
export function buildRealtimeContextText(context: PickyContextPacket): string {
  const lines = [
    "# Picky realtime voice context",
    "",
    "The user is currently speaking via OpenAI Realtime audio. Use this neutral desktop context together with the committed input audio.",
    "",
    `- Source: ${context.source}`,
    `- Captured at: ${context.capturedAt}`,
  ];
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
      const focus = context.screenshots.length > 1 && screenshot.isCursorScreen ? "; primary cursor/focus screen" : "";
      const pixels = screenshot.screenshotWidthInPixels && screenshot.screenshotHeightInPixels ? `; screenshotPixels=${screenshot.screenshotWidthInPixels}x${screenshot.screenshotHeightInPixels}` : "";
      const cursor = screenshot.cursor ? `; cursorScreenshotPixel=${screenshot.cursor.screenshotPixel.x},${screenshot.cursor.screenshotPixel.y}` : "";
      lines.push(`- ${screenshot.label}${screen}${focus}${pixels}${cursor}: ${screenshot.path}`);
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
  if (context.warnings.length > 0) lines.push("", "## Capture warnings", ...context.warnings.map((warning) => `- ${warning}`));
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// 4. Function-tool schemas + descriptions. Tool `description` strings are part
//    of the prompt surface the model sees; keep them tight and behavior-led.
// ---------------------------------------------------------------------------
export function realtimeTools(): Array<Record<string, unknown>> {
  return [
    {
      type: "function",
      name: "picky_start_pickle",
      description: "Delegate complex, long-running, tool-heavy, or multi-turn work to a Pickle shown in Picky's dock.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          title: { type: "string", description: "Short title for the Pickle card in the user's language." },
          instructions: { type: "string", description: "Compact delta-first brief for the Pickle." },
          userMessage: { type: "string", description: "Optional message in the user's language to tell the user after starting Pickle." },
          cwd: { type: "string", description: "Optional absolute working directory for the Pickle." },
        },
        required: ["title", "instructions"],
      },
    },
    {
      type: "function",
      name: "picky_pickle_sessions",
      description: "List current and recent Pickles delegated from Picky. Archived Pickles are hidden unless includeArchive is true.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          includeArchive: { type: "boolean", description: "Include Pickles the user has archived. Defaults to false." },
          page: { type: "number" },
          limit: { type: "number" },
        },
        required: [],
      },
    },
    {
      type: "function",
      name: "picky_steer_pickle",
      description: "Send delta-only steering instructions to an existing Pickle.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          sessionId: { type: "string" },
          message: { type: "string" },
        },
        required: ["sessionId", "message"],
      },
    },
    // Disabled: skill discovery tools removed from realtime runtime.
    // {
    //   type: "function",
    //   name: "picky_skills_search",
    //   description: "Search local Pi skill specifications available to Pickles. Returns matching skill names, descriptions, paths, and snippets.",
    //   parameters: {
    //     type: "object",
    //     additionalProperties: false,
    //     properties: {
    //       query: { type: "string", description: "Optional keywords, e.g. sentry, slack, release, debugging. Empty lists top skills." },
    //       limit: { type: "number", description: "Maximum number of matches to return. Defaults to 8, max 20." },
    //     },
    //     required: [],
    //   },
    // },
    // {
    //   type: "function",
    //   name: "picky_skill_details",
    //   description: "Read the full SKILL.md instructions for one local Pi skill by name before delegating skill-specific work to a Pickle.",
    //   parameters: {
    //     type: "object",
    //     additionalProperties: false,
    //     properties: {
    //       name: { type: "string", description: "Skill name, with or without the skill: prefix." },
    //     },
    //     required: ["name"],
    //   },
    // },
    {
      type: "function",
      name: "read_picky_user_guide",
      description: `Read Picky's bundled user manual before answering questions about Picky usage, menus, shortcuts, settings, Push-to-Talk, Quick Input, HUD, and Pickles. Available sections: ${PICKY_USER_GUIDE_SECTIONS.join("; ")}.`,
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          section: { type: "string", description: `Optional exact manual section title or number to read. Available sections: ${PICKY_USER_GUIDE_SECTIONS.join("; ")}.` },
          query: { type: "string", description: "The user's Picky usage question or topic. Used for relevant excerpts when section is omitted, or as context when section is provided." },
        },
        required: [],
      },
    },
    {
      type: "function",
      name: "picky_remember",
      description: "Persist a long-term fact, rule, or preference the user explicitly asked Picky to remember. Stored across sessions and shown to you on every reply via the Long-term user memory section in your instructions. Use ONLY when the user clearly asks to remember something (\"기억해\", \"remember that\", \"from now on...\"); never guess. One concept per call — split multiple ideas into multiple calls. Returns the assigned id so the user (or you, later) can update or forget it.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          content: { type: "string", description: "Short, self-contained statement of the thing to remember, in the user's language. Max 500 chars. Phrase it as a standing rule/fact (e.g. \"User's GitHub handle is jonghakseo\", \"When the user mentions 이 페이지, treat it as the Realtime API guide.\")" },
        },
        required: ["content"],
      },
    },
    {
      type: "function",
      name: "picky_list_memories",
      description: "List every long-term memory Picky has stored for this user, with their ids. Use this before picky_update_memory or picky_forget to obtain the right id, or when the user asks what you remember.",
      parameters: { type: "object", additionalProperties: false, properties: {}, required: [] },
    },
    {
      type: "function",
      name: "picky_update_memory",
      description: "Replace the content of an existing long-term memory. Call picky_list_memories first if you do not already have the id. Use when the user says the previously remembered fact has changed.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          id: { type: "string", description: "Memory id, exactly as returned by picky_remember or picky_list_memories." },
          content: { type: "string", description: "Replacement statement, max 500 chars." },
        },
        required: ["id", "content"],
      },
    },
    {
      type: "function",
      name: "picky_forget",
      description: "Delete a long-term memory by id. Use when the user explicitly asks you to forget something. Get the id from picky_list_memories first if needed.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          id: { type: "string", description: "Memory id, exactly as returned by picky_remember or picky_list_memories." },
        },
        required: ["id"],
      },
    },
    {
      type: "function",
      name: "picky_recall_recent_context",
      description: "Look up the most recent captured context packets Picky has seen — the browser URL, selected text, cwd, active app, and screenshot labels the user attached on previous turns. Call this when the user references an *earlier* turn (\"방금 그 페이지\", \"5분 전\", \"아까 선택한 그 텍스트\", \"the PR\") or when a long-term memory rule keyed on browser/cwd should fire. Returns the newest packets first.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          limit: { type: "number", description: "Number of recent packets to return (default 5, max 10). The most recent first." },
        },
        required: [],
      },
    },
    {
      type: "function",
      name: "picky_inspect_active_pickle",
      description: "Get a short status summary for one running or recently-finished Pickle: current status, last summary message, most recent tool calls, and changed files. Use when the user asks how a specific delegated task is going (\"그 피클 어떻게 돼가\", \"how's the refactor going\"). Does NOT spawn a new Pickle. Resolve the id with picky_pickle_sessions first if needed.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          sessionId: { type: "string", description: "Pickle session id from picky_pickle_sessions." },
        },
        required: ["sessionId"],
      },
    },
    {
      type: "function",
      name: "picky_abort_pickle",
      description: "Stop a running Pickle. Use ONLY when the user explicitly asks to cancel, kill, or stop a Pickle (\"그거 멈춰\", \"cancel that\", \"필요 없어졌어\"). Resolve the id with picky_pickle_sessions first if needed. Never call without an explicit user request.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          sessionId: { type: "string", description: "Pickle session id from picky_pickle_sessions." },
        },
        required: ["sessionId"],
      },
    },
    {
      type: "function",
      name: "picky_unarchive_pickle",
      description: "Restore an archived Pickle so its card reappears in Picky's dock. Use when the user asks to \"bring back\", \"다시 살려\", \"되살려\", or \"복원\" a Pickle they had previously archived. To find archived candidates, first call picky_pickle_sessions with includeArchive=true. The Pickle's status (completed / cancelled / running) is preserved; only the archived flag is flipped. After unarchiving, if the user wants to continue work on it, call picky_steer_pickle (when still running) or picky_start_pickle (when the status is terminal).",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          sessionId: { type: "string", description: "Pickle session id from picky_pickle_sessions (with includeArchive=true if it has been archived)." },
        },
        required: ["sessionId"],
      },
    },
    {
      type: "function",
      name: "picky_read_file",
      description: "Read a short slice of a local text file for a 1-shot answer. Hard-capped at ~40 lines / 2 KB; longer files come back with `truncated: true` and an auto-generated `summary` from a small reasoning model. Use `offset`+`limit` to page through. For multi-file or multi-step inspection, delegate to picky_start_pickle instead of looping calls.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: { type: "string", description: "Absolute or cwd-relative file path." },
          offset: { type: "number", description: "0-based line offset. Default 0." },
          limit: { type: "number", description: "Max lines to return. Default 40, clamped." },
        },
        required: ["path"],
      },
    },
    {
      type: "function",
      name: "picky_run_bash",
      description: "Run a single short shell command. 10s timeout, output tail-capped at 2 KB (full log saved to disk; `logPath` is returned when truncated). Unsandboxed — NEVER call destructive commands (`rm -rf`, `git push -f`, `git reset --hard`, `>` redirects that overwrite existing files) unless the user explicitly asked in this turn. For long builds, recursive searches, or multi-step workflows, delegate to picky_start_pickle.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          command: { type: "string", description: "Shell command to run via `/bin/bash -lc`." },
          cwd: { type: "string", description: "Optional absolute working directory. Defaults to Picky's tracked cwd." },
        },
        required: ["command"],
      },
    },
    {
      type: "function",
      name: "picky_write_file",
      description: "Overwrite or append a file. The body is NOT echoed back — you cannot verify with a follow-up read in the same turn. Default mode is `overwrite`; use `append` to add to existing files. Parent directories are created if missing. Confirm any destructive overwrite with the user in their previous message before calling.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          path: { type: "string", description: "Absolute or cwd-relative file path." },
          content: { type: "string", description: "Bytes to write (UTF-8)." },
          mode: { type: "string", enum: ["overwrite", "append"], description: "Default overwrite." },
        },
        required: ["path", "content"],
      },
    },
  ];
}
