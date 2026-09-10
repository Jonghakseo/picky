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

- twenty-four 2× PNG scenes covering Small/Medium/Large, light/dark, 100%/130% app font scale, empty/non-empty folders, two selected folder scenes, one pinned light folder scene, two targeted folder scenes, one-, two-, and five-member selected lists, a five-member keyboard-highlighted quick-action list at Small/130%, a four-member idle list with no selected or keyboard-highlighted row, a deterministic completed-Pickle hover preview, a four-character Korean folder label, the folder-to-panel gap relationship, a four-group light-appearance rail over a dark desktop with an opened session, and a light member list over a dark desktop for metadata contrast. Two external-drag scenes add a 35% source row ghost, invalid detached preview, exact target-folder acceptance, and a top-level insertion projection. Empty member lists are intentionally excluded because an open group list requires at least one visible Pickle;
- `index.html` for direct artifact inspection;
- `manifest.json` with separate content-logical and padded-canvas dimensions, pixel dimensions, appearance, preset, and font scale. The canvas keeps a `space.4` (16pt) review margin, exceeding the folder unread badge's documented 7pt visual top overflow (4pt offset + rounded 2.5pt shadow bleed), so intentional overlap is never mistaken for clipping.

It runs only `PickyHUDDockGroupRenderGalleryTests`. That test uses `PickyRenderGalleryRasterizer` (offscreen `NSHostingView` bitmap cache) and the actual `PickyHUDDockGroupFolderTileView`, `PickyHUDDockCollapsedGroupBadge`, `PickyHUDDockGroupEmptySlot`, `PickyHUDDockGroupHeader`, and `PickyHUDDockGroupListView` production components. Fixtures have fixed identities, text, session states, paths, timestamps, and English locale.

The test verifies PNG encoding/decoding, expected 2× canvas dimensions, non-empty alpha content, transparent canvas edges, list panel geometry from `PickyHUDDockGroupListPolicy`, and folder/header geometry from `PickyHUDDockGroupHeaderPresentation`. External-drag scenes use the production list, rail presentation store, rail projection, folder tile, and detached-preview content. It intentionally does not compare byte-for-byte or commit golden images because macOS font and material rendering varies between OS versions.

## Conversation context gallery

```bash
./scripts/render-ui-gallery.sh conversation-context
```

This target writes seven 2× Korean scenes under `build/render-gallery/conversation-context/`: the production header context control, available popover content in dark and light appearance, the unavailable action state, active compaction progress, and context-band ramp states in dark and light appearance. `PickyConversationHeaderRenderGalleryTests` renders the production SwiftUI components without creating an app window. Inspect the PNGs directly; the gallery validates file structure and dimensions but does not prove native popover anchoring or click-outside dismissal.

## Conversation activity gallery

```bash
./scripts/render-ui-gallery.sh conversation-activity
```

This target writes four 2× Korean scenes under `build/render-gallery/conversation-activity/`: collapsed and expanded tool activity summaries in dark and light appearance. `PickyActivitySummaryRenderGalleryTests` renders the production `PickyActivitySummaryView` with deterministic counts and verifies that todo activity stays out of both the compact total and expanded detail grid. Inspect the PNGs directly; the gallery validates file structure and dimensions but does not prove hover, disclosure animation, or tool-history navigation.

## Hub gallery

```bash
./scripts/render-ui-gallery.sh hub
```

This target writes twenty-seven 2× PNGs under `build/render-gallery/hub/`: every production Hub destination (Dashboard, Statistics, Guides, Quick Start, Plugins, Recent Conversation, and Settings) at the 1020×720 default window size in light and dark appearance, plus a 760×560 narrow dark scene for each page. The same three size/appearance variants also cover the production plugin-detail dialog and statistics-reset confirmation. `PickyHubRenderGalleryTests` mounts the actual `PickyHubRootView`, not a gallery-only duplicate, and writes `index.html` and `manifest.json` alongside the images.

The Hub run also writes four full-height Korean settings captures in `build/render-gallery/hub/settings-full/`: 1020pt light/dark at 100%, 760pt dark at 130% font scale, and a 1020pt dark scene with Steer selected. The other scenes show Follow-up selected. These production-root renders expose the groups below General for visual audit. The full-height viewport does not test scroll behavior or expanded advanced tools; inspect those separately. PNG geometry and visible content are validated by the same rasterizer checks as the normal scenes.

The fixture is local and disposable. It uses a unique temporary `PickySettingsStore` root and `UserDefaults` suite, an in-memory agent client that returns a fixed populated statistics snapshot, fixed main-conversation messages, two plugin rows with one installed and one uninstalled state, and an idle Quick Start launcher with all four workflows available. Its permission probes are fixed and it never starts `CompanionManager`, a microphone, a daemon, or an updater. The fixture accepts only simulated `getHubStatistics` and `checkPackageUpdates` commands, then asserts no other lifecycle command was requested.

Guide thumbnails remain the production `AsyncImage` path, but this serialized test installs a narrow `URLProtocol` blocker for `ytimg.com`. The cards therefore show their normal production failure placeholder without fetching remote thumbnails. The gallery does not open a guide modal, so it never creates a WebKit player.

The Hub target passes `-derivedDataPath "${PICKY_DERIVED_DATA_PATH:-/private/tmp/PickyAgentDD}"`. Do not point it at a per-run directory unless the shared agent path is unavailable, and do not run it concurrently with another `xcodebuild` using that path. The test verifies every scene has its exact 2× pixel dimensions, PNG encoding, non-empty alpha, and a multi-color production layout sample. The script independently validates the complete filename matrix, `manifest.json`, `index.html`, and PNG dimensions.

The gallery intentionally has no byte-for-byte golden images. Dashboard greeting copy reads the current clock and local account name, and a few existing page labels use system date formatting, so visual geometry and static state are the reliable oracle. It also cannot prove native menu/popover focus, `NSOpenPanel`, permission requests, updater interactions, WebKit playback, hover/press/focus transitions, or scroll restoration. Inspect those behaviors live only when the changed feature requires them.

## Review limits

Artifacts have a 2× pixel grid tagged 144 dpi, so a viewer shows them at their intended point size. Their detail is still 1 pixel per point: an offscreen `NSHostingView` composites layer contents at `contentsScale == 1`, and the alternatives that do rasterize at 2× lose fidelity (`ImageRenderer` ignores the host appearance and placeholder-fills AppKit-backed views, `dataWithPDF(inside:)` drops layer-drawn surfaces and symbols). Judge geometry, state, and contrast from these artifacts, not glyph antialiasing.

Offscreen material rendering can differ from a displayed child panel. The gallery does not prove live material/vibrancy, native menu/popover behavior, hover/press transitions, drag monitors, accessibility focus, Reduce Transparency fallback, or actual child-`NSPanel` anchoring. Inspect those behaviors separately when the relevant change requires it.

## Local-data dashboard audit

To inspect long titles, project names, counts, and usage from real sessions without
restarting the running app or taking desktop screenshots:

```bash
TMPDIR=/private/tmp pnpm --dir agentd exec tsx ../scripts/export-hub-render-data.mts \
  --output /private/tmp/picky-dashboard-audit/live-statistics.json \
  --pi-settings "$HOME/.pi/agent/settings.json"
./scripts/render-hub-data-audit.sh \
  /private/tmp/picky-dashboard-audit/live-statistics.json \
  /private/tmp/picky-dashboard-audit/render \
  /private/tmp/picky-dashboard-audit/live-statistics.packages.json
```

Use `--source` for a non-default Picky App Support directory and pass the actual Pi
settings path if `PI_CODING_AGENT_DIR` or Picky's Pi directory setting differs.
The exporter reads session metadata, referenced transcripts, and saved
classifications into an isolated temporary projection, runs the production
`HubStatisticsService`, and removes the projection before publishing. It never
connects to the live daemon. Its derived-cache writes stay in the temporary root.
The provenance sidecar records counts and unavailable transcripts separately.
Package export is optional and retains only the `packages` field, not credentials
or unrelated Pi settings. The files can contain private task and project names;
keep them local and do not commit or upload the artifacts.

The opt-in gallery decodes the snapshot through the production wire decoder and
loads it through the real statistics store with an in-memory transport. It renders
the production Dashboard, work statistics, and usage statistics at 1020pt in dark
and light appearance and at 760pt/130% text in dark appearance, in Korean. Tall
viewports reveal sections below the normal scroll fold without moving a real
window. Table height grows with the record/model count. An input with no visible
work or usage is rejected instead of certifying an empty state as a chart audit.
Choose an empty output directory on each run; inspect the nine PNGs, including
their lower sections, not just the manifest.

This proves static layout for the exported data and widths, not live scrolling,
hover, focus, vibrancy, or OS permission behavior. Permissions and launch actions
remain inert fixtures. Video thumbnails use a blocked-network placeholder, and
plugin versions are omitted when only package declarations are provided. The
ordinary deterministic `hub` gallery continues to use its synthetic fixtures.
