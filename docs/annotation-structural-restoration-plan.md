# Annotation Structural Restoration Plan

Design plan for tightening the annotation scene **restoration** gate (`suspended → visible`) so that annotations survive banner rotation and video playback, but are *not* falsely restored when the user switches to a different layout that merely shares a similar color tone.

Status: proposed. Runtime tuning of grid size / periphery weight will be iterated against real captures after the first implementation lands.

## Problem

`PickyAnnotationSceneVisualPolicy.compare` decides "same scene?" from two position-agnostic scalars over the whole fingerprint:

- `globalChangedFraction` — fraction of pixels whose `|Δluminance| ≥ changedPixelThreshold (18)`
- `globalMeanDifference` — mean `|Δluminance|`

These aggregates measure *how much brightness changed*, not *whether the same UI elements are still in the same place*. Consequences:

- A **different page with a similar palette** produces low mean difference and a changed fraction under the restore thresholds (`matchingGlobalChangedFraction 0.18`, `matchingGlobalMeanDifference 8`), so a suspended annotation is **falsely restored** onto an unrelated layout.
- Restoration was deliberately made lenient (`allowsTolerantRestoration` + `canValidateInitialScene`, ROI drift up to `0.20 / 12`) so annotations survive banner/video motion. That leniency is what lets tone-similar different layouts slip through.

Root cause: luminance aggregates conflate *tone similarity* with *structural identity*. We want to gate restoration on **structural persistence** — is a substantial, spatially-distributed chunk of the layout pixel-identical?

## Goals

- **Keep** annotations through banner carousels and video playback (localized central change, stable surrounding chrome).
- **Break** annotations when switching to a structurally different screen, even if the overall color tone is similar.
- Change only the **restoration** path. Preserve the fail-open initial-validation (`validating`) reveal behavior.
- Keep the change local: `PickyAnnotationSceneVisualPolicy.compare` + a fingerprint extension + a few policy constants. Reuse the existing 3-state observation and the 2-consecutive stability tracker.

Non-goals: changing the semantic scroll / app-switch / display paths, changing initial reveal tolerance, or altering polling cadence.

## Key insight

Flat color tone carries no edges; layout structure (window chrome, toolbars, sidebars, text runs, control borders) is entirely expressed as **edges**. Comparing *edge structure by position* separates the two cases that luminance cannot:

- Same page, moving banner → edges everywhere except the banner region are identical.
- Different page, similar tone → edges are in different positions almost everywhere.

## Algorithm

Operates on the existing downsampled luminance fingerprint (`annotationSceneFingerprintMaximumDimension = 256`), which already suppresses subpixel/JPEG noise.

### 1. Edge map (per fingerprint, cached)

From the luminance buffer compute a per-pixel local gradient magnitude:

```
g(x, y) = |L(x+1, y) − L(x, y)| + |L(x, y+1) − L(x, y)|
```

Threshold to a binary edge mask (`edge` / `non-edge`) with an `edgeThreshold` constant. Cache the mask on `PickyAnnotationSceneFingerprint`. Stored/persisted baselines keep only luminance today, so the mask is **derived on load** — no persisted-format change.

To absorb ±1px edge jitter from anti-aliasing and resampling, dilate the edge mask by 1px (a pixel counts as an edge if any 4-neighbor is an edge) before comparison.

### 2. Grid partition

Divide the frame into an `N × N` grid of cells (starting point `12 × 12 = 144`; tunable at runtime — see Tuning). Each cell covers roughly `256/N ≈ 21px`.

### 3. Per-cell structural stability

A cell is **stable** when its structure is essentially unchanged between baseline and current:

```
stableCell ⇔ (fraction of pixels where edgeMaskBaseline == edgeMaskCurrent
                       AND |Δluminance| < changedPixelThreshold) ≥ cellStabilityRatio (≈ 0.9)
```

This is a strict "structurally identical" test per cell, not a tone test.

### 4. Structural persistence score

```
stableFraction = Σ weight(cell) · [cell stable] / Σ weight(cell)
```

Peripheral cells get a higher `weight` than central cells, because banners/videos live in the center while persistent chrome (title bar, sidebar, tab strip, dock-adjacent edges) lives at the periphery. This makes "same window, different center content" score high, and "different window entirely" score low. Weighting is a tunable curve (see Tuning); default is a mild edge boost, not an extreme one.

### 5. Decision — maps onto existing 3-state observation

Let `annotationAnchorStable` = all grid cells overlapping the annotation ROI are stable (this replaces / complements the current ROI drift check for the restore direction).

- **matching (restore-eligible)** when `stableFraction ≥ restoreFloor` (start `0.35`, your 30–40%) **and** `annotationAnchorStable`.
- **mismatching (break)** when `stableFraction < breakFloor` (start `0.20`).
- **indeterminate** otherwise — hold the current phase to avoid flicker.

The existing `PickyAnnotationSceneStabilityTracker` still requires **2 consecutive** confirmations, so a single noisy frame cannot flip state.

### Why both scenarios resolve

- **Banner / video**: only central cells change; periphery chrome cells stay pixel-identical → high `stableFraction` → restore, as long as the annotation anchor is not on the banner itself.
- **Tone-similar different layout**: edge positions differ almost everywhere → few stable cells → low `stableFraction` → break. This is exactly the case current luminance aggregates miss.

## Integration points

- `PickyAnnotationSceneFingerprint` (`Picky/Interaction/PickyAnnotationScenePolicy.swift`): add a cached/derived binary edge mask alongside `luminance`. Derive lazily so the `init?` and persisted-baseline load paths are unchanged.
- `PickyAnnotationSceneVisualPolicy` (same file): add the grid/edge structural comparison and the `restoreFloor` / `breakFloor` / `cellStabilityRatio` / `edgeThreshold` / `gridSize` / periphery-weight constants. Feed the structural verdict into the **restore direction** of `compare`, keeping the existing invalidation-profile logic for the break direction and the narration/initial paths intact.
- The 3-state result and `PickyAnnotationSceneStabilityTracker` are unchanged in shape — only the criteria that produce `matching` vs `mismatching` vs `indeterminate` on the restore path change.
- No change to `PickyAnnotationSceneMonitor` orchestration, semantic scroll/app/window/display paths, or polling policy.

## Scroll interaction

A fixed-position grid compare would mark most cells changed under scrolling, which would wrongly break. Scroll is already handled by a **separate** semantic ROI path (`verifyRegionsAfterSemanticSignal(.scroll)`) that only inspects the annotation anchor. Keep the structural grid score scoped to the **visual polling / restoration gate**; it does not run on the scroll semantic path, so there is no conflict.

## Tuning (runtime-iterated)

Expose as policy constants so runtime testing can iterate without structural changes. Starting values:

| Constant | Start | Meaning |
| --- | --- | --- |
| `gridSize` | `12` | N in the N×N grid |
| `edgeThreshold` | `24` | gradient magnitude → edge |
| `cellStabilityRatio` | `0.90` | per-cell structural-match ratio to call a cell stable |
| `restoreFloor` | `0.35` | weighted stable fraction required to restore |
| `breakFloor` | `0.20` | below this, break instead of holding |
| periphery weight | mild edge boost (e.g. center `1.0` → edge `1.6`) | de-emphasize central banner/video area |

Tuning intent: `restoreFloor` too high → banners/videos wrongly break; too low → tone-similar different layouts wrongly restore. `breakFloor` sets how aggressively an ambiguous frame clears vs holds. Periphery weight trades "same window different content" sensitivity against noise.

## Cost

- Edge map: one O(pixels) pass over ≤ 256×256 ≈ 64K px (< 1 ms), cached per fingerprint.
- Grid aggregation: O(cells). Negligible against the polling cadence. The existing `annotation_scene_compare` PickyPerf signpost already covers this path for profiling.

## Risks

- **Edge noise** from AA/JPEG — mitigated by the 256px downsample plus 1px mask dilation and the per-cell ratio tolerance.
- **Threshold sensitivity** — the whole point is runtime tuning; ship conservative defaults and iterate on real captures.
- **Very sparse UIs** (near-empty windows with almost no edges) could produce a low stable count even when unchanged; the per-cell `luminance < threshold` term keeps flat identical cells stable, so a blank-but-identical region still counts as stable.

## Test plan (characterization-first)

Per `docs/refactoring-principles.md`, add fixtures before touching policy:

- Banner/carousel: stable periphery + changed central band → **restore**.
- Video playback: same shape as banner → **restore**.
- Different layout, similar tone (low global mean difference but shifted edges) → **break**. This is the regression the current policy fails.
- Annotation anchor on the changing region → **break** even when periphery is stable.
- Flat identical region (no edges) → **stable** (does not spuriously break).
- Single noisy frame between two stable frames → no state flip (2-consecutive guard).

Add these to `PickyTests/PickyAnnotationScenePolicyTests.swift` and keep the existing initial-validation / narration / semantic tests green (the restore-direction change must not regress fail-open initial reveal).
