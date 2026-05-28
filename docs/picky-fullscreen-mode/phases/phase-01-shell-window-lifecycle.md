# Phase 01. Shell and window lifecycle

Goal: create a safe fullscreen-capable shell with strong AppKit ownership, capture exclusion, and no HUD integration yet beyond test hooks.

## Files

Create:

- `Picky/Fullscreen/PickyFullscreenCoordinator.swift`
- `Picky/Fullscreen/PickyFullscreenWindowController.swift`
- `Picky/Fullscreen/PickyFullscreenWindow.swift`
- `Picky/Fullscreen/PickyFullscreenStateStore.swift`
- `Picky/Fullscreen/Views/PickyFullscreenWorkspaceView.swift`

Tests:

- `PickyTests/PickyFullscreenStateStoreTests.swift`
- `PickyTests/PickyFullscreenCoordinatorTests.swift` if feasible with fakes

## Design requirements

- `PickyFullscreenWindow` is an `NSWindow` subclass conforming to `PickyScreenCaptureExcludedWindow`.
- Window is strongly owned by `PickyFullscreenWindowController`, retained by `PickyFullscreenCoordinator`.
- No `weak var window`.
- Coordinator APIs are `@MainActor`.
- Closing the window calls back into coordinator once and is idempotent.
- Shell displays placeholder three-column layout only.

## Steps

1. Add `PickyFullscreenStateStore` with persisted `isWorkInfoPanelVisible` and `selectedSessionID`.
2. Add `PickyFullscreenWindow` with capture-exclusion conformance.
3. Add `PickyFullscreenWindowController` that hosts `PickyFullscreenWorkspaceView`.
4. Add `PickyFullscreenCoordinator` with `open`, `close`, `toggle`.
5. Wire a temporary internal debug entry only if needed; remove/hide before final UX.

## Validation

Run targeted build:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
```

Manual checks:

- opening shell creates one window
- repeated open focuses existing window
- close releases controller
- close callback is not double-fired
- window is excluded from screen capture paths that use `PickyScreenCaptureExcludedWindow`

## Exit criteria

- Fullscreen shell can open/close without session mutation.
- Strong ownership is clear in code review.
- No HUD behavior changes yet.
