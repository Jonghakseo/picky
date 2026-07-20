import AppKit
import SwiftUI

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
    let screenContextTargetSticky: Bool
    let dockSide: PickyHUDDockSide
    let isCommandShortcutHintVisible: Bool
    let pendingDoneFlashSessionIDs: Set<String>
    let unreadSessionIDs: Set<String>
    let metrics: PickyHUDDockMetrics
    /// Screen-aware primary-axis budget from the per-display placement.
    let availableRailLength: CGFloat
    let onHoverSession: (String) -> Void
    let onOpenSession: (String) -> Void
    let onToggleScreenContextTarget: (String) -> Void
    let onToggleStickyScreenContextTarget: (String) -> Void
    let onCompactSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onStopSession: (String) -> Void
    /// Starts the choose-folder flow for a new Pickle. A non-nil group id
    /// means the created session should be assigned to that exact group.
    let onCreatePickle: (_ targetGroupID: String?) -> Void
    let pinnedPickleCwds: [String]
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (_ cwd: String, _ targetGroupID: String?) -> Void
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
    /// Exact group targeted by the button that opened the shared new-Pickle
    /// picker. `nil` means the regular dock-bottom `+` initiated the flow.
    @State private var newPickleTargetGroupID: String?
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

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

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
        let resolvedRailLength = overflowLayout.railLength
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
                .frame(width: resolvedRailLength, height: horizontalRailCrossSize, alignment: .center)
            } else {
                // Keep the handle inside the opaque dock capsule so the AppKit-backed
                // handle row retains a reliable hit target across its full width.
                VStack(spacing: 2) {
                    dockAnchorHandle
                    sessionsAndAddSlot
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, metrics.topPadding)
                .padding(.bottom, metrics.bottomPadding)
                .frame(width: metrics.railWidth, height: resolvedRailLength, alignment: .top)
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
            updateDockAddSlotExpansion(pickerIsPresented: isPresented)
            if !isPresented {
                newPickleTargetGroupID = nil
            }
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

    private var horizontalRailCrossSize: CGFloat {
        PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
            projection: projection,
            metrics: metrics
        )
    }

    private var overflowLayout: PickyHUDDockOverflowLayout {
        PickyHUDDockOverflowPolicy.layout(
            contentLength: PickyHUDDockRailLayoutPolicy.contentLength(
                sessionCount: sessions.count,
                isAddSlotExpanded: isAddSlotExpanded,
                dockSide: dockSide,
                projection: projection,
                metrics: metrics
            ),
            availableLength: availableRailLength,
            fixedChromeLength: PickyHUDDockRailLayoutPolicy.fixedChromeLength(
                isAddSlotExpanded: isAddSlotExpanded,
                dockSide: dockSide,
                metrics: metrics
            )
        )
    }

    @ViewBuilder
    private var sessionsAndAddSlot: some View {
        if projection.items.isEmpty && projection.slots.isEmpty {
            // Empty state still lives inside the capsule so the handle has somewhere
            // to anchor visually. Use the full-size add button (not the collapsible
            // one) since there are no sessions to keep it compact for.
            addAgentSlotButton
        } else if overflowLayout.needsScroll {
            if dockSide.orientation == .horizontal {
                horizontalScrollableSessionsAndAddSlot
            } else {
                verticalScrollableSessionsAndAddSlot
            }
        } else if dockSide.orientation == .horizontal {
            horizontalSessionsAndAddSlot
        } else {
            verticalSessionsAndAddSlot
        }
    }

    private var horizontalSessionsAndAddSlot: some View {
        // Bottom-align so ungrouped Pickle icons (`sessionTileHeight`) share
        // the same baseline as a grouped drawer. The collapsible `+` slot is
        // not a Pickle and stays vertically centered in its wrapper.
        HStack(alignment: .bottom, spacing: 2) {
            HStack(alignment: .bottom, spacing: metrics.sessionSpacing) {
                dockBodyItems
            }
            collapsibleAddAgentSlot
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var verticalSessionsAndAddSlot: some View {
        VStack(spacing: metrics.sessionSpacing) {
            dockBodyItems
        }
        collapsibleAddAgentSlot
            .padding(.top, metrics.addSlotTopPadding)
    }

    private var horizontalScrollableSessionsAndAddSlot: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: metrics.sessionSpacing) {
                        dockBodyItems
                    }
                }
                .frame(width: overflowLayout.sessionsViewportLength)
                .onAppear { revealActiveSession(using: proxy) }
                .onChange(of: activeSessionID) { _, _ in revealActiveSession(using: proxy) }
            }
            collapsibleAddAgentSlot
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var verticalScrollableSessionsAndAddSlot: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: metrics.sessionSpacing) {
                    dockBodyItems
                }
            }
            .frame(height: overflowLayout.sessionsViewportLength)
            .onAppear { revealActiveSession(using: proxy) }
            .onChange(of: activeSessionID) { _, _ in revealActiveSession(using: proxy) }
        }
        collapsibleAddAgentSlot
            .padding(.top, metrics.addSlotTopPadding)
    }

    private func revealActiveSession(using proxy: ScrollViewProxy) {
        guard let activeSessionID else { return }
        let reduceMotion = accessibilityReduceMotion
        DispatchQueue.main.async {
            if reduceMotion {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(activeSessionID, anchor: .center)
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(activeSessionID, anchor: .center)
                }
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
        let renderUnits = PickyHUDDockRenderPolicy.renderUnits(from: projection.items)
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
                drawerSpan: PickyHUDDockRenderPolicy.groupDrawerSpan(group: group, members: members, dockSide: dockSide, metrics: metrics),
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
                        .id(topID)
                        .publishDockSlotCenter(sessionID: topID, dockSide: dockSide)
                    } else {
                        // Group has no visible members — render a small
                        // empty drop target so the user can still drag
                        // pickles in or expand/rename via the header menu.
                        emptyGroupCreateSlot(for: group)
                            .publishDockSlotCenter(
                                sessionID: PickyHUDDockRenderPolicy.emptyGroupDropTargetID(groupID: group.id),
                                dockSide: dockSide
                            )
                    }
                } else if members.isEmpty {
                    emptyGroupCreateSlot(for: group)
                        .publishDockSlotCenter(
                            sessionID: PickyHUDDockRenderPolicy.emptyGroupDropTargetID(groupID: group.id),
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
                .id(session.id)
                .publishDockSlotCenter(sessionID: session.id, dockSide: dockSide)
        } else {
            PickyHUDDockIconView(
                session: session,
                index: slot.visibleIndex,
                isActive: activeSessionID == session.id,
                isOpened: openedSessionID == session.id,
                isPreviewed: previewSessionID == session.id,
                isScreenContextArmed: screenContextTargetSessionID == session.id,
                isScreenContextSticky: screenContextTargetSessionID == session.id && screenContextTargetSticky,
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
                onToggleStickyScreenContextTarget: { onToggleStickyScreenContextTarget(session.id) },
                onCompact: { onCompactSession(session.id) },
                onArchive: { onArchiveSession(session.id) },
                onStop: { onStopSession(session.id) },
                onDoneFlashConsumed: { onDoneFlashConsumed(session.id) },
                onReorderHandoff: { anchorScreenPoint in
                    reorderController.begin(sessionID: session.id, anchorScreenPoint: anchorScreenPoint)
                }
            )
            .id(session.id)
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
                    isScreenContextSticky: false,
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
                    onToggleStickyScreenContextTarget: {},
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
        if PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: dockSide) > PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics) {
            pendingDropContainer = layout.container(forSessionID: sessionID)
            scheduleSessionPullOutDwell()
            return
        }
        cancelSessionPullOutDwell()
        if sessionPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { sessionPullOutArmed = false }
        }

        let translationAxis = PickyHUDDockDragGeometry.axisDelta(translation, orientation: dockSide.orientation)
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
            guard let groupID = PickyHUDDockRenderPolicy.parseEmptyGroupDropTargetID(centerKey) else { continue }
            emptyGroupCandidates.append(.init(groupID: groupID, center: center))
        }

        let nearestDestination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: sessionID,
            cursorAxis: cursorAxis,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: emptyGroupCandidates,
            layout: layout,
            slotPitch: PickyHUDDockDragGeometry.slotPitch(orientation: dockSide.orientation, metrics: metrics)
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
        if PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: dockSide) > PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics) {
            if !groupPullOutArmed {
                withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = true }
            }
            groupDragOffset = translation
            return
        }
        if groupPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = false }
        }

        let topEntryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: projection.items)
        guard !topEntryIDs.isEmpty else { return }
        let translationAxis = PickyHUDDockDragGeometry.axisDelta(translation, orientation: dockSide.orientation)
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
        guard let nearestLayoutIdx = PickyHUDDockRenderPolicy.layoutEntryIndex(forVisibleTopEntryID: nearestEntryID, in: layout) else { return }

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
        let presentation = PickyHUDDockHandlePresentation.resolve(isActive: isActive)
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
            // Visible without hover so the drag affordance survives translucent
            // light surfaces. Hover and drag expand and strengthen its contrast.
            Capsule(style: .continuous)
                .fill(presentation.foregroundColor.opacity(presentation.opacity))
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
        return PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1)
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

    private func showRecentPickleFolderPicker(targetGroupID: String?) {
        newPickleTargetGroupID = targetGroupID
        updateDockAddSlotExpansion(pickerIsPresented: true)
        isRecentPickleFolderPickerPresented = true
    }

    private func updateDockAddSlotExpansion(pickerIsPresented: Bool) {
        let expanded = PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: pickerIsPresented,
            activeTargetGroupID: newPickleTargetGroupID
        )
        withAnimation(PickyHUDExpansion.animation) {
            isAddSlotExpanded = expanded
        }
        onAddSlotExpandedChanged(expanded)
    }

    private func newPicklePickerBinding(targetGroupID: String?) -> Binding<Bool> {
        Binding(
            get: {
                PickyHUDDockNewPicklePopoverPolicy.isPresented(
                    pickerIsPresented: isRecentPickleFolderPickerPresented,
                    activeTargetGroupID: newPickleTargetGroupID,
                    anchorGroupID: targetGroupID
                )
            },
            set: { isPresented in
                if isPresented {
                    showRecentPickleFolderPicker(targetGroupID: targetGroupID)
                } else if newPickleTargetGroupID == targetGroupID {
                    isRecentPickleFolderPickerPresented = false
                }
            }
        )
    }

    private func emptyGroupCreateSlot(for group: PickyDockGroup) -> some View {
        newPicklePicker(
            anchoredTo: PickyHUDDockGroupEmptySlot(
                color: group.color,
                metrics: metrics,
                onCreatePickle: {
                    showRecentPickleFolderPicker(targetGroupID: group.id)
                }
            ),
            targetGroupID: group.id
        )
    }

    private func newPicklePicker<Anchor: View>(
        anchoredTo anchor: Anchor,
        targetGroupID: String?
    ) -> some View {
        anchor.recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(targetGroupID: targetGroupID),
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd, targetGroupID: targetGroupID)
            },
            onChooseFolder: {
                chooseFolderForNewPickle(targetGroupID: targetGroupID)
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            // Use the full live list, not the collapsed projection slots, so
            // members hidden inside a collapsed group remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
    }

    private func createPickleInRecentFolder(_ cwd: String, targetGroupID: String?) {
        isRecentPickleFolderPickerPresented = false
        newPickleTargetGroupID = nil
        onCreatePickleInRecentFolder(cwd, targetGroupID)
    }

    private func chooseFolderForNewPickle(targetGroupID: String?) {
        isRecentPickleFolderPickerPresented = false
        newPickleTargetGroupID = nil
        onCreatePickle(targetGroupID)
    }

    private var addAgentSlotButton: some View {
        Button {
            showRecentPickleFolderPicker(targetGroupID: nil)
        } label: {
            ZStack {
                PickyHUDMaterialFill(
                    shape: RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous),
                    fallback: DS.Colors.surface1
                )
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
        .recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(targetGroupID: nil),
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd, targetGroupID: nil)
            },
            onChooseFolder: {
                chooseFolderForNewPickle(targetGroupID: nil)
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            // Use the full live list, not the collapsed projection slots, so
            // members hidden inside a collapsed group remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
        .hoverAffordance()
    }

    /// Accent color the next group will adopt. Surfaced to the creator
    /// popover so the user sees the swatch alongside the name field. New
    /// groups always default to a neutral gray.
    private var nextSuggestedGroupColor: PickyDockGroupColor {
        PickyDockGroupColor.defaultColor
    }

    private var collapsibleAddAgentSlot: some View {
        Button {
            showRecentPickleFolderPicker(targetGroupID: nil)
        } label: {
            ZStack {
                ZStack {
                    PickyHUDMaterialFill(
                        shape: RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous),
                        fallback: DS.Colors.surface1
                    )
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
        .recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(targetGroupID: nil),
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd, targetGroupID: nil)
            },
            onChooseFolder: {
                chooseFolderForNewPickle(targetGroupID: nil)
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            // Use the full live list, not the collapsed projection slots, so
            // members hidden inside a collapsed group remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .onHover { hovering in
            let pickerKeepsExpanded = PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
                pickerIsPresented: isRecentPickleFolderPickerPresented,
                activeTargetGroupID: newPickleTargetGroupID
            )
            let expanded = hovering || pickerKeepsExpanded
            onAddSlotExpandedChanged(expanded)
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = expanded
            }
        }
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
        .hoverAffordance()
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
