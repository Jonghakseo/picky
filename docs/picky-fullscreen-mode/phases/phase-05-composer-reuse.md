# Phase 05. Composer reuse

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: reuse `PickyConversationComposerView` in fullscreen without duplicating behavior or corrupting draft/attachment state.

## Files

Modify:

- `Picky/HUD/Conversation/PickyConversationComposerView.swift` only if small dependency seams are needed
- `Picky/Fullscreen/Views/PickyFullscreenConversationPaneView.swift`
- `Picky/Fullscreen/Views/PickyFullscreenWorkspaceView.swift`

Tests:

- focused view-model/draft tests if existing coverage allows
- manual QA for autocomplete/drop/screen-context behavior

## Design requirements

- Do not build a fullscreen-only composer.
- Do not mount HUD composer and fullscreen composer simultaneously.
- Preserve existing behavior for drafts, attachments, slash autocomplete, file autocomplete, screen context chip, notify, terminal, send/stop, model/thinking controls.
- Fullscreen drop target forwards files into existing composer pipeline.

## Integration rules

- Fullscreen composer receives the same session ID selected in fullscreen.
- If selected session changes, composer draft/attachments restore by session ID.
- Fullscreen reuses `PickyConversationComposerView` submit routing. `followUp(text:sessionID:)` is used only when the shared composer policy selects follow-up; running/queued/waiting/cancelled/failed sessions may steer according to existing HUD behavior.
- Stop button uses the same existing view-model action/conditions as HUD composer.

## Current implementation notes

- `PickyFullscreenConversationPaneView` mounts the shared `PickyConversationComposerView`.
- File drops are forwarded through the shared draft/attachment path binding.
- `.id(session.id)` remounts the composer when fullscreen-local selection changes.
- `PickyFullscreenModeController` hides HUD before opening fullscreen and restores it after close, preventing duplicate composer mounting.

## Validation

Manual QA:

- type draft, close/reopen fullscreen, draft persists
- switch sessions, each draft is preserved separately
- drop file/screenshot, path appears in composer
- slash autocomplete works
- file mention autocomplete works
- screen context chip appears when armed
- notify toggle works
- terminal toggle works
- submit/steer updates the same session according to shared HUD composer policy
- stop button appears under same conditions as HUD

## Exit criteria

- Fullscreen composer behavior matches HUD composer without copied logic.
