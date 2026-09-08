# Hub implementation validation

Worktree: `feat/new-interface`. Integration and verification are in progress.
The running Picky application must not be restarted or used as a test host through manual app control.

## Content publication

`Picky/Resources/hub-guides.json` intentionally starts as an empty array. The HTML mockups supplied layout examples, not verified published Picky videos. Six initial records all pointed to the YouTube player sample `M7lc1UVf-VE`; shipping that sample under product-guide titles would misrepresent its content. The feed and dashboard display their empty states until maintainers supply verified video IDs, titles, summaries and publication dates. Render fixtures may contain synthetic entries but production resources must not.

To publish an entry, add an object with `id`, `kind` (`guide` or `update`), bilingual `title` and `summary`, ISO calendar date `publishedOn`, `youtubeVideoID`, and optional HTTPS `thumbnailURL`. Check that the video permits embedding and that its content matches both localized descriptions before shipping.

Share links use the repository URL documented in `README.md`, not the unverified `picky.app` domain.

## Integration findings

- `WKWebViewConfiguration.allowsInlineMediaPlayback` is declared under `TARGET_OS_IPHONE` in the Apple SDK header. Removed from the macOS representable; the macOS player retains native inline playback. Official reference: <https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/allowsinlinemediaplayback>.
- Removing `CompanionPanelView` removed the last view-wide `PickySessionListViewModel` observation. The architecture ratchet was reduced from one to zero, not disabled. The guard passes with its four existing warnings.
- The page-level grid environment must be injected above each page, not inside its scroll content. Hub root now measures the viewport and supplies the bounded content width. Inner content measurement subtracts insets before applying the maximum width.
- Settings now initialize, observe and save only their owning route. Failed onboarding replay rolls back only the revision it wrote. Quick Start shares the ordinary follow-up validation/state path but requires correlated daemon acceptance, persists uncertainty before sending, and never automatically resends an uncertain or partially rejected instruction.
- Foreground preparation runs only for `voice`/`voice-follow-up`, before both screenshot and metadata capture. Text submissions retain the persistent Hub. Workspace activation observations update the remembered external app while Hub is open; Picky activations do not overwrite it. Close/PTT dismissal removes the observer.
- Dashboard exposes the shared period/project scope instead of labeling filtered data as weekly. Visible Dashboard/Statistics pages refresh stale snapshots with in-flight coalescing. An explicit model allowlist resolving to no models no longer falls back to excluded providers.
- Consolidated duplicated follow-up and settings-save branches instead of raising file/type size limits. Existing two-argument `followUp` protocol requirements remain supported by a forwarding overload.

## Executed core verification

- `/tmp/hub-core-final-tests.log`: **461 Swift tests passed**, with `TEST SUCCEEDED`. All ten selected Hub/protocol suites plus the existing agent-client router, session view model, voice-context coordinator and companion direct-message suites actually executed. No signing changes or manual control of the running Picky app were used.
- `/tmp/hub-foreground-source-tests.log`: 17 focused tests passed. Source-parameterized capture assertions cover `voice`, `voice-follow-up`, `text`, and `text-follow-up`, and the latest-external-app fixture covers editor → browser → direct Hub focus. These are isolated dependency tests, not native Workspace interaction evidence.
- `/tmp/hub-plugin-fanout-test.log`: five tests passed after correcting the fake client's event broadcast. The original fake shared one AsyncStream among competing subscribers, unlike the production router. No production plugin completion fix is claimed from this harness correction.
- Latest focused agentd run passed 245 tests; TypeScript typecheck and ESLint passed. The earlier full backend checkpoint passed 1,256 with two skipped (`/tmp/hub-agentd-suite.log`), before final priority changes.
- Architecture, localization, UI design-token and whitespace checks passed. Architecture retains four pre-existing warnings.

## P2 and privacy verification

- `/tmp/hub-p2-review-fixes-2.log`: 36 selected Swift tests passed, covering modal lifecycle, plugin outcomes/retries, route-owned settings and consent state. The replay-save test reads the persisted file after an attempted dismissal while saving.
- `/tmp/hub-optin-integration.log`: 248 agentd tests passed. Consent defaults to off, missing/malformed settings fail closed, withdrawal aborts work, configuration writes are serialized, and an older enable operation cannot resume transmission after withdrawal. Typecheck and ESLint passed.
- Plugin mutations retain errors and retry actions by plugin ID. Dashboard rows expose their own errors even after another operation succeeds. Installed versions come only from a matching local package manifest, not the catalog source's tag or pin.
- Modal focus restoration waits for the actual SwiftUI removal event, not Task.yield. Presentation IDs reject stale removals. Accepted onboarding replay cannot be dismissed or replaced while its persistence operation is busy; the Cancel button is disabled for the same interval.
- The user chose default-off classification with explicit disclosure and opt-in. Settings hides the toggle when the durable state is unconfirmed instead of implying that classification is off. Failed withdrawal does not restart the classifier in the current daemon; the visible error requires retrying persistence before a daemon restart.
- `/tmp/hub-gallery-3.log`: **27 production PNGs generated and directly inspected**, including every page in wide light/dark and narrow dark, plus plugin detail and reset confirmation in the same three variants. Artifacts are in `build/render-gallery/hub/`, with `index.html`, `manifest.json` and three overview contact sheets.
- Visual inspection caught and fixed overflowing minimum-width Quick Start grids, a second stale width environment inside the page scroll container, and dynamic localization keys interpreted as interpolation format strings. The latest narrow renders retain the right content inset and switch Quick Start to one column.
- The user approved one isolated native keyboard-focus verification through `scripts/pre-push-checks.sh`. It executed exactly once in the second gate attempt and **failed**. `/tmp/hub-pre-push-ui-2.log` reports 2,601 Swift Testing tests with two issues, both from `PickyHubNativeFocusTests.dismissingTheProductionModalReturnsKeyboardActivationToItsTrigger()`. No other Swift test failure was reported. The gate's backend phases passed 837 + 428 tests, with two skipped. No commit, push, signing change, or control of the running Picky app occurred.

## Remaining verification and findings
- Independent review confirmed the other core fixes; the follow-up foreground review (#16) confirmed both source scoping and latest-app tracking with no new findings. Native Workspace activation and click behavior remain unverified manually.
- The three additional P2 findings from review #20 were repaired with focused tests. Independent re-review #21 confirmed all three fixes and found no new consent-boundary issues. That review did not verify native focus, and the subsequent native timeout remains a blocker.
- The first pre-push attempt passed 1,265 backend tests with two skipped, then stopped on a six-field tuple SwiftLint error before any native UI test executed. The tuple was replaced with the existing named model-usage type; all seven aggregation tests passed before the second gate attempt. Lint limits and signing were not changed.
- Gallery evidence does not cover live microphone/permission requests, updater actions, actual package installation, media playback, external Workspace app activation, or full end-user Hub navigation.

## Native focus blocker

- Result: **initial-focus prerequisite failed; product cause remains unconfirmed**. A deeper read of the original `ActionTestSummary.failureSummaries[].sourceCodeContext.callStack` recovered the caller at the failed run's line29 (current line30, after the post-failure locale injection). It is the first `didAppear && isKeyWindow && AX label == expected` condition. Neither the first Space event nor modal presentation was reached. This corrects the earlier claim that the failing phase was unknown; the high-level xcresult summaries omit these source locations.
- The observed values of that compound condition are still missing. The failed fixture lacked the production `LocalizedHostingRoot` locale, its optional AX cast collapses several failure modes into nil, and its appearance-time focus request precedes any established key-window readiness. These are observation/precondition gaps, not proof of which one caused the timeout. The shared button's internal and caller-level FocusState bindings remain an unconfirmed product candidate. Modal dismissal/restoration cannot explain this recorded failure because those actions were not executed.
- Evidence: `/private/tmp/PickyAgentDD/Logs/Test/Test-Picky-2026.09.08_16-17-28-+0900.xcresult`; raw summary and bounded original stack are `/tmp/hub-focus-analysis.KYcJkd/native-summary.json` and `failure-location.json`. Both issues refer to the same timeout. The result contains no media attachments. The detailed read-only analysis and decision table are `/tmp/hub-focus-analysis.KYcJkd/analysis.md`.
- The helper now reports the phase, key-window state and actual focused accessibility element. Its SwiftUI locale is explicitly aligned with the localized oracle. These are diagnostic improvements, not a confirmed fix.
- `/tmp/hub-native-diagnostics-build.log`: `TEST BUILD SUCCEEDED`, **compilation only**. No second native execution was performed. No product or test code was changed during the subsequent failure analysis.
- Next proposed verification: in a future approved pre-push UI cycle, compare a standard SwiftUI Button and the Hub button with the same known locale and established window readiness. Observe Space action counts independently of AX identity, then record raw AX class/cast/role/identifier/label and expected locale. Only exercise modal restoration after initial keyboard operation is established. A working standard control with a failing Hub control narrows the product investigation; correct raw focus with a failing cast/label comparison identifies an observation defect. Do not extend timeouts or change product focus routing without this evidence.
- Apple references: [accessibility focus traversal](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXUItesting/cocoaAXUItesting.html) and [SwiftUI focus interactions](https://developer.apple.com/videos/play/wwdc2023/10162/). Text-editor focus is not a substitute for a standard-button control, and button keyboard navigation has system-policy dependencies.

Offscreen rendering does not prove native keyboard focus, window anchoring, media playback or live permission flows. Those limitations must remain explicit in the final report.
