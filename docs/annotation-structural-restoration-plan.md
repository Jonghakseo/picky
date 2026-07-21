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

### 3. Per-cell structural stability (edge-centric)

A cell is scored by **edge correspondence**, not by raw pixel matching. Counting matching flat
pixels as "stable" would let a wide flat background dominate and dilute sparse edge changes
(the exact sparse-page false-restore failure). Instead:

```
edgeUnion        = pixels that are an edge in baseline OR current
edgeIntersection = pixels that are an edge in baseline AND current
```

- A cell is **neutral** (skipped) when it has too little edge material: `edgeUnion < max(1, cellPixels · minCellEdgeCoverage)`. Flat background is therefore neither positive nor negative evidence.
- Otherwise the cell is **structural**, and **stable** when `edgeIntersection / edgeUnion ≥ minCellEdgeCorrespondence`. Moved/lost/added edges drop the ratio and mark the cell unstable. The 1px dilation keeps a genuine ±1px jitter above the ratio.

### 4. Structural persistence score (non-anchor grid only)

```
stableFraction = Σ weight(cell) · [cell stable] / Σ weight(cell)   over NON-anchor structural cells
```

The anchor regions are judged separately (below), so the global `stableFraction` is computed over the **non-anchor** grid — this keeps a bounded local anchor drift from being confused with a broad layout change. Peripheral cells get a higher `weight` than central cells (banners/videos live centrally; persistent chrome lives at the periphery). When there are no structural non-anchor cells (a flat frame), `stableFraction` is `1.0`.

### 5. Decision — maps onto existing 3-state observation

Per-annotation-region signals (not unioned, so one changed annotation among several is not averaged away):

- `anchorStructurallyStable` = no region contains an unstable structural cell.
- `anchorHasStructure` = some anchor region carries its own persistent structure (edges), not just a trivially-matching flat area.
- `anchorBroke` = some region contains an unstable structural cell **and** that region's own luminance drift exceeds the bounded `initialValidationROI*` allowance.

`hasEvidence` = the non-anchor grid carries at least `minStructuralCoverage` weighted structural cells. A whole-frame luminance mismatch (`globalMismatches`) is deferred until after the structural verdict rather than short-circuiting it. The `.strict` decision (an anchor ROI that itself changed a lot — `roiMismatches` — always breaks first):

- `anchorBroke` → **mismatching**.
- **Anchor-centric keep**: the annotation's own ROI is unchanged (`roiMatches`) **and** `anchorStructurallyStable` **and** `anchorHasStructure` → **matching**, even if the rest of the frame changed a lot. This keeps an annotation pinned to an unchanged region (e.g. a YouTube sidebar) while a full-screen video plays beside it.
- `stableFraction ≥ requiredStableFraction` **and** `anchorStructurallyStable` → **matching**, where `requiredStableFraction` is `structuralOverrideFloor` when `globalMismatches` (a full-frame tone change such as a rotating hero banner needs strong surrounding structure to override) and `restoreFloor` otherwise.
- `globalMismatches` → **mismatching** (whole frame changed with no structural rescue).
- `!hasEvidence` → defer to luminance: **matching** if luminance matches, else **indeterminate** (a near-flat frame cannot claim a structural layout change; protects tiny incidental changes).
- `stableFraction < breakFloor` → **mismatching**.
- otherwise → **indeterminate** (hold phase, avoid flicker).

Limitation: when the changing region dominates the frame (e.g. a near-full-screen video), the global `stableFraction` (~0.55) is indistinguishable from a genuinely different screen, so global structure alone cannot rescue it — the anchor-centric keep is what preserves an annotation pinned to the still-unchanged part.

The existing `PickyAnnotationSceneStabilityTracker` still requires **2 consecutive** confirmations, so a single noisy frame cannot flip state.

### Why the scenarios resolve

- **Banner / video**: only central cells change; periphery chrome cells persist → high non-anchor `stableFraction` → restore, as long as the annotation anchor is not on the banner.
- **Tone-similar different layout (with real structure)**: edges reorganize → few stable structural cells → low `stableFraction` → break. Because flat pixels are neutral, this holds even for pages with a mostly-uniform background.
- **Bounded anchor drift** (highlight/color): the anchor region is structurally touched but its luminance drift stays within the bounded allowance → `anchorBroke` false → deferred to the initial/narration tolerance rather than an outright break.
- **Honest scope**: a genuinely near-blank page (almost no structure) has no distributed edges to judge, so `hasEvidence` is false and the decision defers to luminance. Structural rejection needs a real amount of on-screen structure.

## Integration points

- `PickyAnnotationSceneFingerprint` (`Picky/Interaction/PickyAnnotationScenePolicy.swift`): add a cached/derived binary edge mask alongside `luminance`. Derive lazily so the `init?` and persisted-baseline load paths are unchanged.
- `PickyAnnotationSceneVisualPolicy` (same file): the grid/edge structural comparison plus the `minCellEdgeCorrespondence` / `minCellEdgeCoverage` / `minStructuralCoverage` / `restoreFloor` / `breakFloor` / `edgeThreshold` / `gridSize` / periphery-weight constants. The structural verdict gates only the **`.strict`** profile (the visual restoration polling path). `.lenient` (narration) keeps its bounded-drift tolerance and `.semantic` (scroll/app) stays luminance-only.
- The 3-state result and `PickyAnnotationSceneStabilityTracker` are unchanged in shape — only the criteria that produce `matching` vs `mismatching` vs `indeterminate` on the `.strict` path change.
- `PickyAnnotationSceneMonitor` gains a `stableFraction` log field only (observability for tuning); orchestration, semantic scroll/app/window/display paths, and polling policy are unchanged.

## Scroll interaction

A fixed-position grid compare would mark most cells changed under scrolling, which would wrongly break. Scroll is already handled by a **separate** semantic ROI path (`verifyRegionsAfterSemanticSignal(.scroll)`) that only inspects the annotation anchor. Keep the structural grid score scoped to the **visual polling / restoration gate**; it does not run on the scroll semantic path, so there is no conflict.

## Tuning (runtime-iterated)

Expose as policy constants so runtime testing can iterate without structural changes. Starting values:

| Constant | Start | Meaning |
| --- | --- | --- |
| `gridSize` | `12` | N in the N×N grid |
| `edgeThreshold` | `24` | gradient magnitude → edge |
| `minCellEdgeCorrespondence` | `0.5` | edge intersection/union for a cell to count as unchanged |
| `minCellEdgeCoverage` | `0.03` | min edge fraction (min 1px) before a cell is structural vs neutral |
| `minStructuralCoverage` | `0.10` | non-anchor structural coverage required before the structural verdict is trusted |
| `restoreFloor` | `0.35` | weighted stable fraction required to restore |
| `structuralOverrideFloor` | `0.65` | higher stable fraction required to override a whole-frame luminance mismatch (banner) |
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
