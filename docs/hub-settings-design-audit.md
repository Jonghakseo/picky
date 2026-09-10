# Hub settings design audit

## Scope and decision

Reviewed all seven groups in `Picky/Hub/Pages/PickyHubSettingsPage.swift`, embedded routes in `Picky/Companion/CompanionPanelSettingsView.swift`, `Picky/Hub/Statistics/PickyHubClassificationSettingsView.swift`, and `Picky/Shortcuts/ShortcutSettingsViews.swift`. Shared Hub destructive text is defined in `Picky/Hub/PickyHubTheme.swift`. The supplied Korean dark-mode screenshot is the baseline visual evidence. Code inspection covers the remaining groups; live interaction is not implied by that inspection.

The goal is to find a setting, understand its effect, and change its value without the controls overpowering their labels. Keep the existing single scrolling page and deep links rather than introducing tabs that unmount draft-owning views. Jump links remain actions, not selected tabs. Preserve native menus, toggles, autosave, explicit draft Save, permission requests, and destructive confirmations.

Use existing DS spacing and Hub typography/color tokens. Reading descriptions use secondary text, not disabled-adjacent tertiary text. Embedded cards regain identifying headings. No material, shadow, new animation, or custom focus ring is needed. Native menus and toggles retain their behavior. Jump buttons keep native Button actions and keyboard semantics with a multiline SwiftUI label and immediate hover/pressed state layers; AppKit's bordered button truncated long English labels in the first render. No jump animation is introduced beyond the existing Reduce Motion-aware scroll.

References: [Picky principles](../design/PRINCIPLES.md), [tokens](../design/TOKENS.md), [audit rubric](../design/AUDIT.md), Apple [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).

## Baseline score

Scores describe screenshot and source evidence, not unperformed interaction testing.

| Criterion | Score | Evidence |
|---|---:|---|
| Information hierarchy | 1 | Embedded section titles disappear; page chrome and menus dominate |
| Action/status semantics | 1 | Jump links look like tabs without selection; save/error semantics remain explicit |
| Token consistency | 1 | Hub and embedded panel use different text roles and raw spacing |
| Density/spacing | 0 | Flexible popups absorb most row width; jump links overflow horizontally |
| Interaction completeness | 1 | Native controls retained, but folder removal targets are tiny |
| Appearance/accessibility | 1 | Dark explanations and field labels have weak contrast |
| Material/elevation/motion | 2 | No new floating treatment is needed; jump scroll honors Reduce Motion |
| Product invariants | 2 | Draft ownership, confirmations, status, and explicit deep links exist |

## Findings and changes

- **P1, reading contrast.** Embedded `fieldLabel`, explanatory text, and classification details use metadata-grade text colors. Use primary for embedded field labels and secondary for reading content. Preserve standalone panel colors and semantic error/warning/success colors.
- **P2, menu geometry.** `PickyHubSettingsRow` gives all controls a minimum width but no useful menu measure. `PickyNativeMenuPicker.sizeThatFits` accepts that offered width, producing the large gray bars in the screenshot. Bound menu presentation at the settings call sites rather than changing the native adapter or constraining every toggle and folder list. Embedded account/model, reasoning, context, quality, and voice menus use a 320pt maximum measure; segmented controls and text fields keep their existing width. This component metric accommodates longer provider/model names.
- **P2, navigation discoverability.** `groupLinks` hides overflow and gives every category pill the same blue treatment. Show all categories in a wrapping neutral action layout. Do not pretend a jump link is a selected tab.
- **P2, embedded identity.** `sectionHeader` suppresses every embedded heading, so account, main-agent, voice, and shortcut cards lose their identity. Restore compact accessible card headings while keeping the Hub group heading and durable save affordance. The overlay-only embedding keeps just the accurate Hub group heading, not the standalone “Overlay & Notifications” title.
- **P1, shortcut instructions.** Full-page renders revealed that `ShortcutSettingsRow` still rendered explanatory and capture instructions with small tertiary text. Use the existing supporting typography and secondary foreground; recorder and Save/Cancel behavior remain unchanged.
- **P1, destructive text contrast.** The Hub's light danger foreground `#F87171` measured 2.77:1 against white using sRGB relative luminance. Its replacement `#CC2329` measures 5.47:1. Map its shared foreground role to `DS.Colors.destructiveText` so settings reset and its confirmation use foreground-grade semantic red without changing action roles.
- **P2, folder actions.** `folderRow` uses a small x glyph and a generic accessibility label. Give the native button a usable hit area, retain the path as contextual help, and identify the target folder to assistive technology.

## Group coverage

| Group | Inspected controls and retained behavior |
|---|---|
| General | Language and immediate locale application, appearance, app/report/terminal scales, channel, update checks, onboarding confirmation |
| Account and agent | OAuth status/login, main-agent paths/model/reasoning/context, advanced tool disclosure, draft Save and validation errors |
| Voice and input | STT/TTS providers, credentials, provider-specific options, TTS disabled state, voice loading/errors, shortcut controls |
| Screen and overlay | Cursor/annotation and response-bubble settings; notification controls remain in their dedicated group |
| Pickle and workspace | Pickle defaults/model/reasoning, default directory, Dock settings, pinned/recent folder actions |
| Notifications, permissions and privacy | Confirmed classification snapshot, saving/error/unknown states, completion/failure/input preferences, permission actions, privacy notice |
| Advanced and diagnostics | Watchdog, shell installation, reset confirmation, pending/success/error status |

## Keep

Keep the common Hub shell and brand identity. Do not redesign the sidebar or other Hub destinations for a settings request. The semantic danger foreground correction also applies to other Hub destructive buttons that share that token. Preserve native menu item identity, persistence ownership, validation text, disabled controls, and all status icons. Keep advanced tools behind the existing disclosure rather than moving or deleting controls.

## Selector chrome follow-up

The second supplied screenshot specifically requests replacing the gray popup bezel and blue arrow, not only narrowing the control. Hub settings opts into quiet popup chrome through `pickyUsesSubtleMenuChrome`; other native picker call sites retain their standard appearance. The closed control uses a neutral surface, a single monochrome disclosure chevron, and hover/pressed/disabled feedback. The open menu, selection, keyboard handling, accessibility role, and stable menu-item identity remain AppKit-owned.

All menu-style selectors in the embedded settings routes now use `PickyNativeMenuPicker`, including language, reasoning/context/quality, model, STT/TTS provider, and Edge voice/language. Option values, unavailable saved options, loading/error states, bindings, and save callbacks are retained. Segmented controls and text fields are not converted.

## Validation

Use the production Hub offscreen gallery, including normal light/dark/narrow windows and full-height Korean settings captures at 100% and narrow 130% font scale. Inspect generated PNGs, not merely their existence. The gallery uses disposable settings and mock dependencies, never the running app or daemon.

Offscreen output cannot prove native menu opening, VoiceOver announcements, keyboard traversal, hover/press, system permission dialogs, or window scroll restoration. These remain live checks; the running Picky app must not be restarted without explicit permission.

### Executed evidence

- Xcode 16.3 Hub gallery run passed. It generated the normal 27-scene matrix plus three full-height Korean settings captures. Inspected light/dark General and selectors, narrow 130%, account/model controls, voice/shortcuts, overlay/workspace, and the light privacy/diagnostics footer.
- `embeddedNativeSelectorPersistsItsChosenReasoningLevel` passed through the production embedded view and native target/action to the persisted settings file.
- The percentage-menu activation regression passed. `PickyNativeMenuPickerTests` passed all six test functions, including standard/subtle selection variants, disabled behavior, translated/dynamic options, unavailable values, font scale, native accessibility role/value, and stable menu/item identity.
- `writesFullPageHubAuditFromExportedSnapshot` had no exported-data request and returned without exercising that unrelated audit path; it is not evidence for this change.
- `pnpm run lint:ui-design-tokens` and `git diff --check` passed.
- One attempt stopped before tests because another build held the shared build DB. After verifying that build had exited, the retry passed without changing signing or restarting Picky.

Preview: `build/render-gallery/settings-selector-preview-dark.png`. Complete evidence: `build/render-gallery/hub/index.html` and `build/render-gallery/hub/settings-full/`. No live popup opening, VoiceOver traversal, or system permission dialog was exercised.

## Main-agent density follow-up

The later main-agent screenshot still shows a continuous wall of labels, explanatory prose, and runtime paths. Narrower selectors do not solve that information hierarchy. Keep all controls and warnings visible, but group the card into workspace/instructions, model/reasoning, screen context, delivery mode, and local runtime paths. Use 24pt group separation, 8pt field spacing, and readable multiline leading instead of reducing font size or hiding settings behind new disclosures. Moving controls must not move draft ownership or durable Save/error state out of the main-agent section.

Replace the wide gray Follow-up/Steer segmented control with two exclusive choice cards. Each option shows its name, a short behavioral description, and a non-color selection marker. Selected uses Action Blue subtly; rest remains neutral. Stack the choices when the available width or font scale cannot support both. Retain native Button keyboard activation and expose each selected state to accessibility. Clarify that the preference applies to PTT/Quick Input sent to an armed Pickle, and that idle Pickles start immediately with either choice.

Verification extends the existing production gallery to both selected modes and exercises observed setting changes through the mounted production main-agent view to persisted `armedPickleDispatchMode`. Live keyboard traversal and hover still require a displayed window and are not inferred from offscreen renders.


The attempted offscreen AX-press test could not observe pure SwiftUI buttons. Diagnostics showed that the modern child API was empty and the legacy API exposed native controls only; `PickyHubSettingsRuntimeContractTests` documents the same limitation. The saved-state test therefore checks the real view observer and persistence boundary, not a synthetic button press. Actual button activation and keyboard traversal remain unverified. No production behavior or assertion about persisted values was changed to accommodate the harness.

Density follow-up results: the production gallery test completed and its 27 standard plus four full-height settings PNGs passed encoding/dimension checks. Inspected light/dark layouts, narrow 130%, and both selected dispatch modes. The unchanged native percentage-menu and reasoning-persistence tests also passed. The replacement `dispatchModeChangesPersistFromTheMountedSettingsView` test then passed in isolation for Steer and Follow-up, checking the observed value and the saved file. The earlier suite was not a pass because its unsupported AX observation failed; those results are not presented as successful button activation. Token lint and diff checks passed. Preview files are `build/render-gallery/agent-settings-dark.png`, `agent-settings-dark-steer.png`, `agent-settings-light.png`, and `agent-settings-narrow.png`.

## Independent cards and progressive explanation

The next revision separates the five main-agent groups into actual Hub cards with canvas gaps, replacing the single enclosing card. The main-agent view remains a single draft/save owner; this is a visual grouping change, not five independently mounted settings routes. Standalone Companion settings keep their existing shell.

Each field shows a short summary by default. Native Details disclosures contain the existing full explanation; inputs, the workspace/AGENTS.md warning, save status, validation errors, restart impact, and image-token implications remain outside collapsed content. The card headings use the existing type hierarchy, with neutral surfaces, 16–20pt insets, and no extra shadows. Full-page light/dark and narrow 130% production renders plus existing reasoning/dispatch persistence tests are the validation boundary. The user requested the rendered preview as part of completion.

Executed verification: the Hub run succeeded with the production gallery and three menu/persistence tests (percentage menus, reasoning level, both dispatch modes). The exported-snapshot test returned without exercising that optional path. Reviewed the generated light/dark card crops and narrow 130% layout; all controls and default warnings remain visible. Previews: `build/render-gallery/agent-settings-cards-dark.png` and `agent-settings-cards-light.png`. Native Details activation/keyboard traversal and expanded layouts remain unverified. `git diff --check` passed. Token lint failed on the same two raw-padding occurrences reproduced in unmodified HEAD `232f187eb`; this change adds neither occurrence. The running app was not restarted.
