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
    "- The one-shot file/shell tools (`picky_read_file`, `picky_run_bash`, `picky_write_file`) are for bounded here-and-now actions: reading short file slices, running non-interactive local commands or small scripts (including simple automation such as `open`/`osascript` when the user requested it), and tiny file writes. If a requested script fits the tool description and can safely be attempted within the enforced caps, call the tool directly; do not say you cannot run it just because it automates a local app. Delegate only when the task becomes multi-step, long-running, interactive, destructive without confirmation, or needs coding-agent judgment.",
    "- When the user asks you to perform a novel reusable workflow that is not covered by the available Picky skills and would require multi-turn instructions, multiple tool calls, or tool chaining to do reliably, ask in the user's language whether they want you to turn it into a Picky skill for next time. Do not create a skill unless they confirm; after confirmation, call `picky_skills` to find `create-picky-skill`, read its path with `picky_read_file`, then follow that recipe.",
    "- When the user asks for something that obviously needs the Pi coding agent (writing or editing code, multi-file refactors, running builds or tests, longer debugging or investigation, anything you cannot finish here-and-now in voice), do NOT try to fake it with the one-shot tools. Summarize the task in one short sentence and ask the user whether to spin up a Pickle to delegate it (e.g. \"Should I spin up a Pickle for this?\"). Only call `picky_start_pickle` after they confirm.",
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
    "- Automatically maintain memory when you learn durable, reusable information: user preferences, standing rules, personal/project facts, stable identifiers, or new capabilities/workflows Picky can perform. The user does NOT need to say \"remember\" for these.",
    "- If new information conflicts with or meaningfully refines an existing memory, call `picky_list_memories` to get the id and then `picky_update_memory` with the corrected self-contained statement. Add a new memory only when no existing memory should be updated.",
    "- Do not store one-off task details, transient screen state, secrets, credentials, sensitive personal data, or raw logs. Use one concise concept per memory.",
    "- Trigger phrases to watch for: \"내 ~\", \"전에 말한\", \"기억하지\", \"우리가 정한\", \"my ~\", \"I told you\", \"we agreed\", or any identifier (name, handle, cwd, repo, URL) that overlaps with a stored item.",
    "- IDs are not shown here; call `picky_list_memories` when you need the id for `picky_update_memory` / `picky_forget`, when checking for conflicts before storing, or when the user asks what you remember.",
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
 *  tells the model to call `picky_skills` when in doubt. Skill bodies stay on
 *  disk; read the listed path with `picky_read_file` before applying one. */
function appendPickySkillsSection(lines: string[], skills: PickySkillSummary[]): void {
  lines.push(
    "",
    "## Picky skills (user-authored behavior recipes)",
    "- These are short behavior recipes the user has saved under `~/Library/Application Support/Picky/skills/`. The list below is a snapshot taken when this realtime session started.",
    "- When a user turn matches one of these skills, read the listed `path` with `picky_read_file` BEFORE acting, then follow the recipe.",
    "- New skills the user adds mid-session do not appear in this list. If the user mentions a skill that is missing here, call `picky_skills` to refresh the catalog."
  );
  if (skills.length === 0) {
    lines.push("- (No Picky skills authored yet. If the user asks to create one, call `picky_skills` to confirm whether `create-picky-skill` exists, then read its `path` with `picky_read_file`.)");
    return;
  }
  lines.push("", "### Available Picky skills");
  for (const skill of skills) {
    const description = skill.description?.trim() || "(no description)";
    lines.push(`- ${skill.name} — ${description} — path: ${skill.path}`);
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
      description: "Delegate complex, long-running, tool-heavy, or multi-turn work to a Pickle shown in Picky's dock. Ask once before calling if the user did not explicitly ask to start a Pickle.",
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
      name: "picky_skills",
      description: "List every Picky-only behavior recipe the user has authored under ~/Library/Application Support/Picky/skills/. Returns only each skill's name, description, and SKILL.md file path. To apply a skill, read its path with `picky_read_file` first; this tool does not return skill bodies.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {},
        required: [],
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
      description: "Persist a durable long-term fact, rule, preference, stable identifier, or reusable capability/workflow you learned. The user may explicitly ask to remember it, but explicit wording is NOT required when the information is clearly useful across future sessions. Before adding, prefer updating an existing related memory if the new information conflicts with or refines it. Never store one-off task details, secrets, credentials, sensitive personal data, or raw logs. One concise concept per call. Returns the assigned id so the user or you can update/forget it later.",
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
      description: "List every long-term memory Picky has stored for this user, with their ids. Use this before picky_update_memory or picky_forget, when checking whether newly learned information should update an existing memory instead of creating a duplicate, or when the user asks what you remember.",
      parameters: { type: "object", additionalProperties: false, properties: {}, required: [] },
    },
    {
      type: "function",
      name: "picky_update_memory",
      description: "Replace the content of an existing long-term memory. Call picky_list_memories first if you do not already have the id. Use proactively when newly learned durable information conflicts with, corrects, or meaningfully refines an existing memory; the user does not need to explicitly ask for the update.",
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
      description: "Run a non-interactive local shell command or small script via `/bin/bash -lc`. Use it for bounded checks, local inspection, clipboard reads/writes (`pbcopy`/`pbpaste`), and simple macOS automation such as `osascript` paste when the user requested it and permissions allow, all within the enforced 10s timeout. Output is tail-capped at 2 KB (full log saved to disk; `logPath` is returned when truncated). Unsandboxed — do not run destructive commands (`rm -rf`, `git push -f`, `git reset --hard`, or overwrite redirects) unless the user explicitly requested or confirmed them. If the task needs interaction, streaming, long-running processes, repeated tool chaining, or coding-agent judgment, delegate to `picky_start_pickle`.",
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
