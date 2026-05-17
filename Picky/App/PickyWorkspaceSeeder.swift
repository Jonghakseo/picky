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

    /// Filename of the seeded narration extension that scopes
    /// `picky_narrate_progress` to this workspace's cwd and enforces the
    /// "narrate before any other tool" policy via `tool_call` blocking.
    static let narrateExtensionFilename = "picky-narrate-progress.ts"

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
        fileManager: FileManager = .default,
        log: (String) -> Void = { print($0) }
    ) -> String {
        let path = defaultWorkspacePath(appSupportRoot: appSupportRoot)
        seed(workspacePath: path, fileManager: fileManager, log: log)
        return path
    }

    /// Seed an arbitrary path. Splits out from `seedDefaultWorkspace` so
    /// migrations / tests can target a different root without hard-coding the
    /// AppSupport URL.
    static func seed(
        workspacePath: String,
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
    /// extensions (currently only `picky-narrate-progress.ts`) when missing.
    /// User edits are preserved — existing files are never overwritten.
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
        let narrateURL = extensionsURL.appendingPathComponent(narrateExtensionFilename, isDirectory: false)
        guard !fileManager.fileExists(atPath: narrateURL.path) else { return }
        do {
            try defaultNarrateExtensionSource.write(to: narrateURL, atomically: true, encoding: .utf8)
            log("🧩 Picky: Seeded \(narrateExtensionFilename) at \(narrateURL.path)")
        } catch {
            log("⚠️ Picky: Failed to seed \(narrateURL.path): \(error.localizedDescription)")
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

    ## Narration before tool calls

    - Per user prompt the first non-narrate tool call is free. From the
      second non-narrate tool call onwards in the same agent run,
      `picky_narrate_progress` must have been called at least once
      earlier. Treat this as mandatory, not best-effort.
    - One narration covers the entire multi-turn agent run for that
      prompt; do not narrate again after the first narration.
    - The narration must be a short present-continuous sentence in the
      user's language (~20 chars, max 40), describing the activity only —
      never include final answers, code, paths, or sensitive identifiers.
    - If narration is disabled the tool returns silently — do not
      retry.

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

    /// Default content for `.pi/extensions/picky-narrate-progress.ts`. The
    /// extension is the canonical home for the `picky_narrate_progress` tool
    /// (the agentd main runtime no longer registers it) so the tool is only
    /// visible to the main agent running in this workspace cwd. It also
    /// enforces a hard rule via `tool_call` blocking: the first non-narrate
    /// tool call in an agent run is allowed for free; from the second
    /// non-narrate tool call onwards `picky_narrate_progress` must have been
    /// called at least once. Counters reset on `agent_start`, so the
    /// grace + narration cover the entire multi-turn agent run for that
    /// prompt.
    ///
    /// Picky's TTS is reached through `globalThis.__pickyAgentd.narrate(text)`,
    /// installed by agentd at startup. See `PickyAgentdBridge` in
    /// `agentd/src/bootstrap.ts` for the interface contract.
    static let defaultNarrateExtensionSource: String = #"""
    // Auto-seeded by Picky. Registers `picky_narrate_progress` for the main
    // agent running in this workspace cwd and enforces that it is called once
    // before any other tool call in the same assistant response.
    //
    // Delete this file and relaunch Picky to reseed the default.

    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { Type } from "typebox";

    const TOOL_NAME = "picky_narrate_progress";
    const MAX_CHARS = 40;

    interface PickyAgentdBridge {
      narrate?: (text: string) => void;
    }

    function bridge(): PickyAgentdBridge | undefined {
      return (globalThis as unknown as { __pickyAgentd?: PickyAgentdBridge }).__pickyAgentd;
    }

    export default function (pi: ExtensionAPI) {
      // Per-agent-run state. Reset at agent_start. The first non-narrate tool
      // call passes for free (cheap one-shot tasks don't need narration); from
      // the second non-narrate tool call onwards picky_narrate_progress must
      // have been called at least once in this agent run.
      let narrationDone = false;
      let freeToolUsed = false;

      pi.on("agent_start", async () => {
        narrationDone = false;
        freeToolUsed = false;
      });

      pi.on("tool_call", async (event) => {
        if (event.toolName === TOOL_NAME) {
          // Mark immediately so sibling tool_call events in the same parallel
          // batch see the flag and are not blocked.
          narrationDone = true;
          return;
        }
        if (narrationDone) return;
        if (!freeToolUsed) {
          // One-tool grace per agent run consumed.
          freeToolUsed = true;
          return;
        }
        return {
          block: true,
          reason: `Call ${TOOL_NAME} before the next tool call. The one-tool grace per user prompt is already used; from the second tool call onwards a short present-continuous filler line in the user's language (~20 chars, max ${MAX_CHARS}) is required.`,
        };
      });

      pi.registerTool({
        name: TOOL_NAME,
        label: "Picky narrate progress",
        description:
          "Speak a brief filler line via Picky's companion voice. The first non-narrate tool call per user prompt is free; from the second non-narrate tool call onwards this tool must have been called at least once.",
        promptSnippet: `${TOOL_NAME}: from the second tool call of a user prompt onwards, speak one short filler line. The first tool call per prompt is free; one narration covers the rest of the agent run.`,
        promptGuidelines: [
          `Per user prompt the first non-narrate tool call is allowed without narration. From the second non-narrate tool call onwards, ${TOOL_NAME} must have been called at least once earlier in the same agent run.`,
          `Do not call ${TOOL_NAME} again after the first narration in the same agent run — one narration is enough for the whole prompt.`,
          `Use one short present-continuous sentence in the user's language (~20 characters, max ${MAX_CHARS}); describe only the activity.`,
          `Never include final answers, code, paths, or sensitive identifiers in the narration line.`,
          `If narration is disabled the tool returns silently — do not retry.`,
        ],
        parameters: Type.Object({
          text: Type.String({
            description:
              "Short present-continuous filler line in the user's language. Ideally ~20 characters, max 40.",
          }),
        }),
        async execute(_toolCallId, params) {
          const raw = typeof params.text === "string" ? params.text.trim() : "";
          if (!raw) throw new Error("text must not be empty");
          const api = bridge();
          if (!api?.narrate) {
            return {
              content: [
                { type: "text", text: "Narration bridge unavailable; continue without retrying." },
              ],
              details: { text: raw, delivered: false },
            };
          }
          api.narrate(raw);
          return {
            content: [
              {
                type: "text",
                text: `Narration dispatched (${raw.length} chars). Continue the underlying work; do not narrate the same step again.`,
              },
            ],
            details: { text: raw, delivered: true },
          };
        },
      });
    }
    """#
}
