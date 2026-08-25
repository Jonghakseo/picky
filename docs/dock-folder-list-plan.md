# Dock Folder List Plan

_Status: design confirmed from mockup; implementation not started_

_Last updated: 2026-08-25_

## Summary

The dock rail currently renders every member of an expanded group as its own 54pt tile, so rail length grows linearly with Pickle count. With 14 Pickles across three groups the sessions region alone measures about 951pt, which overflows the screen budget on a laptop display.

This plan replaces in-rail group expansion with a two-layer model:

1. **The rail only ever shows one slot per group.** Rail length scales with group count, not Pickle count.
2. **A group's members open as a floating list panel** anchored to the folder tile, layered above the conversation card.

The core invariant is:

> Rail length is a function of top-level entry count only. Member visibility is delegated to a transient overlay that never changes the HUD's layout footprint.

## Design Decision Card

- **User goal:** keep every Pickle reachable without the dock growing past the screen, and switch between Pickles in different groups without closing the one currently open.
- **Target surface/component:** dock rail folder tile plus a new floating list panel; the conversation card is untouched.
- **Rejected alternative:** collapsing the member list into a strip inside the conversation card header. It couples group navigation to card layout and cannot show a group other than the open Pickle's own group.
- **Rejected alternative:** an N x N icon grid. Six-character compacted labels (`PickyHUDDockLabelPolicy.compactLabel`) cannot distinguish Pickles whose titles share a prefix.

## Layout model

### Rail

Top-level entries are ungrouped sessions and groups. A group always occupies exactly one slot, rendered as the existing folder badge (`PickyHUDDockCollapsedGroupBadge`). Group headers, the expanded member drawer, and the expand/collapse chevron are removed from the rail.

Rail length for a vertical dock:

```text
topPadding + n * sessionTileHeight + (n - 1) * sessionSpacing + addSlot + bottomPadding
```

where `n = ungroupedSessionCount + groupCount`.

| Scenario | Today | With this plan |
| --- | --- | --- |
| 3 groups, 14 members, 0 ungrouped | ~951pt | ~189pt |
| 3 groups, 14 members, 2 ungrouped | ~1077pt | ~315pt |

### List panel

New constants, all in points at the medium preset (`scale = 1.0`) and scaled by `PickyHUDDockMetrics.scaled` for other presets:

| Constant | Value | Note |
| --- | --- | --- |
| `groupListPanelWidth` | 260 | Fixed; does not vary by group or title length |
| `groupListRowHeight` | 38 | Glyph 20 + two text lines |
| `groupListMaxVisibleRows` | 8 | Beyond this the list scrolls internally |

Derived panel height:

```text
padding(8) * 2 + header(22) + min(memberCount, 8) * 38
```

Maximum height is therefore 342pt regardless of member count. Panel padding is 8, corner radius reuses `metrics.iconCornerRadius` (12), and the border is 0.5pt `DS.Colors.borderSubtle`.

### Row anatomy

```text
[status glyph 20] [title 13pt / subtitle 11pt] [unread dot 7pt] [⌘N 11pt]
```

- Horizontal padding 10, inter-element gap 8.
- Title: 13pt, `DS.Colors.textPrimary`, single line, tail truncation. The full title is exposed as the row's accessibility label and help tooltip. The row uses the untruncated `session.title`, not `PickyHUDDockLabelPolicy.compactLabel`, which stays in use for the rail tile only.
- Subtitle: 11pt, `DS.Colors.textTertiary`, `<cwd leaf> · <relative time>`.
- Selected row (the Pickle whose card is open): `DS.Colors.overlayCursorBlue` at 14% opacity, corner radius 7.
- Hover row: `DS.Colors.surface3`.

## Anchor and clamp

The panel is anchored to the folder tile's frame in the rail coordinate space (`PickyHUDDockRailCoordinateSpace`) and offset outward from the rail by `PickyHUDDockLayout.panelGap` (10pt).

| Dock side | Anchored corner | Opens toward | Clamp axis |
| --- | --- | --- | --- |
| `.left` | Panel top-left to folder top-left | Right | Y |
| `.right` | Panel top-right to folder top-right | Left | Y |
| `.top` | Panel top-left to folder bottom-left | Down | X |
| `.bottom` | Panel bottom-left to folder top-left | Up | X |

Clamp rules:

- The panel is clamped along its long axis to stay inside `screen.visibleFrame` inset by `PickyHUDDockLayout.screenMargin` (8pt).
- Clamping only translates the panel. It never flips the open direction, so the panel always appears on the same side of the rail for a given dock side.
- When clamping moves the panel away from its anchor, the anchored edge stays flush with the rail; only the long-axis offset changes.
- The anchor is recomputed when the dock side changes, the dock size preset changes, the rail reorders, or the display changes. A panel open across any of these events closes.

## Layering

Z-order within the HUD panel, outermost last:

1. Conversation card
2. Dock rail
3. Group list panel

The panel may cover the conversation card. It must never cover the rail, which is guaranteed by the `panelGap` outward offset rather than by hit-test exclusions.

## Concurrency of open state

Two independent pieces of state:

- `openedSessionID` — the Pickle whose conversation card is open.
- `openGroupListID` — the group whose list panel is showing.

They are not coupled. Opening a list never closes the card, and opening a card never forces a specific list.

- The list panel is an accordion: at most one group list is open at a time. Opening another group's list replaces the current one immediately, with no intermediate closed state.
- Selecting a row swaps the card's session. By default the panel then closes. When the panel's pin toggle is on, the panel stays open for consecutive switching. The pin is panel-scoped session state, not persisted.
- `PickyHUDDockGroupCollapsePolicy.toggleResult`'s `sessionIDToClose` behavior is removed. Under the old model collapsing a group had to close a card belonging to that group; under this model the card is independent of folder state.
- Clicking the same folder that owns the open list closes the list and leaves the card untouched.
- Clicking outside the panel closes the list only.

### Folder tile states

Two states can apply to different folders at the same time and must be visually distinct:

| State | Treatment |
| --- | --- |
| List panel open for this group | 1pt inset ring in `DS.Colors.overlayCursorBlue`, background at 14% |
| Open card's Pickle belongs to this group | Background at 7%, no ring |
| Both | Ring plus 14% background |

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
- Per group, the folder tile keeps its numeric badge, which counts unread member Pickles (`PickyHUDDockRailView.swift:421`), not unread messages.
- Opening a Pickle clears its own unread only, which decrements the folder count by one.

## Keyboard

`⌘1`–`⌘9` are context-dependent, resolved against whichever target set is frontmost:

- No list open: numbers map to rail slots in dock order, counting ungrouped sessions and folders alike. A folder's number opens its list panel rather than a session. This extends `PickyDockSlot.visibleIndex` to treat a group as one slot instead of borrowing its top member's index.
- List open: numbers map to that list's rows, first row is `⌘1`, capped at 9 by the existing `numberShortcutForSessionIndex` rule. Rows past the ninth show no shortcut hint.
- `↑` / `↓` move the list's highlighted row; `return` opens the highlighted row.
- `esc` is two-stage: the first press closes the list and leaves the card open, the second closes the card.
- The command-shortcut hint overlay (`PickyHUDCommandShortcutHintPolicy`) reflects the same context switch, so hints on rail tiles are suppressed while a list is open.

## Drag and drop

- Rows reorder by drag inside the panel. A drag resolves to `onMoveSessionInDock(sessionID, .group(id:memberIndex:))` with the destination row index, reusing the existing move API unchanged.
- Row reorder hit-testing is always single-axis on Y, for every dock side. The rail's `dockSide.orientation` axis branch does not apply, because the list is vertical even when the dock is horizontal. Row centers publish through the same measured-center pattern as `PickyDockSlotCenterPreferenceKey`, in the panel's own coordinate space.
- While a row is dragged, remaining rows shift to preview the insertion point, matching the rail's existing reorder preview behavior.
- When the list scrolls (more than 8 members), dragging within 24pt of the panel's top or bottom edge auto-scrolls at a fixed rate so rows outside the viewport remain reachable.
- Dragging a Pickle onto a folder tile and dwelling opens that group's list, allowing a drop into a specific row position.
- Dropping onto a row inserts at that index; dropping onto the panel background appends.
- Dragging a row out of the panel removes the Pickle from the group and drops it as an ungrouped rail slot. The pull-out threshold reuses the rail's dwell rule so a brief wobble never ungroups.
- Group reordering moves to folder-tile drag, replacing the current group-header drag (`handleGroupHeaderDrag*`).
- The panel stays open for the whole drag regardless of the pin toggle, and does not close on the drop that ends a reorder.

## Interaction with existing dock affordances

- The dock icon hover preview (`miniPreviewOffset`, `previewCardWidth` 238) is suppressed while a list panel is open, since the panel occupies the same region and carries richer information.
- The folder context menu (rename, color, ungroup, delete) moves from the removed group header onto the folder tile.
- `PickyDockGroup.isCollapsed` and the per-display `collapsedOverrides` become unused for rendering. They are removed rather than retained as dead state; a persisted `isCollapsed` value is ignored on load.
- `PickyHUDDockOverflowPolicy` stays as the safety net for many ungrouped Pickles or many groups.

## Implementation surfaces

| Concern | Location |
| --- | --- |
| Anchor, clamp, panel height, visible row count | New `PickyHUDDockGroupListPolicy` (pure) |
| Open-state accordion and card independence | `PickyHUDDockGroupCollapsePolicy` replaced by `PickyHUDDockGroupListOpenPolicy` |
| Shortcut context resolution | `PickyHUDDockInteractionPolicy`, `PickyHUDKeyboardShortcutPolicy` |
| Slot projection with one slot per group | `PickyDockProjector`, `PickyDockSlot` |
| Rail rendering without headers or member drawers | `PickyHUDDockRailView`, `PickyHUDDockGroupViews` |
| Panel rendering | New `PickyHUDDockGroupListView` |

## Test plan

Pure policy tests come first, per `docs/refactoring-principles.md`:

- Anchor math for all four dock sides, including the mirrored `.right` case.
- Clamp keeps the panel inside the visible frame and never flips direction.
- Panel height saturates at 8 rows for member counts of 8, 9, and 40.
- Opening group B's list while group A's list is open leaves `openedSessionID` unchanged.
- Selecting a row switches the card and, with pin off, closes the panel; with pin on, keeps it.
- `esc` closes the list first and the card second.
- `⌘3` opens the third rail slot's list when no list is open, and the third row when one is.
- Reordering rows within a list produces the same `memberSessionIDs` order as the equivalent pre-plan rail member drag, for both vertical and horizontal dock sides.
- A row dragged out of the panel lands as an ungrouped top-level slot and is removed from `memberSessionIDs`.
- Folder unread count equals the number of unread member Pickles and decrements by one when a member is opened.

## Open questions

- Whether the pin toggle should persist per group or reset on every open. Current decision: reset.
- Whether row subtitles should show the Pi branch instead of the cwd leaf when a worktree is detected.
