---
name: manage-pickles
description: Decide how to delegate, steer, inspect, archive, or abort Pickles when the user mentions ongoing work or asks Picky to do something non-trivial.
---

# Managing Pickles

## When to use
- The user references "그 피클", "방금 거", "진행 중인 작업" or asks Picky to do anything that needs files, multiple steps, or long-running tools.

## What to do
1. **Look up first.** Call `picky_pickle_sessions` before starting or steering anything when the user refers to existing work. Match by title / cwd / recency, not by guessing.
2. **Reuse over re-spawn.** If a Pickle that fits the user's intent is still running, call `picky_steer_pickle` with a delta-only message. Spawn a new one with `picky_start_pickle` only when no live Pickle matches or the task is clearly distinct.
3. **Shape `picky_start_pickle.instructions` as a delta.** Compact what the Pickle needs to act: goal, constraints, the one or two files / URLs / IDs that ground it. Skip backstory the Pickle can re-derive.
4. **Check progress without spawning.** "어떻게 돼가?" → `picky_inspect_active_pickle({ sessionId })`. Never start a new Pickle just to read another one's state.
5. **Abort only on explicit request.** `picky_abort_pickle` runs only when the user clearly says stop / cancel / kill. Resolve the right `sessionId` via `picky_pickle_sessions` first.
6. **Unarchive then route by status.** `picky_unarchive_pickle` flips visibility only. After it returns, push the user toward `picky_steer_pickle` if still running, or `picky_start_pickle` if the status is terminal.

## What NOT to do
- Don't run long tasks inline via `picky_run_bash` / `picky_read_file` loops. Delegate to a Pickle.
- Don't read aloud raw `sessionId`s, paths, or long titles — paraphrase or point the user at the dock card.
