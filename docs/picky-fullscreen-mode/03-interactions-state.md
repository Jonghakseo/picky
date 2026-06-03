# 03. Interactions and state

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; pseudocode reflects current ownership.

## Mode transition

Fullscreen is an alternative presentation mode, not an additional overlay.

```text
open fullscreen
  resolve target session
  hide HUD dock/panels
  unmount compact composer
  create/focus fullscreen window
  mount fullscreen composer

close fullscreen
  unmount fullscreen composer
  persist state
  release/close fullscreen window
  restore HUD dock/panels
```

## Opening fullscreen

Inputs:

- optional explicit session ID from dock/card expand button
- current open/hovered dock session
- `viewModel.selectedSession`
- most recently updated active session

Algorithm:

```swift
func open(sessionID requested: String?) {
    let resolved = resolveSessionID(requested)
    stateStore.selectedSessionID = resolved
    hudVisibility.hideForFullscreen()
    windowController = makeWindowController(selectedSessionID: resolved)
    windowController?.showWindow(nil)
    windowController?.window?.makeKeyAndOrderFront(nil)
}
```

Rules:

- If fullscreen is already open, focus it and optionally update local selected session.
- Opening fullscreen must not cancel current turns.
- Opening fullscreen must not archive, pin, or otherwise mutate sessions.

## Closing fullscreen

```swift
func close() {
    fullscreenCoordinator.close()
    // PickyFullscreenStateStore persists through its setters.
    // PickyFullscreenModeController.fullscreenDidClose() restores HUD after the window tears down.
}
```

Rules:

- Do not cancel Pickles.
- Do not reset or recreate sessions.
- Let fullscreen composer disappear before restoring dock so draft/attachment persistence runs.
- Restore dock/HUD overlay after fullscreen unmounts.

## Session selection

MVP uses fullscreen-local row selection.

When user clicks a sidebar Pickle:

```text
stateStore.selectedSessionID = session.id
conversation pane updates
composer restores draft for session ID
`변경사항` panel updates
```

Do not call global `viewModel.select(sessionID:)` merely because the user selected a row in fullscreen.

Audit existing view-model actions that may update global selection:

- follow-up
- steering
- screen-context arming
- draft/attachment helpers
- terminal overlay actions

If an action intentionally changes global selection, document the side effect. Since dock mode is hidden during fullscreen, visual conflict is reduced, but restored dock selection should still be predictable.

## Composer lifecycle

The same session must not have two mounted composers.

Reason: `PickyConversationComposerView` owns local state for draft text and attachments and persists through view-model hooks. Two instances can overwrite each other.

Requirement:

```text
HUD compact composer unmounted
  before
fullscreen composer mounted

fullscreen composer unmounted
  before
HUD compact composer restored
```

## File drop

Fullscreen conversation pane should accept file/screenshot drops and forward paths to the same composer pipeline used by `PickyConversationCardView`.

Rules:

- Do not create a separate fullscreen attachment store.
- Do not bypass existing path insertion behavior.
- Dropped screenshots/files remain session draft attachments exactly like HUD composer.

## Screen context

Reuse existing state/actions:

```swift
viewModel.toggleScreenContextTarget(sessionID:)
viewModel.armScreenContextTarget(sessionID:sticky:)
viewModel.clearScreenContextTarget(sessionID:)
```

Fullscreen window must conform to `PickyScreenCaptureExcludedWindow` so screen-context follow-ups do not recursively capture Picky's own workspace.

## Model and thinking

Actions:

```swift
viewModel.cycleModel(sessionID:direction:)
viewModel.cycleThinkingLevel(sessionID:)
```

Display uses effective assistant run fallback from `02-data-contracts.md`.

Do not add model/speed menus that do not exist in current Picky controls.

## Waiting/running/completed states

### Running

- Header shows running status.
- Conversation shows current turn live progress.
- Composer shows stop button if existing HUD conditions say it should.
- `변경사항` panel updates changed files/artifacts/git metadata.

### Waiting for input

- Header/status clearly indicates waiting.
- Pending extension UI remains visible in HUD/fullscreen-visible surface, not hidden in logs.
- Pending extension UI remains visible in HUD/fullscreen surfaces; `변경사항` does not invent queue details unless backed by session data.

### Completed

- Center shows final assistant answer as the primary body for each completed turn, with optional work summary collapsed by default.
- Session-level changed files card may appear near latest answer.
- `변경사항` panel remains available for changed files, artifacts, and read-only git metadata.

## Persistence

MVP store:

```swift
selectedSessionID: String?
isWorkInfoPanelVisible: Bool
```

Recommended backing: existing settings store or `UserDefaults` wrapper matching project conventions.

Persistence rules:

- app-level right panel state
- fullscreen-local selected session is restored if session still exists
- if stored session disappeared, fall back to most recently updated active session
- no session content in fullscreen store
