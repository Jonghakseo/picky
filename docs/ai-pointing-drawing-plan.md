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

## TL;DR

Picky already has the full transport + rendering pipeline for "AI points here".
It is **inert but complete**: the app-side event and `BlueCursorView` renderer
work, but there is **no LLM-callable tool registered** — the old
`createPickyShowPointerTool` was removed in commit `dab252f3`. So:

- **Phase 1 (revive pointing)** = wire one tool back in. Low risk, hours-scale.
- **Phase 2 (multi-shape drawing)** = the real new work: a versioned annotation
  protocol + a dedicated AI-annotation renderer.

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
| LLM-callable pointer tool | MISSING | not registered in `agentd/src/bootstrap.ts:307-324`; `agentd/src/application/pointer-tool.ts` only builds a request object |

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

### Phase 1 — Revive AI pointing (small, low risk)

1. Add a real `defineTool` (`createPickyShowPointerTool`) in
   `agentd/src/application/pointer-tool.ts` that calls
   `SessionSupervisor.requestPointerOverlay()` (`agentd/src/session-supervisor.ts:445-454`).
2. Register it in `agentd/src/bootstrap.ts:307-324`.
3. Add prompt guidance in `agentd/src/prompt-builder.ts`. Use **structured tool
   calls**, not custom text-tag parsing — Pi's runtime supports tools natively,
   which avoids the parsing fragility and prompt pollution of a `[POINT:x,y]`
   text convention.
4. Tests: `agentd/src/application/pointer-tool.test.ts`,
   `agentd/src/session-supervisor.test.ts`.

Transport and rendering are already proven, so this is mostly re-exposing a
capability.

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
7. **Lifecycle semantics.** Support replace / append / clear, TTL, animation
   completion, cancellation on new user input, deterministic per-id cleanup.
   Add an annotation collection alongside — not inside — `PickyPointerTarget` in
   `Picky/Interaction/PickyInteractionState.swift`.
8. **Use target bounds.** Populate `targetFrame` (currently always nil at
   `Picky/CompanionManager.swift:2185-2203`) so ring/rect size can match the
   referenced element.
9. **Tests.** Extend `pointer-tool.test.ts`, `session-supervisor.test.ts`,
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
| LLM output format | text tags like `[POINT:x,y]` regex-parsed | **structured tool calls** (Pi supports tools; avoids parsing fragility + prompt pollution) |
| Event reuse | one multi-purpose tag | new `annotationOverlayRequested`, separate from pointer |
| Shape style | hand-drawn / sketchy | Picky design system (Action Blue, semantic status) |
| Coordinates | screenshot px + `:screenN` | keep existing px + `screenId`; extend `pointer-validation.ts` |

## Integration seams (files a change plugs into)

- Tool: `agentd/src/application/pointer-tool.ts` + register in `agentd/src/bootstrap.ts:307-324`
- Handler: `SessionSupervisor.requestPointerOverlay()` (`agentd/src/session-supervisor.ts:445-454`)
- Protocol: `agentd/src/protocol.ts:267-278` <-> `Picky/PickyAgentProtocol.swift:275,416-418`
- Validation: `agentd/src/domain/pointer-validation.ts`
- App state: `Picky/Interaction/PickyInteractionState.swift`
- Render: new `PickyAgentAnnotationOverlayView` mounted at `Picky/Overlay/BlueCursorView.swift:595-615`
- Tests: `agentd/src/application/pointer-tool.test.ts`, `agentd/src/session-supervisor.test.ts`, `PickyTests/PickyPointerOverlayResolverTests.swift`

## Status of evidence

- Picky code claims are cited to file:line from a read-only mapping pass.
- Reference-app claims come from static string/regex/entitlement analysis of the
  installed bundle (no app launch, no network). Exact compiled logic (rescale
  formula, dwell constants) is inferred from adjacent symbol names.
