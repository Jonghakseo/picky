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
- while narration is active, a mismatch suspends and can resume; after the final TTS queue drains, the next mismatch permanently clears the annotation and stops the monitor
- if the scene is already suspended when the final TTS queue drains, it clears immediately instead of polling for restoration

## Instruments signposts

Debug builds emit these `PickyPerf` intervals under subsystem `com.jonghakseo.picky`, category `hud-perf`:

- `annotation_scene_sample`
- `annotation_scene_compare`
- `annotation_scene_stability`

Open Instruments with the Logging template, attach to Picky, then filter by those names. Release builds compile the signposts out.

## Suggested manual scenario

1. While TTS is active, display an annotation and wait for `visible`; confirm no close control is present.
2. Switch to another app; expect immediate `suspended` without interrupting TTS.
3. Return before TTS ends; expect two `matching` samples and `visible`.
4. After TTS ends on the matching scene, confirm an `xmark + Close` control appears at the top-right of every annotated display. Click any one and expect all annotations plus the monitor to clear.
5. Repeat without clicking, then change the app/window or scroll away after TTS; expect a permanent clear and a monitor stop rather than a later resume.
6. Repeat while suspended and let TTS finish before returning; expect the annotation to clear immediately without showing the close control.
7. Keep a settled annotation on its original static screen for over 30 seconds and confirm `delayMs=5000` until it is dismissed, cleared, or replaced.
