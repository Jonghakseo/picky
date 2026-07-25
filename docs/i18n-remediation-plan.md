# i18n remediation plan

## Purpose

This is the implementation backlog from the application-wide i18n audit. It
covers Picky-owned text that reaches users in the app, HUD, notifications,
AppKit surfaces, speech, and `agentd` events rendered by the HUD.

The catalog is **not** the current problem: `Picky/Resources/Localizable.xcstrings`
has 568 keys, complete `en` and `ko` translations, no empty values, and no
format-placeholder mismatches. The gaps are code paths that bypass the catalog
or use the system locale instead of Picky's selected locale.

This plan does not translate user/agent-authored content, paths, model names,
tool names, debug logs, Pi-only prompts, or developer CLI output.

## Completion criteria

- All Picky-owned visible copy resolves from `Localizable.xcstrings` using the
  selected Picky language.
- AppKit-owned alerts, menus, panels, and window titles use `L10n.t(...)` and
  refresh or are recreated after `LocaleManager.didChangeNotification`.
- `agentd` sends semantic presentation codes plus typed arguments, never
  already-English HUD system/error/summary copy.
- Date, relative-date, number, byte-count, duration, list, and plural
  formatting use `LocaleManager`'s effective locale.
- The System language choice immediately returns to the actual macOS language.
- Static and runtime i18n checks cover English, Korean, and System language.

## Priority 0 — language selection correctness

### Restore the true system language

- **Location:** `Picky/Localization/LocaleManager.swift:71-99`
- **Problem:** `apply(.system)` calculates `newChoice.resolvedLocale` before
  clearing the process `AppleLanguages` override. After choosing a fixed
  language, relaunching, and selecting System, it can retain the previous
  forced language rather than the macOS language.
- **Action:** Clear the override before resolving the System locale, or resolve
  the unmodified macOS preference through a dedicated source. Add a regression
  test for fixed language -> cold launch -> System.

## Priority 1 — blocking and high-visibility surfaces

### Main-agent question form and activity chip

- **Locations:**
  - `Picky/QuickInput/PickyMainQuestionPanelView.swift:146-316`
  - `Picky/Overlay/PickyMainActivityChipView.swift:107,139,153`
- **Problem:** The form mixes Korean visible controls and English VoiceOver
  labels (`이전`, `제출`, `Next question`, `Sending`, etc.). The waiting chip is
  Korean-only and its accessibility text is English-only.
- **Action:** Add semantic catalog keys for every Picky-owned fallback,
  validation message, navigation/control label, placeholder, and accessibility
  value. Use `L10n.t(...)` for interpolated/string-typed values.

### Shell command, terminal, feedback, and watchdog AppKit UI

- **Locations:**
  - `Picky/App/ShellCommandMenuController.swift:51-150`
  - `Picky/Sessions/PickyTerminalOverlay.swift:39-41,592-786,811-815`
  - `Picky/Feedback/CompanionPanelFeedbackView.swift:26-40,318-342,456-458`
  - `Picky/Watchdog/PickyWatchdogAlertHelper/main.swift:101,109-111`
- **Problem:** Alerts, terminal statuses, feedback attachment UI, and watchdog
  controls are hardcoded English.
- **Action:** Move Picky-owned labels/messages to catalog keys. For `NSAlert`,
  `NSOpenPanel`, `NSMenuItem`, and window titles, resolve with `L10n.t(...)`.
  Confirm the watchdog helper target can load the catalog; otherwise give it a
  small localized resource bundle/API rather than falling back to literals.

### Session notifications, reports, overlays, and voice failures

- **Locations:**
  - `Picky/PickySessionViewModel.swift:908,945,995-1015,1841`
  - `Picky/CompanionManager.swift:1220,1275,2101,2345,2411-2450,2743-2774`
  - `Picky/BuddyDictationManager.swift:741,751`
  - `Picky/PickyAskUserQuestionForm.swift:111`
  - `Picky/Overlay/PickyAgentAnnotationOverlayView.swift:38-39`
- **Problem:** User-visible notification bodies, report/tool-history titles,
  agent summaries, answer failures, PTT permission failures, confirmation
  summaries, and accessibility summaries use raw English fallbacks.
- **Action:** Localize Picky-owned fallback copy at the presentation boundary.
  Preserve raw agent/user content as authored; only wrap Picky-owned error and
  state messages in localized templates.

### agentd messages rendered by Picky

- **Locations:**
  - `agentd/src/application/runtime-event-handler.ts:169,253,287-288,451,536-554`
  - `agentd/src/session-message-builder.ts:75`
  - `agentd/src/session-supervisor.ts:2162,2706`
  - `agentd/src/server.ts:689,741`
  - `agentd/src/domain/pickle-handoff-context.ts:37-42`
- **Problem:** Node writes English text such as `Session compacted`, `Agent
  failed`, `Cancelled by user`, tool termination summaries, package errors,
  and `New Pickle` directly into message journals/session cards. The HUD then
  renders those strings verbatim.
- **Action:** Extend the app-daemon protocol/message model with a semantic
  Picky presentation code and typed parameters (for example
  `sessionCompacted`, `packageOperationTimedOut(timeoutMs)`). Swift maps codes
  to catalog keys at render time. Do not translate in `agentd`, and do not use
  English prose as an identifier. Keep unknown external errors as a localized
  generic error plus safely displayed detail.

## Priority 2 — HUD and SwiftUI chrome

These surfaces use catalog-missing literals or `Text(String)` values and must
be migrated to semantic catalog keys. Dynamic values require `L10n.t(...)` or
a localized format style, not a `String` passed to `Text`.

| Surface | Locations |
| --- | --- |
| Dock group creation | `Picky/HUD/PickyDockGroupCreatorView.swift:61-162` |
| Dock preview, unread state, session status/fallbacks | `Picky/HUD/PickyHUDDockIconView.swift:144-203,1227-1335` |
| Tool activity status, risk, cwd fallback | `Picky/HUD/PickyToolActivityRow.swift:20-60` |
| Question bubble controls/statuses | `Picky/HUD/Conversation/Bubbles/PickyQuestionBubbleView.swift:26-28,107-250` |
| Error, typing, compacting, tool-call, extension bubble labels | `Picky/HUD/Conversation/Bubbles/PickyErrorBubbleView.swift:27`; `PickyTypingBubbleView.swift:32,54-56`; `PickyToolCallInlineRow.swift:51,61-72`; `PickyAgentBubbleView.swift:95`; `PickyCompactStatusViews.swift:39`; `PickyOpenAsReportHoverIcon.swift:39` |
| Composer/header/menu/context-line/terminal controls | `Picky/HUD/Conversation/PickyConversationComposerView.swift:313-314,336,361-362,446,871-872,1438-1439`; `PickyConversationHeaderView.swift:170-171,307,348-349,851-852,873`; `PickyConversationMenu.swift:63`; `PickyConversationContextLineView.swift:199,221,250,293`; `PickyInlineTerminalCardView.swift:112,186,205,223,255`; `PickySessionExtendedTerminalView.swift:265` |
| Report, archive, dock, history, list, resize UI | `Picky/HUD/PickyReportViewer.swift:939-943,1061-1090`; `PickyHUDArchivedSessionsListView.swift:120,186`; `PickyHUDArchiveUndoToast.swift:103`; `PickyHUDDockRailView.swift:925-926`; `PickyToolHistoryViewer.swift:244,481,488,501,518,617`; `PickyConversationListView.swift:465,559`; `PickyHUDView.swift:374` |

## Priority 2 — remaining AppKit and shortcut UI

- **Locations:**
  - `Picky/App/PickyAppMenuInstaller.swift:31-160`
  - `Picky/HUD/Conversation/Bubbles/PickyUserBubbleSurfaceView.swift:230-235`
  - `Picky/HUD/Conversation/Bubbles/PickyMarkdownInlineTextView.swift:585-596`
  - `Picky/Companion/CompanionPanelHeaderView.swift:19,35-36`
  - `Picky/Companion/CompanionPanelMessagesView.swift:184`
  - `Picky/QuickInput/QuickInputPanelView.swift:21-23,239,253,524`
  - `Picky/Shortcuts/ShortcutCaptureRecorder.swift:38-45,191,209,226`
- **Action:** Localize app/right-click menu entries, panel tooltips and labels,
  composer placeholders, Quick Input controls, and shortcut-recording status
  messages. `ShortcutCaptureRecorder` should expose a semantic status enum or
  key/arguments, because its current plain `String` is rendered with
  `Text(message)` and cannot localize at the view boundary.

## Priority 2 — locale-aware formatting and language-specific speech

### Use Picky's effective locale everywhere

- **Locations:**
  - `Picky/Companion/CompanionPanelSettingsView.swift:241,838`
  - `Picky/HUD/Conversation/PickyRewindPickerView.swift:189-191`
  - `Picky/HUD/Conversation/PickyConversationHeaderView.swift:948-950`
  - `Picky/HUD/Conversation/Bubbles/PickyActivitySummaryView.swift:120-122`
  - `Picky/Companion/CompanionPanelStatusView.swift:321`
  - `Picky/Companion/PickyMainAgentTranscriptRow.swift:50`
  - `Picky/HUD/PickyToolHistoryEntry.swift:213-214`
  - `Picky/HUD/PickyToolHistoryViewer.swift:642-645`
  - `agentd/src/application/runtime-event-handler.ts:546-548`
- **Action:** Resolve language labels through `LocaleManager.stringsBundle` and
  `effectiveLocale`, not process-default `String(localized:)`. Inject
  `effectiveLocale` into `RelativeDateTimeFormatter`, `DateFormatter`, number,
  byte-count, and duration formatters. Node must send raw numeric values, not
  `en-US`-formatted text.

### Add plural and list formatting

- **Locations:** `Picky/Resources/Localizable.xcstrings:2008` and count-bearing
  strings; `Picky/Companion/CompanionPanelExtensionsView.swift:334-335`.
- **Action:** Add string-catalog plural variations for singular/plural English
  copy and remove literals such as `session(s)`. Use `ListFormatter` with the
  effective locale, or a complete localized sentence, instead of manually
  joining translated fragments with `, `.

### Make TTS substitutions language-aware

- **Location:** `Picky/Companion/Speech/PickySpeechTextSanitizer.swift:19-31`
- **Problem:** URLs and paths are always replaced with Korean (`링크`, `해당
  경로`), including for English TTS.
- **Action:** Pass utterance/voice language into the sanitizer and select
  localized substitution text from the catalog or a language-specific speech
  policy.

## Guardrails and verification

1. Extend `scripts/check-localizations.sh` (or add a focused static checker)
   to fail on Picky-owned user-facing literals absent from the catalog. Permit
   an explicit, reviewed allowlist only for symbols, key caps, user content,
   and developer diagnostics.
2. Add unit tests for:
   - fixed language -> System locale restoration;
   - `L10n.t` format arguments under English and Korean;
   - semantic agentd presentation code -> Swift localized rendering;
   - plural/list formatting and language-specific TTS substitutions.
3. Run the existing catalog validator and a two-language UI smoke pass over:
   onboarding, Quick Input, main-agent question form, HUD dock/conversation,
   terminal, archive, notification, feedback, shortcut capture, shell command
   dialog, right-click menus, and watchdog alert.
4. Test both language changes at runtime and after a cold launch. Verify that
   every AppKit surface receiving a locale-change notification refreshes.

## Suggested delivery slices

1. LocaleManager regression + main question form/activity chip.
2. Shared Swift key/formatter helpers + HUD/Quick Input/shortcut migration.
3. AppKit alerts/menus/window titles and feedback/terminal surfaces.
4. Protocol change for semantic `agentd` presentation events, then migrate
   session/system/error/fallback messages.
5. Plural/list/TTS work and static/runtime guardrails.
