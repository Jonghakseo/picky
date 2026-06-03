# Phase 01. Shell and window lifecycle

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: maintain a safe fullscreen-capable shell with strong AppKit ownership and capture exclusion.

## Files

Current files:

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
- Shell composes the implemented sidebar, conversation pane, and `변경사항` panel.

## Current implementation notes

- `PickyFullscreenStateStore`, `PickyFullscreenWindow`, `PickyFullscreenWindowController`, and `PickyFullscreenCoordinator` exist.
- Entry points are production-hidden by `PickyFullscreenFeatureFlags` unless `PICKY_FULLSCREEN_ENABLED=1`.
- HUD visibility is now handled by phase 02 / `PickyFullscreenModeController`, so the original “no HUD behavior changes yet” constraint is historical.

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
- HUD behavior is coordinated by `PickyFullscreenModeController`; no session mutation occurs during open/close.
