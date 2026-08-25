# Dock Folder List Plan

_Status: design confirmed from mockup; implementation not started_

_Last updated: 2026-08-25_

## Summary

The dock rail currently renders every member of an expanded group as its own 54pt tile, so rail length grows linearly with Pickle count. With 14 Pickles across three groups the rail measures about 1002pt, which overflows the screen budget on a laptop display.

This plan replaces in-rail group expansion with a two-layer model:

1. **The rail only ever shows one slot per group.** Rail length scales with top-level entry count, not Pickle count.
2. **A group's members open as a floating list panel** anchored to the folder tile, layered above the conversation card.

The core invariant is:

> Rail length is a function of top-level entry count only. Member visibility is delegated to a transient overlay that never changes the rail's own footprint.

## Design Decision Card

- **User goal:** keep every Pickle reachable without the dock growing past the screen, and switch between Pickles in different groups without closing the one currently open.
- **Target surface/component:** dock rail folder tile plus a new floating list panel; the conversation card is untouched.
- **Rejected alternative:** collapsing the member list into a strip inside the conversation card header. It couples group navigation to card layout and cannot show a group other than the open Pickle's own group.
- **Rejected alternative:** an N x N icon grid. Six-character compacted labels (`PickyHUDDockLabelPolicy.compactLabel`) cannot distinguish Pickles whose titles share a prefix.
- **Accepted cost:** the list panel covers part of the conversation card while open. This is accepted deliberately so the HUD footprint never widens; the panel is transient and always closes on row selection.

## Layout model

### Rail

Top-level entries are ungrouped sessions and groups. A group always occupies exactly one slot, rendered as the existing folder badge (`PickyHUDDockCollapsedGroupBadge`). Group headers, the expanded member drawer, and the expand/collapse chevron are removed from the rail.

Rail length reuses the existing formula unchanged, with `sessionCount` redefined as `topLevelSlotCount` and the group-header term forced to zero:

```text
PickyHUDDockLayout.dockRailHeight(sessionCount: topLevelSlotCount, isAddSlotExpanded:)
  = topPadding(4) + handleAreaHeight(14) + 2
  + n * sessionTileHeight(54) + (n - 1) * sessionSpacing(9)
  + addSlotTopPadding(7) + addSlotFrameHeight(14 collapsed / 36 expanded)
  + bottomPadding(10)
```

`PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount:)` becomes dead once headers are removed and its call site in `PickyHUDDockRailPolicy.contentLength` drops to zero. The horizontal orientation uses `horizontalDockRailLength` with the same substitution, and `horizontalDockRailCrossSize(hasGroupHeaders:)` is always called with `false`.

Full-rail comparison at the medium preset with a collapsed add slot:

| Scenario | Top-level slots today | Today | Top-level slots after | After |
| --- | --- | --- | --- | --- |
| 3 groups, 14 members, 0 ungrouped | 14 + 3 headers | 1002pt | 3 | 231pt |
| 3 groups, 14 members, 2 ungrouped | 16 + 3 headers | 1128pt | 5 | 357pt |

Both columns use the same formula, so the numbers are directly comparable. The earlier draft's 951pt figure counted only the sessions region and is superseded.

`PickyHUDDockOverflowPolicy` stays as the safety net: a user with many ungrouped Pickles or many groups still hits the screen budget and still scrolls.

### List panel

New constants, defined at the medium preset (`scale = 1.0`):

| Constant | Value | Scaling |
| --- | --- | --- |
| `groupListPanelWidth` | 260 | Scales with preset geometry |
| `groupListRowHeight` | 38 | Minimum height; grows with text, see below |
| `groupListMaxVisibleRows` | 8 | Fixed count, not scaled |

Derived panel height:

```text
panelPadding(8) * 2 + header(22) + min(memberCount, 8) * rowHeight
```

At the medium preset with default text size this saturates at 342pt regardless of member count.

Panel chrome:

- Corner radius reuses `metrics.iconCornerRadius` (12); border 0.5pt `DS.Colors.borderSubtle`.
- Background uses the same HUD material as the conversation card so the panel reads as the same surface family, with a solid `DS.Colors.surface2` fallback under Reduce Transparency.
- Elevation is expressed by the border plus material only, matching the dock's existing treatment; no new shadow token is introduced.
- Header row (22pt): group color swatch 8pt, group name 12pt medium, member count 11pt `textTertiary`. No other controls.
- Open and close use a 120ms fade with a 0.98 scale from the anchored corner. Under Reduce Motion both are a plain opacity change with no scale.

Preset and text scaling:

- `groupListPanelWidth`, `groupListRowHeight`, padding, and header height scale through the same `scaled(_:)` path as other dock metrics. `PickyHUDDockMetrics.scaled` is currently private and must be exposed, or the new values must live as computed properties on `PickyHUDDockMetrics` itself. The latter is preferred so the private helper stays private.
- `groupListMaxVisibleRows` is not scaled. The visible row count stays 8 at every preset.
- Row height is a minimum, not a fixed frame. When the system text size grows, the row grows and the panel's saturation height grows with it. The 8-row cap keeps the panel bounded in row count even when its point height changes.

### Row anatomy

```text
[status glyph 20] [title 13pt / subtitle 11pt] [unread dot 7pt] [⌘N 11pt]
```

- Horizontal padding 10, inter-element gap 8. Order is expressed with leading/trailing semantics so RTL locales mirror correctly.
- Title: 13pt, `DS.Colors.textPrimary`, single line, tail truncation. The row uses the untruncated `session.title`, not `PickyHUDDockLabelPolicy.compactLabel`, which stays in use for the rail tile only. When `title` is empty the row falls back to the cwd leaf, then to `"Pickle"`, matching `PickyHUDDockIconView.dockLabel`.
- Subtitle: 11pt, `DS.Colors.textTertiary`, `<cwd leaf> · <relative time>`. When `cwd` is nil or `/`, the subtitle shows the relative time alone. Relative time uses the locale-aware formatter already used by the HUD, never a hand-built Korean or English string.
- Selected row (the Pickle whose card is open): `DS.Colors.overlayCursorBlue` at 14% opacity, corner radius 7.
- Hover row: `DS.Colors.surface3`. Pressed row: `surface4`. Keyboard-highlighted row: 1pt inset `overlayCursorBlue` ring, distinct from the selected fill so both can show at once.

### Row actions

The rail tile's direct gestures are preserved on the row, and everything else moves to the context menu:

| Gesture | Result |
| --- | --- |
| Click | Open the Pickle in the conversation card |
| Drag | Reorder within the list, or pull out to ungroup |
| Press and hold | Archive, reusing the existing 1.5s hold and its progress ring |
| Right-click | Context menu |

The context menu carries every remaining per-Pickle action that lives on the dock tile today: stop, compact, screen-context arm, sticky screen-context arm, move to another group, and ungroup. The folder tile's own context menu carries rename, color, ungroup all, and delete.

## Anchor and clamp

The panel is anchored to the folder tile's frame in the rail coordinate space (`PickyHUDDockRailCoordinateSpace`) and offset from the rail by `PickyHUDDockLayout.panelGap` (10pt) toward the screen interior.

| Dock side | Anchored corner | Opens toward | Clamped axis |
| --- | --- | --- | --- |
| `.left` | Panel top-left to folder top-left | Screen interior, +X | Rail primary axis (Y) |
| `.right` | Panel top-right to folder top-right | Screen interior, -X | Rail primary axis (Y) |
| `.top` | Panel top-left to folder bottom-left | Screen interior, +Y | Rail primary axis (X) |
| `.bottom` | Panel bottom-left to folder top-left | Screen interior, -Y | Rail primary axis (X) |

Terminology: the anchored edge is always the one facing the rail; the open direction is always `towardScreenInterior`; the clamped axis is always the rail's primary axis, which is Y for vertical docks and X for horizontal docks regardless of the panel's own shape.

Clamp rules:

- The panel is clamped along the rail's primary axis to stay inside `screen.visibleFrame` inset by `PickyHUDDockLayout.screenMargin` (8pt).
- Clamping only translates the panel. It never flips the open direction, so the panel always appears on the same side of the rail for a given dock side.
- Clamping never changes the anchored edge's offset from the rail.

The panel closes, rather than re-anchoring, on any event that invalidates the anchor: dock side change, dock size preset change, rail overflow scroll, rail reorder, display reconfiguration, HUD hide, and the owning group being deleted.

## Hosting requirements

The hosting mechanism is deliberately left to implementation, but it must satisfy all of the following. These are acceptance criteria, not suggestions.

- The panel is never clipped by the HUD window frame. This is the constraint that rules out a naive same-window overlay: `NSPanel` size follows SwiftUI intrinsic size (`PickyHUDSizeReporting`, `PickyHUDOverlayManager`), and a `.top`/`.bottom` dock with no open card reserves only about 68pt (`PickyHUDView.horizontalPreviewReserveHeight`). Either the window frame grows to contain the panel, or the panel lives in its own window.
- Opening or closing the panel never moves the rail or the conversation card by even one point.
- The panel's visible rect is reported to ink pass-through (`PickyHUDInkPassThroughPolicy`) so clicks over the panel are not passed through to apps beneath. This follows the existing rule that pass-through is computed from visible chrome rects, not view frames.
- Z-order is rail above panel above card. The panel may cover the card and must never cover the rail; the `panelGap` offset guarantees this geometrically rather than through hit-test exclusions.
- If a separate window is used, it must not steal key window status from the conversation composer, must be suppressed on secure input surfaces exactly like the main HUD, and must be torn down with its owning display's panel.

## Open state

Two independent pieces of state:

- `openedSessionID` — the Pickle whose conversation card is open.
- `openGroupListID` — the group whose list panel is showing.

They are not coupled. Opening a list never closes the card, and opening a card never forces a specific list.

- The list panel is an accordion: at most one group list is open per display. Opening another group's list replaces the current one immediately, with no intermediate closed state.
- Selecting a row swaps the card's session and closes the panel. There is no pinned mode; reopening costs one folder click.
- `PickyHUDDockGroupCollapsePolicy.toggleResult`'s `sessionIDToClose` behavior is removed. Under the old model collapsing a group had to close a card belonging to that group; under this model the card is independent of folder state.
- Clicking the folder that owns the open list closes the list and leaves the card untouched.

### Ownership and multi-display

`openGroupListID` and the keyboard-highlighted row are display-local, living beside the per-display panel state in `PickyHUDOverlayManager`. Opening a list on display A has no effect on display B's rail. Neither value is persisted; both reset when a display's panel is rebuilt.

### Outside-click

- Clicks inside the panel are handled by the panel.
- Clicks on the rail are handled by the rail. A click on a different folder switches the accordion in one click and is not consumed as a mere dismiss.
- Clicks anywhere else inside the same HUD panel, including the conversation card, close the list and are still delivered to their target in the same click. Navigating away must not cost two clicks.
- Clicks in another application or on another display's HUD close the list. Because `PickyHUDPanel.sendEvent` only observes events routed to its own window, this requires a global mouse-down monitor scoped to the panel's lifetime, installed on open and removed on close.

### Live membership changes

The list's visible rows are the group's active members: `memberSessionIDs` filtered by the session universe the HUD already renders. Archived members intentionally remain in `memberSessionIDs` (`PickyDockGrouping.swift:217-230`) but are not rows.

| Event while the list is open | Result |
| --- | --- |
| A non-selected member is archived or removed | Its row disappears; list stays open; highlight index clamps into range |
| The selected member is archived or removed | Row disappears; list stays open; the card follows its existing close/replace behavior; selection styling clears |
| A member is added to this group | Row appears at its projected index; highlight and scroll offset are preserved |
| The last active member disappears | List switches to the empty state rather than closing, so the folder does not vanish under the cursor |
| The group itself is deleted or ungrouped | List closes immediately |
| A member moves to another group | Row disappears from this list; no automatic switch to the other group |

### Empty and single-member groups

- A group with zero active members still occupies one rail slot and still opens. The panel shows an empty state with a single "New Pickle here" action, which reuses the existing group-targeted create flow (`onCreatePickle(targetGroupID:)`).
- A group with one member still renders as a folder, not as a bare tile. Slot identity must not change with member count, or `⌘N` numbering would shift as Pickles complete.

## Folder tile

### States

Two states can apply to different folders at the same time and must be visually distinct:

| State | Treatment |
| --- | --- |
| List panel open for this group | 1pt inset ring in `DS.Colors.overlayCursorBlue`, background at 14% |
| Open card's Pickle belongs to this group | Background at 7%, no ring |
| Both | Ring plus 14% background |

### Mini glyph selection

The folder badge shows at most four cells. Today it takes the first three members in order plus `+N`. That hides the state that matters most when a group is large, so cell selection changes to status priority:

```text
blocked > waiting_for_input > failed > running > queued > completed > cancelled
```

- The three glyph cells show the three highest-priority members; ties break by the group's own member order.
- The fourth cell keeps `+N` whenever the group has more than three members, where `N = memberCount - 3`.
- Ordering is presentation-only. It never reorders `memberSessionIDs`, and the list panel still shows members in stored order.

## Status and unread

Status glyph color comes from the existing `PickyDockPickleStatusVisual.color(_:)` with no new mapping:

| Status | Color |
| --- | --- |
| `queued` | `DS.Colors.accentText` |
| `running` | `DS.Colors.overlayCursorBlue` |
| `waiting_for_input` | `DS.Colors.warning` |
| `blocked` | `DS.Colors.warningText` |
| `completed` | `DS.Colors.success` |
| `failed` | `DS.Colors.destructiveText` |
| `cancelled` | `DS.Colors.textTertiary` |

Rows reuse `PickyDockPickleStatusVisual.statusAssetName(_:)` for the expressive `waiting_for_input`, `blocked`, and `failed` glyphs.

Unread keeps its current two-level meaning and gains no new semantics:

- Per Pickle, unread is a boolean drawn from `PickySessionViewModel.unreadSessionIDs`. A row renders the existing 7pt `DS.Colors.notification` dot. It is never a number.
- Per group, the folder tile keeps its numeric badge, which counts unread member Pickles (`PickyHUDDockRailView.swift:422`), not unread messages.
- Opening a Pickle clears its own unread only, which decrements the folder count by one.
- Unread only covers the attention states `completed`, `failed`, and `waiting_for_input` (`PickySessionViewModel.updateUnreadStateIfNeeded`). `running` and `blocked` members are therefore invisible in the folder count, which is exactly why mini glyph selection is status-prioritized above.

## Keyboard and focus

`⌘1`–`⌘9` are context-dependent, resolved against whichever target set is frontmost on that display:

- No list open: numbers map to rail slots in dock order, counting ungrouped sessions and folders alike. A folder's number opens its list panel rather than a session.
- List open: numbers map to that list's rows, first row is `⌘1`, capped at 9 by the existing `numberShortcutForSessionIndex` rule. Rows past the ninth show no shortcut hint.
- The command-shortcut hint overlay (`PickyHUDCommandShortcutHintPolicy`) follows the same context switch, so rail tile hints are suppressed while a list is open.

Focus contract:

| Condition | `↑` `↓` `return` | `esc` |
| --- | --- | --- |
| List open, no text input focused | List owns them | Closes list |
| List open, composer or terminal focused | Text input keeps them; list is navigable only by mouse or `⌘N` | Closes list first, text input keeps its own Esc behavior only after the list is closed |
| No list open, card open | Existing behavior | Closes card |

- Opening a list highlights the currently open Pickle's row when it belongs to that group, otherwise the first row.
- Arrow navigation clamps at both ends; it does not wrap.
- Moving the highlight scrolls the highlighted row into view.
- The list does not become key window and does not take first responder away from the composer. This preserves the existing rule that Esc is not intercepted while text input is focused (`PickyHUDView.handleKeyboardShortcut`).

Accessibility:

- The folder tile exposes label `<group name>`, value `<member count> Pickles, <unread count> unread`, and actions open list, rename, delete.
- Each row exposes label `<title>`, value `<status>, <cwd leaf>, <relative time>`, trait selected when its card is open, and actions open, archive, stop.
- The full untruncated title is always in the accessibility label even when the visible text is truncated, and is also available as a help tooltip.
- VoiceOver focus order is folder, then rows top to bottom, then back to the rail.

## Drag and drop

### Reordering within a list

- Rows reorder by drag inside the panel, resolving to `onMoveSessionInDock(sessionID, .group(id:memberIndex:))`.
- **Visible index must be translated to a full-list index.** `PickyDockContainer.group(memberIndex:)` indexes the complete `memberSessionIDs` array including archived members that are not rendered as rows, an invariant fixed by `PickyTests/PickyDockGroupingTests.swift:251-301`. A pure helper converts a visible drop position into the insertion index within the full array; the naive identity mapping is wrong whenever a hidden archived member precedes the drop point.
- Row reorder hit-testing is always single-axis on Y, for every dock side. The rail's `dockSide.orientation` axis branch does not apply, because the list is vertical even when the dock is horizontal. Row centers publish through the same measured-center pattern as `PickyDockSlotCenterPreferenceKey`, in the panel's own coordinate space.
- While a row is dragged, remaining rows shift to preview the insertion point.
- When the list scrolls, dragging within 24pt of the panel's top or bottom edge auto-scrolls at 240pt per second.

### Cross-surface drags

| Phase | Condition | Effect on release |
| --- | --- | --- |
| Inside panel | Pointer within panel bounds | Reorder to the previewed index |
| Pulled out | Pointer outside panel bounds for 250ms | Ungroup: insert as a top-level slot at the rail position nearest the pointer |
| Over another folder | Pointer over a folder tile for 400ms | That folder's list opens; the drag continues and can drop into it |
| Over the rail's archive zone | Existing rail pull-out dwell satisfied | Archive |

Ungroup and archive are separate outcomes with separate thresholds and must not be conflated. Today outward pull-out from the rail means archive-on-release (`PickyHUDDockRailView.swift:667-731`); pulling a row out of the list means ungroup, and only the rail's own archive zone archives.

- A drag that ends outside every valid target, or is cancelled with Esc, restores the original order and leaves membership unchanged.
- If the dragged member disappears mid-drag, the drag cancels and no move is emitted.
- The panel stays open for the whole drag and does not close on the drop that ends a reorder.
- Dragging a Pickle from the rail onto a folder tile and dwelling opens that group's list, allowing a drop into a specific row position. Dropping onto the panel background appends to the end of the visible rows, translated to the full-list tail index.
- Group reordering moves to folder-tile drag, replacing the current group-header drag (`handleGroupHeaderDrag*`).

## Model and protocol compatibility

`PickyDockGroup.isCollapsed` is **repurposed, not removed**. It is a wire field on the Picky CLI contract (`PickyDockGroupPayload.collapsed` in `PickyPickleCLIProtocol.swift:16`, filled by `PickyDockGroupCLIPolicy.snapshot`), so deleting it would break CLI consumers and older-build decoding.

- New meaning: `isCollapsed == true` means the group's members are not currently displayed, which under this design is the folder-only resting state. `false` means the group's list panel is open.
- The polarity is compatible with the legacy meaning, so a persisted layout decodes without migration.
- On load, the accordion invariant is enforced by normalization: if more than one group has `isCollapsed == false`, the first in dock order stays open and the rest are set to `true`.
- Because list-open state is display-local and transient, the persisted value is written as `true` for every group on save. The field survives for contract compatibility; it is not a durable user setting anymore.
- `docs/user-manual.md:324-326` documents per-display collapse as a user-facing feature and must be rewritten in the same change.
- The per-display `collapsedOverrides` dictionary is repurposed the same way, becoming the display-local list-open state, or replaced by `openGroupListID` if a single optional id proves sufficient. Whichever is chosen, `PickyDockGrouping.swift:450,472`, `PickyHUDDockRailView.swift:162`, `PickyHUDView.swift:94`, and `PickyHUDOverlayManager.swift:290` all need updating.

## Implementation surfaces

| Concern | Location |
| --- | --- |
| Anchor, clamp, panel height, visible row count | New `PickyHUDDockGroupListPolicy` (pure) |
| Visible-row index to full-member index translation | New pure helper beside `PickyDockGrouping` |
| Open-state accordion and card independence | `PickyHUDDockGroupCollapsePolicy` replaced by `PickyHUDDockGroupListOpenPolicy` |
| Shortcut context resolution | `PickyHUDDockInteractionPolicy`, `PickyHUDKeyboardShortcutPolicy`, `PickyHUDCommandShortcutHintPolicy` |
| Top-level slot identity, header render item removal, drop hit-test | `PickyDockGrouping` (`PickyDockSlot`, `PickyDockRenderItem.groupHeader`, projector drop hit-test at `:655`) |
| Rail content length without header extra | `PickyHUDDockRailPolicy`, `PickyHUDDockLayout` |
| Rail rendering without headers or member drawers | `PickyHUDDockRailView`, `PickyHUDDockGroupViews` |
| Mini glyph priority selection | `PickyHUDDockCollapsedGroupBadge` |
| Panel rendering | New `PickyHUDDockGroupListView` |
| Panel hosting, window sizing, ink chrome | `PickyHUDOverlayManager`, `PickyHUDPlacement`, `PickyHUDSizeReporting`, `PickyHUDView`, `PickyHUDInkPassThroughPolicy` |
| CLI contract compatibility | `PickyDockGroupCLIPolicy`, `PickyPickleCLIProtocol`, `PickyAgentProtocol` |
| User-facing docs | `docs/user-manual.md` |

## Test plan

Pure policy tests come first, per `docs/refactoring-principles.md`.

New tests:

- Anchor math for all four dock sides, including the mirrored `.right` case.
- Clamp keeps the panel inside the visible frame and never flips direction.
- Panel height saturates at 8 rows for member counts of 8, 9, and 40.
- Opening group B's list while group A's list is open leaves `openedSessionID` unchanged.
- Selecting a row switches the card and closes the panel.
- `esc` closes the list first and the card second; with text input focused the list still closes first.
- `⌘3` opens the third rail slot's list when no list is open, and the third row when one is.
- Folder unread count equals the number of unread member Pickles and decrements by one when a member is opened.
- Mini glyph selection puts `blocked` and `running` members ahead of `completed` ones and never mutates `memberSessionIDs`.
- Visible-row reorder produces the same stored order as the pre-plan rail member drag, including groups whose hidden archived members precede the drop point.
- A row dragged out of the panel ungroups rather than archives; the rail archive zone still archives.
- Live mutation cases from the table above, one test each.
- `isCollapsed` normalization keeps exactly one open group when a legacy layout has several expanded.

Existing suites to migrate:

| Suite | Action |
| --- | --- |
| `PickyTests/PickyHUDDockGroupCollapsePolicyTests.swift:12-125` | Rewrite against `PickyHUDDockGroupListOpenPolicy`; the `sessionIDToClose` cases are deleted with the behavior |
| `PickyTests/PickyDockGroupingTests.swift:187-317` | Update projection expectations for one-slot groups; keep the hidden-member ordering cases as-is |
| `PickyTests/PickyHUDDockRailPolicyTests.swift:14-68` | Update header and empty-tile expectations to the header-free model |
| `PickyTests/PickyTests.swift:269-274` | Update legacy rail geometry expectations |
| `PickyTests/PickySessionDockLayoutControllerTests.swift:128-171` | Must keep passing unchanged; this is the hidden archived member ordering guard |

Integration checks that cannot be expressed as pure tests:

- Panel is not clipped with a `.top` dock and no open card.
- Ink pass-through does not leak clicks under the open panel.
- Composer focus survives opening and closing a list.
- HUD open and switch signposts do not regress, compared per `docs/perf-profiling.md`.

## Out of scope

- Showing the Pi branch instead of the cwd leaf in row subtitles. The subtitle stays `<cwd leaf> · <relative time>`; a worktree-aware variant is a separate change.
- Any change to how groups are created, named, or colored.
- Any change to the conversation card's own layout.
