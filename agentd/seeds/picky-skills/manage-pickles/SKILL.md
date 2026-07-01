---
name: manage-pickles
description: Decide how to delegate, steer, inspect, archive, or abort Pickles when the user mentions ongoing work or asks Picky to do something non-trivial.
---

# Managing Pickles

## When to use
- The user refers to an ongoing or earlier Pickle ("that task", "the one from earlier", "my current job"), in any language.
- The user asks Picky to do anything that needs files, multiple steps, or long-running tools.

## What to do
1. **Look up first.** Call `picky_pickle_sessions` before starting or steering anything when the user refers to existing work. Match by title / cwd / recency, not by guessing.
2. **Reuse over re-spawn.** If a Pickle that fits the user's intent is still running, call `picky_steer_pickle` with a delta-only message. Spawn a new one with `picky_start_pickle` only when no live Pickle matches or the task is clearly distinct; if the user did not explicitly ask to start/delegate to a Pickle, ask once before starting it.
3. **Shape `picky_start_pickle.instructions` as a delta.** Compact what the Pickle needs to act: goal, constraints, the one or two files / URLs / IDs that ground it. Skip backstory the Pickle can re-derive.
4. **Check progress without spawning.** When the user asks how something is going, call `picky_inspect_active_pickle({ sessionId })`. Never start a new Pickle just to read another one's state.
5. **Abort only on explicit request.** `picky_abort_pickle` runs only when the user clearly says stop / cancel / kill. Resolve the right `sessionId` via `picky_pickle_sessions` first.
6. **Archive / unarchive explicitly.** Archive only when the user asks to hide/clean up a Pickle. Archived terminal Pickles are recoverable only inside Picky's current 7-day retention window.
7. **Unarchive then route by status.** To find archived candidates, call `picky_pickle_sessions({ includeArchive: true })` first. `picky_unarchive_pickle` flips visibility only. After it returns, push the user toward `picky_steer_pickle` if still running, or `picky_start_pickle` if the status is terminal.
8. **CLI fallback for operators.** When operating from a shell, use `picky pickle-list --archived [--query text]` to explore archived Pickles, `picky pickle-archive <session-id>` to archive, and `picky pickle-unarchive <session-id>` to restore.

## What NOT to do
- Don't run long tasks inline via `picky_run_bash` / `picky_read_file` loops. Delegate to a Pickle.
- Don't read aloud raw `sessionId`s, paths, or long titles — paraphrase or point the user at the dock card.
