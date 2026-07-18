# AI Pointing & Drawing — Design and Improvement Plan

Use this when adding an **LLM-driven "Picky points/draws on the user's screen"**
feature: the agent asks Picky to render arrows, circles, rectangles, a spotlight,
a moving buddy cursor, and text labels on a transparent overlay to guide the user.
This complements the already-shipped reverse direction — the **user** drawing ink
annotations that are sent to the model as neutral visual context.

This plan was derived from a static analysis of a comparable macOS app
cross-checked against Picky's actual code. It stays
inside Picky's non-negotiable boundary: Picky captures neutral context and
renders/controls overlays; Pi decides intent and when to point/draw.

> **Current implementation:** visual guidance is emitted as an inline, streamed
> DSL in the assistant reply, not as a structured tool call. `agentd` strips and
> incrementally parses completed tags, immediately reusing the existing validated
> pointer/annotation request paths. This avoids the extra model continuation that
> a tool result would require.

## TL;DR

Picky has the full transport + rendering pipeline for "AI points here". The
app-side events, `BlueCursorView`, and annotation renderer are fed by a streamed
inline DSL rather than registered LLM tools:

- **Pointing** uses `[POINT: x=… y=… ttl=…]` and maps to the pointer request path.
- **Multi-shape drawing** uses tags such as `[CIRCLE: …]` and maps to the
  versioned annotation protocol + dedicated AI-annotation renderer.

## What already exists (reusable)

| Component | State | Evidence |
| --- | --- | --- |
| Per-display transparent click-through overlay | present | `Picky/Overlay/OverlayWindow.swift:20-59` (`ignoresMouseEvents`, all-Spaces) |
| Multi-display overlay lifecycle | present | `Picky/Overlay/OverlayWindowManager.swift:36-101,132-145` |
| AI point renderer (spotlight + pulse rings + tag + animated cursor) | present | `Picky/Overlay/BlueCursorView.swift:1133-1719` (60fps Bezier fly-out, spring fly-back) |
| User freehand ink (already shipped) | present | `Picky/Overlay/PickyInkOverlayView.swift:20-128`, `Picky/Context/PickyInkContext.swift` |
| Coordinate resolver (screenshot px -> AppKit global, Y-flip, clamp) | present | `Picky/PointerOverlay/PickyPointerOverlayResolver.swift:63-100` |
| ScreenCaptureKit capture with self-window exclusion | present | `Picky/Context/CompanionScreenCaptureUtility.swift:17-169` |
| Protocol event `pointerOverlayRequested` | present | `Picky/PickyAgentProtocol.swift:275,416-418`, `agentd/src/server.ts:129` |
| Coordinate validation/clamp + tests | present | `agentd/src/domain/pointer-validation.ts:19-51` |
| Streamed visual DSL parser | present | `agentd/src/domain/annotation-dsl.ts`; `SessionSupervisor` emits existing request events mid-stream |

**Picky already does better than comparable apps:** it excludes its own
overlay windows from capture (no visual feedback loop) and sends the screenshot's
actual pixel size with the request (no brittle fixed-downscale assumption).

## User-ink flow (the reverse direction, for reference)

PTT / Quick Input → `PickyInkCaptureController` (CGEvent tap, 28pt threshold) →
`PickyInkOverlayView` live render → `PickyInkMarkMapper` converts strokes to
screenshot pixels → strokes + numbered badges are burned into the JPEG
(`Picky/Context/PickyAppSupport.swift:68-149`) → `agentd/src/prompt-builder.ts:186-197`
describes them as "User-marked screen regions".

AI drawing is the exact inverse: reuse the same coordinate system, overlay
windows, and capture infrastructure in reverse.

## Coordinate & capture facts (already in place)

- Capture: ScreenCaptureKit `SCScreenshotManager.captureImage`, JPEG q0.8
  (`Picky/Context/CompanionScreenCaptureUtility.swift:81-176`).
- Downscale: longest edge 1280 / 1920 / 2560 px, default 1280
  (`Picky/App/Settings/PickySettings.swift:178-200`).
- Coordinate conventions:
  - model/request coords: screenshot pixels, top-left origin
  - display/overlay state: AppKit global points, bottom-left origin
  - SwiftUI overlay: local, top-left origin
- Conversion: `x / screenshotWidth * displayWidth`; `y` inverted into AppKit
  global Y (`PickyPointerOverlayResolver.swift:82-93`), then to local SwiftUI
  (`Picky/Overlay/PickyOverlayGeometry.swift:18-25`).
- Validation clamps and rejects unknown screens
  (`agentd/src/domain/pointer-validation.ts:19-51`).

## Phased plan

### Phase 1 — Streamed AI pointing

1. `AnnotationDslParser` incrementally recognizes `[POINT: x=… y=… r=… ttl=…]`
   across assistant deltas, strips it from user-visible text, and emits the
   existing `SessionSupervisor.requestPointerOverlay()` path immediately.
2. `prompt-builder.ts` injects the named-argument DSL grammar only when the
   existing `picky_show_pointer` setting is enabled. The parser remains active
   even when prompt guidance is disabled.
3. Tests cover split tags, escaped quoted labels, malformed tags, and
   mid-stream pointer emission.

Transport and rendering remain unchanged; the DSL changes only how the model
supplies coordinates, avoiding a second inference after a tool result.

### Phase 2 — Multi-shape drawing (the new work)

Target shape scope (maintainer-selected): **point/target, circle/ellipse,
rectangle, line, spotlight, label/tag.** (Arrow and freehand are intentionally
out of scope for v1; revisit later.)

5. **Versioned annotation protocol.** Do not overload `pointerOverlayRequested`.
   Add a new `annotationOverlayRequested` event. Fields per annotation:
   `shape` (point | circle | rect | line | spotlight | label),
   coordinates (screenshot px, matching existing convention), `screenId`,
   `label`, `ttl`, optional style. Render fixed semantic layers rather than
   accepting model-controlled stacking. Mirror the Codable types across
   `agentd/src/protocol.ts:267-278` and `Picky/PickyAgentProtocol.swift:275,416-418`.
6. **Dedicated AI-annotation renderer.** Keep transient AI annotations separate
   from user ink. Add `PickyAgentAnnotationOverlayView` mounted near the existing
   ink and point-highlight layers in `Picky/Overlay/BlueCursorView.swift:595-615`.
   Render a collection of circles, rectangles, lines, spotlight regions, and
   labels. Follow the Picky design system (Action Blue, semantic status) and
   apply a subtle deterministic hand-drawn stroke treatment for outline shapes.
7. **Lifecycle semantics.** DSL tags append during a turn, auto-clear on a new
   turn, and require a TTL; animation completion and deterministic per-id cleanup
   remain app-owned.
   Add an annotation collection alongside — not inside — `PickyPointerTarget` in
   `Picky/Interaction/PickyInteractionState.swift`.
8. **Use target bounds.** Populate `targetFrame` (currently always nil at
   `Picky/CompanionManager.swift:2185-2203`) so ring/rect size can match the
   referenced element.
9. **Tests.** Extend `annotation-dsl.test.ts`, `session-supervisor.test.ts`,
   `PickyTests/PickyPointerOverlayResolverTests.swift`; add compound-annotation,
   lifecycle-race, and concurrent-display tests plus pure-geometry renderer tests.

### Phase 3 — Optional: observability-gated guidance & computer-use

Adopt selectively from the lessons below only if/when Picky adds step-by-step
guidance or actual automation.

## Lessons worth adopting (from comparable apps)

Adopt now (Phase 1-2):

- **Gate "hot" actionable annotations by observability, not model confidence.**
  Only draw an actionable target when Picky can detect step completion (a click,
  or a re-capture diff). Everything else (drag, typing, sliders) degrades to a
  passive highlight/line. Prevents false progress tracking.
- **Radius-carrying targets (`x,y,r`)** instead of bare points, for dwell/hit-test
  tolerance. Pairs with populating `targetFrame`.
- **Explicit "step back / no annotation" escape hatch** driven by upstream
  context (e.g. app-switch detection), so the AI does not draw stale annotations
  after the user has moved on.
- **Hover-dwell completion signal:** poll the real cursor; if it stays within a
  target radius for a minimum duration, treat the step as done and re-capture —
  cheaper and more robust than detecting arbitrary UI changes.

Adopt later (Phase 3, if computer-use is added):

- **No-foreground contract:** never raise/activate the target app. Explicitly
  block every silently-activating API (`open`, `osascript activate`, cross-app
  `CGEventPost`, tab-switch shortcuts). Use a focus-restore guard that
  intercepts a launching app's self-activation and snaps focus back.
- **Prefer AX `element_index` clicks over raw coordinate clicks;** matches
  Picky's AX-leaning resolver philosophy.
- **capture_mode tri-state** (vision / ax / set-of-mark) switched by symptoms.
- **Reuse Picky/Pi skill file structure** (`Use When` / `Do Not Use When` /
  `Fallbacks` / `Safety` / `Verification`) for any new pointing/computer-use skill.

Already handled well by Picky (keep): self-window capture exclusion, sending the
screenshot's real pixel dimensions, per-display keying.

## Design decisions — where Picky should differ from comparable apps

| Aspect | Comparable app | Picky recommendation |
| --- | --- | --- |
| LLM output format | text tags like `[POINT:x,y]` regex-parsed | **streamed named-argument DSL** (`[POINT: x=… y=… ttl=…]`), parsed incrementally and validated through existing request paths |
| Event reuse | one multi-purpose tag | new `annotationOverlayRequested`, separate from pointer |
| Shape style | hand-drawn / sketchy | Picky design system (Action Blue, semantic status) |
| Coordinates | screenshot px + `:screenN` | keep existing px + `screenId`; extend `pointer-validation.ts` |

## Integration seams (files a change plugs into)

- Parser: `agentd/src/domain/annotation-dsl.ts`, fed by main-agent `assistant_delta` events
- Handler: `SessionSupervisor.requestPointerOverlay()` / `requestAnnotationOverlay()`
- Protocol: `agentd/src/protocol.ts:267-278` <-> `Picky/PickyAgentProtocol.swift:275,416-418`
- Validation: `agentd/src/domain/pointer-validation.ts`
- App state: `Picky/Interaction/PickyInteractionState.swift`
- Render: new `PickyAgentAnnotationOverlayView` mounted at `Picky/Overlay/BlueCursorView.swift:595-615`
- Tests: `agentd/src/domain/annotation-dsl.test.ts`, `agentd/src/session-supervisor.test.ts`, `PickyTests/PickyPointerOverlayResolverTests.swift`

## Status of evidence

- Picky code claims are cited to file:line from a read-only mapping pass.
- Reference-app claims come from static string/regex/entitlement analysis of the
  installed bundle (no app launch, no network). Exact compiled logic (rescale
  formula, dwell constants) is inferred from adjacent symbol names.
