# Phase 05. Composer reuse

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
- `followUp(text:sessionID:)` is used for submit.
- Stop button uses the same existing view-model action/conditions as HUD composer.

## Steps

1. Identify current `PickyConversationComposerView` initializer dependencies.
2. Add only minimal parameters needed for fullscreen layout if any.
3. Mount composer in fullscreen conversation pane.
4. Add drop forwarding from center pane to composer path insertion mechanism.
5. Verify HUD composer is unmounted before fullscreen composer mounts.
6. Verify fullscreen composer unmounts before HUD restore.

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
- send follow-up updates same session
- stop button appears under same conditions as HUD

## Exit criteria

- Fullscreen composer behavior matches HUD composer without copied logic.
