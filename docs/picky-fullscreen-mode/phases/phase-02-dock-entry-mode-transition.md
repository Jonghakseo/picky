# Phase 02. Dock entry and mode transition

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: add dock expand entry point and enforce dock/fullscreen mutual exclusion.

## Files

Modify:

- `Picky/PickyApp.swift`
- `Picky/HUD/PickyHUDView.swift`
- `Picky/HUD/PickyHUDDockRailView.swift` or current dock rail file
- `Picky/HUD/PickyHUDOverlayManager.swift`

Current supporting files:

- `Picky/Fullscreen/PickyFullscreenModeController.swift`
- `Picky/HUD/PickyHUDVisibilityControlling.swift`

Tests:

- coordinator/mode-controller unit tests with fake HUD visibility

## Design requirements

- Expand button is visually distinct from add-Pickle.
- Opening fullscreen hides HUD dock/panels before fullscreen composer can mount.
- Closing fullscreen restores HUD dock/panels after fullscreen unmounts.
- Mode transition is idempotent.
- No session cancellation or mutation.

## Suggested API

```swift
@MainActor
protocol PickyHUDVisibilityControlling: AnyObject {
    var isHUDVisibleForFullscreen: Bool { get }
    func hideForFullscreen()
    func restoreAfterFullscreen()
}
```

`PickyHUDOverlayManager` can implement this directly or delegate to a small helper.

## Current implementation notes

- `PickyHUDView` exposes the fullscreen affordance when `PickyFullscreenFeatureFlags.isEnabled`.
- `PickyApp` wires the HUD action to `PickyFullscreenModeController.open(sessionID:)`.
- `PickyHUDOverlayManager` implements `PickyHUDVisibilityControlling`; close flows restore HUD through `fullscreenDidClose()`.

## Validation

Manual checks:

- dock expand opens the intended Pickle
- dock/panels disappear while fullscreen is visible
- closing fullscreen restores dock/panels
- no compact composer remains mounted during fullscreen
- add-Pickle hover/drag behavior still works

## Exit criteria

- There is no visible state where dock mode and fullscreen mode coexist.
- There is no duplicate composer for the same session.
