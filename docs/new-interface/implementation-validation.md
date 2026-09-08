# Hub implementation validation

Worktree: `feat/new-interface`. The final quality gate and native keyboard contract passed. Independent handoff findings F1–F6 remain unresolved; this is not a claim that the whole Hub is ready to ship.
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
- The earlier approved isolated native test failed before keyboard input in `/tmp/hub-pre-push-ui-2.log`. Subsequent evidence identified fixture/observation problems rather than a required product focus change. The final successful keyboard verification is recorded below.

## Final keyboard verification

- `/tmp/hub-focus-gate-final.log`: **all local quality checks passed**, including the Swift run reporting **2,604 tests passed**, backend **837 + 428 tests passed with two skipped**, build, lint and repository guards. The native test explicitly **executed and passed in 0.424 seconds**; it was not skipped in this gate.
- `/tmp/hub-focus-final-unit.log`: the targeted run reported eight tests passed, with the native case correctly skipped outside the pre-push gate. It includes the AX observer regression and a later duplicate modal-removal callback whose task is awaited before checking final counts.
- Actual keyboard evidence uses `NSEvent` Space down/up events dispatched through the isolated window, not direct invocation of button actions. The standard SwiftUI Button activates once. The production Hub button activates once, the dialog's **Cancel activates once and Confirm zero times**, then the restored Hub button activates again.
- After SwiftUI fixture removal, window close and host cleanup, the exact counts remain **trigger=2, Cancel=1, Confirm=0, focusRequests=2**. The latter is one initial request plus one restoration. Review #23 confirmed that review #22's final-count gap was addressed, with no new findings.
- Keyboard Navigation is an explicit precondition for this button-focus contract. Ordinary tests retain the pre-push-only gate; without Keyboard Navigation, this native suite reports a condition-based skip rather than misclassifying an unsupported environment as a product failure. A skip is not native verification.
- For the final positive run, the user explicitly approved temporarily enabling system Keyboard Navigation. An external `try/finally` wrapper set only `AppleKeyboardUIMode`, ran `scripts/pre-push-checks.sh`, and restored its original absence. `/tmp/hub-focus-analysis.KYcJkd/keyboard-navigation-restoration-final.json` and a fresh AppKit probe confirm **mode=0, keyboardNavigation=false** after restoration. The repository test itself never changes preferences. No signing change, running-app restart or push occurred.
- No product code changed to resolve this native test failure. The existing production window, Hub button, modal and dismissal callbacks were exercised.

### Why the old focus verdict was invalid

1. The original xcresult's raw call stack identifies the first compound initial-focus condition at the failed run's line29. Keyboard input and modal presentation had not happened; the two issues were a recorded timeout and its thrown error, not separate product failures.
2. A metadata-only probe found that `SwiftUI.AccessibilityNode` exposes accessibility selectors without formally conforming to `NSAccessibilityProtocol`. The old optional cast can therefore lose valid data. A pure observer test reproduced this failure, then passed with guarded selector dispatch. This is a real observer defect, but it was not the only failed prerequisite.
3. `/tmp/hub-focus-gate-3.log` shows active/key window readiness but disabled Keyboard Navigation. Even the standard button did not receive focus or Space. Volatile process defaults did not change AppKit's actual policy.
4. With the user-approved setting enabled, `/tmp/hub-focus-gate-keyboard-enabled.log` shows working standard/Hub Space, modal dismissal and restored Space. However, `window.accessibilityFocusedUIElement` returned the **NSHostingView AXGroup**, not the virtual button, so the old AX label expectations still failed.
5. The final test establishes real responder readiness and checks keyboard action results, with distinct Cancel/Confirm counters and final cleanup assertions. AX class, role and label remain diagnostic information, not an invalid keyboard-focus oracle. This does not claim that external assistive-technology AX navigation has been validated.

Apple references: [accessibility focus traversal](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXUItesting/cocoaAXUItesting.html) and [SwiftUI focus interactions](https://developer.apple.com/videos/play/wwdc2023/10162/). Text-editor focus is not a substitute for a standard-button control.

## Independent handoff findings still open

The user supplied `/tmp/picky-new-interface-review-handoff.md` after the keyboard-test work. Rechecking HEAD `6efea2629` confirmed these six independent omissions. `/tmp/picky-new-interface-review-checked.md` contains the detailed comparison. These are **not fixed by the passing keyboard gate**; regression coverage for these cases has not yet been added.

| ID | Remaining issue | Evidence |
|---|---|---|
| F1 / P1 | Quick Start success, resume and Open only call `requestOpenSession`; they do not restore hidden HUD visibility through its owner. | Source traced through selection, local card state and actual panel visibility policy. Native reproduction not run. |
| F2 / P2 | Notification deep links route to overlay rather than privacy; tools links lose the leaf target and leave advanced controls collapsed. | Parser, navigator and final group/disclosure placement checked. |
| F3 / P2 | Browser capture permission row opens generic Security settings instead of calling `requestScreenContent()`. | Compared with the existing approval/capture/persistence owner and old prerequisites action. |
| F4 / P2 | A `main_agent` kickoff followed by one user instruction reports zero follow-ups. | Current production function reproduced `user -> 1`, `main_agent -> 0` for the same one-follow-up case. |
| F5 / P2 | With 65 unchanged transcripts, a 64-entry LRU rereads/reparses all 65 on the second snapshot. | Current production service reproduced first=65, second=65, cacheSize=64. User-visible latency was not measured. |
| F6 / P2 | Recent Conversation omits text-selection enablement on AI Markdown that the old transcript row provided. | Old/new component and parent selection modifiers compared. Native drag-selection reproduction not run. |

F4/F5 reproduction output is `/tmp/hub-handoff-probe-current.log`; fixtures were created in a fresh temporary directory and removed. No real daemon, model provider or user session data was used. Fix F1 first, then settings/permissions and statistics correctness/cache boundaries. Keep stable-ID fork/main usage deduplication when changing the cache.

## Other verification limits

- Independent reviews #16 and #21 confirmed their bounded core/P2 fixes. They did not cover the later handoff omissions above.
- The original six-field tuple lint failure was fixed with the existing named model-usage type and seven passing aggregation tests, without changing lint limits or signing.
- The 27 inspected renders remain valid visual evidence, but they do not prove microphone/permission requests, updater actions, actual package installation, media playback, external Workspace activation, external accessibility navigation, or all end-user Hub flows.
- The handoff's sidebar text truncation note was not independently rerendered during that recheck. Verified guide publication metadata is still required before filling the production feed.
