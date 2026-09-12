# Hub component rules

Applies only to the Hub window: Dashboard, Statistics, Guides, Quick Start, Plugins, Conversation, Settings, sidebar, and Hub dialogs. Pickle HUD, Dock, cursor overlays, standalone Companion settings, and shared conversation/bubble implementations are outside this change.

## Decision

Use the existing Hub components and semantic tokens instead of another design system. Keep native controls, page retention, navigation, command dispatch, draft ownership, persistence, confirmation, and error states intact. Shared controls may be styled by a Hub-local wrapper, never by changing their global defaults.

| Role | Rule |
| --- | --- |
| Label, control, supporting explanation | 8pt between related elements |
| Independent fields and card sections | 16pt; 24pt for distinct subgroups |
| Standard card inset | 20pt; compact list rows 16pt horizontal and 12pt vertical |
| Card/grid gap | 16pt |
| Page/section separation | 32pt; heading to content 16pt |
| Card shape | 12pt radius, neutral surface, subtle border, no decorative shadow |
| Controls | 8pt radius, at least 32pt actionable height, 12pt horizontal inset. Dropdown selectors use `PickyHubMenuPicker`, backed by the shared native popup control. |
| Type | Page 24pt, section 20pt, card/subsection 18pt, body 14pt, supporting 13pt, metadata 12pt; scale with app font setting. Use only regular, medium, and semibold. Reserve semibold for headings, controls, and short status emphasis; never use bold or heavy. |
| Text | Leading alignment and natural wrapping; truncate only explicitly secondary metadata such as paths. Put supporting labels and metadata below their title instead of using eyebrow text above it. |
| Text selection | The Hub root enables `pickyHubTextSelectionEnabled`, but only read-only body, path, error, and statistics text marked with `pickyHubSelectableText()` becomes selectable. Never apply SwiftUI `textSelection` to the Hub root, controls, tabs, navigation, or clickable-card labels. |
| Actions | Standard Button semantics, visible labels or accessibility labels for icons; selected state has a non-color cue |
| Disclosures | Whole label row activates; expanded content is leading-aligned; expose current state |
| Responsive layout | Reflow actions/filters before clipping at 760pt or enlarged fonts; no smaller text to force a fit |
| Feedback | Preserve hover, press, disabled, busy and keyboard focus; Reduce Motion suppresses optional movement |
| Colors | Hub semantic roles; Action Blue for action/selection, semantic tones for status |

`PickyHubTheme.Spacing` owns `related` (8), `field` (16), `group` (24), `cardInset` (20), `rowHorizontal` (16), and `rowVertical` (12). `PickyHubTheme.Control` owns `minimumHeight` (32), `horizontalInset` (12), and `maximumFieldWidth` (320). Layout/card/type roles remain in their existing theme namespaces. Chart geometry, sidebar/window mechanics, and tightly grouped noninteractive metadata can retain documented role-specific metrics; do not mechanically replace every number.

## Validation boundary

Reuse the production Hub render gallery and existing navigation, settings persistence, modal, and grid contracts. Review all seven pages in light/dark and narrow layouts, and a larger-font scene set. A render establishes appearance and geometry, not mouse, keyboard, VoiceOver, permissions, or live service behavior. Keep the running app untouched. No performance improvement is claimed without measurements.

References: [Picky principles](../design/PRINCIPLES.md), [tokens](../design/TOKENS.md), [Apple accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Apple layout](https://developer.apple.com/design/human-interface-guidelines/layout), [SwiftUI text selectability](https://developer.apple.com/documentation/swiftui/textselectability/enabled).

## Applied surfaces

- Dashboard: greeting/prerequisite groups, summary cards, guide/quick-start sections, and plugin rows share spacing and card roles.
- Statistics: filter labels and controls, tabs, summary cards and data-table text wrap without changing aggregation or numeric column geometry.
- Guides: cards, empty states, and video-dialog action layout use common roles. The shipping feed is currently empty; populated-card inspection uses a separate sample fixture.
- Quick Start: workflow cards and actions reflow; dispatch and folder-selection callbacks are unchanged.
- Plugins: category chips wrap, card column counts account for font scale, and detail/removal/reload actions retain confirmation and busy/error state.
- Conversation: only the Hub timeline/header/composer wrappers change, preserving its scroll owner and shared message behavior.
- Settings: Hub rows and headings reflow with consistent card spacing. Shared Companion settings and permission views mark copy-worthy explanations and errors, while the Hub-local environment gate keeps standalone Companion surfaces unchanged.
- Shell: the brand is a keyboard-focusable Button; navigation can scroll when needed while footer controls remain available. Common scrolling pages use an explicit leading-aligned vertical container.

The existing design-token lint does not scan the entire Hub tree. Its pass is supplemental, not proof that every Hub style follows this document. Render review and the shared components remain necessary.

## Executed verification

- The selective-text AppKit regression passed. Marked Hub body text and the production Conversation subtitle became non-editable selectable fields, while page titles and button labels stayed non-selectable; disabling the Hub environment removed selection.
- Final production gallery succeeded: 27 standard page/dialog scenes, four full settings scenes, fourteen full/enlarged page scenes, two expanded-disclosure renders, and two populated guide-card renders. The regenerated Settings light/dark, Statistics narrow-dark, and Dashboard dark scenes retained their expected geometry and styling.
- Inspected light/dark overview, enlarged-page layouts, Quick Start's corrected leading heading, and the populated guide card. The latter has OCR assertions for the final title word and absence of an untranslated kind key.
- Eighteen existing contracts passed across `PickyHubLayoutPolicyTests`, `PickyHubModalTests`, `PickyHubPageMountTests`, and `PickyHubSettingsRuntimeContractTests`. After the final scroll-container adjustment, the seven page-mount/settings contracts passed again; subsequent changes affected only guide-card text and its render assertions.
- The gallery's native-menu and reasoning/dispatch persistence regressions passed. The exported-snapshot test returned early because no export request was supplied and is not counted as exercised evidence.
- Design-guide validation, token lint, architecture guard, and diff checks passed. Shared Companion text markers default off outside the Hub, and command/draft ownership is unchanged. The app was not restarted.
- Native pointer/keyboard/VoiceOver operation, video playback, and live external-service actions remain unverified. These results are not an accessibility certification or a performance claim.

Preview: `build/render-gallery/hub/common-rules-preview.html` (theme/size selector), plus `overview-wide-dark.png`, `overview-wide-light.png`, and `overview-large.png` in the same directory. The normal gallery script regenerates the raw PNGs; the task-specific overview/preview files are generated review artifacts.
