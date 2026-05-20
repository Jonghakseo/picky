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
import type { PickySkillSummary } from "../application/picky-skill-store.js";
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
  "Key terms: Picky, Pickle, Pi, HUD, dock, repo, branch.",
].join("\n");

// ---------------------------------------------------------------------------
// 2. session.instructions - top-level system prompt for Realtime main
// ---------------------------------------------------------------------------
export function buildRealtimeInstructions(
  userMemories: MainRealtimeUserMemoryItem[] = [],
  recentHistory: MainRealtimeHistoryMessage[] = [],
  pickySkills: PickySkillSummary[] = [],
): string {
  const baseLines = [
    buildMainAgentBootstrapPair({ omitTtsParenthesisHint: true }).user,
    "",
    "Before replying, scan the `## Long-term user memory` section below and apply any item that matches the user's current request, identifiers, or captured context — even when the user did not ask you to recall it.",
    "",
    "## Realtime voice mode overrides",
    `- Use \`read_picky_user_guide\` before answering questions about how to use Picky. Prefer its \`section\` parameter when the question maps to one of these manual sections: ${PICKY_USER_GUIDE_SECTIONS.join("; ")}.`,
    "- To check the progress of one specific delegated Pickle, call `picky_inspect_active_pickle` (does not spawn a new Pickle). Call `picky_abort_pickle` only when the user explicitly asks to stop one.",
    "- The captured context you see at the start of THIS turn is gone by the next turn. Call `picky_recall_recent_context` when the user references an earlier turn or a stored memory rule depends on the prior browser/cwd.",
    "- The one-shot file/shell tools (`picky_read_file`, `picky_run_bash`, `picky_write_file`) follow the per-call rules in each tool's description. If answering would need 3+ calls or a long-running command, delegate to `picky_start_pickle` instead of looping.",
    "- Do NOT pass `cwd` to `picky_start_pickle` just because the captured-context block reports one. The `- CWD:` line in the per-turn context describes Picky's own main-agent cwd, not the Pickle target. Picky already defaults new Pickles to the user's configured Pickle cwd, so omit the argument unless the user explicitly named a different folder in this turn.",
    "",
    "## Reasoning",
    "- For greetings, acknowledgements, simple confirmations, and direct factual answers, respond immediately without extended reasoning.",
    "- For multi-step requests, tool routing decisions, or anything that requires checking recent context, reason internally before speaking.",
    "- Do not perform extended reasoning when the user's audio is unclear; ask for a short clarification instead.",
  ];
  baseLines.push(
    "",
    "## Long-term user memory",
    "- Memories below are always in scope; apply the relevant ones to your reply without being asked. Do not recite them back unless the user explicitly asks what you remember.",
    "- Trigger phrases to watch for: \"내 ~\", \"전에 말한\", \"기억하지\", \"우리가 정한\", \"my ~\", \"I told you\", \"we agreed\", or any identifier (name, handle, cwd, repo, URL) that overlaps with a stored item.",
    "- IDs are not shown here; call `picky_list_memories` only when you need the id for `picky_update_memory` / `picky_forget` or when the user explicitly asks what you remember.",
  );
  if (userMemories.length === 0) {
    baseLines.push("- (No long-term memories stored yet.)");
  } else {
    baseLines.push("", "### Stored memories");
    for (const memory of userMemories) {
      baseLines.push(`- ${memory.content}`);
    }
  }
  appendPickySkillsSection(baseLines, pickySkills);
  appendRecentConversationSection(baseLines, recentHistory);
  return baseLines.join("\n");
}

/** Picky-only skills authored by the user under
 *  `~/Library/Application Support/Picky/skills/`. This list is a snapshot
 *  taken once at session start — additions or edits the user makes mid-session
 *  will NOT appear here until the next session, which is why the instruction
 *  tells the model to call `picky_skill({ action: "list" })` when in doubt.
 *  The body of each skill is fetched on demand via `picky_skill({ action: "get" })`. */
function appendPickySkillsSection(lines: string[], skills: PickySkillSummary[]): void {
  lines.push(
    "",
    "## Picky skills (user-authored behavior recipes)",
    "- These are short behavior recipes the user has saved under `~/Library/Application Support/Picky/skills/`. The list below is a snapshot taken when this realtime session started.",
    "- When a user turn matches one of these skills, call `picky_skill({ action: \"get\", name })` to read the full body BEFORE acting, then follow the recipe.",
    "- New skills the user adds mid-session do not appear in this list. If the user mentions a skill that is missing here, call `picky_skill({ action: \"list\" })` (optionally with `query`) to refresh."
  );
  if (skills.length === 0) {
    lines.push("- (No Picky skills authored yet. If the user asks to create one, use `picky_skill({ action: \"list\" })` to confirm and then follow the `create-picky-skill` recipe if it exists.)");
    return;
  }
  lines.push("", "### Available Picky skills");
  for (const skill of skills) {
    const description = skill.description?.trim() || "(no description)";
    lines.push(`- ${skill.name} — ${description}`);
  }
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
  if (context.activeWindow?.title && !context.browser?.title) lines.push(`- Active window: ${context.activeWindow.title}`);
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
          cwd: { type: "string", description: "Optional. Omit to use Picky's configured default Pickle cwd. Only set this when the user explicitly named a different folder in this turn — do NOT copy the `- CWD:` line from the per-turn captured context, which describes Picky's main-agent cwd and is not the Pickle target." },
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
    {
      type: "function",
      name: "picky_skill",
      description: "Look up Picky-only behavior recipes the user has authored under ~/Library/Application Support/Picky/skills/. The session-start instructions already list every skill's name and one-line description; use this tool to read the body of a specific skill (`action: \"get\"`) before applying it, or to refresh the list mid-session when the user mentions a skill that is not in the snapshot (`action: \"list\"`).",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          action: { type: "string", enum: ["list", "get"], description: "`list` returns the names and descriptions of all (or query-filtered) Picky skills. `get` returns the full Markdown body of one skill by name." },
          query: { type: "string", description: "Optional keywords for action=list. Empty/omitted returns the full catalog." },
          name: { type: "string", description: "Required when action=get. The skill's `name` from the snapshot, e.g. `create-picky-skill`." },
          limit: { type: "number", description: "Optional cap on action=list results. Default 8, max 20." },
        },
        required: ["action"],
      },
    },
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
