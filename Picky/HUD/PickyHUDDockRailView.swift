import AppKit
import SwiftUI

struct PickyHUDDockRailView: View {
    let sessions: [PickyHUDDockSession]
    /// Every live session card, including those hidden inside collapsed
    /// groups. `sessions` only carries the dock-visible slots, so the
    /// collapsed-group folder grid resolves its members from here.
    let allSessions: [PickyHUDDockSession]
    /// Projection of the *persisted* layout. Read through the `projection`
    /// computed property below, which overlays the in-flight drag preview
    /// so callers (render + hit-test) transparently see the prospective
    /// drop while a Pickle is being dragged.
    let baseProjection: PickyDockProjection
    /// Persisted dock layout. The rail uses it to translate visible
    /// top-level entry indices back to `entries` indices when committing
    /// folder-tile group reorders.
    let layout: PickyDockLayout
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
    /// Persist a new order for the pinned folders after a drag reorder.
    let onReorderPinnedPickleFolders: ([String]) -> Void
    /// Create a new group with a name and (optionally) an initial set of
    /// member sessions. Returns the new group's id so callers can chain
    /// follow-up actions (e.g. focus the new group), though the dock
    /// rail itself ignores the return value.
    let onCreateDockGroup: (_ name: String, _ memberIDs: [String]) -> String
    let onRenameDockGroup: (_ id: String, _ name: String) -> Void
    let onSetDockGroupColor: (_ id: String, _ color: PickyDockGroupColor) -> Void
    /// Routes a rail primary click through the HUD's shared group activation
    /// coordinator, which resolves current visible membership.
    let onActivateDockGroup: (_ id: String) -> Void
    let onRemoveDockGroup: (_ id: String, _ keepMembers: Bool) -> Void
    /// Persist a session move into a specific dock container/position.
    let onMoveSessionInDock: (_ sessionID: String, _ destination: PickyDockContainer) -> Void
    /// Reorder a group as a whole within the top-level layout.
    let onMoveDockGroup: (_ groupID: String, _ toTopLevelIndex: Int) -> Void
    /// One-shot request from the HUD root after a child list panel's header
    /// action. The matching rail folder tile remains the popover anchor.
    let pendingPickleFolderPickerRequest: PickyHUDDockGroupPickerRequest?
    let onPickleFolderPickerPresentationAcknowledged: (UUID) -> Void
    let onDockHoverChanged: (Bool) -> Void
    let onAddSlotExpandedChanged: (Bool) -> Void
    let onDoneFlashConsumed: (String) -> Void
    let onDockHandleDragChanged: (CGPoint) -> Void
    let onDockHandleDragEnded: () -> Void
    let onDockHandleDoubleClick: () -> Void

    @State private var isAddSlotExpanded = false
    @State private var isRecentPickleFolderPickerPresented = false
    /// Group whose tile anchors the shared new-Pickle picker. This can be nil
    /// while `newPickleTargetGroupID` remains non-nil when an offscreen group
    /// request falls back to the regular dock-bottom `+` anchor.
    @State private var newPickleAnchorGroupID: String?
    /// Exact group that should receive the newly-created Pickle.
    @State private var newPickleTargetGroupID: String?
    /// Identity is captured by the anchor that begins a popover presentation.
    /// A delayed older popover may therefore never acknowledge a replacement.
    @State private var pickleFolderPickerPresentationRequest: PickyHUDDockGroupPickerRequest?
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
    /// Ordered top-level identities captured with the frozen centers. If this
    /// changes from a daemon or CLI update, the geometry no longer maps to the
    /// live projection and the drag must cancel.
    @State private var dragReferenceTopEntryIDs: [String] = []
    @State private var dragReferenceCenters: [String: CGFloat] = [:]
    /// Group top-entry centers backstop badge hit-testing if SwiftUI has not yet
    /// published the more precise badge frame when pickup begins.
    @State private var dragReferenceGroupTopEntryCenters: [String: CGFloat] = [:]
    /// Visible folder badge frames captured with the slot snapshot. Labels stay
    /// clickable but do not extend the grouping drop zone or delay edge escape.
    @State private var dragReferenceGroupDropFrames: [String: CGRect] = [:]
    /// Destination the dragged icon would land in if released *right now*.
    /// Top-level destinations move the placeholder so siblings make room.
    /// Folder destinations keep the persisted source placeholder stable; the
    /// actual grouping commit still occurs only when the user releases.
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
    /// one per folder tile). Drives whole-group reorder hit-testing.
    @State private var topEntryCenters: [String: CGFloat] = [:]
    /// Visible folder badge frames in rail coordinates. Session drags freeze
    /// these at pickup so preview reflow cannot move a drop target.
    @State private var groupDropFrames: [String: CGRect] = [:]
    /// Currently-dragged group id (folder tile drag). Mutually exclusive with
    /// `draggingSessionID`.
    @State private var draggingGroupID: String?
    /// Raw cursor translation from group pickup. The rendered offset is derived
    /// synchronously from the group's current Stack-assigned frame so a preview
    /// reorder cannot expose one frame of stale preference geometry.
    @State private var groupDragTranslation: CGSize = .zero
    @State private var groupDragStartCenter: CGFloat = 0
    @State private var groupDragStartLayoutIndex: Int = 0
    /// The prospective final position of a folder tile. This is preview-only;
    /// the persisted layout changes once when the drag ends.
    @State private var pendingGroupTopLevelIndex: Int?
    /// Top-entry geometry captured before the group preview reflows. It keeps
    /// the target stable even when groups have non-uniform header chrome.
    @State private var groupDragReferenceTopEntryCenters: [String: CGFloat] = [:]
    @State private var groupDragReferenceTopEntryIDs: [String] = []

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.pickyAppFontScale) private var fontScale

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

    /// Live render projection. Top-level Pickle destinations reorder its clear
    /// placeholder without persisting. Folder destinations deliberately keep
    /// the persisted projection because a folder accepts the Pickle rather than
    /// introducing a linear slot. The actual move always commits on release.
    private var persistedStructure: PickyHUDDockPersistedStructure {
        PickyHUDDockRenderPolicy.persistedStructure(in: baseProjection)
    }

    private var projection: PickyDockProjection {
        let visibleSessionIDs = baseProjection.slots.compactMap(\.sessionID)
        if let draggingSessionID,
           let pendingDropContainer {
            let preview = PickyHUDDockRenderPolicy.sessionPreviewLayout(
                layout: layout,
                draggedSessionID: draggingSessionID,
                destination: pendingDropContainer
            )
            if preview != layout {
                return PickyDockProjector.project(layout: preview, visibleSessionIDs: visibleSessionIDs)
            }
        }
        if let draggingGroupID,
           let pendingGroupTopLevelIndex,
           layout.entries.firstIndex(where: {
               guard case let .group(group) = $0 else { return false }
               return group.id == draggingGroupID
           }) != pendingGroupTopLevelIndex {
            var preview = layout
            preview.moveGroup(id: draggingGroupID, toTopLevelIndex: pendingGroupTopLevelIndex)
            return PickyDockProjector.project(layout: preview, visibleSessionIDs: visibleSessionIDs)
        }
        return baseProjection
    }

    private var selectedGroupID: String? {
        PickyHUDDockRenderPolicy.selectedGroupID(
            openedSessionID: openedSessionID,
            draggingSessionID: draggingSessionID,
            layout: layout
        )
    }

    private var dropTargetedGroupID: String? {
        PickyHUDDockRenderPolicy.dropTargetedGroupID(
            draggingSessionID: draggingSessionID,
            destination: pendingDropContainer
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
                .frame(width: verticalRailCrossSize, height: resolvedRailLength, alignment: .top)
            }
        }
        .background(dockGlassBackground)
        .coordinateSpace(name: PickyHUDDockRailCoordinateSpace)
        .background(PickyHUDDockRailFrameReporter())
        .overlay { draggedFloatingIconOverlay }
        .onPreferenceChange(PickyDockSlotCenterPreferenceKey.self) { centers in
            slotCenters = centers
        }
        .onPreferenceChange(PickyDockTopEntryCenterPreferenceKey.self) { centers in
            topEntryCenters = centers
        }
        .onPreferenceChange(PickyDockGroupDropFramePreferenceKey.self) { frames in
            groupDropFrames = frames
        }
        .onChange(of: persistedStructure) { _, structure in
            cancelDragsForPersistedStructureChange(structure)
        }
        .onHover(perform: onDockHoverChanged)
        .onChange(of: isRecentPickleFolderPickerPresented) { _, isPresented in
            updateDockAddSlotExpansion(pickerIsPresented: isPresented)
            if !isPresented {
                newPickleAnchorGroupID = nil
                newPickleTargetGroupID = nil
                pickleFolderPickerPresentationRequest = nil
            }
        }
        .onChange(of: pendingPickleFolderPickerRequest) { _, _ in
            presentPendingPickleFolderPickerIfPossible()
        }
        .onChange(of: renderedGroupIDs) { _, _ in
            // Revalidate a request after any projection change. A disappearing
            // target reanchors to the ordinary dock add slot without consuming
            // intent before a popover actually appears.
            presentPendingPickleFolderPickerIfPossible()
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

    private var groupCount: Int {
        projection.items.reduce(into: 0) { count, item in
            if case .group = item { count += 1 }
        }
    }

    private var emptyGroupCount: Int {
        let activeSessionIDs = Set(allSessions.map(\.id))
        return projection.items.reduce(into: 0) { count, item in
            guard case .group(let group) = item,
                  !group.memberSessionIDs.contains(where: activeSessionIDs.contains)
            else { return }
            count += 1
        }
    }

    private var sizingSlotCount: Int {
        PickyHUDDockReorderAnimationPolicy.sizingSlotCount(
            renderedSlotCount: projection.slots.count,
            persistedSlotCount: baseProjection.slots.count,
            isSessionDragging: draggingSessionID != nil
        )
    }

    private var verticalRailCrossSize: CGFloat {
        PickyHUDDockRailLayoutPolicy.verticalCrossSize(
            groupCount: groupCount,
            metrics: metrics,
            fontScale: fontScale
        )
    }

    private var horizontalRailCrossSize: CGFloat {
        PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
            groupCount: groupCount,
            metrics: metrics,
            fontScale: fontScale
        )
    }

    private var overflowLayout: PickyHUDDockOverflowLayout {
        PickyHUDDockOverflowPolicy.layout(
            contentLength: PickyHUDDockRailLayoutPolicy.contentLength(
                sessionCount: sizingSlotCount,
                groupCount: groupCount,
                emptyGroupCount: emptyGroupCount,
                isAddSlotExpanded: isAddSlotExpanded,
                dockSide: dockSide,
                metrics: metrics,
                fontScale: fontScale
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
        guard let activeSessionID,
              let targetID = projection.scrollTargetID(forSessionID: activeSessionID)
        else { return }
        let reduceMotion = accessibilityReduceMotion
        DispatchQueue.main.async {
            if reduceMotion {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
    }

    /// Renders one rail tile for each top-level session or folder.
    @ViewBuilder
    private var dockBodyItems: some View {
        ForEach(projection.items, id: \.stableID) { item in
            switch item {
            case .session(let id):
                if let card = sessions.first(where: { $0.id == id }),
                   let slot = projection.slots.first(where: { $0.sessionID == id }) {
                    iconView(for: card, slot: slot)
                        .publishDockTopEntryCenter(entryID: "session:\(id)", dockSide: dockSide)
                        .transaction { transaction in applySlotShiftAnimation(&transaction, to: item) }
                }
            case .group(let group):
                if let slot = projection.slots.first(where: { $0.groupID == group.id }) {
                    folderTile(for: group, slot: slot)
                        .publishDockTopEntryCenter(entryID: "group:\(group.id)", dockSide: dockSide)
                        .transaction { transaction in applySlotShiftAnimation(&transaction, to: item) }
                }
            }
        }
    }

    @ViewBuilder
    private func folderTile(for group: PickyDockGroup, slot: PickyDockSlot) -> some View {
        let memberCards = group.memberSessionIDs.compactMap { id in
            allSessions.first(where: { $0.id == id })
        }
        let unreadCount = memberCards.reduce(0) { count, card in
            unreadSessionIDs.contains(card.id) ? count + 1 : count
        }
        let hasVisibleMembers = !memberCards.isEmpty
        let isSelected = selectedGroupID == group.id
        let isDropTargeted = dropTargetedGroupID == group.id
        PickyHUDDockGroupFolderTileView(
            group: group,
            metrics: metrics,
            fontScale: fontScale
        ) {
            if memberCards.isEmpty {
                groupTileButton(
                    for: group,
                    memberCards: memberCards,
                    unreadCount: unreadCount,
                    slot: slot,
                    isSelected: isSelected,
                    isDropTargeted: isDropTargeted
                )
                .publishDockGroupBadgeFrame(groupID: group.id)
                .publishDockGroupDropFrame(groupID: group.id)
                .pickyDockGroupContextMenu(
                    group: group,
                    onRename: { presentRenameDialog(for: group) },
                    onSetColor: { onSetDockGroupColor(group.id, $0) },
                    onUngroup: { onRemoveDockGroup(group.id, true) },
                    onDeleteWithArchive: { onRemoveDockGroup(group.id, false) }
                )
                .highPriorityGesture(groupReorderGesture(for: group.id))
            } else {
                groupTileButton(
                    for: group,
                    memberCards: memberCards,
                    unreadCount: unreadCount,
                    slot: slot,
                    isSelected: isSelected,
                    isDropTargeted: isDropTargeted
                )
                .publishDockGroupBadgeFrame(groupID: group.id)
                .publishDockGroupDropFrame(groupID: group.id)
                .pickyDockGroupContextMenu(
                    group: group,
                    onRename: { presentRenameDialog(for: group) },
                    onSetColor: { onSetDockGroupColor(group.id, $0) },
                    onUngroup: { onRemoveDockGroup(group.id, true) },
                    onDeleteWithArchive: { onRemoveDockGroup(group.id, false) }
                )
            }
        } header: { header in
            header
                .onTapGesture { activateGroupTile(group.id) }
                .pickyDockGroupContextMenu(
                    group: group,
                    onRename: { presentRenameDialog(for: group) },
                    onSetColor: { onSetDockGroupColor(group.id, $0) },
                    onUngroup: { onRemoveDockGroup(group.id, true) },
                    onDeleteWithArchive: { onRemoveDockGroup(group.id, false) }
                )
                .highPriorityGesture(groupReorderGesture(for: group.id))
        }
        .publishDockGroupInteractionFrame(groupID: group.id)
        .id("group:\(group.id)")
        .opacity(draggingGroupID == group.id && groupPullOutArmed ? 0.5 : 1)
        .visualEffect { content, geometry in
            let frame = geometry.frame(in: .named(PickyHUDDockRailCoordinateSpace))
            let currentHomeCenter = dockSide.orientation == .horizontal ? frame.midX : frame.midY
            let offset = draggingGroupID == group.id
                ? PickyHUDDockDragGeometry.cursorLockedOffset(
                    translation: groupDragTranslation,
                    dragStartCenter: groupDragStartCenter,
                    currentHomeCenter: currentHomeCenter,
                    orientation: dockSide.orientation
                )
                : .zero
            return content.offset(x: offset.width, y: offset.height)
        }
        .zIndex(draggingGroupID == group.id ? 220 : 0)
        .accessibilityLabel(group.displayName)
        .accessibilityValue(L10n.t("group.folder.accessibility.value", memberCards.count, unreadCount))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(
            hasVisibleMembers ? L10n.t("group.folder.action.open") : L10n.t("dock.startPickle")
        )) {
            activateGroupTile(group.id)
        }
        .accessibilityAction(named: Text(L10n.t("group.folder.action.rename"))) {
            presentRenameDialog(for: group)
        }
        .accessibilityAction(named: Text(L10n.t("group.folder.action.delete"))) {
            PickyHUDDockGroupDeletePrompt.confirmDeleteWithArchive(
                groupName: group.displayName,
                onConfirm: { onRemoveDockGroup(group.id, false) }
            )
        }
    }

    @ViewBuilder
    private func groupTileButton(
        for group: PickyDockGroup,
        memberCards: [PickyHUDDockSession],
        unreadCount: Int,
        slot: PickyDockSlot,
        isSelected: Bool,
        isDropTargeted: Bool
    ) -> some View {
        if memberCards.isEmpty {
            newPicklePicker(
                anchoredTo: PickyHUDDockGroupEmptySlot(
                    color: group.color,
                    metrics: metrics,
                    isDropTargeted: isDropTargeted,
                    onCreatePickle: { activateGroupTile(group.id) }
                ),
                anchorGroupID: group.id
            )
        } else {
            newPicklePicker(
                anchoredTo: PickyHUDDockCollapsedGroupBadge(
                    members: memberCards,
                    unreadCount: unreadCount,
                    tint: group.color.accent,
                    metrics: metrics,
                    shortcutNumber: PickyHUDDockLayout.numberShortcutForSessionIndex(slot.visibleIndex),
                    isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                    isSelected: isSelected,
                    isDropTargeted: isDropTargeted,
                    onTap: { activateGroupTile(group.id) },
                    onReorderBegan: { handleGroupTileDragBegin(groupID: group.id) },
                    onReorderChanged: { translation in
                        handleGroupTileDragChanged(groupID: group.id, translation: translation)
                    },
                    onReorderEnded: { translation in
                        handleGroupTileDragEnded(groupID: group.id, translation: translation)
                    }
                ),
                anchorGroupID: group.id
            )
        }
    }

    private func activateGroupTile(_ groupID: String) {
        onActivateDockGroup(groupID)
    }

    @MainActor
    private func presentRenameDialog(for group: PickyDockGroup) {
        let alert = NSAlert()
        alert.messageText = L10n.t("group.rename.dialog.title")
        alert.informativeText = L10n.t("group.rename.dialog.message")
        alert.alertStyle = .informational
        let field = NSTextField(string: group.name)
        field.placeholderString = L10n.t("group.rename.dialog.placeholder")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("group.rename.dialog.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            onRenameDockGroup(group.id, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @ViewBuilder
    private func iconView(
        for session: PickyHUDDockSession,
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

    /// Animation applied to every non-dragged top-level sibling, including
    /// both Pickles and folders. The dragged item stays cursor-driven so its
    /// explicit offset never competes with a layout spring.
    private var slotShiftAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.78)
    }

    private func applySlotShiftAnimation(_ transaction: inout Transaction, to item: PickyDockRenderItem) {
        guard PickyHUDDockReorderAnimationPolicy.shouldAnimate(
            item: item,
            draggingSessionID: draggingSessionID,
            draggingGroupID: draggingGroupID,
            reduceMotion: accessibilityReduceMotion
        ) else { return }
        transaction.animation = slotShiftAnimation
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
        dragReferenceTopEntryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: baseProjection.items)
        dragReferenceCenters = slotCenters
        dragReferenceGroupTopEntryCenters = topEntryCenters
        dragReferenceGroupDropFrames = groupDropFrames
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
            guard let sessionID = slot.sessionID,
                  let container = slot.container,
                  let center = dragReferenceCenters[sessionID]
            else { return nil }
            return .init(container: container, center: center)
        }
        let topLevelInsertionCandidates = PickyHUDDockRenderPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: dragReferenceTopEntryIDs,
            referenceCenters: dragReferenceGroupTopEntryCenters,
            draggedSessionID: sessionID,
            layout: layout
        )
        let activeSessionIDs = Set(allSessions.map(\.id))
        let emptyGroupCandidates = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: dragReferenceSlots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: dragReferenceGroupDropFrames,
            topEntryCenters: dragReferenceGroupTopEntryCenters,
            orientation: dockSide.orientation,
            metrics: metrics,
            fontScale: fontScale
        )
        let nonEmptyGroupCandidates = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: dragReferenceSlots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: dragReferenceGroupDropFrames,
            topEntryCenters: dragReferenceGroupTopEntryCenters,
            orientation: dockSide.orientation,
            metrics: metrics,
            fontScale: fontScale
        )

        let nearestDestination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: sessionID,
            cursorAxis: cursorAxis,
            slotCandidates: slotCandidates,
            topLevelInsertionCandidates: topLevelInsertionCandidates,
            emptyGroupCandidates: emptyGroupCandidates,
            nonEmptyGroupCandidates: nonEmptyGroupCandidates,
            layout: layout,
            slotPitch: PickyHUDDockDragGeometry.slotPitch(orientation: dockSide.orientation, metrics: metrics)
        )

        // Record where the icon *would* land. Top-level targets move the clear
        // placeholder; folder targets leave it at the source and project an
        // explicit acceptance state onto the badge. Nothing persists until release.
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
        dragReferenceTopEntryIDs = []
        dragReferenceCenters = [:]
        dragReferenceGroupTopEntryCenters = [:]
        dragReferenceGroupDropFrames = [:]
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
        dragReferenceTopEntryIDs = []
        dragReferenceCenters = [:]
        dragReferenceGroupTopEntryCenters = [:]
        dragReferenceGroupDropFrames = [:]
        activeReorderSessionID = nil
        reorderController.reset()
    }

    // MARK: - Group folder tile drag (whole-group reorder)

    /// The folder tile and its identity label use this single gesture path so
    /// either pickup point produces identical reorder and pull-out behavior.
    private func groupReorderGesture(for groupID: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if draggingGroupID != groupID { handleGroupTileDragBegin(groupID: groupID) }
                handleGroupTileDragChanged(groupID: groupID, translation: value.translation)
            }
            .onEnded { value in
                handleGroupTileDragEnded(groupID: groupID, translation: value.translation)
            }
    }

    private func handleGroupTileDragBegin(groupID: String) {
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
        pendingGroupTopLevelIndex = layoutIdx
        groupDragReferenceTopEntryCenters = topEntryCenters
        groupDragReferenceTopEntryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: baseProjection.items)
        groupDragTranslation = .zero
        groupDragStartCenter = topEntryCenters["group:\(groupID)"] ?? 0
    }

    private func handleGroupTileDragChanged(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }

        // macOS Dock-style pull-out: while the group block is dragged clearly
        // outside the dock, arm removal-on-release immediately (no dwell) and
        // let the block float freely under the cursor instead of reordering.
        if PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: dockSide) > PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics) {
            if !groupPullOutArmed {
                withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = true }
            }
            groupDragTranslation = translation
            return
        }
        if groupPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = false }
        }
        groupDragTranslation = translation

        let translationAxis = PickyHUDDockDragGeometry.axisDelta(translation, orientation: dockSide.orientation)
        let cursorAxis = groupDragStartCenter + translationAxis
        let topEntryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: baseProjection.items)
        guard let nearestLayoutIdx = PickyHUDDockRenderPolicy.nearestLayoutEntryIndex(
            cursorAxis: cursorAxis,
            visibleTopEntryIDs: topEntryIDs,
            referenceCenters: groupDragReferenceTopEntryCenters,
            layout: layout
        ) else { return }

        // Preview against the frozen drag-start geometry. Persisting this on
        // every pointer event made the source layout and its centers move under
        // the cursor, which caused the visible oscillation and wrong drops.
        if pendingGroupTopLevelIndex != nearestLayoutIdx {
            pendingGroupTopLevelIndex = nearestLayoutIdx
        }
    }

    private func handleGroupTileDragEnded(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }
        let didRemove = groupPullOutArmed
        groupPullOutArmed = false
        groupDragTranslation = .zero
        draggingGroupID = nil
        let destination = pendingGroupTopLevelIndex
        pendingGroupTopLevelIndex = nil
        groupDragReferenceTopEntryCenters = [:]
        groupDragReferenceTopEntryIDs = []
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
        } else if let destination, destination != groupDragStartLayoutIndex {
            onMoveDockGroup(groupID, destination)
        }
    }

    private func handleGroupTileDragCanceled() {
        guard draggingGroupID != nil else { return }
        groupPullOutArmed = false
        groupDragTranslation = .zero
        draggingGroupID = nil
        pendingGroupTopLevelIndex = nil
        groupDragReferenceTopEntryCenters = [:]
        groupDragReferenceTopEntryIDs = []
    }

    private func cancelDragsForPersistedStructureChange(_ structure: PickyHUDDockPersistedStructure) {
        if PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: dragReferenceTopEntryIDs,
            currentTopEntryIDs: structure.topEntryIDs
        ) {
            handleReorderCanceled()
        }
        if PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: groupDragReferenceTopEntryIDs,
            currentTopEntryIDs: structure.topEntryIDs
        ) {
            handleGroupTileDragCanceled()
        }
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

    private var renderedGroupIDs: Set<String> {
        Set(projection.items.compactMap { item -> String? in
            guard case .group(let group) = item else { return nil }
            return group.id
        })
    }

    private func presentPendingPickleFolderPickerIfPossible() {
        guard let request = pendingPickleFolderPickerRequest else { return }
        switch PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: renderedGroupIDs,
            hasUntargetedAddAnchor: true
        ) {
        case .targeted(let groupID):
            showRecentPickleFolderPicker(
                anchorGroupID: groupID,
                targetGroupID: groupID,
                request: request
            )
        case .untargeted(let targetGroupID):
            showRecentPickleFolderPicker(
                anchorGroupID: nil,
                targetGroupID: targetGroupID,
                request: request
            )
        case .deferred:
            break
        }
    }

    private func acknowledgePickleFolderPickerPresentation(requestID: UUID) {
        onPickleFolderPickerPresentationAcknowledged(requestID)
    }

    private func showRecentPickleFolderPicker(
        anchorGroupID: String?,
        targetGroupID: String?,
        request: PickyHUDDockGroupPickerRequest? = nil
    ) {
        newPickleAnchorGroupID = anchorGroupID
        newPickleTargetGroupID = targetGroupID
        pickleFolderPickerPresentationRequest = request
        updateDockAddSlotExpansion(pickerIsPresented: true)
        isRecentPickleFolderPickerPresented = true
    }

    private func updateDockAddSlotExpansion(pickerIsPresented: Bool) {
        let expanded = PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: pickerIsPresented,
            activeAnchorGroupID: newPickleAnchorGroupID
        )
        withAnimation(PickyHUDExpansion.animation) {
            isAddSlotExpanded = expanded
        }
        onAddSlotExpandedChanged(expanded)
    }

    private func newPicklePickerBinding(anchorGroupID: String?) -> Binding<Bool> {
        Binding(
            get: {
                PickyHUDDockNewPicklePopoverPolicy.isPresented(
                    pickerIsPresented: isRecentPickleFolderPickerPresented,
                    activeAnchorGroupID: newPickleAnchorGroupID,
                    anchorGroupID: anchorGroupID
                )
            },
            set: { isPresented in
                if isPresented {
                    showRecentPickleFolderPicker(
                        anchorGroupID: anchorGroupID,
                        targetGroupID: anchorGroupID
                    )
                } else if newPickleAnchorGroupID == anchorGroupID {
                    isRecentPickleFolderPickerPresented = false
                    newPickleAnchorGroupID = nil
                    newPickleTargetGroupID = nil
                    pickleFolderPickerPresentationRequest = nil
                }
            }
        )
    }


    private func newPicklePicker<Anchor: View>(
        anchoredTo anchor: Anchor,
        anchorGroupID: String?
    ) -> some View {
        let presentationRequestID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: anchorGroupID,
            activeAnchorGroupID: newPickleAnchorGroupID,
            activeRequest: pickleFolderPickerPresentationRequest
        )
        return anchor.recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(anchorGroupID: anchorGroupID),
            onPresentationAcknowledged: {
                guard let presentationRequestID else { return }
                acknowledgePickleFolderPickerPresentation(requestID: presentationRequestID)
            },
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd)
            },
            onChooseFolder: {
                chooseFolderForNewPickle()
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            onReorderPinnedPickleFolders: onReorderPinnedPickleFolders,
            // Use the full live list, not the collapsed projection slots, so
            // members hidden behind folder tiles remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
    }

    private func createPickleInRecentFolder(_ cwd: String) {
        let targetGroupID = newPickleTargetGroupID
        isRecentPickleFolderPickerPresented = false
        newPickleAnchorGroupID = nil
        newPickleTargetGroupID = nil
        pickleFolderPickerPresentationRequest = nil
        onCreatePickleInRecentFolder(cwd, targetGroupID)
    }

    private func chooseFolderForNewPickle() {
        let targetGroupID = newPickleTargetGroupID
        isRecentPickleFolderPickerPresented = false
        newPickleAnchorGroupID = nil
        newPickleTargetGroupID = nil
        pickleFolderPickerPresentationRequest = nil
        onCreatePickle(targetGroupID)
    }

    private var addAgentSlotButton: some View {
        let presentationRequestID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: nil,
            activeAnchorGroupID: newPickleAnchorGroupID,
            activeRequest: pickleFolderPickerPresentationRequest
        )
        return Button {
            showRecentPickleFolderPicker(anchorGroupID: nil, targetGroupID: nil)
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
            isPresented: newPicklePickerBinding(anchorGroupID: nil),
            onPresentationAcknowledged: {
                guard let presentationRequestID else { return }
                acknowledgePickleFolderPickerPresentation(requestID: presentationRequestID)
            },
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd)
            },
            onChooseFolder: {
                chooseFolderForNewPickle()
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            onReorderPinnedPickleFolders: onReorderPinnedPickleFolders,
            // Use the full live list, not the collapsed projection slots, so
            // members hidden behind folder tiles remain selectable.
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
        let presentationRequestID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: nil,
            activeAnchorGroupID: newPickleAnchorGroupID,
            activeRequest: pickleFolderPickerPresentationRequest
        )
        return Button {
            showRecentPickleFolderPicker(anchorGroupID: nil, targetGroupID: nil)
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
            isPresented: newPicklePickerBinding(anchorGroupID: nil),
            onPresentationAcknowledged: {
                guard let presentationRequestID else { return }
                acknowledgePickleFolderPickerPresentation(requestID: presentationRequestID)
            },
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd)
            },
            onChooseFolder: {
                chooseFolderForNewPickle()
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            onReorderPinnedPickleFolders: onReorderPinnedPickleFolders,
            // Use the full live list, not the collapsed projection slots, so
            // members hidden behind folder tiles remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .onHover { hovering in
            let pickerKeepsExpanded = PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
                pickerIsPresented: isRecentPickleFolderPickerPresented,
                activeAnchorGroupID: newPickleAnchorGroupID
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
