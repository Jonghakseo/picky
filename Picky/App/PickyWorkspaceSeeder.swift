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
    /// `mainAgentRuntimeMode` gates the Pi-specific `AGENTS.md` payload. The
    /// OpenAI Realtime runtime carries its own instructions in `session.update`
    /// and never opens the workspace AGENTS.md, so the workspace directory
    /// itself is still created (Pickle daemons may use it as a cwd) but no Pi
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
        cleanupLegacyTellPlanExtension(workspaceURL: workspaceURL, fileManager: fileManager, log: log)
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
    }

    private static func cleanupLegacyTellPlanExtension(
        workspaceURL: URL,
        fileManager: FileManager,
        log: (String) -> Void
    ) {
        // One-shot cleanup of the previously seeded picky-tell-plan.ts. Without
        // this, old installs would keep loading the dead extension and expose a
        // tool that can no longer reach Picky.
        let legacyTellPlanURL = workspaceURL
            .appendingPathComponent(extensionsDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent("picky-tell-plan.ts", isDirectory: false)
        guard fileManager.fileExists(atPath: legacyTellPlanURL.path) else { return }
        do {
            try fileManager.removeItem(at: legacyTellPlanURL)
            log("🧹 Picky: Removed legacy \(legacyTellPlanURL.path)")
        } catch {
            log("⚠️ Picky: Failed to remove legacy \(legacyTellPlanURL.path): \(error.localizedDescription)")
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
}