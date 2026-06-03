# Phase 03. Sidebar session selection

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: render the left Pickle list and support fullscreen-local session selection.

## Files

Current files:

- `Picky/Fullscreen/Views/PickyFullscreenSidebarView.swift`
- `Picky/Fullscreen/Domain/PickyFullscreenSessionSelection.swift`

Modify:

- `Picky/Fullscreen/Views/PickyFullscreenWorkspaceView.swift`
- `Picky/Fullscreen/PickyFullscreenStateStore.swift`

Tests:

- selection fallback helper tests

## Design requirements

- Sidebar reads from `PickySessionListViewModel.SessionCard` list.
- Selection is fullscreen-local in MVP.
- Selecting a row updates fullscreen state store, not necessarily global HUD selection.
- Archived sessions are deferred unless already cheap and clearly separated.
- `+ New Pickle` reuses the recent-folder picker and creates/selects a fullscreen-local session.

## Selection fallback

```text
requested session ID if exists
else stored selected session ID if exists
else viewModel.selectedSession if exists
else most recently updated active session
else nil
```

## Current implementation notes

- `PickyFullscreenSessionSelection` implements requested → stored → view-model selected → most-recent fallback.
- `PickyFullscreenSidebarView` renders session rows, empty state, and the New Pickle affordance.
- `PickyFullscreenWorkspaceView` creates an empty Pickle via `viewModel.createEmptyPickleSession(cwd:)` and selects it locally.

## Validation

- switching rows updates center/right placeholders
- persisted selected session restores if still available
- deleted/missing selected session falls back safely
- global HUD selection does not unexpectedly change from row clicks

## Exit criteria

- Fullscreen can browse active Pickles independently of dock visibility.
