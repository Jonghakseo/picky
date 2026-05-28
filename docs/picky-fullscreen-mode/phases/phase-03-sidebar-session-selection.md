# Phase 03. Sidebar session selection

Goal: render the left Pickle list and support fullscreen-local session selection.

## Files

Create:

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
- `+ New Pickle` affordance can be placeholder until phase 07.

## Selection fallback

```text
requested session ID if exists
else stored selected session ID if exists
else viewModel.selectedSession if exists
else most recently updated active session
else nil
```

## Steps

1. Add selection resolver pure helper.
2. Render sidebar list with title/status/updated time.
3. Bind row selection to `stateStore.selectedSessionID`.
4. Update workspace to derive selected `SessionCard` from state store.
5. Add empty state when no sessions exist.

## Validation

- switching rows updates center/right placeholders
- persisted selected session restores if still available
- deleted/missing selected session falls back safely
- global HUD selection does not unexpectedly change from row clicks

## Exit criteria

- Fullscreen can browse active Pickles independently of dock visibility.
