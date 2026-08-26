# UI render gallery

The render gallery produces reviewable PNG artifacts from production SwiftUI views without launching Picky.app, opening an `NSWindow`/`NSPanel`, taking a desktop screenshot, or using WindowServer automation.

## Dock-group gallery

```bash
./scripts/render-ui-gallery.sh dock-group
```

The command cleans and regenerates `build/render-gallery/dock-group/` with:

- twelve 2× PNG scenes covering Small/Medium/Large, light/dark, 100%/130% app font scale, empty/non-empty folders, two- and five-member selected lists, a four-character Korean folder label, and the folder-to-panel gap relationship;
- `index.html` for direct artifact inspection;
- `manifest.json` with logical/pixel dimensions, appearance, preset, and font scale.

It runs only `PickyHUDDockGroupRenderGalleryTests`. That test uses an offscreen `NSHostingView` bitmap cache and the actual `PickyHUDDockGroupFolderTileView`, `PickyHUDDockCollapsedGroupBadge`, `PickyHUDDockGroupEmptySlot`, `PickyHUDDockGroupHeader`, and `PickyHUDDockGroupListView` production components. Fixtures have fixed identities, text, session states, paths, timestamps, and English locale.

The test verifies PNG encoding/decoding, expected 2× dimensions, non-empty alpha content, list panel geometry from `PickyHUDDockGroupListPolicy`, and folder/header geometry from `PickyHUDDockGroupHeaderPresentation`. It intentionally does not compare byte-for-byte or commit golden images because macOS font and material rendering varies between OS versions.

## Review limits

Offscreen material rendering can differ from a displayed child panel. The gallery does not prove live material/vibrancy, native menu/popover behavior, hover/press transitions, drag monitors, accessibility focus, Reduce Transparency fallback, or actual child-`NSPanel` anchoring. Inspect those behaviors separately when the relevant change requires it.
