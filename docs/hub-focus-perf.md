# Hub focus performance gate

`PickyHubFocusPerformanceTests` measures the production `PickyHubRootView` in a disposable fixture. It opens no live Picky window, does not start an agent daemon, uses a temporary settings root and defaults suite, and never touches real sessions or preferences.

The test owns two AppKit windows for a few seconds. Each measured sample activates an already-running Finder, verifies the test application is inactive, then activates the isolated test host and its rendered Hub. This exercises application activation as well as a real `NSWindow.didBecomeKeyNotification` transition. Finder windows and files are never inspected or changed, and no helper application is launched. The second owned window is used only for warm-up and the sensitivity control. The test restores the app that was frontmost before it when possible, closes both owned windows and deletes fixture state.

## Gate and artifact

Run the narrow local gate:

```bash
./scripts/pre-push-checks.sh --hub-focus-perf
```

The command uses the pinned Xcode toolchain and shared `/private/tmp/PickyAgentDD`, runs exactly `PickyHubFocusPerformanceTests` serially, and fails unless all of these are true:

- WindowServer and an already-running Finder are available, the test host actually deactivates/reactivates, and every one of seven transitions becomes key.
- The Hub's production root is attached to that key window and reaches its first main-loop/layout/display checkpoint.
- The production settings page actually contains the app, report and terminal font menus. A lightweight dashboard alone cannot satisfy the benchmark.
- An isolated 300 ms synchronous delay in the control window's `didResignKey` callback is visible in the measured key-acquisition clock and rejected by the same budget. It runs after the seven product samples and does not affect their summary.
- The provisional local budget passes: key acquisition median ≤ 100 ms, p95 ≤ 150 ms, max ≤ 250 ms, and render-ready-after-key p95 ≤ 100 ms.
- `build/perf/hub-focus/pre-push.json`, its sibling PNG, and the xcodebuild log prove the selected test executed and passed.

Normal `xcodebuild test` runs skip this WindowServer test. Full `pre-push-checks.sh` excludes the performance suite from the ordinary Swift invocation, then measures it once in a fresh, targeted test host. Every UI-effect test still executes once. Runner serialization alone is not used as a guarantee against concurrent Swift Testing tasks or leftover asynchronous work from unrelated suites. The environment-isolation guard explicitly allowlists this test and rejects any ungated new key-window call.

The JSON contains each transition, median/p95/max scalar summaries, per-transition main-thread CPU time, gate thresholds, the negative-control result, display/OS/CPU/RAM context, and a local fixture screenshot. With seven samples, the nearest-rank p95 equals the maximum; it is a small regression sample, not a population percentile estimate. `build/` is ignored, so diagnostic images and measurements stay local.

## Calibration

Use calibration before changing a budget. It records the same artifact but intentionally fails the test after writing it, so an observed slow baseline cannot be mistaken for a passing gate.

```bash
PICKY_HUB_FOCUS_PERF_REPORT_PATH="$PWD/build/perf/hub-focus/calibration.json" \
  ./scripts/pre-push-checks.sh --hub-focus-perf-calibrate
```

Review the recorded report and its hardware context, then update the provisional thresholds only with comparable samples. Calibration's nonzero exit is expected, but a missing report is still inconclusive.

## What this proves, and what it cannot

The key-acquisition metric starts immediately before `NSApp.activate` / `makeKeyAndOrderFront` and stops at the actual `didBecomeKey` notification. Rendering readiness also requires the application to be active. Render-ready starts there and stops after a `RunLoop.main.perform` checkpoint plus production-host layout/display. Both latency clocks use `DispatchTime.uptimeNanoseconds`, not calendar time. `clock_gettime(CLOCK_THREAD_CPUTIME_ID)` records CPU consumed by the main thread across the full transition, excluding time it spends blocked or descheduled.

This catches expensive synchronous AppKit/SwiftUI focus work in the exercised production Hub, including the native picker accessibility refresh that motivated the gate. It is a local regression budget, not a universal macOS responsiveness claim. It cannot measure compositor presentation, keyboard-event delivery from a physical device, unrelated system load, or a different user's display/accessibility configuration. A logged-in WindowServer is required. If activation or rendering cannot be observed, the test reports **inconclusive** and fails rather than silently passing.

For deeper attribution after a failure, use the stable Hub/HUD signposts and Time Profiler workflow in [`perf-profiling.md`](perf-profiling.md). Apple documents the key-window notification used by the harness at [NSWindow.didBecomeKeyNotification](https://developer.apple.com/documentation/appkit/nswindow/didbecomekeynotification), and documents Xcode test plans and test execution at [Testing your apps in Xcode](https://developer.apple.com/documentation/xcode/testing-your-apps-in-xcode).

## Measured change (2026-09-09)

On macOS 15.6.1, Xcode 16.3 Debug, 14 logical processors, 48 GiB RAM and three displays, the same seven-transition Finder-to-isolated-Settings scenario produced:

| Metric | Previous implementation | Native menus + retained lazy pages |
| --- | ---: | ---: |
| Total ready, median | 37.44 ms | 30.27 ms |
| Total ready, p95/max | 77.73 ms | 33.79 ms |
| Main-thread CPU, median | 30.68 ms | 21.98 ms |
| Main-thread CPU, p95/max | 71.67 ms | 26.48 ms |
| Key notification, median | 6.74 ms | 8.76 ms |

That is 19% less median elapsed time through render readiness and 28% less median main-thread CPU in this fixture. Key-notification latency itself did not improve; the reduction is in the full render-readiness path. The candidate passed the budget; its 300 ms sensitivity control measured 301.27 ms and was rejected by that same budget. Local evidence is under `build/perf/hub-focus/{before,final}.{json,png,log}` (the earlier candidate remains as `after.*`). Baseline source was the Hub root/settings at `871fb9f58`; calibration intentionally exited nonzero after recording its samples, not because activation failed.

This disposable fixture is not the full live-session workload. Do not compare these numbers directly with the earlier manually captured 127 ms live-app focus CPU. An initial same-application/two-window experiment also measured less work; it was replaced with the cross-application scenario before this comparison. The live development-signed Picky process was not restarted.

## Deterministic contracts alongside the timing gate

`PickyNativeMenuPickerTests` observes actual NSMenu mutation notifications across 100 focus-equivalent updates, with a real label mutation as a positive control. Selection, disabled state, duplicate display names, unavailable values, translated labels and app font scale have separate native-control assertions.

`PickyHubPageMountTests` exercises the production retained-page host and child state identity. `PickyHubSettingsRuntimeContractTests` reaches the real settings file through native selection actions, changes English/Korean labels without replacing the menu, and verifies a first Settings deep link against rendered tool text. The last assertion uses Apple's local Vision OCR because offscreen SwiftUI does not publish its AX text tree; it does not capture the desktop or request permissions. Its render/model-load timeout is not a performance budget. Implicit animations are disabled through the transaction in that deterministic fixture, while runtime focus measurements use the normal production motion environment.
