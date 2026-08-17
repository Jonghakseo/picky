# Utility panel: Progress + Artifacts

Status: Cycle 2 implemented (2026-08-17).

The Pickle utility panel contains `터미널 | 진행 | 작업물`. `진행` is a compact progress dashboard, not a raw tool-log browser; `작업물` lists file artifacts only. The detached tool-history viewer remains available.

## Confirmed product decisions

- `진행` answers what is running, what changed, and what failed before exposing raw history.
- Tool details remain available through the secondary `세부 활동 N건 보기` disclosure.
- File artifacts have **write-only provenance**. A file mentioned in an assistant answer is never registered as a session artifact.
- Files remain separate from the conversation artifact tray, which continues to render links/reports only.

## Progress dashboard

- The top row gives authoritative session state: the latest running tool when present, otherwise working, input-needed, failed, blocked, queued, completed, or cancelled state.
- Key progress is newest first and includes edits/writes, bash results, and subagent work; it shows at most 12 items and points to details for older items.
- Only successful, provably read-only investigation (`read` and conservative `rg`/`grep`/`find` searches without shell control, redirection, or mutation) is collapsed into `조사 N건`. Failed or running investigation remains visible.
- Compact metadata reports unique changed files, commands, and agent identities.
- All raw rows use the existing `PickyToolHistoryEntryView` only after the user expands details. The dashboard projects entries once per render and uses `LazyVStack` to bound initial rendering.
- The progress tab keeps the running indicator. Turn-aware failure indicators remain future work.

## File artifact contract

A file artifact is an allowed non-source file Pi saved successfully with its file-writing tool. Structured `write` tool events provide the normalized path; display previews are never parsed for provenance.

- Existing files overwritten by `write` are included.
- Source files, hidden paths, dependency/build output, and system temporary paths are excluded.
- macOS `/var/...` and `/private/var/...` system-temp aliases are both excluded, including safe realpath aliases when available.
- Rewriting the same path updates its existing artifact. `updatedAt` is strictly monotonic even if the clock repeats a millisecond or moves backward, so the unseen badge is re-armed.
- Final-answer extraction was removed. Link materialization behavior is unchanged.

## UI state and accessibility

- Persisted `activity` tab selection migrates to `progress`; obsolete `changes` still falls back to terminal.
- The terminal remains mounted across tab changes, requests first responder only while the terminal tab is selected, and resigns an already-held terminal or descendant responder when it becomes hidden.
- Artifact seen state advances to the latest currently rendered file `updatedAt`, never `Date()`, and does not advance for an empty artifacts tab. Actual `NSPanel` visibility remains required.
- Artifact rows use accessibility containment so Open, Finder, and Copy Path remain separately reachable by VoiceOver.

## Deferred work

Turn grouping, per-file diffs, full-history retrieval beyond the snapshot cap, turn-aware failure badges, and detached tool-history viewer absorption are not implemented. Full bash output remains available in the detached viewer; progress details show the existing preview rows.

## Test coverage

- Pure Swift progress projection covers authoritative header state and accessibility keys, ordering, conservative investigation collapse, subagent recognition, unique counts, compact-list truncation, all-investigation, empty state, and raw-detail count.
- Swift state tests cover tab migration, terminal focus resignation/eligibility, and delayed artifact visibility.
- agentd tests cover write-only provenance, monotonic rewrites, clock rollback, and temporary-path exclusion.
