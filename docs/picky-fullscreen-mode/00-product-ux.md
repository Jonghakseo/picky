# 00. Product UX

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; current implementation notes below supersede the original design-only wording.

## Goal

Add a focused fullscreen workspace for an existing Pickle session.

The workspace has four areas:

```text
┌──────────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ Left sidebar          │ Center conversation                          │ Right work info       │
│                      │                                              │                      │
│ + New Pickle          │ Pickle title / cwd/status/model/context chips│ 변경사항             │
│ Pickle list           │                                              │ Branch/worktree      │
│                      │ user message                                 │ Changed files         │
│                      │ final answer + optional work summary          │ Artifacts / links     │
│                      │ turn/session changed-files card              │                      │
│                      │                                              │                      │
│                      │ Composer                                     │ [collapse]            │
└──────────────────────┴──────────────────────────────────────────────┴──────────────────────┘
```

## Entry point

Add an explicit fullscreen/expand affordance to the Pickle dock. Do not overload the existing `+` add-Pickle slot. The control is currently hidden unless `PICKY_FULLSCREEN_ENABLED` is enabled in the launching environment.

Recommended SF Symbols:

- `arrow.up.left.and.arrow.down.right`
- `arrow.up.left.and.arrow.down.right.square`
- `rectangle.expand.vertical`

Placement:

```text
┌───────────────┐
│     ───       │ dock drag handle
│   [expand]    │ fullscreen button
│               │
│   [pickle]    │
│   [pickle]    │
│               │
│      ·        │ add-Pickle slot
└───────────────┘
```

## Opening behavior

1. Resolve target session:
   - open compact Pickle card session
   - else hovered/active dock icon session
   - else `viewModel.selectedSession`
   - else most recently updated active session
2. Hide HUD dock/panels.
3. Open fullscreen workspace.
4. If no sessions exist, either disable the button or show an empty shell with `+ New Pickle` in the sidebar.

## Closing behavior

1. Unmount fullscreen workspace/composer.
2. Persist fullscreen UI state.
3. Close fullscreen window.
4. Restore HUD dock/panels.
5. Do not cancel, reset, archive, or otherwise mutate Pickle sessions.

## Center conversation rule

The center is a clean LLM chat UI, not a dashboard.

- Running/current turn: show live progress, tool activity, thinking/progress rows, and streaming/latest assistant text.
- Completed/non-current turn: show user request and final assistant answer as the primary body.
- Intermediate completed-turn work logs may appear only behind the expandable work-summary row.
- System completion/failure rows may appear separately as compact status rows.
- Changed-files cards must label their scope: `변경 파일` for turn-scoped diffs, `세션 변경 파일` for session fallback.
- Do not replay every internal progress log inline after completion.

## Right panel rule

The right panel label is `변경사항`.

It is read-only. Current implementation may show session changed files, artifacts, branch/worktree summary, `+/-` metrics, and diff-derived file rows from the selected Pickle `cwd`. It must not show transient desktop context that was not intentionally persisted as session/worktree data:

- active app
- active window
- current browser URL/title
- selected text
- screenshot paths or thumbnails

Phase 07 tracks the remaining product decision: whether read-only branch/worktree metadata and the GitHub link are allowed long-term under the “no IDE/git controls” non-goal, or whether they should be reduced. Do not add mutating branch/worktree/PR/cloud controls without resolving that gate.

## Composer rule

Fullscreen composer must expose existing Pickle composer capabilities only:

- follow-up text
- slash command autocomplete
- file mention autocomplete
- dropped file/screenshot path insertion
- persisted draft and attachments
- screen-context armed chip
- notify on completion toggle
- terminal toggle
- send/stop
- bash/private bash syntax behavior
- model cycling
- thinking-level cycling

Do not add permission selector, plan mode, plugin menu, goal suggestions, cloud transfer, mutating worktree/PR controls, or other Codex-only controls. Read-only branch/worktree metadata remains covered by the phase 07 decision gate.

## Collapsed right panel

Right panel collapsed/open state should be remembered. MVP scope: app-level global preference.

```text
┌──────────────────────┬──────────────────────────────────────────────────────────────┬──────┐
│ Left sidebar          │ Center conversation                                          │ info │
│ Pickles               │ Larger chat width                                            │ rail │
│                      │ Composer remains wide                                        │  ⓘ   │
└──────────────────────┴──────────────────────────────────────────────────────────────┴──────┘
```
