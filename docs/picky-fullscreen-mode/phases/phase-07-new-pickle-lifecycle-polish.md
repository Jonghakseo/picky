# Phase 07. New Pickle and lifecycle polish

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; this phase contains an unresolved product-decision gate.

Goal: integrate new Pickle affordance and lifecycle details without expanding MVP scope into IDE/git controls.

## Files

Modify as needed:

- `Picky/Fullscreen/Views/PickyFullscreenSidebarView.swift`
- existing new Pickle creation flow files from HUD/settings
- `Picky/Fullscreen/PickyFullscreenStateStore.swift`

## Design requirements

- `+ New Pickle` in sidebar should reuse existing creation flow.
- If recent-folder picker is cheap and already available, reuse it. Otherwise defer.
- New session becomes fullscreen-local selected session after creation.
- Do not add mutating worktree/branch/PR/cloud controls.
- **Decision needed:** current fullscreen `변경사항` UI includes read-only branch/worktree metadata and a GitHub link. Product must decide whether those are acceptable read-only metadata or should be removed/reduced to preserve the original no-IDE/git-control boundary.

## Steps

1. Locate existing HUD new Pickle action and dependencies.
2. Expose a small closure/action to fullscreen sidebar.
3. Add sidebar `+ New Pickle` button.
4. On successful creation, set `stateStore.selectedSessionID` to new session.
5. Add empty state for zero sessions.
6. Polish archived/pinned display only if backed by existing fields.

## Validation

- creating new Pickle from fullscreen works or is clearly deferred
- new Pickle appears in sidebar
- new Pickle is selected locally
- closing fullscreen restores dock without losing session
- no mutating worktree/PR/cloud controls appear; read-only branch/worktree metadata and GitHub link remain explicitly marked as a product decision

## Exit criteria

- Fullscreen can start or select work without leaving the workspace, within existing Picky capabilities.
