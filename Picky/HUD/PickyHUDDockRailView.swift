import AppKit
import Combine
import SwiftUI

enum PickyHUDArchiveHoldPolicy {
    static let duration: TimeInterval = 1.2
    static let feedbackStartDelay: TimeInterval = 0.2
    static let feedbackStartDelayNanoseconds: UInt64 = 200_000_000
    static let maximumDistance: CGFloat = 10
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73

    static var feedbackAnimationDuration: TimeInterval {
        max(0, duration - feedbackStartDelay)
    }
}

extension PickySessionListViewModel.SessionCard {
    var canRequestDockCompaction: Bool {
        guard !isCompacting else { return false }
        switch status {
        case .completed, .blocked, .failed, .cancelled:
            return true
        case .queued, .running, .waiting_for_input:
            return false
        }
    }
}

/// Owns an in-flight Pickle reorder drag at the dock-rail level. The per-icon
/// click host only detects the reorder threshold and hands off here; from then
/// on an app-level `NSEvent` monitor drives the drag to completion. This is
/// essential because the live drop preview reparents the dragged icon across
/// group boundaries (top-level <-> group member), which tears down and
/// recreates its per-icon NSView. A rail-level monitor is immune to that, so
/// the drag survives crossing into/out of groups and only commits on release.
final class PickyDockReorderDragController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dragging(sessionID: String, translation: CGSize)
        case ended(sessionID: String, translation: CGSize)
    }

    @Published private(set) var phase: Phase = .idle

    private var monitor: Any?
    private var anchorScreenPoint: NSPoint = .zero
    private var sessionID: String?

    /// Begin tracking a reorder for `sessionID`. `anchorScreenPoint` is the
    /// mouse-down location in screen space so deltas stay continuous with the
    /// threshold the icon already crossed.
    func begin(sessionID: String, anchorScreenPoint: NSPoint) {
        if self.sessionID != nil { cancelMonitor() }
        self.sessionID = sessionID
        self.anchorScreenPoint = anchorScreenPoint
        phase = .dragging(sessionID: sessionID, translation: currentTranslation())
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let sessionID = self.sessionID else { return event }
            let translation = self.currentTranslation()
            switch event.type {
            case .leftMouseUp:
                self.phase = .ended(sessionID: sessionID, translation: translation)
                self.cancelMonitor()
                self.sessionID = nil
                return nil
            default:
                self.phase = .dragging(sessionID: sessionID, translation: translation)
                return nil
            }
        }
    }

    /// Acknowledge that the SwiftUI side consumed the terminal phase and return
    /// to idle so the next drag starts clean.
    func reset() {
        phase = .idle
    }

    /// Screen-space delta from the mouse-down anchor, flipped to SwiftUI
    /// top-down y. Screen-space keeps it stable even as the icon's NSView is
    /// recreated mid-drag.
    private func currentTranslation() -> CGSize {
        let current = NSEvent.mouseLocation
        return CGSize(width: current.x - anchorScreenPoint.x, height: -(current.y - anchorScreenPoint.y))
    }

    private func cancelMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { cancelMonitor() }
}

struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    /// Every live session card, including those hidden inside collapsed
    /// groups. `sessions` only carries the dock-visible slots, so the
    /// collapsed-group folder grid resolves its members from here.
    let allSessions: [PickySessionListViewModel.SessionCard]
    /// Projection of the *persisted* layout. Read through the `projection`
    /// computed property below, which overlays the in-flight drag preview
    /// so callers (render + hit-test) transparently see the prospective
    /// drop while a Pickle is being dragged.
    let baseProjection: PickyDockProjection
    /// Persisted dock layout. The rail uses it to translate visible
    /// top-level entry indices back to `entries` indices when committing
    /// group-header drag reorders.
    let layout: PickyDockLayout
    /// Per-display group collapse overrides. The drag preview projection must
    /// apply these too, or expanded-on-this-display groups would render with
    /// their model (default) collapse state mid-drag and appear to collapse.
    let collapsedGroupOverrides: [String: Bool]
    let activeSessionID: String?
    let openedSessionID: String?
    let previewSessionID: String?
    let screenContextTargetSessionID: String?
    let dockSide: PickyHUDDockSide
    let isCommandShortcutHintVisible: Bool
    let pendingDoneFlashSessionIDs: Set<String>
    let unreadSessionIDs: Set<String>
    let metrics: PickyHUDDockMetrics
    let onHoverSession: (String) -> Void
    let onOpenSession: (String) -> Void
    let onToggleScreenContextTarget: (String) -> Void
    let onCompactSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onStopSession: (String) -> Void
    let onCreatePickle: () -> Void
    let pinnedPickleCwds: [String]
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (String) -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    let onPinPickleFolder: (String) -> Void
    let onUnpinPickleFolder: (String) -> Void
    /// Create a new group with a name and (optionally) an initial set of
    /// member sessions. Returns the new group's id so callers can chain
    /// follow-up actions (e.g. focus the new group), though the dock
    /// rail itself ignores the return value.
    let onCreateDockGroup: (_ name: String, _ memberIDs: [String]) -> String
    let onRenameDockGroup: (_ id: String, _ name: String) -> Void
    let onSetDockGroupColor: (_ id: String, _ color: PickyDockGroupColor) -> Void
    let onToggleDockGroupCollapsed: (_ id: String) -> Void
    let onRemoveDockGroup: (_ id: String, _ keepMembers: Bool) -> Void
    /// Persist a session move into a specific dock container/position.
    let onMoveSessionInDock: (_ sessionID: String, _ destination: PickyDockContainer) -> Void
    /// Reorder a group as a whole within the top-level layout.
    let onMoveDockGroup: (_ groupID: String, _ toTopLevelIndex: Int) -> Void
    let onDockHoverChanged: (Bool) -> Void
    let onAddSlotExpandedChanged: (Bool) -> Void
    let onDoneFlashConsumed: (String) -> Void
    let onDockHandleDragChanged: (CGPoint) -> Void
    let onDockHandleDragEnded: () -> Void
    let onDockHandleDoubleClick: () -> Void

    @State private var isAddSlotExpanded = false
    @State private var isRecentPickleFolderPickerPresented = false
    @State private var isAddSlotMenuPresented = false
    @State private var isHandleHovered = false
    @State private var isHandleDragging = false
    @State private var draggingSessionID: String?
    /// Raw cursor translation (in points) since the drag began. Positions the
    /// floating dragged icon overlay; the in-flow slot is rendered as an
    /// invisible placeholder so the real icon never reparents (no flicker).
    @State private var dragTranslation: CGSize = .zero
    /// Frozen geometry the drop decision is computed against, captured once at
    /// drag start from the persisted (pre-preview) layout. The drop target is
    /// hit-tested ONLY against this snapshot — never against the live,
    /// self-reflowing preview centers — which breaks the feedback loop where
    /// inserting the placeholder shifted measured centers and flipped the
    /// decision back and forth (the group-boundary oscillation/flicker).
    @State private var dragReferenceSlots: [PickyDockSlot] = []
    @State private var dragReferenceCenters: [String: CGFloat] = [:]
    /// Destination the dragged icon would land in if released *right now*.
    /// Drives the live preview projection so siblings animate to make room
    /// at the landing spot, but the actual `onMoveSessionInDock` commit is
    /// deferred to release — the Pickle's group assignment only changes once
    /// the user lets go, never while the cursor merely crosses a boundary.
    @State private var pendingDropContainer: PickyDockContainer?
    /// Rail-level reorder drag tracker. Survives the dragged icon's NSView
    /// being recreated when the preview reparents it across a group boundary.
    @StateObject private var reorderController = PickyDockReorderDragController()
    /// Session whose reorder drag is currently being driven by
    /// `reorderController`, so the phase handler knows when to fire `begin`.
    @State private var activeReorderSessionID: String?
    /// Primary-axis center the dragged icon occupied at pickup time, in the
    /// dock rail's named coordinate space. Combined with the gesture's
    /// `translation` it gives the current cursor axis position without
    /// needing per-frame global coordinate math.
    @State private var dragStartCenter: CGFloat = 0
    /// Group id whose inline rename input should grab keyboard focus on next
    /// appearance. Set right after `onCreateDockGroup()` so the user can type
    /// a name immediately; cleared on commit/cancel.
    @State private var pendingRenameGroupID: String?
    /// Per-session primary-axis centers measured via `GeometryReader` in the
    /// `PickyHUDDockRailCoordinateSpace`. Updated on every layout pass via
    /// `PickyDockSlotCenterPreferenceKey`. Drives precise drop hit-testing
    /// for icon drags so reorders survive non-uniform group-header chrome.
    @State private var slotCenters: [String: CGFloat] = [:]
    /// Per-top-entry primary-axis centers (one per ungrouped session and
    /// one per group container). Drives the group-header drag's drop
    /// hit-test against other top-level entries.
    @State private var topEntryCenters: [String: CGFloat] = [:]
    /// Currently-dragged group id (header drag). Mutually exclusive with
    /// `draggingSessionID`.
    @State private var draggingGroupID: String?
    @State private var groupDragOffset: CGSize = .zero
    @State private var groupDragStartCenter: CGFloat = 0
    @State private var groupDragStartLayoutIndex: Int = 0
    @State private var groupDragCurrentLayoutIndex: Int = 0

    /// macOS Dock-style pull-out. While dragging an icon or group clearly
    /// away from the dock on the cross axis, we arm a destructive release:
    /// a Pickle archives, a group is removed. Sessions require a short dwell
    /// outside (so a quick wobble never archives); groups arm immediately.
    @State private var sessionPullOutArmed = false
    @State private var groupPullOutArmed = false
    /// Pending dwell timer that arms `sessionPullOutArmed`. Cancelled the
    /// moment the cursor returns inside the pull-out threshold or the drag
    /// ends, so a stale timer can never arm after the fact.
    @State private var sessionPullOutDwellWork: DispatchWorkItem?

    /// Live render/hit-test projection. While a Pickle is being dragged, this
    /// reflects the *prospective* drop (`pendingDropContainer`) so siblings
    /// animate to make room at the landing spot — without persisting the
    /// move. The actual commit happens on release. When not dragging (or the
    /// prospective drop equals the current home) it is the persisted
    /// projection unchanged.
    private var projection: PickyDockProjection {
        guard let draggingSessionID,
              let pendingDropContainer,
              layout.container(forSessionID: draggingSessionID) != pendingDropContainer else {
            return baseProjection
        }
        var preview = layout
        preview.move(session: draggingSessionID, to: pendingDropContainer)
        return PickyDockProjector.project(
            layout: preview,
            visibleSessionIDs: baseProjection.slots.map(\.sessionID),
            collapsedOverrides: collapsedGroupOverrides
        )
    }

    var body: some View {
        let _ = PickyPerf.event("dock_rail_body")
        Group {
            if dockSide.orientation == .horizontal {
                HStack(spacing: 2) {
                    dockAnchorHandle
                    sessionsAndAddSlot
                }
                // Symmetric leading/trailing in horizontal so the dock doesn't
                // look lopsided. Vertical's larger `bottomPadding` exists to
                // give the `+` button breathing room below the dash; in
                // horizontal the equivalent breathing room comes from the
                // empty panel area to the right of the dock, not from internal
                // padding.
                .padding(.horizontal, metrics.topPadding)
                .padding(.vertical, metrics.horizontalPadding)
                .frame(width: railHeight, height: horizontalRailCrossSize, alignment: .center)
            } else {
                // The handle is the first child INSIDE the dock capsule (after a small top
                // padding) so the dock body itself acts as the hit target. The capsule
                // background is opaque, which sidesteps SwiftUI's transparent-view hit-
                // testing quirks: clicks anywhere in the handle's row hit the NSView
                // backing the handle, not the empty space outside an external pill.
                VStack(spacing: 2) {
                    dockAnchorHandle
                    sessionsAndAddSlot
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, metrics.topPadding)
                .padding(.bottom, metrics.bottomPadding)
                .frame(width: metrics.railWidth, height: railHeight, alignment: .top)
            }
        }
        .background(dockGlassBackground)
        .coordinateSpace(name: PickyHUDDockRailCoordinateSpace)
        .overlay { draggedFloatingIconOverlay }
        .onPreferenceChange(PickyDockSlotCenterPreferenceKey.self) { centers in
            slotCenters = centers
        }
        .onPreferenceChange(PickyDockTopEntryCenterPreferenceKey.self) { centers in
            topEntryCenters = centers
        }
        .onHover(perform: onDockHoverChanged)
        .onChange(of: isRecentPickleFolderPickerPresented) { _, isPresented in
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = isPresented
            }
            onAddSlotExpandedChanged(isPresented)
        }
        // Drive the reorder drag from the rail-level controller. Running the
        // handlers here (rather than from the per-icon NSView) means they keep
        // firing with fresh layout/slot state even after the dragged icon's
        // view is recreated by a cross-group preview reparent.
        .onChange(of: reorderController.phase) { _, phase in
            handleReorderPhase(phase)
        }
    }

    private func handleReorderPhase(_ phase: PickyDockReorderDragController.Phase) {
        switch phase {
        case .idle:
            break
        case .dragging(let sessionID, let translation):
            if activeReorderSessionID != sessionID {
                activeReorderSessionID = sessionID
                handleReorderBegin(sessionID: sessionID)
            }
            handleReorderChanged(sessionID: sessionID, translation: translation)
        case .ended(let sessionID, let translation):
            if activeReorderSessionID == sessionID {
                handleReorderEnded(sessionID: sessionID, translation: translation)
            }
            activeReorderSessionID = nil
            reorderController.reset()
        }
    }

    /// Number of group header chips rendered in this projection. Every group
    /// renders one header chip regardless of collapse state (an expanded group
    /// emits a `.groupHeader` item; a collapsed group emits `.collapsedGroup`
    /// but still renders the same chip above its badge). The rail height must
    /// account for ALL of them or the bottom `+` slot overflows the capsule
    /// when groups are collapsed.
    private var groupHeaderCount: Int {
        projection.items.reduce(0) { count, item in
            switch item {
            case .groupHeader, .collapsedGroup: return count + 1
            default: return count
            }
        }
    }

    /// Number of empty-group drop tiles rendered (one per expanded group
    /// with zero projected members, plus one per collapsed group with no
    /// projected top member). Each tile occupies a full session tile slot
    /// below its header but does NOT appear in `projection.slots`, so the
    /// rail height must account for them explicitly or the dashed drop slot
    /// overflows the capsule.
    private var emptyGroupDropTileCount: Int {
        var count = 0
        for item in projection.items {
            switch item {
            case .groupHeader(let g):
                if !projection.slots.contains(where: { slot in
                    if case .group(let id, _) = slot.container { return id == g.id }
                    return false
                }) {
                    count += 1
                }
            case .collapsedGroup(_, let topMember):
                if topMember == nil { count += 1 }
            default:
                break
            }
        }
        return count
    }

    private var railHeight: CGFloat {
        if dockSide.orientation == .horizontal {
            // Horizontal: group headers stack ABOVE their drawer (cross axis),
            // so they do not add to long-axis length. Empty-group drop tiles
            // are full-sized tiles inside the drawer and do add one tile
            // worth of long-axis length each (`sessionTileWidth`, not
            // `sessionTileHeight`).
            let emptyDropExtraLength = CGFloat(emptyGroupDropTileCount) * (metrics.sessionTileWidth + metrics.sessionSpacing)
            return PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: sessions.count,
                isAddSlotExpanded: isAddSlotExpanded,
                metrics: metrics
            ) + emptyDropExtraLength
        }
        let headersExtraLength = PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: groupHeaderCount)
        let emptyDropExtraLength = CGFloat(emptyGroupDropTileCount) * (metrics.sessionTileHeight + metrics.sessionSpacing)
        let base = PickyHUDDockLayout.dockRailHeight(
            sessionCount: sessions.count,
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        )
        return base + headersExtraLength + emptyDropExtraLength
    }

    /// Cross-axis (height) of the dock rail in horizontal mode. Grows by the
    /// group header chip height when any dock group is rendered so the title
    /// sits inside the capsule above its members.
    private var horizontalRailCrossSize: CGFloat {
        PickyHUDDockLayout.horizontalDockRailCrossSize(
            hasGroupHeaders: groupHeaderCount > 0,
            metrics: metrics
        )
    }

    @ViewBuilder
    private var sessionsAndAddSlot: some View {
        if projection.items.isEmpty && projection.slots.isEmpty {
            // Empty state still lives inside the capsule so the handle has somewhere
            // to anchor visually. Use the full-size add button (not the collapsible
            // one) since there are no sessions to keep it compact for.
            addAgentSlotButton
        } else {
            if dockSide.orientation == .horizontal {
                // Bottom-align so ungrouped Pickle icons (`sessionTileHeight`)
                // share the same baseline as the drawer of a grouped block
                // (which sits below its title chip). Without this they
                // floated to the rail's vertical center and looked offset
                // from the grouped Pickles whenever any dock group existed.
                // The collapsible `+` slot is *not* a Pickle and stays
                // vertically centered — flexing its height to fill the
                // wrapper lets the button center itself inside that frame
                // while the body row keeps its bottom-aligned baseline.
                HStack(alignment: .bottom, spacing: 2) {
                    HStack(alignment: .bottom, spacing: metrics.sessionSpacing) {
                        dockBodyItems
                    }
                    collapsibleAddAgentSlot
                        .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: metrics.sessionSpacing) {
                    dockBodyItems
                }
                collapsibleAddAgentSlot
                    .padding(.top, metrics.addSlotTopPadding)
            }
        }
    }

    /// Renders the projection (ungrouped icons + group headers + group
    /// members + collapsed groups) in dock order. Group rendering wraps the
    /// member icons (or the stacked badge) in `PickyHUDDockGroupContainer`
    /// so the 2px accent bar and header chip stay visually unified.
    @ViewBuilder
    private var dockBodyItems: some View {
        // Group the projection items by group so we can render each group as
        // a single visual block with its accent bar. Ungrouped sessions emit
        // standalone slots that pass straight through.
        let renderUnits = Self.buildRenderUnits(from: projection.items)
        ForEach(renderUnits) { unit in
            renderUnitView(unit)
        }
    }

    @ViewBuilder
    private func renderUnitView(_ unit: PickyHUDDockRenderUnit) -> some View {
        switch unit.kind {
        case .session(let id):
            if let card = sessions.first(where: { $0.id == id }),
               let slot = projection.slots.first(where: { $0.sessionID == id }) {
                iconView(for: card, slot: slot)
                    .publishDockTopEntryCenter(
                        entryID: "session:\(id)",
                        dockSide: dockSide
                    )
            }
        case .group(let group, let members):
            PickyHUDDockGroupContainer(
                group: group,
                dockSide: dockSide,
                metrics: metrics,
                drawerSpan: groupDrawerSpan(group: group, members: members),
                isRenamingOnAppear: pendingRenameGroupID == group.id,
                onRenameCommit: { newName in
                    onRenameDockGroup(group.id, newName)
                    if pendingRenameGroupID == group.id { pendingRenameGroupID = nil }
                },
                onRenameCancel: {
                    if pendingRenameGroupID == group.id { pendingRenameGroupID = nil }
                },
                onToggleCollapsed: { onToggleDockGroupCollapsed(group.id) },
                onSetColor: { onSetDockGroupColor(group.id, $0) },
                onUngroup: { onRemoveDockGroup(group.id, true) },
                onDeleteWithArchive: { onRemoveDockGroup(group.id, false) },
                onHeaderDragBegin: { handleGroupHeaderDragBegin(groupID: group.id) },
                onHeaderDragChanged: { handleGroupHeaderDragChanged(groupID: group.id, translation: $0) },
                onHeaderDragEnded: { handleGroupHeaderDragEnded(groupID: group.id, translation: $0) },
                onHeaderDragCanceled: { handleGroupHeaderDragCanceled() },
                isHeaderDragging: draggingGroupID == group.id,
                headerDragOffset: draggingGroupID == group.id ? groupDragOffset : .zero,
                pullOutBadgeText: (draggingGroupID == group.id && groupPullOutArmed)
                    ? L10n.t("dock.drag.remove.label")
                    : nil
            ) {
                if group.isCollapsed {
                    // The collapsed render unit only carries the top member, so
                    // resolve the full visible member set from the group itself
                    // to fill the app-drawer folder grid.
                    let memberCards = group.memberSessionIDs.compactMap { id in
                        allSessions.first(where: { $0.id == id })
                    }
                    let unreadCount = memberCards.reduce(0) { count, card in
                        unreadSessionIDs.contains(card.id) ? count + 1 : count
                    }
                    if let topID = memberCards.first?.id {
                        PickyHUDDockCollapsedGroupBadge(
                            members: memberCards,
                            unreadCount: unreadCount,
                            tint: group.color.accent,
                            metrics: metrics,
                            shortcutNumber: projection.slots
                                .first(where: { $0.sessionID == topID })
                                .flatMap { PickyHUDDockLayout.numberShortcutForSessionIndex($0.visibleIndex) },
                            isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                            onTap: { onToggleDockGroupCollapsed(group.id) }
                        )
                        .publishDockSlotCenter(sessionID: topID, dockSide: dockSide)
                    } else {
                        // Group has no visible members — render a small
                        // empty drop target so the user can still drag
                        // pickles in or expand/rename via the header menu.
                        PickyHUDDockGroupEmptySlot(color: group.color, metrics: metrics)
                            .publishDockSlotCenter(
                                sessionID: Self.emptyGroupDropTargetID(groupID: group.id),
                                dockSide: dockSide
                            )
                    }
                } else if members.isEmpty {
                    PickyHUDDockGroupEmptySlot(color: group.color, metrics: metrics)
                        .publishDockSlotCenter(
                            sessionID: Self.emptyGroupDropTargetID(groupID: group.id),
                            dockSide: dockSide
                        )
                } else {
                    // Expanded group: members live inside the same app-drawer
                    // surface as the collapsed folder, extended along the dock
                    // axis so the grouping stays visible while expanded.
                    Group {
                        if dockSide.orientation == .horizontal {
                            HStack(spacing: metrics.sessionSpacing) {
                                ForEach(members, id: \.sessionID) { member in
                                    if let card = sessions.first(where: { $0.id == member.sessionID }),
                                       let slot = projection.slots.first(where: { $0.sessionID == member.sessionID }) {
                                        iconView(for: card, slot: slot)
                                    }
                                }
                            }
                        } else {
                            VStack(spacing: metrics.sessionSpacing) {
                                ForEach(members, id: \.sessionID) { member in
                                    if let card = sessions.first(where: { $0.id == member.sessionID }),
                                       let slot = projection.slots.first(where: { $0.sessionID == member.sessionID }) {
                                        iconView(for: card, slot: slot)
                                    }
                                }
                            }
                        }
                    }
                    .pickyDockGroupDrawer(tint: group.color.accent, cornerRadius: metrics.iconCornerRadius)
                }
            }
            .publishDockTopEntryCenter(
                entryID: "group:\(group.id)",
                dockSide: dockSide
            )
        }
    }

    @ViewBuilder
    private func iconView(
        for session: PickySessionListViewModel.SessionCard,
        slot: PickyDockSlot
    ) -> some View {
        if draggingSessionID == session.id {
            // The dragged Pickle is rendered as a floating overlay that never
            // reparents (see `draggedFloatingIconOverlay`). In the flow it is
            // an invisible placeholder of identical size so neighbors reflow
            // to make room at the landing spot, but no real icon view crosses
            // the group-container boundary — which is what caused the flicker.
            Color.clear
                .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
                .publishDockSlotCenter(sessionID: session.id, dockSide: dockSide)
        } else {
            PickyHUDDockIconView(
                session: session,
                index: slot.visibleIndex,
                isActive: activeSessionID == session.id,
                isOpened: openedSessionID == session.id,
                isPreviewed: previewSessionID == session.id,
                isScreenContextArmed: screenContextTargetSessionID == session.id,
                dockSide: dockSide,
                shortcutNumber: PickyHUDDockLayout.numberShortcutForSessionIndex(slot.visibleIndex),
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                isUnread: unreadSessionIDs.contains(session.id),
                metrics: metrics,
                isDragging: false,
                dragOffset: .zero,
                onHover: { onHoverSession(session.id) },
                onOpen: { onOpenSession(session.id) },
                onToggleScreenContextTarget: { onToggleScreenContextTarget(session.id) },
                onCompact: { onCompactSession(session.id) },
                onArchive: { onArchiveSession(session.id) },
                onStop: { onStopSession(session.id) },
                onDoneFlashConsumed: { onDoneFlashConsumed(session.id) },
                onReorderHandoff: { anchorScreenPoint in
                    reorderController.begin(sessionID: session.id, anchorScreenPoint: anchorScreenPoint)
                }
            )
            .publishDockSlotCenter(sessionID: session.id, dockSide: dockSide)
            .transaction { transaction in
                // While a drag is in progress, animate sibling slot moves so
                // they slide to make room at the landing spot.
                guard draggingSessionID != nil else { return }
                transaction.animation = slotShiftAnimation
            }
        }
    }

    /// The real dragged Pickle, floating above the rail at the cursor. Lives in
    /// a single stable overlay so it never reparents across group containers
    /// (the in-flow slot is an invisible placeholder). Pure-translation
    /// positioning means it tracks the cursor with no per-frame layout lag.
    @ViewBuilder
    private var draggedFloatingIconOverlay: some View {
        if let id = draggingSessionID,
           let card = sessions.first(where: { $0.id == id }) {
            GeometryReader { geo in
                PickyHUDDockIconView(
                    session: card,
                    index: 0,
                    isActive: activeSessionID == id,
                    isOpened: false,
                    isPreviewed: false,
                    isScreenContextArmed: false,
                    dockSide: dockSide,
                    shortcutNumber: nil,
                    isCommandShortcutHintVisible: false,
                    shouldFlashCompletion: false,
                    isUnread: unreadSessionIDs.contains(id),
                    metrics: metrics,
                    isDragging: true,
                    dragOffset: .zero,
                    onHover: {},
                    onOpen: {},
                    onToggleScreenContextTarget: {},
                    onCompact: {},
                    onArchive: {},
                    onStop: {},
                    onDoneFlashConsumed: {},
                    onReorderHandoff: { _ in }
                )
                // Follow the cursor on both axes so a pull-out reads like
                // the macOS Dock; reorder hit-testing still uses only the
                // primary-axis delta, so cross-axis follow is purely visual.
                .opacity(sessionPullOutArmed ? 0.5 : 1)
                .position(
                    x: dockSide.orientation == .vertical
                        ? geo.size.width / 2 + dragTranslation.width
                        : dragStartCenter + dragTranslation.width,
                    y: dockSide.orientation == .vertical
                        ? dragStartCenter + dragTranslation.height
                        : geo.size.height / 2 + dragTranslation.height
                )

                if sessionPullOutArmed {
                    pullOutBadge(L10n.t("dock.drag.archive.label"))
                        .position(
                            x: dockSide.orientation == .vertical
                                ? geo.size.width / 2 + dragTranslation.width
                                : dragStartCenter + dragTranslation.width,
                            y: (dockSide.orientation == .vertical
                                ? dragStartCenter + dragTranslation.height
                                : geo.size.height / 2 + dragTranslation.height)
                                - (metrics.sessionTileHeight / 2 + 16)
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Small capsule label floated over a dragged Pickle once archive-on-
    /// release is armed, mirroring the macOS Dock cue.
    private func pullOutBadge(_ text: String) -> some View {
        PickyHUDDockPullOutBadge(text: text)
    }

    /// Synthetic id used to publish/look up an empty group's drop tile
    /// center in `slotCenters`. Distinct from any real session id so drag
    /// hit-tests can tell "drop into empty group" apart from "drop onto a
    /// session".
    private static func emptyGroupDropTargetID(groupID: String) -> String {
        "_empty_group:\(groupID)"
    }

    /// Long-axis span of a group block's drawer (the surface that hosts
    /// member icons or the collapsed/empty placeholder). The header chip is
    /// sized to match so the group title sits centered above the drawer. In
    /// vertical mode every group occupies a single column; in horizontal
    /// mode an expanded group with N members spans N tiles plus (N-1) gaps.
    private func groupDrawerSpan(
        group: PickyDockGroup,
        members: [PickyHUDDockGroupMemberRef]
    ) -> CGFloat {
        guard dockSide.orientation == .horizontal else {
            return metrics.sessionTileWidth
        }
        if group.isCollapsed || members.isEmpty {
            return metrics.sessionTileWidth
        }
        let n = CGFloat(members.count)
        return n * metrics.sessionTileWidth + max(0, n - 1) * metrics.sessionSpacing
    }

    /// Extract the group id from a synthetic empty-group drop target id, or
    /// return nil if the input is a real session id.
    private static func parseEmptyGroupDropTargetID(_ id: String) -> String? {
        guard id.hasPrefix("_empty_group:") else { return nil }
        return String(id.dropFirst("_empty_group:".count))
    }

    /// Walk projection items linearly and emit one render unit per ungrouped
    /// session or per group block. Group members get attached to their owning
    /// group, collapsed groups carry the single visible top member as their
    /// only "member".
    private static func buildRenderUnits(from items: [PickyDockRenderItem]) -> [PickyHUDDockRenderUnit] {
        var units: [PickyHUDDockRenderUnit] = []
        var activeGroup: PickyDockGroup?
        var activeMembers: [PickyHUDDockGroupMemberRef] = []

        func flushGroup() {
            if let group = activeGroup {
                units.append(.init(kind: .group(group: group, members: activeMembers)))
                activeGroup = nil
                activeMembers = []
            }
        }

        for item in items {
            switch item {
            case .session(let id):
                flushGroup()
                units.append(.init(kind: .session(id: id)))
            case .groupHeader(let group):
                flushGroup()
                activeGroup = group
                activeMembers = []
            case .groupMember(_, let sid, _):
                if activeGroup != nil {
                    activeMembers.append(.init(sessionID: sid))
                } else {
                    // Malformed projection — stray member without header.
                    // Render as ungrouped to avoid losing the icon.
                    units.append(.init(kind: .session(id: sid)))
                }
            case .collapsedGroup(let group, let topMember):
                flushGroup()
                var members: [PickyHUDDockGroupMemberRef] = []
                if let topMember { members.append(.init(sessionID: topMember)) }
                units.append(.init(kind: .group(group: group, members: members)))
            }
        }
        flushGroup()
        return units
    }

    /// Distance between successive icon centers along the dock's primary
    /// axis. Drives the threshold at which a drag tips the icon into the
    /// next visible slot.
    private var slotPitchAlongAxis: CGFloat {
        switch dockSide.orientation {
        case .horizontal: return metrics.sessionTileWidth + metrics.sessionSpacing
        case .vertical:   return metrics.sessionTileHeight + metrics.sessionSpacing
        }
    }

    /// Animation applied to each non-dragged icon's slot transition. The
    /// dragged icon must NOT be animated because its visual position is
    /// already driven explicitly by `dragOffset`; spring-interpolating its
    /// slot on top of the offset desyncs the icon from the cursor and causes
    /// the visible lag/jitter. We attach the animation per-child via the
    /// `transaction` modifier so siblings slide while the dragged one snaps.
    private var slotShiftAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.78)
    }

    // MARK: - Reorder gestures

    /// Cursor delta projected onto the dock's primary axis, in points. SwiftUI
    /// top-down y is already applied at the NSView boundary, so we just pick
    /// the relevant component here. Positive = later visible slot (right in
    /// horizontal, down in vertical).
    private func axisDelta(_ translation: CGSize) -> CGFloat {
        switch dockSide.orientation {
        case .horizontal: return translation.width
        case .vertical:   return translation.height
        }
    }

    /// Signed distance the cursor has been dragged *away* from the dock along
    /// the cross axis (perpendicular to the icon column/row). Positive means
    /// pulled out toward open screen; negative means pushed across the dock.
    private func pullOutDistance(_ translation: CGSize) -> CGFloat {
        switch dockSide {
        case .left:   return translation.width
        case .right:  return -translation.width
        case .top:    return translation.height
        case .bottom: return -translation.height
        }
    }

    /// Cross-axis travel past which a drag counts as "outside the dock". Based
    /// on the dock thickness plus a margin so the icon has visibly cleared the
    /// capsule before a destructive release arms.
    private var pullOutThreshold: CGFloat { metrics.railWidth * 0.5 + 40 }

    /// Schedule the dwell that arms session archive-on-release. Idempotent:
    /// re-arming while a timer is pending (or already armed) is a no-op, so
    /// per-frame drag callbacks don't keep rescheduling it.
    private func scheduleSessionPullOutDwell() {
        guard sessionPullOutDwellWork == nil, !sessionPullOutArmed else { return }
        let work = DispatchWorkItem {
            sessionPullOutDwellWork = nil
            guard draggingSessionID != nil else { return }
            withAnimation(.easeOut(duration: 0.16)) { sessionPullOutArmed = true }
        }
        sessionPullOutDwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelSessionPullOutDwell() {
        sessionPullOutDwellWork?.cancel()
        sessionPullOutDwellWork = nil
    }

    private func handleReorderBegin(sessionID: String) {
        guard projection.slots.contains(where: { $0.sessionID == sessionID }) else { return }
        draggingSessionID = sessionID
        pendingDropContainer = layout.container(forSessionID: sessionID)
        dragTranslation = .zero
        // Anchor the floating overlay on the measured slot center captured the
        // moment the user picked up the icon. Falling back to 0 keeps the
        // first frame safe when the GeometryReader publish hasn't landed yet.
        dragStartCenter = slotCenters[sessionID] ?? 0
        // Freeze the hit-test geometry now, while the rail still shows the
        // base (un-previewed) layout. Every subsequent drop decision is made
        // against this fixed snapshot, so the preview reflow is a pure visual
        // consequence and can never feed back into the decision.
        dragReferenceSlots = baseProjection.slots
        dragReferenceCenters = slotCenters
    }

    private func handleReorderChanged(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID else { return }
        dragTranslation = translation

        // macOS Dock-style pull-out: once the icon has clearly cleared the
        // dock on the cross axis, freeze the layout (no sibling reflow) and
        // arm archive-on-release after a short dwell. Returning early keeps
        // the dock visually still while the icon floats outside.
        if pullOutDistance(translation) > pullOutThreshold {
            pendingDropContainer = layout.container(forSessionID: sessionID)
            scheduleSessionPullOutDwell()
            return
        }
        cancelSessionPullOutDwell()
        if sessionPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { sessionPullOutArmed = false }
        }

        let translationAxis = axisDelta(translation)
        let cursorAxis = dragStartCenter + translationAxis

        // Hit-test against the FROZEN reference snapshot (captured at drag
        // start), not the live preview. Because the reference never moves
        // during the drag, the decision is a pure function of cursor position
        // and can't oscillate as the preview reflows. The resolution itself
        // (nearest center + group-edge escape) lives in the pure
        // `PickyDockDropResolver` so it can be unit-tested.
        let slotCandidates: [PickyDockDropResolver.SlotCandidate] = dragReferenceSlots.compactMap { slot in
            guard let center = dragReferenceCenters[slot.sessionID] else { return nil }
            return .init(container: slot.container, center: center)
        }
        var emptyGroupCandidates: [PickyDockDropResolver.EmptyGroupCandidate] = []
        for (centerKey, center) in dragReferenceCenters {
            guard let groupID = Self.parseEmptyGroupDropTargetID(centerKey) else { continue }
            emptyGroupCandidates.append(.init(groupID: groupID, center: center))
        }

        let nearestDestination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: sessionID,
            cursorAxis: cursorAxis,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: emptyGroupCandidates,
            layout: layout,
            slotPitch: slotPitchAlongAxis
        )

        // Record where the icon *would* land. This drives the live preview
        // projection (siblings make room at the landing spot) but is NOT
        // committed: grouping/ungrouping only happens on release, so the
        // assignment never flickers as the cursor crosses a boundary.
        if let nearestDestination, pendingDropContainer != nearestDestination {
            pendingDropContainer = nearestDestination
        }
    }

    private func handleReorderEnded(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID else { return }
        let didArchive = sessionPullOutArmed
        cancelSessionPullOutDwell()
        sessionPullOutArmed = false
        if didArchive {
            // Released outside the dock after the dwell: archive instead of
            // reordering. No move is committed.
            onArchiveSession(sessionID)
        } else {
            // Commit the deferred move exactly once, on release.
            let currentContainer = layout.container(forSessionID: sessionID)
            if let destination = pendingDropContainer, destination != currentContainer {
                onMoveSessionInDock(sessionID, destination)
            }
        }
        draggingSessionID = nil
        pendingDropContainer = nil
        dragTranslation = .zero
        dragReferenceSlots = []
        dragReferenceCenters = [:]
    }

    private func handleReorderCanceled() {
        guard draggingSessionID != nil else { return }
        // No commit on cancel — the Pickle simply snaps back to its slot.
        cancelSessionPullOutDwell()
        sessionPullOutArmed = false
        draggingSessionID = nil
        pendingDropContainer = nil
        dragTranslation = .zero
        dragReferenceSlots = []
        dragReferenceCenters = [:]
        activeReorderSessionID = nil
        reorderController.reset()
    }

    // MARK: - Group header drag (whole-group reorder)

    /// Visible top-level entry ids in the order the projection emitted them.
    /// `"session:<id>"` for an ungrouped slot, `"group:<id>"` for a group
    /// (either expanded or collapsed). Drives the header drag's drop
    /// hit-test along the same axis the icons live on.
    private var visibleTopEntryIDs: [String] {
        var ids: [String] = []
        for item in projection.items {
            switch item {
            case .session(let sid): ids.append("session:\(sid)")
            case .groupHeader(let g): ids.append("group:\(g.id)")
            case .collapsedGroup(let g, _): ids.append("group:\(g.id)")
            case .groupMember: break
            }
        }
        return ids
    }

    /// Translate a visible top-entry index back to its index in
    /// `dockLayout.entries`. Necessary when the visible projection is a
    /// strict subset of the persisted layout (for example archived or
    /// missing sessions). When the visible entry id maps to a layout entry
    /// that no longer exists, returns nil so the caller can no-op safely.
    private func layoutEntryIndex(forVisibleTopEntryID entryID: String) -> Int? {
        layout.entries.firstIndex { entry in
            switch entry {
            case .session(let id): return "session:\(id)" == entryID
            case .group(let g):    return "group:\(g.id)" == entryID
            }
        }
    }

    private func handleGroupHeaderDragBegin(groupID: String) {
        guard let layoutIdx = layout.entries.firstIndex(where: { entry in
            if case .group(let g) = entry, g.id == groupID { return true }
            return false
        }) else { return }
        // Cancel any in-flight icon drag so the two gestures never run in
        // parallel. The user typically pulls one or the other; defensive
        // here keeps state machines from getting tangled.
        if draggingSessionID != nil {
            handleReorderCanceled()
        }
        draggingGroupID = groupID
        groupDragStartLayoutIndex = layoutIdx
        groupDragCurrentLayoutIndex = layoutIdx
        groupDragOffset = .zero
        groupDragStartCenter = topEntryCenters["group:\(groupID)"] ?? 0
    }

    private func handleGroupHeaderDragChanged(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }

        // macOS Dock-style pull-out: while the group block is dragged clearly
        // outside the dock, arm removal-on-release immediately (no dwell) and
        // let the block float freely under the cursor instead of reordering.
        if pullOutDistance(translation) > pullOutThreshold {
            if !groupPullOutArmed {
                withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = true }
            }
            groupDragOffset = translation
            return
        }
        if groupPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = false }
        }

        let topEntryIDs = visibleTopEntryIDs
        guard !topEntryIDs.isEmpty else { return }
        let translationAxis = axisDelta(translation)
        let cursorAxis = groupDragStartCenter + translationAxis

        // Find the visible top entry whose measured center is closest to
        // the cursor. Skip entries with no published center (= still
        // settling) so the hit-test never picks an unmeasured entry.
        var nearestVisibleIdx: Int? = nil
        var minDistance: CGFloat = .infinity
        for (i, entryID) in topEntryIDs.enumerated() {
            guard let center = topEntryCenters[entryID] else { continue }
            let distance = abs(center - cursorAxis)
            if distance < minDistance {
                minDistance = distance
                nearestVisibleIdx = i
            }
        }
        guard let nearestVisibleIdx else { return }
        let nearestEntryID = topEntryIDs[nearestVisibleIdx]
        guard let nearestLayoutIdx = layoutEntryIndex(forVisibleTopEntryID: nearestEntryID) else { return }

        if nearestLayoutIdx != groupDragCurrentLayoutIndex {
            onMoveDockGroup(groupID, nearestLayoutIdx)
            groupDragCurrentLayoutIndex = nearestLayoutIdx
        }

        // Keep the group block glued under the cursor.
        let currentHomeCenter = topEntryCenters["group:\(groupID)"] ?? groupDragStartCenter
        let shift = currentHomeCenter - groupDragStartCenter
        let offsetAxis = translationAxis - shift
        switch dockSide.orientation {
        case .horizontal:
            groupDragOffset = CGSize(width: offsetAxis, height: translation.height)
        case .vertical:
            groupDragOffset = CGSize(width: translation.width, height: offsetAxis)
        }
    }

    private func handleGroupHeaderDragEnded(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }
        let didRemove = groupPullOutArmed
        groupPullOutArmed = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            groupDragOffset = .zero
        }
        draggingGroupID = nil
        if didRemove {
            // Released outside the dock: remove the group and archive its
            // members (same outcome as the context-menu delete). A group with
            // Pickles inside confirms first; an empty group is removed at once.
            let group = layout.group(withID: groupID)
            if let group, !group.memberSessionIDs.isEmpty {
                // Defer the modal so the block first springs back into the
                // dock, then the confirmation appears over a settled layout.
                DispatchQueue.main.async {
                    PickyHUDDockGroupDeletePrompt.confirmDeleteWithArchive(
                        groupName: group.displayName
                    ) {
                        onRemoveDockGroup(groupID, false)
                    }
                }
            } else {
                onRemoveDockGroup(groupID, false)
            }
        }
    }

    private func handleGroupHeaderDragCanceled() {
        guard draggingGroupID != nil else { return }
        groupPullOutArmed = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            groupDragOffset = .zero
        }
        draggingGroupID = nil
    }

    /// Drag handle that lives inside the dock capsule's top row. Backed by an
    /// `NSViewRepresentable` so AppKit handles hit testing, tracking area, and
    /// cursor rects — the same NSView bounds drive all three, which avoids the
    /// SwiftUI hit-test quirks that plagued earlier overlay-based attempts.
    /// The visible 22×4 pill is overlaid with `.allowsHitTesting(false)` so it's
    /// purely decorative and never claims clicks.
    private var dockAnchorHandle: some View {
        let isActive = isHandleHovered || isHandleDragging
        return PickyHUDDockAnchorHandleHost(
            onHoverChanged: { hovering in isHandleHovered = hovering },
            onDragChanged: { delta in
                if !isHandleDragging { isHandleDragging = true }
                onDockHandleDragChanged(delta)
            },
            onDragEnded: {
                isHandleDragging = false
                onDockHandleDragEnded()
            },
            onDoubleClick: onDockHandleDoubleClick
        )
        // Fill the capsule's available inner width (railWidth minus the dock's
        // 6pt horizontal padding on each side) so the handle row spans the
        // entire top of the capsule.
        .frame(
            maxWidth: dockSide.orientation == .horizontal ? nil : .infinity,
            maxHeight: dockSide.orientation == .horizontal ? .infinity : nil
        )
        .frame(
            width: dockSide.orientation == .horizontal ? metrics.handleAreaHeight : nil,
            height: dockSide.orientation == .horizontal ? nil : metrics.handleAreaHeight
        )
        .overlay {
            // Quiet by default — the pill should hint at draggability without
            // shouting. Hover and drag expand and darken it for a clear cue.
            Capsule(style: .continuous)
                .fill(DS.Colors.textTertiary.opacity(isActive ? 0.7 : 0.22))
                .frame(
                    width: dockSide.orientation == .horizontal
                        ? metrics.handleHeight
                        : (isActive ? metrics.handleActiveWidth : metrics.handleIdleWidth),
                    height: dockSide.orientation == .horizontal
                        ? (isActive ? metrics.handleActiveWidth : metrics.handleIdleWidth)
                        : metrics.handleHeight
                )
                .animation(.easeOut(duration: 0.14), value: isHandleHovered)
                .animation(.easeOut(duration: 0.14), value: isHandleDragging)
                .allowsHitTesting(false)
        }
        .onDisappear {
            isHandleHovered = false
            if isHandleDragging {
                isHandleDragging = false
                onDockHandleDragEnded()
            }
        }
        .accessibilityLabel("HUD dock handle")
        .accessibilityHint("Drag to move the Pickle dock. Crossing the middle of the screen switches the dock edge. Double-click to toggle between vertical and horizontal layouts.")
    }

    /// Frosted-glass panel that hosts the dock icons. Uses .ultraThinMaterial
    /// so the desktop / app underneath actually shows through, then layers a
    /// gradient stroke (bright top, dimmer bottom) for the macOS-style top
    /// gloss, and an ambient shadow so the dock no longer disappears against
    /// light backgrounds. Outer shape is a refined rounded rectangle (radius
    /// scales with the preset) for a more polished panel feel than a full pill.
    private var dockGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape
                    .fill(DS.Colors.surface1.opacity(0.18))
            )
            .overlay(
                shape
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
            )
            .compositingGroup()
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockShadowOpacity),
                radius: PickyHUDExpansion.dockShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockShadowYOffset
            )
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockTightShadowOpacity),
                radius: PickyHUDExpansion.dockTightShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockTightShadowYOffset
            )
    }

    private func showRecentPickleFolderPicker() {
        withAnimation(PickyHUDExpansion.animation) {
            isAddSlotExpanded = true
        }
        onAddSlotExpandedChanged(true)
        isRecentPickleFolderPickerPresented = true
    }

    private var addAgentSlotButton: some View {
        Button(action: showRecentPickleFolderPicker) {
            ZStack {
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .strokeBorder(
                        DS.Colors.textTertiary.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                    )
                Image(systemName: "plus")
                    .font(.system(size: metrics.plusFontSize, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: metrics.addSlotButtonSide, height: metrics.addSlotButtonSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .recentPickleFolderPicker(
            isPresented: $isRecentPickleFolderPickerPresented,
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
            onChooseFolder: onCreatePickle,
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            availableSessionsForGroupCreation: sessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
    }

    /// Accent color the next group will adopt. Surfaced to the creator
    /// popover so the user sees the swatch alongside the name field. New
    /// groups always default to a neutral gray.
    private var nextSuggestedGroupColor: PickyDockGroupColor {
        PickyDockGroupColor.defaultColor
    }

    private var collapsibleAddAgentSlot: some View {
        Button(action: showRecentPickleFolderPicker) {
            ZStack {
                ZStack {
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .strokeBorder(
                            DS.Colors.textTertiary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: metrics.plusFontSize, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: metrics.addSlotButtonSide, height: metrics.addSlotButtonSide)
                .opacity(isAddSlotExpanded ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(DS.Colors.textSecondary.opacity(0.78))
                    .frame(
                        width: dockSide.orientation == .horizontal ? metrics.collapsedDashHeight : metrics.collapsedDashWidth,
                        height: dockSide.orientation == .horizontal ? metrics.collapsedDashWidth : metrics.collapsedDashHeight
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 1, y: 0.4)
                    .opacity(isAddSlotExpanded ? 0 : 1)
            }
            .frame(
                width: dockSide.orientation == .horizontal
                    ? PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
                    : metrics.addSlotButtonSide,
                height: dockSide.orientation == .horizontal
                    ? metrics.addSlotButtonSide
                    : PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .recentPickleFolderPicker(
            isPresented: $isRecentPickleFolderPickerPresented,
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
            onChooseFolder: onCreatePickle,
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            availableSessionsForGroupCreation: sessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .onHover { hovering in
            let expanded = hovering || isRecentPickleFolderPickerPresented
            onAddSlotExpandedChanged(expanded)
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = expanded
            }
        }
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
    }

    private var recentPickleFolderPickerArrowEdge: Edge {
        switch dockSide {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }
}
