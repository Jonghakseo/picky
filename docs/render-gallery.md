# UI render gallery

The render gallery produces reviewable PNG artifacts from production SwiftUI views without launching Picky.app, opening an `NSWindow`/`NSPanel`, taking a desktop screenshot, or using WindowServer automation.

## When to use

Use the render gallery whenever a change can alter the dock-group folder or list visually, including:

- layout, spacing, padding, alignment, sizing, corner radius, material, color, shadow, typography, truncation, badges, or state backgrounds;
- selected, idle, unread, empty-folder, and combined folder-to-panel presentation;
- dock size presets, light/dark appearance, app font scale, or CJK text behavior;
- refactors that should preserve the current appearance of a production component.

Run it before requesting visual review and before considering the UI task complete. Compare the exact scenes affected by the change, not only whether the command passed. If the existing matrix does not represent the changed state, add a deterministic scene backed by the production component rather than a gallery-only imitation.

The gallery is not a substitute for live interaction checks when a change concerns hover/press transitions, drag behavior, menus, popovers, accessibility focus, material/vibrancy, or child-panel anchoring. Use the gallery for the static appearance, then validate those behaviors separately without assuming a good PNG proves them.

## How to use

1. For a before/after review, render the unchanged baseline first and preserve the generated directory outside `build/render-gallery/dock-group/`, because the next run cleans that directory:

   ```bash
   ./scripts/render-ui-gallery.sh dock-group
   rm -rf build/render-gallery/dock-group-before
   cp -R build/render-gallery/dock-group build/render-gallery/dock-group-before
   ```

2. Make the UI change in the production SwiftUI component. Do not reproduce the component with gallery-only shapes, text, or screenshots.

3. Regenerate the gallery:

   ```bash
   ./scripts/render-ui-gallery.sh dock-group
   ```

4. Inspect the artifacts in `build/render-gallery/dock-group/`:

   - `index.html`: all scenes and their preset, appearance, font scale, and logical dimensions;
   - `manifest.json`: exact scene names and canvas/content geometry;
   - individual PNG files: direct visual inspection at 2× scale. A coding agent should read the relevant PNG files directly rather than launching Picky.app.

5. Compare the affected before/after scenes. Check content insets, alignment, clipping, truncation, state distinction, light/dark contrast, Small/Medium/Large density, 100%/130% font scale, and CJK text where applicable. Confirm unrelated scenes did not change unexpectedly.

6. If coverage is missing, add a stable scene in `PickyTests/PickyHUDDockGroupRenderGalleryTests.swift`, add its filename to `scripts/render-ui-gallery.sh`, regenerate the gallery, and update this document's scene count or coverage description. Keep fixture IDs, text, timestamps, locale, state, and geometry deterministic.

7. Treat a successful command as structural validation only. The task is visually verified only after the relevant PNGs have been inspected and any interaction-specific checks from the previous section have been completed.

## Dock-group gallery

```bash
./scripts/render-ui-gallery.sh dock-group
```

The command cleans and regenerates `build/render-gallery/dock-group/` with:

- twenty 2× PNG scenes covering Small/Medium/Large, light/dark, 100%/130% app font scale, empty/non-empty folders, two selected folder scenes, two targeted folder scenes, one-, two-, and five-member selected lists, a five-member keyboard-highlighted quick-action list at Small/130%, a four-member idle list with no selected or keyboard-highlighted row, a four-character Korean folder label, and the folder-to-panel gap relationship. Two external-drag scenes add a 35% source row ghost, invalid detached preview, exact target-folder acceptance, and a top-level insertion projection. Empty member lists are intentionally excluded because an open group list requires at least one visible Pickle;
- `index.html` for direct artifact inspection;
- `manifest.json` with separate content-logical and padded-canvas dimensions, pixel dimensions, appearance, preset, and font scale. The canvas keeps a `space.4` (16pt) review margin, exceeding the folder unread badge's documented 7pt visual top overflow (4pt offset + rounded 2.5pt shadow bleed), so intentional overlap is never mistaken for clipping.

It runs only `PickyHUDDockGroupRenderGalleryTests`. That test uses an offscreen `NSHostingView` bitmap cache and the actual `PickyHUDDockGroupFolderTileView`, `PickyHUDDockCollapsedGroupBadge`, `PickyHUDDockGroupEmptySlot`, `PickyHUDDockGroupHeader`, and `PickyHUDDockGroupListView` production components. Fixtures have fixed identities, text, session states, paths, timestamps, and English locale.

The test verifies PNG encoding/decoding, expected 2× canvas dimensions, non-empty alpha content, transparent canvas edges, list panel geometry from `PickyHUDDockGroupListPolicy`, and folder/header geometry from `PickyHUDDockGroupHeaderPresentation`. External-drag scenes use the production list, rail presentation store, rail projection, folder tile, and detached-preview content. It intentionally does not compare byte-for-byte or commit golden images because macOS font and material rendering varies between OS versions.

## Conversation context gallery

```bash
./scripts/render-ui-gallery.sh conversation-context
```

This target writes five 2× Korean scenes under `build/render-gallery/conversation-context/`: the production header context control, available popover content in dark and light appearance, the unavailable action state, and active compaction progress. `PickyConversationHeaderRenderGalleryTests` renders the production SwiftUI components without creating an app window. Inspect the PNGs directly; the gallery validates file structure and dimensions but does not prove native popover anchoring or click-outside dismissal.

## Review limits

Offscreen material rendering can differ from a displayed child panel. The gallery does not prove live material/vibrancy, native menu/popover behavior, hover/press transitions, drag monitors, accessibility focus, Reduce Transparency fallback, or actual child-`NSPanel` anchoring. Inspect those behaviors separately when the relevant change requires it.
