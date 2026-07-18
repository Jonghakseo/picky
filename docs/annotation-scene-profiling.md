# Annotation Scene Monitor Profiling

Use this after launching a Debug Picky build to measure annotation scene validation and suspend/resume behavior. The monitor is entirely app-local: fingerprints are never logged or sent to agentd.

## Structured logs

```bash
log stream \
  --predicate 'subsystem == "com.jonghakseo.picky" && category == "annotation-scene"' \
  --info --debug --style compact
```

Useful fields:

- `phase`: `validating`, `visible`, or `suspended`
- `outcome`: `matching`, `mismatching`, `indeterminate`, or `semantic-*`
- `captureMs`: ScreenCaptureKit plus first-sample baseline decode time
- `compareMs`: grayscale fingerprint comparison time
- `totalMs`: semantic check plus capture and comparison time
- `globalChanged`, `roiChanged`: changed-pixel fractions, never pixel data
- `delayMs`: next adaptive polling delay
- `samples`: total samples when a monitor stops

Expected adaptive cadence:

- validation: 300 ms between the two required matches
- first 5 seconds visible: 500 ms
- 5–30 seconds visible: 1 second
- long-lived visible annotation: 5 seconds
- first visual mismatch or restoration match: 300 ms minimum confirmation interval, preserved even when more wake-up events arrive
- application/window mismatch: notification-driven wake-up plus a 5-second semantic-only liveness retry; no pixel capture while still mismatched
- display change: immediate suspend, capture-cache invalidation, then suspended adaptive pixel validation
- window title change: immediate pixel sample without URL lookup or URL-based invalidation

## Instruments signposts

Debug builds emit these `PickyPerf` intervals under subsystem `com.jonghakseo.picky`, category `hud-perf`:

- `annotation_scene_sample`
- `annotation_scene_compare`
- `annotation_scene_stability`

Open Instruments with the Logging template, attach to Picky, then filter by those names. Release builds compile the signposts out.

## Suggested manual scenario

1. Display an annotation and wait for `visible`.
2. Switch to another app; expect immediate `suspended` and no repeating capture samples.
3. Return to the original app/window; expect two `matching` samples and `visible`.
4. Scroll away and back; expect the same suspend/resume cycle.
5. Leave the original screen static for over 30 seconds and confirm `delayMs=5000`.
