//
//  PickyWorkspaceSeeder.swift
//  Picky
//
//  Owns the default Picky workspace under
//  `~/Library/Application Support/Picky/Workspace`. The workspace is the cwd
//  the always-on Picky main agent runs in by default, so Pi auto-loads any
//  `AGENTS.md`, `.pi/extensions`, `.pi/skills`, and `.pi/prompts` the user
//  drops there. We seed a default `AGENTS.md` on first launch so Picky has a
//  usable persona out of the box, and never overwrite the user's edits.
//
//  Pi context-file loading reference:
//    /usr/local/lib/node_modules/@earendil-works/pi-coding-agent/README.md
//

import Foundation

enum PickyWorkspaceSeeder {
    /// Filename Pi reads for context, per the Pi README's Context Files section.
    static let agentsMarkdownFilename = "AGENTS.md"

    /// Project-local Pi extensions directory auto-discovered by pi-coding-agent
    /// when running in this cwd. See `docs/extensions.md` in the Pi package.
    static let extensionsDirectoryRelativePath = ".pi/extensions"

    /// Filename of the seeded plan-announcement extension that scopes
    /// `picky_tell_plan` to this workspace's cwd and enforces the "announce
    /// the plan before any other tool" policy via `tool_call` blocking.
    static let tellPlanExtensionFilename = "picky-tell-plan.ts"

    /// Path of the default workspace. Does not check whether the directory or
    /// the seeded `AGENTS.md` actually exist; use `seedDefaultWorkspace` to
    /// create both before pointing Pi at the path.
    static func defaultWorkspacePath(
        appSupportRoot: URL = PickyAppSupport.defaultRoot()
    ) -> String {
        appSupportRoot.appendingPathComponent("Workspace", isDirectory: true).path
    }

    /// Idempotently creates the workspace directory and seeds the default
    /// `AGENTS.md`. The markdown is written only when missing — user edits are
    /// always preserved on subsequent launches.
    @discardableResult
    static func seedDefaultWorkspace(
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi,
        fileManager: FileManager = .default,
        log: (String) -> Void = { print($0) }
    ) -> String {
        let path = defaultWorkspacePath(appSupportRoot: appSupportRoot)
        seed(workspacePath: path, mainAgentRuntimeMode: mainAgentRuntimeMode, fileManager: fileManager, log: log)
        return path
    }

    /// Seed an arbitrary path. Splits out from `seedDefaultWorkspace` so
    /// migrations / tests can target a different root without hard-coding the
    /// AppSupport URL.
    ///
    /// `mainAgentRuntimeMode` gates the Pi-specific payloads under the
    /// workspace. Both `AGENTS.md` (Pi's cwd-loaded standing prompt) and
    /// `.pi/extensions/picky-tell-plan.ts` (Pi's tool_call gate) are only
    /// read by the Pi SDK runtime - the OpenAI Realtime runtime carries its
    /// own instructions in `session.update` and never opens the workspace
    /// AGENTS.md or invokes the tell-plan extension. Seeding them under the
    /// realtime runtime would leave dormant files behind that confuse
    /// anyone inspecting the workspace, so the workspace directory itself
    /// is still created (Pickle daemons may use it as a cwd) but no Pi
    /// payload is written.
    static func seed(
        workspacePath: String,
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi,
        fileManager: FileManager = .default,
        log: (String) -> Void = { print($0) }
    ) {
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        do {
            try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        } catch {
            log("⚠️ Picky: Failed to create workspace at \(workspaceURL.path): \(error.localizedDescription)")
            return
        }
        guard mainAgentRuntimeMode == .pi else { return }
        let agentsURL = workspaceURL.appendingPathComponent(agentsMarkdownFilename, isDirectory: false)
        if !fileManager.fileExists(atPath: agentsURL.path) {
            do {
                try defaultAgentsMarkdown.write(to: agentsURL, atomically: true, encoding: .utf8)
                log("🧩 Picky: Seeded default \(agentsMarkdownFilename) at \(agentsURL.path)")
            } catch {
                log("⚠️ Picky: Failed to seed \(agentsURL.path): \(error.localizedDescription)")
            }
        }
        seedExtensions(workspaceURL: workspaceURL, fileManager: fileManager, log: log)
    }

    /// Creates `.pi/extensions/` under the workspace and drops bundled Picky
    /// extensions (currently only `picky-tell-plan.ts`) when missing. User
    /// edits are preserved — existing files are never overwritten.
    private static func seedExtensions(
        workspaceURL: URL,
        fileManager: FileManager,
        log: (String) -> Void
    ) {
        let extensionsURL = workspaceURL.appendingPathComponent(extensionsDirectoryRelativePath, isDirectory: true)
        do {
            try fileManager.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        } catch {
            log("⚠️ Picky: Failed to create extensions dir at \(extensionsURL.path): \(error.localizedDescription)")
            return
        }
        let tellPlanURL = extensionsURL.appendingPathComponent(tellPlanExtensionFilename, isDirectory: false)
        guard !fileManager.fileExists(atPath: tellPlanURL.path) else { return }
        do {
            try defaultTellPlanExtensionSource.write(to: tellPlanURL, atomically: true, encoding: .utf8)
            log("🧩 Picky: Seeded \(tellPlanExtensionFilename) at \(tellPlanURL.path)")
        } catch {
            log("⚠️ Picky: Failed to seed \(tellPlanURL.path): \(error.localizedDescription)")
        }
    }

    /// Default Picky persona + Pickle routing policy. The text is lifted from
    /// the always-on bootstrap prompt that previously lived inside agentd, so
    /// users can edit thresholds and persona without rebuilding agentd.
    static let defaultAgentsMarkdown: String = """
    # Picky main agent — default persona and routing

    This file is the default seed for Picky's always-on main agent workspace.
    Pi reads it as part of context whenever the main agent runs in this cwd
    (see Pi's "Context Files" docs). Edit it freely to shape Picky's persona
    and Pickle routing policy. Picky never overwrites this file once it
    exists; delete the file and relaunch Picky to reseed defaults.

    You can also drop `.pi/extensions`, `.pi/skills`, and `.pi/prompts`
    directories here to extend Picky without modifying the app.

    ## Persona

    You are Picky, the always-on assistant. You receive the user's
    voice/text request plus captured desktop context, and reply in the
    user's language by default (mirror the request's language; if it is
    ambiguous, fall back to the OS UI language). You are a thin shell on
    top of Pi: prefer delegating real work to a Pickle (a long-running Pi
    session shown in the Picky dock) over doing it inline.

    ## Routing rules

    - If the request is simple, answer directly in 1-3 short sentences.
    - If the request refers to existing delegated work, a running Pickle, a
      recent Pickle result, or asks to continue/change/check progress, call
      `picky_pickle_sessions` before deciding what to do.
    - Only call `picky_steer_pickle` when the user is explicitly or
      contextually following up on a specific existing Pickle (for example,
      naming it, referring to its task/result, or asking to continue/adjust
      the same delegated work). Do not steer just because a Pickle is
      running in the same repo or cwd; if the new request is a separate
      concern, start a new Pickle with `picky_start_pickle` instead. Keep
      the steer message delta-only: the new instruction plus essential
      references, not a restatement of the whole task or prior logs.
    - If the request needs new long-running work, detailed screen analysis,
      code/repo/file tools, web/video extraction, MCPs, or multiple turns,
      call `picky_start_pickle` with clear instructions for a Pickle Pi
      agent. As a rule of thumb, if completing the request will likely take
      more than 4 tool calls, delegate to a Pickle instead of handling it
      inline.
    - Single, short tool calls such as reading one document, looking up a
      skill, or running one bounded bash command can be handled directly in
      the main turn without a Pickle. For tools whose runtime is hard to
      bound (notably `bash`), always set a strict timeout so the main turn
      cannot stall.
    - Keep `picky_start_pickle.instructions` compact and action-oriented,
      roughly a short paragraph: goal, essential constraints, known
      decisions, key paths/URLs/IDs, and expected output. Do not paste the
      full current prompt, captured context, screenshot metadata, prior
      transcript, or tool logs.
    - `picky_start_pickle` accepts an optional `cwd`; omit it to use
      Picky's configured Pickle default cwd. Only set `cwd` when the user
      explicitly asks for another local repo/path or the correct working
      directory is otherwise clear; use an absolute path.
    - For screen-understanding requests with multiple screenshots, inspect
      all screenshots and distinguish the primary cursor/focus screen from
      secondary screens.
    - When you hand off, tell the user that you are delegating to a Pickle
      and that progress can be checked in the Picky dock.
    - When a Pickle completion message is provided later, summarize the
      result briefly and tell the user to open the Pickle card for
      details.
    - If the captured context Source is `text`, treat the request text as
      deliberate typed input, not speech recognition or STT output. Do not
      say the text was misrecognized; if it is unclear, ask the user to
      retype or clarify.
    - Do not expose internal tool logs. Do not hard-code workflows from
      URLs or app names; use the user's intent and context.

    ## Announce the plan before tool calls

    - Before the first tool call in an agent run, call `picky_tell_plan`
      once to announce the work plan for the user prompt, unless you have
      already produced user-visible assistant text in this run. Mandatory
      for tool-first runs; one plan covers the whole agent run.
    - Speak the plan, not progress: intended approach and rough order of
      steps. Do not narrate what just happened.
    - One or two short sentences in the user's language (target ~40 chars,
      max ~100, guidance only). Never include final answers, code, paths,
      or sensitive identifiers.
    - If narration is disabled the tool returns silently — do not retry.

    ## Self-update

    - When the user gives a persistent rule, preference, or workflow change
      ("from now on do X", "apply this rule", "add/update/remove this
      instruction", and the equivalent in any other language), follow it
      for the current turn AND directly edit this `AGENTS.md` file to
      add/update/remove the matching item under the most relevant section
      (or create a new `## ` section if none fits). Keep entries concise
      and imperative; do not duplicate existing rules. After editing, tell
      the user which section was changed in one short line.
    - Pickle-related guidance is a special case: when the user gives
      instructions about how to run a Pickle (default cwd or repo path for
      a kind of task, fixed procedures/checklists, preferred skills/MCPs,
      naming conventions, what to include in `instructions`, etc.), record
      them directly in this `AGENTS.md` under a `## Pickle execution`
      section (create it if missing). Group entries by trigger or task
      type so the routing rules above can reference them. Do not stash
      this kind of guidance in memory or sibling notes — it must live in
      `AGENTS.md` so it is loaded on every main-agent turn.
    - Do NOT put one-off facts, scratch notes, or transient context into
      `AGENTS.md`. For those, prefer the built-in memory tool if one is
      available in the current session (e.g. a `remember` tool). If no
      memory tool is available, create a sibling file next to this
      `AGENTS.md` (for example `NOTES.md`, or a topic-named file like
      `notes/<topic>.md`) and add a short bullet under a `## Notes` section
      here pointing to that file's path so future sessions can find it.
      Keep `AGENTS.md` itself focused on persistent persona/rules/policy.
    """

    /// Default content for `.pi/extensions/picky-tell-plan.ts`. The
    /// extension is the canonical home for the `picky_tell_plan` tool (the
    /// agentd main runtime never registers it) so the tool is only visible
    /// to the main agent running in this workspace cwd. The tool announces
    /// a short work plan (not progress chatter): before a tool-first agent
    /// run executes its first tool, the agent must call `picky_tell_plan`
    /// once and describe what it intends to do, roughly in what order. Runs
    /// that already produced assistant text may continue without a plan call.
    /// The per-run flags reset on `agent_start`, so one plan announcement
    /// covers the entire multi-turn agent run for that user prompt. The character cap
    /// inside the extension is guidance only — the tool does not truncate or
    /// reject input by length.
    ///
    /// Picky's TTS is reached through `globalThis.__pickyAgentd.narrate(text)`,
    /// installed by agentd at startup. See `PickyAgentdBridge` in
    /// `agentd/src/bootstrap.ts` for the interface contract.
    static let defaultTellPlanExtensionSource: String = #"""
    // Auto-seeded by Picky. Registers `picky_tell_plan` for the main agent
    // running in this workspace cwd and enforces that tool-first runs call it
    // before the first non-plan tool in the same agent run.
    //
    // Delete this file and relaunch Picky to reseed the default.

    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { Type } from "typebox";

    const TOOL_NAME = "picky_tell_plan";
    // Soft target only; no programmatic truncation. Used in guidance text.
    const TARGET_CHARS = 40;
    const MAX_CHARS = 100;

    interface PickyAgentdBridge {
      narrate?: (text: string) => void;
      getNarrationEnabled?: () => boolean;
      onNarrationEnabledChange?: (listener: (enabled: boolean) => void) => () => void;
    }

    function bridge(): PickyAgentdBridge | undefined {
      return (globalThis as unknown as { __pickyAgentd?: PickyAgentdBridge }).__pickyAgentd;
    }

    function isNarrationEnabled(): boolean {
      // Default true so a missing or pre-rename bridge does not silently
      // hide the tool from the LLM.
      return bridge()?.getNarrationEnabled?.() ?? true;
    }

    export default function (pi: ExtensionAPI) {
      // Per-agent-run flags. Reset at agent_start. Tool-first runs must call
      // picky_tell_plan before the first non-plan tool. If the assistant has
      // already produced user-visible text, the plan has effectively been
      // spoken inline and the first tool can proceed without narration.
      let narrationDone = false;
      let previousNonPlanToolCall = false;
      let assistantProducedText = false;
      let unsubscribe: (() => void) | undefined;

      function assistantMessageHasText(message: { role?: string; content?: unknown }): boolean {
        if (message.role !== "assistant" || !Array.isArray(message.content)) return false;
        return message.content.some((part) => {
          if (!part || typeof part !== "object") return false;
          const candidate = part as { type?: unknown; text?: unknown };
          return candidate.type === "text" && typeof candidate.text === "string" && candidate.text.trim().length > 0;
        });
      }

      function syncActiveTools(enabled: boolean): void {
        const active = pi.getActiveTools();
        const has = active.includes(TOOL_NAME);
        if (enabled && !has) {
          pi.setActiveTools([...active, TOOL_NAME]);
        } else if (!enabled && has) {
          pi.setActiveTools(active.filter((name) => name !== TOOL_NAME));
        }
      }

      pi.on("session_start", async () => {
        syncActiveTools(isNarrationEnabled());
        unsubscribe?.();
        unsubscribe = bridge()?.onNarrationEnabledChange?.((enabled) => {
          syncActiveTools(enabled);
        });
      });

      pi.on("session_shutdown", async () => {
        unsubscribe?.();
        unsubscribe = undefined;
      });

      pi.on("agent_start", async () => {
        narrationDone = false;
        previousNonPlanToolCall = false;
        assistantProducedText = false;
      });

      pi.on("message_update", async (event) => {
        const streamEvent = event.assistantMessageEvent;
        if (streamEvent.type === "text_delta" && streamEvent.delta.trim().length > 0) {
          assistantProducedText = true;
          return;
        }
        if (streamEvent.type === "text_end" && streamEvent.content.trim().length > 0) {
          assistantProducedText = true;
          return;
        }
        if (assistantMessageHasText(event.message)) {
          assistantProducedText = true;
        }
      });

      pi.on("message_end", async (event) => {
        if (assistantMessageHasText(event.message)) {
          assistantProducedText = true;
        }
      });

      pi.on("tool_call", async (event) => {
        // When the user has narration off, the tool is not in the active set
        // and the LLM cannot see it, so the gate must not block other tools.
        if (!isNarrationEnabled()) return;
        if (event.toolName === TOOL_NAME) {
          // Mark immediately so sibling tool_call events in the same parallel
          // batch see the flag and are not blocked.
          narrationDone = true;
          return;
        }
        if (!narrationDone && !previousNonPlanToolCall && !assistantProducedText) {
          return {
            block: true,
            reason: `Call ${TOOL_NAME} first to announce the plan for this tool-first user prompt (~${TARGET_CHARS} chars, max ${MAX_CHARS}), or answer with text before using tools. One plan covers the whole agent run.`,
          };
        }
        previousNonPlanToolCall = true;
      });

      pi.registerTool({
        name: TOOL_NAME,
        label: "Picky tell plan",
        description:
          "Announce the work plan via Picky's companion voice before a tool-first agent run uses tools.",
        promptSnippet: `${TOOL_NAME}: speak the plan (intended approach + rough order) before the first tool in a tool-first agent run.`,
        promptGuidelines: [
          `Mandatory for tool-first runs: call ${TOOL_NAME} once before the first non-plan tool if you have not already produced user-visible assistant text in this agent run; one plan covers the whole prompt.`,
          `Speak the plan, not progress: intended approach and rough order of steps (e.g. "Read the failing test, trace the recent diff, propose a fix."). Do not narrate what just happened.`,
          `One or two short sentences in the user's language, target ~${TARGET_CHARS} chars, max ${MAX_CHARS} (guidance only). Never include final answers, code, paths, or sensitive identifiers.`,
          `If narration is disabled the tool returns silently — do not retry.`,
        ],
        parameters: Type.Object({
          text: Type.String({
            description:
              "Short work-plan announcement in the user's language: intended approach + rough order. Target ~40 chars, max ~100 (guidance only, not enforced).",
          }),
        }),
        async execute(_toolCallId, params) {
          const raw = typeof params.text === "string" ? params.text.trim() : "";
          if (!raw) throw new Error("text must not be empty");
          if (assistantProducedText) {
            narrationDone = true;
            return {
              content: [
                { type: "text", text: "Plan narration skipped because assistant text was already produced in this agent run." },
              ],
              details: { text: raw, delivered: false, skipped: true, skipReason: "assistantTextAlreadyProduced" },
            };
          }
          const api = bridge();
          if (!api?.narrate) {
            return {
              content: [
                { type: "text", text: "Narration bridge unavailable; continue without retrying." },
              ],
              details: { text: raw, delivered: false, skipped: false, skipReason: "bridgeUnavailable" },
            };
          }
          api.narrate(raw);
          return {
            content: [
              {
                type: "text",
                text: `Plan dispatched (${raw.length} chars). Continue the work; do not narrate again in this agent run.`,
              },
            ],
            details: { text: raw, delivered: true, skipped: false, skipReason: "" },
          };
        },
      });
    }
    """#
}
