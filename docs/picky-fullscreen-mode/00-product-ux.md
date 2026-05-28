# 00. Product UX

Status: design only.

## Goal

Add a focused fullscreen workspace for an existing Pickle session.

The workspace has four areas:

```text
┌──────────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ Left sidebar          │ Center conversation                          │ Right work info       │
│                      │                                              │                      │
│ + New Pickle          │ Pickle title / cwd/git/model/thinking chips  │ 작업 정보             │
│ Pickle list           │                                              │ Status/runtime        │
│                      │ user message                                 │ Context usage         │
│                      │ final assistant answer only                   │ Activity/tools        │
│                      │ session changed files card                    │ Session changed files │
│                      │                                              │ Artifacts/queues      │
│                      │ Composer                                     │ [collapse]            │
└──────────────────────┴──────────────────────────────────────────────┴──────────────────────┘
```

## Entry point

Add an explicit fullscreen/expand affordance to the Pickle dock. Do not overload the existing `+` add-Pickle slot.

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
- Completed/non-current turn: show user request and final assistant answer only.
- System completion/failure rows may appear separately as compact status rows.
- Do not show every internal progress log after completion.

## Right panel rule

The right panel label is `작업 정보`.

It uses existing Pickle session data only. It must not show:

- active app
- active window
- browser URL/title
- selected text
- screenshot paths
- line additions/deletions

unless those become stable persisted session fields in a later design.

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

Do not add permission selector, plan mode, plugin menu, goal suggestions, cloud transfer, worktree/PR controls, or other Codex-only controls.

## Collapsed right panel

Right panel collapsed/open state should be remembered. MVP scope: app-level global preference.

```text
┌──────────────────────┬──────────────────────────────────────────────────────────────┬──────┐
│ Left sidebar          │ Center conversation                                          │ info │
│ Pickles               │ Larger chat width                                            │ rail │
│                      │ Composer remains wide                                        │  ⓘ   │
└──────────────────────┴──────────────────────────────────────────────────────────────┴──────┘
```
