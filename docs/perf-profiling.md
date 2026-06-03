# HUD Performance Profiling Playbook

Use this when the Picky HUD (conversation card, dock, composer) feels laggy
on activation, during streaming, or under any user-visible interaction. The
workflow is "measure before you fix" — fixing without measurement on a
SwiftUI/AppKit hybrid view tree consistently picks the wrong target.

This playbook is a faithful write-up of how the 2026-05 HUD-lag investigation
was done. The same steps work for any future symptom.

## Available instrumentation

`Picky/Feedback/PickyPerf.swift` exposes a thin `OSSignposter` wrapper:

```swift
PickyPerf.interval("name") { ... work ... }   // timed interval
PickyPerf.event("name")                       // one-shot marker
```

- Subsystem: `com.jonghakseo.picky`
- Category: `hud-perf`
- Release builds compile the calls down to a direct closure invocation
  with no signpost emission (see the `#if DEBUG` gate). Debug builds emit
  standard `os_signpost` markers visible in Instruments and `log stream`.

You may add or remove signposts freely while investigating — they cost
nothing in Release.

## Where to plant signposts

Pick the smallest unit that brackets the suspected hot work, not the whole
view body. The 2026-05 round measured:

- `conversation_card_body`, `conversation_list_body` (events) — SwiftUI body
  re-evaluation count. Plant as `let _ = PickyPerf.event(...)` at the top
  of `var body`.
- `agent_bubble_make_nsview`, `agent_bubble_update_nsview` (events) —
  `NSViewRepresentable` lifecycle counts. Reveals whether SwiftUI is
  reusing or recreating bubbles. Same pair for `user_bubble_*`.
- `bubble_configure`, `render_blocks`, `rebuild_block_views`,
  `bubble_measured_size` (intervals) — wrap the bodies of the matching
  methods on `PickyBubbleMarkdownContentView`.

Add the signposts, build Debug, exercise the scenario, then remove or keep
the call sites as the cleanup commit dictates. Keeping signposts on a
function you actively care about is fine — the runtime cost is zero.

## Capturing in Instruments

```bash
./scripts/run-dev-signed-app.sh
open -a Instruments
```

1. Template: **Logging** (or empty document with `+` → **os_signpost**).
2. Attach to the running `Picky` process.
3. Record (⏺) → exercise the scenario → stop (⏹). 5–10 seconds is enough.
4. In the bottom detail pane, group/filter by subsystem
   `com.jonghakseo.picky` and category `hud-perf`.
5. Switch the detail-pane mode to **Summary: Name** (or whatever Instruments
   calls the per-name aggregation in the version you have) to see Count,
   Duration sum, Avg, Min, Max, Std Dev per signpost name.

The aggregated view is what makes the bottleneck obvious. Raw timeline
view is harder to read for >100 events.

## Capturing with `log stream` (lightweight alternative)

For a quick count-only check without launching Instruments:

```bash
log stream \
  --predicate 'subsystem == "com.jonghakseo.picky" && category == "hud-perf"' \
  --info --debug --style compact
```

Exercise the scenario in another window, `Ctrl-C`, then count by name:

```bash
log show --last 10s \
  --predicate 'subsystem == "com.jonghakseo.picky" && category == "hud-perf"' \
  --info --debug \
  | grep -oE '(name_a|name_b|name_c)' \
  | sort | uniq -c | sort -rn
```

`log stream` does not show interval durations directly — use Instruments
when timing matters, `log stream` when only call counts matter.

## Reading the results

Two columns matter when picking the next fix:

| You see | What it means | Likely next step |
|---|---|---|
| One interval dominates Duration sum | That function is the bottleneck regardless of how often it is called | Cache the result, memoize per identity, or short-circuit reentry |
| Interval count ≫ work units in the scenario | Some upstream signal triggers the work repeatedly per scenario step | Find the trigger (SwiftUI publish, AppKit layout cycle, event handler) and rate-limit at the source |
| Event count = N × visible items, N > 1 | View identity is being torn down per item per trigger | Look at `.id(...)` boundaries and `@ObservedObject` fan-out |
| Render/parse cost is small per call but call count is huge | Cost is in the call frame, not the body | Cache by input key (markdown, width, etc.) at the boundary |
| Interval duration is tiny but Std Dev is huge | Cold-start cost vs steady-state — first call is paying for setup | Pre-warm in onAppear / .task, or accept it once |

Never reason about "the slow part" without these numbers. The 2026-05 round
suspected cmark parsing was the hot path; profiling showed cmark was
<1% of HUD activation time and a layout-side `measuredSize` cache miss was
83%.

## Case study: 2026-05 HUD activation lag

**Symptom:** activating a Pickle with many message bubbles felt laggy.

**Pre-profile hypotheses (mostly wrong):**
- cmark markdown parsing is heavy → false, <1ms total
- `.id(activeSession.id)` tearing down the bubble tree → real but only ~28ms (8%)
- ViewModel fan-out → real but invisible at this layer

**Actual profile (one activation of a message-heavy Pickle):**

| Signpost | Count | Duration sum | Share |
|---|---|---|---|
| `bubble_measured_size` | 601 | 288.67 ms | **83%** |
| `bubble_configure` | 77 | 30.97 ms | 9% |
| `rebuild_block_views` | 38 | 28.44 ms | 8% |
| `render_blocks` | 38 | 0.67 ms | <1% |

**Read:**

- `bubble_configure` (77) ≫ `render_blocks` (38) → the C-1 short-circuit
  (`Picky/HUD/Conversation/Bubbles/PickyBubbleMarkdownContentView.swift`
  `lastMarkdown` guard) was working.
- `bubble_measured_size` count (601) ÷ unique bubble count (~38) ≈ 16 →
  AppKit's layout cycle requests `measuredSize` for the same view at the
  same width many times per pass. That's not avoidable from the caller
  side; it must be absorbed by a cache on the callee side.

**Fix:** a small width-keyed `(width, NSSize)` cache on both
`PickyBubbleMarkdownContentView` and the `PickyMarkdownBlockNSView` base
class, invalidated only when the block-view set or font scale actually
changes (commit `309fe9a4`). The per-width map matters because SwiftUI/AppKit
can alternate between a couple of near-identical widths during layout; a
single-slot cache would thrash. Expected post-fix `bubble_measured_size`
Duration sum: single-digit ms (one real measure per unique width;
remaining calls are cache hits at <1µs each).

**Lesson:** AppKit layout-cycle reentry is a common HUD-side bottleneck
because SwiftUI fan-out amplifies how often layout runs. Measure first,
cache the deterministic callee, only then chase ViewModel structure.

## When the cleanup decision is "keep" vs "remove"

- **Keep** signposts on functions whose perf you want to track over time
  (e.g. `bubble_measured_size`, `render_blocks`, `bubble_configure`). The
  next regression appears in the same signpost track without re-instrumenting.
- **Remove** ad-hoc signposts added to localize a one-time bug. Carrying
  every probe forever clutters the Instruments view.

The 2026-05 fix kept the four bubble-side signposts and the two body
events; they form a stable baseline for any future HUD perf change.
