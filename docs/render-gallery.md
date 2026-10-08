# UI render gallery

The render gallery produces reviewable PNG artifacts from production SwiftUI views without launching Picky.app, opening an `NSWindow`/`NSPanel`, taking a desktop screenshot, or using WindowServer automation.

The [Swift UI mockup runbook](../runbook/swift-ui-mockup.md) is the canonical execution and review workflow. It separates production validation from explicitly requested proposal mockups and covers 1:1 sizing, linked Debug harnesses, artifact review, and safe opening. The [project skill](../.agents/skills/picky-swift-ui-mockup/SKILL.md) links to that workflow and owns reusable tools and examples. This document lists production targets, supported scenes, and rendering limits.

## When to use

Use the render gallery whenever a change can alter the list dock visually, including:

- layout, spacing, padding, alignment, sizing, corner radius, material, color, shadow, typography, truncation, badges, or state backgrounds;
- collapsed and expanded group headers, empty-group placeholders, opened, unread, and screen-context rows;
- dock size presets (S/M/L), vertical and horizontal orientation, light/dark appearance, or CJK text behavior;
- refactors that should preserve the current appearance of a production component.

Run it before requesting visual review and before considering the UI task complete. Compare the exact scenes affected by the change, not only whether the command passed. If the existing matrix does not represent the changed state, add a deterministic scene backed by the production component rather than a gallery-only imitation.

The gallery is not a substitute for live interaction checks when a change concerns hover/press transitions, drag behavior, menus, popovers, accessibility focus, material/vibrancy, or the resize tab. Use the gallery for the static appearance, then validate those behaviors separately without assuming a good PNG proves them.

## Dock gallery

```bash
./scripts/render-ui-gallery.sh dock-group
```

The command writes 90 production dock images to `build/render-gallery/dock-chrome/` through `PickyHUDDockChromeTests`. The matrix covers S/M/L, light/dark, and vertical/horizontal for seven states: a collapsed group, an expanded group, two expanded groups back to back (their cards keep a gap), an expanded empty group with its drop placeholder, an empty dock, overflow, and an attention state (opened row, unread row, and a Pickle armed for the next Picky input). It adds the two 32pt restore-button appearances and four `backdrop-*` scenes that place the M dock over white and black in each appearance (the live HUD panel is transparent). The scenes mount `PickyHUDDockRailView` with its actual notches, rows, headers, utility controls, and archive access. Fixtures have fixed identities, Korean titles, statuses, and timestamps.

To compare before and after a change, copy `build/render-gallery/dock-chrome/` aside before regenerating; the command overwrites the same files. If coverage is missing, add a `FixtureState` case in `PickyTests/PickyHUDDockChromeTests.swift`, add it to the expected matrix in `scripts/render-ui-gallery.sh`, and update the count here.

The same command runs the geometry contract tests: the rendered rail must match `PickyHUDDockRailLayoutPolicy` (the length and thickness panel placement uses before SwiftUI measures anything), plus the minimization, drop-candidate, resize-snap, and core policy suites. It uses Xcode 16.3 and the shared `/private/tmp/PickyAgentDD`. Offscreen renders can drop bare SF Symbols and asset-catalog status glyphs (the `+` utility, waiting/failed Pickle glyphs); check those in the running app. Static rendering does not prove real panel anchoring, desktop pass-through, drag gestures, or keyboard focus.

## Conversation context gallery

```bash
./scripts/render-ui-gallery.sh conversation-context
```

This target writes nine 2× Korean scenes under `build/render-gallery/conversation-context/`: the production header context control, available popover content in dark and light appearance, the unavailable action state, active compaction progress, context-band ramp states in dark and light appearance, and the full production card with Command shortcut hints shown in dark and light appearance (checks that header badges stay inside the card's clip bounds). `PickyConversationHeaderRenderGalleryTests` renders the production SwiftUI components without creating an app window. Inspect the PNGs directly; the gallery validates file structure and dimensions but does not prove native popover anchoring or click-outside dismissal.

## Conversation composer gallery

```bash
./scripts/render-ui-gallery.sh conversation-composer
```

This target writes twenty 2× Korean scenes under `build/render-gallery/conversation-composer/`. They cover the production composer, model and thinking pickers, Fast mode off/on controls, and the first-activation cost notice in light and dark appearance. `PickyConversationHeaderRenderGalleryTests` mounts the actual `PickyConversationRuntimeControlsView` and its popover content directly without opening a window. The six Fast mode scenes show the control states and complete notice text; they do not prove native popover anchoring, first-click presentation, or acknowledgement persistence. The command uses the shared agent DerivedData path.

## Conversation activity gallery

```bash
./scripts/render-ui-gallery.sh conversation-activity
```

This target writes four 2× Korean scenes under `build/render-gallery/conversation-activity/`: collapsed and expanded tool activity summaries in dark and light appearance. `PickyActivitySummaryRenderGalleryTests` renders the production `PickyActivitySummaryView` with deterministic counts and a fixed turn duration (collapsed label `2분 5초 동안 완료`); the expanded detail grid leaves out todo activity. Inspect the PNGs directly; the gallery validates file structure and dimensions but does not prove hover, disclosure animation, or tool-history navigation.

## Messenger UX gallery

```bash
./scripts/render-ui-gallery.sh messenger-ux
```

This target writes ten 2× Korean scenes under `build/render-gallery/messenger-ux/` for `design/proposals/messenger-ux-2026-10.md`: the Pickle chat (date dividers, an older reply with in-place `더 보기`, send-time labels, the clock for a message still being sent, and the presence line) at rest and with one bubble's time pinned to stand in for hover, presence-line states, the RECT translation callout overlay over a fixture desktop, and main-agent cursor chips under the concise policy. `PickyMessengerUXRenderGalleryTests` mounts the production bubbles, `PickyConversationPresenceRow`, `PickyConversationDateDivider`, `PickyAgentAnnotationOverlayView`, and `PickyMainActivityChipStackView`; only the desktop backdrop under the overlay is a fixture. It cannot prove pointer hover, the typing-dot animation, or overlay pass-through.

## Hub gallery

```bash
./scripts/render-ui-gallery.sh hub
```

This target writes thirty-nine 2× PNGs under `build/render-gallery/hub/`: every production Hub destination (Dashboard, Statistics, Guides, Quick Start, Scheduled Jobs, Plugins, Recent Conversation, Web access, and Settings) at the 1020×720 default window size in light and dark appearance, plus a 760×560 narrow dark scene for each page. The same three size/appearance variants also cover the production plugin-detail dialog, the statistics-reset confirmation, and the Statistics Badges and Pickle Hall of Fame tabs (the page scene shows the default Rhythm tab). `PickyHubRenderGalleryTests` mounts the actual `PickyHubRootView`, not a gallery-only duplicate, and writes `index.html` and `manifest.json` alongside the images.

Calendar-specific regression checks live in `PickyHubCalendarRenderTests`. They mount the production week view in an unshown window to assert the actual initial scroll offset and the visible job, then deliver a history-load response and verify the viewport refocuses on a recorded execution. Static scenes also cover month/compact agenda layouts and instruction-focused details. To save these scenes, write an output directory to `build/render-gallery/.calendar-output-path` before running that suite, and remove the request file afterward. These checks do not activate Picky or prove desktop pointer/focus behavior.

The Hub run also writes four full-height Korean settings captures in `build/render-gallery/hub/settings-full/`: 1020pt light/dark at 100%, 760pt dark at 130% font scale, and a 1020pt dark scene with Steer selected. The other scenes show Follow-up selected. These production-root renders expose the groups below General for visual audit. Main-agent settings render as five independent cards with explanatory Details collapsed. The full-height viewport does not test scroll behavior, expanded explanations, or expanded advanced tools; inspect those separately. PNG geometry and visible content are validated by the same rasterizer checks as the normal scenes.

The Hub suite also renders the production Plugins page with bundled Handoff and Picky CLI cards under `bundled-plugins/`: 1020pt light/dark at 100% and 760pt dark at 130%. Temporary bundle and installation directories make Handoff outdated and the CLI skill uninstalled. OCR checks that both bundled cards, a curated card, and the update action remain visible. These full-height captures check card consistency and narrow-layout wrapping, not live scrolling or button clicks.

The fixture is local and disposable. It uses a unique temporary `PickySettingsStore` root and `UserDefaults` suite, an in-memory agent client that returns a fixed populated statistics snapshot, fixed main-conversation messages with a Task that stopped before product code work and its waiting Pickle question, two plugin rows with one installed and one uninstalled state, and an idle Quick Start launcher with all four workflows available. Its permission probes are fixed and it never starts `CompanionManager`, a microphone, a daemon, or an updater. The fixture accepts only simulated `getHubStatistics` and `checkPackageUpdates` commands, then asserts no other lifecycle command was requested.

Guide thumbnails remain the production `AsyncImage` path, but this serialized test installs a narrow `URLProtocol` blocker for `ytimg.com`. The cards therefore show their normal production failure placeholder without fetching remote thumbnails. The gallery does not open a guide modal, so it never creates a WebKit player.

The Hub target passes `-derivedDataPath "${PICKY_DERIVED_DATA_PATH:-/private/tmp/PickyAgentDD}"`. Do not point it at a per-run directory unless the shared agent path is unavailable, and do not run it concurrently with another `xcodebuild` using that path. The test verifies every scene has its exact 2× pixel dimensions, PNG encoding, non-empty alpha, and a multi-color production layout sample. The script independently validates the complete filename matrix, `manifest.json`, `index.html`, and PNG dimensions.

The gallery intentionally has no byte-for-byte golden images. Dashboard greeting copy reads the current clock and local account name, and a few existing page labels use system date formatting, so visual geometry and static state are the reliable oracle. It also cannot prove native menu/popover focus, `NSOpenPanel`, permission requests, updater interactions, WebKit playback, hover/press/focus transitions, or scroll restoration. Inspect those behaviors live only when the changed feature requires them.

## Review limits

Artifacts have a 2× pixel grid tagged 144 dpi, so a viewer shows them at their intended point size. Their detail is still 1 pixel per point: an offscreen `NSHostingView` composites layer contents at `contentsScale == 1`, and the alternatives that do rasterize at 2× lose fidelity (`ImageRenderer` ignores the host appearance and placeholder-fills AppKit-backed views, `dataWithPDF(inside:)` drops layer-drawn surfaces and symbols). Judge geometry, state, and contrast from these artifacts, not glyph antialiasing.

A bare SwiftUI `Image(systemName:)` in a fixture or mockup view can be missing from these renders. Wrap it as `Text(Image(systemName:))`, which renders reliably. Production views that draw symbols through AppKit are unaffected.

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

Settings disclosure review also exports `settings-full/disclosure-expanded-dark.png` and `disclosure-expanded-light.png`. These render the shared production disclosure style with multi-line explanation content expanded; unlike the full-page scenes, they are component renders and do not establish live pointer/keyboard activation.

The Hub component-rule audit exports `component-audit/<page>-1020-100.png` and
`<page>-760-130.png` for all eight pages. These use the production root with a
full-height viewport (3200pt wide-layout height; 2400pt narrow/enlarged height)
to inspect content below the initial screen and 130% text reflow. The normal
30-scene manifest remains unchanged. Tall viewports do not establish ordinary
window scroll behavior; use the normal-size scenes alongside them.

### Hub typography refinement scenes

The Hub gallery also writes `typography/resume-130-light.png` and
`typography/resume-130-dark.png` from the production Quick Start resume card.
The OCR contract requires exactly one Continue action and the unconfirmed
first-instruction warning. The populated `component-audit/guide-card-130-*.png`
scenes require the final title word and no decorative publication date.
`typography/markdown-130-*.png` shows the shared main-agent Markdown renderer
with Hub typography, including strong emphasis, italic text, a strong link,
and code. A separate attributed-text contract verifies the emphasis font and
that Hub styling does not alter the default Markdown cache.

These four additional PNGs do not change the standard 30-scene manifest.
Compare the full-height `component-audit/dashboard-*.png` scenes as well as the
normal window; the normal viewport alone cannot establish that lower cards and
plugin rows remain readable. The font policy applies to Picky-owned Hub content,
not system dialogs or remote video content.
The gallery awaits the modal host's queued render-phase dismissal before moving
from the standard dialog scenes to full-height pages, then requires that no
rendered presentation remains. A logically dismissed but still-rendered dialog
is not valid full-page evidence.
## Tool History Gallery

```bash
./scripts/render-ui-gallery.sh tool-history
```

The opt-in gallery writes four PNGs and a manifest under
`build/render-gallery/tool-history/`. It renders the production compact history
window and expanded `edit`, `write`, `todo`, `ask`, and failed-result rows in light
and dark appearances. Fixture models load saved arguments and results through the
same detail model as the app; no live sessions or filesystem actions are used.

Inspect the PNGs for spacing, clipping, status visibility, and file links. The
script rejects stale images. Hover-only menus, keyboard focus, Finder/open actions,
and scrolling still require separate interaction verification. This target uses
the shared agent DerivedData path; do not run it alongside another Xcode job.

## Async tasks (mounted card and archived access)

```bash
./scripts/render-ui-gallery.sh async-tasks
```

This target uses Xcode 16.3 and shared `/private/tmp/PickyAgentDD`, refuses a
competing Xcode job, and runs `PickyAsyncTaskShelfTests`,
`PickyRunningTaskFooterTests` and `PickyAsyncTaskShelfRenderGalleryTests` in the
ordinary desktop-isolated host.
It does not start or restart the live app or enable UI-effect tests.

The 120 production-component PNGs and `manifest.json` are written to
`build/render-gallery/async-tasks/`. The 36 shelf scenes cover single work, multiple
roots (collapsed at 100%, expanded at 130%), expanded subagent-group details,
a bounded long child/detail document, result processing, one-line failure guidance with
full reasons under disclosure, reconciling unavailable detail,
unsupported tracking, and unknown execution/provider kind. Each state is
rendered light/dark at 100% English and 130% long CJK Korean. OS accessibility
settings are not toggled; the component uses opaque surfaces and no animation.
Group scenes render the expanded production row; other original scenes render the production shelf.
Processing scenes supply an older fetched detail beside the current v2 state to check that a late refresh does not restore an obsolete running status. Time fixtures use recent task timestamps rather than the epoch.
Twenty additional scenes render the actual conversation card with the mounted
shelf in running, short-card (compact work opener), processing, failure, and
unavailable states. Four archived-list scenes show the retained-work controls.
Twenty-four review scenes cover a surviving failed child and the delivery-reason
variants, including an unverified delivery whose reason keeps the warning tone
instead of reading as a confirmed failure. Thirty-six footer scenes render the
production `PickyRunningTaskFooterView` from a projected session store: a running
batch that keeps its finished members, a batch beside a standalone command, the
collapsed summary, queued agents, result handling, unverified delivery, a failed
agent next to running work, a failed invocation whose agents all completed, and
canonical counts without detail, which report verification rather than failure.
Inspect the PNGs directly, especially composer visibility in the short card and
whether every member of a running batch is still listed.

These renders prove static presentation only, not keyboard interaction,
VoiceOver navigation, popover anchoring, focus/IME, scrolling, transcript anchoring,
native material, or successful command dispatch.
