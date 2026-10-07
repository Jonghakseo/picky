import AppKit
import SwiftUI

/// The list-style Pickle dock. Vertical docks stack rows; horizontal docks lay
/// out chips. Groups render as a header with their members inline when
/// expanded. Drag gestures reorder Pickles, move them into or out of groups,
/// and reorder whole groups; every move commits once on release.
struct PickyHUDDockRailView: View {
    /// Every active session, including members of collapsed groups.
    let sessions: [PickyHUDDockSession]
    /// Projection of the *persisted* layout. Read through `projection`, which
    /// overlays the in-flight drag preview.
    let baseProjection: PickyDockProjection
    /// Persisted dock layout, used to translate rendered entries back into
    /// layout indices when committing moves.
    let layout: PickyDockLayout
    let activeSessionID: String?
    let openedSessionID: String?
    let screenContextTargetSessionID: String?
    let screenContextTargetSticky: Bool
    let dockSide: PickyHUDDockSide
    let isCommandShortcutHintVisible: Bool
    let pendingDoneFlashSessionIDs: Set<String>
    let unreadSessionIDs: Set<String>
    let metrics: PickyHUDDockMetrics
    /// Screen-aware primary-axis budget from the per-display placement.
    let availableRailLength: CGFloat
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
    let onReorderPinnedPickleFolders: ([String]) -> Void
    let onCreateDockGroup: (_ name: String, _ memberIDs: [String]) -> String
    let onRenameDockGroup: (_ id: String, _ name: String) -> Void
    let onSetDockGroupColor: (_ id: String, _ color: PickyDockGroupColor) -> Void
    let onSetDockGroupCollapsed: (_ id: String, _ collapsed: Bool) -> Void
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
    /// Applies a size preset chosen by dragging the resize tab.
    var onChangeDockSizePreset: (PickyHUDDockSizePreset) -> Void = { _ in }
    var archiveAccess: PickyHUDArchivedSessionAccess? = nil
    var onMinimize: () -> Void = {}
    @StateObject var expansion = PickyHUDDockExpansionController()
    @State private var isArchivePresented = false
    @State private var isMenuTracking = false

    @State var isAddSlotExpanded = false
    @State var isRecentPickleFolderPickerPresented = false
    /// Anchor of the shared new-Pickle popover: a group id for a header `+`,
    /// nil for the dock `+`. The anchor's group receives the new Pickle.
    @State var newPickleAnchorGroupID: String?
    @State private var isHandleHovered = false
    @State private var isHandleDragging = false
    @State private var isDockHovered = false
    @State private var isResizeTabHovered = false
    @State private var resizeDragStartPreset: PickyHUDDockSizePreset?
    /// Keeps the resize tab reachable for a moment after the pointer leaves
    /// the rail. See `resizeTabGrace`.
    @State private var isResizeTabGraced = false
    @State private var resizeTabGraceTask: Task<Void, Never>?
    @State private var draggingSessionID: String?
    /// Raw cursor translation since the drag began. Positions the floating
    /// row; the in-flow slot is an invisible placeholder so the real row never
    /// reparents across a group boundary.
    @State private var dragTranslation: CGSize = .zero
    /// Frozen geometry the drop decision is computed against, captured once
    /// at drag start from the persisted layout. Hit-testing never reads the
    /// self-reflowing preview, which keeps the decision from oscillating.
    @State private var dragReferenceSlots: [PickyDockSlot] = []
    @State private var dragReferenceTopEntryIDs: [String] = []
    @State private var dragReferenceCenters: [String: CGPoint] = [:]
    @State private var dragReferenceTopEntryExtents: [String: PickyDockAxisExtent] = [:]
    @State private var dragReferenceGroupDropFrames: [String: CGRect] = [:]
    /// Destination the dragged row would land in if released right now.
    @State private var pendingDropContainer: PickyDockContainer?
    /// Rail-level reorder drag tracker. Survives the dragged row's NSView
    /// being recreated when the preview moves it across a group boundary.
    @StateObject private var reorderController = PickyDockReorderDragController()
    @State private var activeReorderSessionID: String?
    @State private var dragStartCenter: CGFloat = 0
    @State private var dragStartSourceCenter: CGPoint?
    /// Per-row full centers in the rail coordinate space.
    @State private var slotCenters: [String: CGPoint] = [:]
    /// Primary-axis span of each top-level entry (Pickle row or group block).
    @State private var topEntryExtents: [String: PickyDockAxisExtent] = [:]
    /// Group header frames in rail coordinates: the "drop into group" target.
    @State private var groupDropFrames: [String: CGRect] = [:]
    @State private var draggingGroupID: String?
    @State private var groupDragTranslation: CGSize = .zero
    @State private var groupDragStartCenter: CGFloat = 0
    @State private var groupDragStartLayoutIndex: Int = 0
    @State private var pendingGroupTopLevelIndex: Int?
    @State private var groupDragReferenceTopEntryExtents: [String: PickyDockAxisExtent] = [:]
    @State private var groupDragReferenceTopEntryIDs: [String] = []
    /// Scroll position of an overflowing list, for the edge fades.
    @State private var listScrollOffset: CGFloat = 0
    /// Viewport span of an overflowing list in rail coordinates.
    @State private var listViewportExtent: PickyDockAxisExtent?
    /// Scroll offset when the current drag began; frozen drop geometry is
    /// relative to it.
    @State private var dragStartScrollOffset: CGFloat = 0
    @State private var autoScrollDirection = 0
    @State private var autoScrollTick = 0
    @State private var autoScrollTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.pickyAppFontScale) var fontScale

    /// macOS Dock-style pull-out. While dragging a row or group clearly away
    /// from the dock on the cross axis, a release archives the Pickle (after a
    /// short dwell) or removes the group.
    @State private var sessionPullOutArmed = false
    @State private var groupPullOutArmed = false
    @State private var sessionPullOutDwellWork: DispatchWorkItem?

    private var orientation: PickyHUDDockOrientation { dockSide.orientation }

    private var persistedStructure: PickyHUDDockPersistedStructure {
        PickyHUDDockRenderPolicy.persistedStructure(in: baseProjection)
    }

    /// Live render projection. Top-level and expanded-group destinations move
    /// the dragged row's clear placeholder; nothing persists until release.
    var projection: PickyDockProjection {
        let visibleSessionIDs = sessions.map(\.id)
        if let draggingSessionID, let pendingDropContainer {
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

    private var activeSessionIDSet: Set<String> { Set(sessions.map(\.id)) }

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
        dockChrome
        .animation(accessibilityReduceMotion || holdsExpansion ? nil : .easeOut(duration: 0.18), value: expansion.isExpanded)
        .background(PickyHUDDockRailFrameReporter())
        .overlay(alignment: resizeTabAlignment) { resizeTab }
        .onHover { hovering in
            isDockHovered = hovering
            updateResizeTabGrace(isDockHovered: hovering)
            onDockHoverChanged(hovering)
            updateExpansion()
        }
        // Reserve the final width once. Hover changes visible ink, not the
        // panel size or the conversation-card position.
        .frame(width: orientation == .vertical ? railCrossSize : nil,
               height: orientation == .horizontal ? railCrossSize : nil,
               alignment: dockSide == .left ? .leading : dockSide == .right ? .trailing : dockSide == .top ? .top : .bottom)
        .coordinateSpace(name: PickyHUDDockRailCoordinateSpace)
        .overlay { draggedFloatingRowOverlay }
        .onChange(of: holdsExpansion) { _, _ in updateExpansion() }
        .onChange(of: expansion.previewTarget) { _, _ in updateExpansion() }
        .onChange(of: dockSide) { _, _ in updateExpansion() }
        .onAppear { updateExpansion() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            if isDockHovered { isMenuTracking = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuTracking = false
        }
        .onPreferenceChange(PickyDockSlotCenterPreferenceKey.self) { centers in
            guard slotCenters != centers else { return }
            slotCenters = centers
        }
        .onPreferenceChange(PickyDockTopEntryExtentPreferenceKey.self) { extents in
            guard topEntryExtents != extents else { return }
            topEntryExtents = extents
        }
        .onPreferenceChange(PickyDockGroupDropFramePreferenceKey.self) { frames in
            guard groupDropFrames != frames else { return }
            groupDropFrames = frames
        }
        .onChange(of: persistedStructure) { _, structure in
            cancelDragsForPersistedStructureChange(structure)
        }
        .onChange(of: isRecentPickleFolderPickerPresented) { _, isPresented in
            updateDockAddSlotExpansion(pickerIsPresented: isPresented)
            if !isPresented { newPickleAnchorGroupID = nil }
        }
        // Drive the reorder drag from the rail-level controller so handlers
        // keep firing with fresh layout state after the dragged row's view is
        // recreated by a cross-group preview.
        .onChange(of: reorderController.phase) { _, phase in
            handleReorderPhase(phase)
        }
        .onDisappear {
            autoScrollTask?.cancel()
            autoScrollTask = nil
            expansion.stop()
        }
        .environment(\.pickyDockHorizontalLayout, orientation == .horizontal)
        .environment(\.pickyDockCompactLayout, orientation == .vertical
            ? PickyHUDDockCompactLayout(isExpanded: expansion.isExpanded, iconOnLeadingEdge: dockSide == .left) : nil)
    }

    @ViewBuilder
    private var dockChrome: some View {
        if orientation == .horizontal {
            PickyHUDHorizontalDockChrome(
                dockSide: dockSide, metrics: metrics, railLength: overflowLayout.railLength,
                cellSide: horizontalCellSide, previewHeight: metrics.horizontalPreviewHeight(fontScale: fontScale),
                revealedHeight: expansion.isExpanded ? metrics.horizontalPreviewHeight(fontScale: fontScale) : 0,
                onMinimize: onMinimize
            ) {
                listContent
            } utilities: {
                dockUtilities
            } handle: {
                dockAnchorHandle
            } preview: {
                horizontalPreview
            }
        } else {
            PickyHUDDockChrome(
                dockSide: dockSide, metrics: metrics, railLength: overflowLayout.railLength,
                crossSize: railCrossSize, onMinimize: onMinimize,
                compactWidth: expansion.isExpanded ? railCrossSize : PickyHUDDockCompactLayout.iconColumnWidth
            ) {
                listContent
            } utilities: {
                dockUtilities
            } handle: {
                dockAnchorHandle
            }
        }
    }

    private var dockUtilities: some View {
        let utilityLayout = orientation == .vertical
            ? AnyLayout(VStackLayout(spacing: metrics.utilitySpacing))
            : AnyLayout(HStackLayout(spacing: 0))
        return utilityLayout {
            if !projection.items.isEmpty {
                addAgentSlotButton
                    .frame(width: orientation == .horizontal ? horizontalCellSide : nil,
                           height: orientation == .horizontal ? horizontalCellSide : nil)
                    .onHover { horizontalHover(.newPickle, inside: $0) }
            }
            if let archiveAccess {
                PickyHUDArchivedDockAccessView(archiveMembership: archiveAccess.membership,
                    commands: archiveAccess.commands,
                    compactMetrics: orientation == .vertical ? metrics : nil,
                    onPresentationChanged: { isArchivePresented = $0 })
                    .frame(width: orientation == .horizontal ? horizontalCellSide : nil,
                           height: orientation == .horizontal ? horizontalCellSide : nil)
                    .onHover { horizontalHover(.archive, inside: $0) }
            } else if orientation == .horizontal {
                Color.clear.frame(width: horizontalCellSide, height: horizontalCellSide)
                    .allowsHitTesting(false)
            }
        }
    }

    private var horizontalCellSide: CGFloat { metrics.horizontalCompactCellSide(fontScale: fontScale) }

    var resolvedHorizontalPreviewTarget: PickyHUDDockPreviewTarget {
        if !isDockHovered, let activeSessionID { return .session(activeSessionID) }
        return expansion.previewTarget ?? activeSessionID.map(PickyHUDDockPreviewTarget.session) ?? .newPickle
    }

    private func horizontalHover(_ target: PickyHUDDockPreviewTarget, inside: Bool) {
        guard orientation == .horizontal, inside else { return }
        // Keep the last target while crossing into its name row. The rail's
        // outer exit owns collapse, not exits between adjacent icon cells.
        isDockHovered = true
        expansion.preview(target)
        updateExpansion()
    }

    // MARK: - Layout

    private var holdsExpansion: Bool {
        // A key HUD window is not a dock interaction. Holding on window
        // activation would keep the rail open after the pointer leaves it.
        activeSessionID != nil || isCommandShortcutHintVisible
            || isRecentPickleFolderPickerPresented || isArchivePresented || isMenuTracking
            || isHandleDragging || draggingSessionID != nil || draggingGroupID != nil
            || isResizeTabHovered || resizeDragStartPreset != nil
    }

    private func updateExpansion() {
        let hasPreview = orientation == .vertical || expansion.previewTarget != nil || activeSessionID != nil
        expansion.update(pointerInside: isDockHovered && hasPreview, heldOpen: holdsExpansion && hasPreview)
    }

    private var railCrossSize: CGFloat {
        PickyHUDDockRailLayoutPolicy.crossSize(dockSide: dockSide, metrics: metrics, fontScale: fontScale)
    }

    private func contentLength(for projection: PickyDockProjection) -> CGFloat {
        PickyHUDDockRailLayoutPolicy.contentLength(
            projection: projection,
            activeSessionIDs: activeSessionIDSet,
            dockSide: dockSide,
            metrics: metrics,
            fontScale: fontScale
        )
    }

    var overflowLayout: PickyHUDDockOverflowLayout {
        let sizingLength = PickyHUDDockReorderAnimationPolicy.sizingLength(
            renderedLength: contentLength(for: projection),
            persistedLength: contentLength(for: baseProjection),
            isSessionDragging: draggingSessionID != nil
        )
        return PickyHUDDockOverflowPolicy.layout(
            contentLength: sizingLength,
            availableLength: availableRailLength,
            fixedChromeLength: PickyHUDDockRailLayoutPolicy.fixedChromeLength(
                dockSide: dockSide,
                metrics: metrics,
                hasDockAddUtility: !projection.items.isEmpty,
                fontScale: fontScale
            )
        )
    }

    private var listCrossLength: CGFloat {
        orientation == .vertical ? railCrossSize : horizontalCellSide
    }

    @ViewBuilder
    private var listContent: some View {
        if projection.items.isEmpty {
            addAgentSlotButton
                .onHover { horizontalHover(.newPickle, inside: $0) }
        } else if overflowLayout.needsScroll {
            scrollingList
        } else {
            listStack
        }
    }

    @ViewBuilder
    private var listStack: some View {
        if orientation == .horizontal {
            HStack(spacing: 0) { listEntries }
                .frame(height: listCrossLength)
        } else {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) { listEntries }
                .frame(width: listCrossLength)
        }
    }

    private var scrollingList: some View {
        let viewportLength = overflowLayout.sessionsViewportLength
        let fullLength = PickyHUDDockRailLayoutPolicy.listLength(
            projection: projection,
            activeSessionIDs: activeSessionIDSet,
            orientation: orientation,
            metrics: metrics,
            fontScale: fontScale
        )
        let fades = PickyHUDDockScrollFadePolicy.fades(
            offset: listScrollOffset,
            contentLength: fullLength,
            viewportLength: viewportLength
        )
        return ScrollViewReader { proxy in
            ScrollView(orientation == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                listStack
                    .background {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(Self.listViewportSpace))
                            Color.clear.preference(
                                key: PickyDockListScrollOffsetPreferenceKey.self,
                                value: orientation == .horizontal ? -frame.minX : -frame.minY
                            )
                        }
                    }
            }
            .coordinateSpace(name: Self.listViewportSpace)
            .onPreferenceChange(PickyDockListScrollOffsetPreferenceKey.self) { offset in
                guard abs(listScrollOffset - offset) > 0.5 else { return }
                listScrollOffset = offset
                // The pointer may rest while the list moves under it (autoscroll
                // or a wheel scroll), so re-resolve the drop at the same cursor.
                reresolveDragAfterScroll()
            }
            .frame(
                width: orientation == .horizontal ? viewportLength : listCrossLength,
                height: orientation == .horizontal ? listCrossLength : viewportLength
            )
            .background {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named(PickyHUDDockRailCoordinateSpace))
                    Color.clear.preference(
                        key: PickyDockListViewportExtentPreferenceKey.self,
                        value: orientation == .horizontal
                            ? PickyDockAxisExtent(lower: frame.minX, upper: frame.maxX)
                            : PickyDockAxisExtent(lower: frame.minY, upper: frame.maxY)
                    )
                }
            }
            .onPreferenceChange(PickyDockListViewportExtentPreferenceKey.self) { extent in
                guard listViewportExtent != extent else { return }
                listViewportExtent = extent
            }
            .onChange(of: autoScrollTick) { _, _ in performAutoScrollStep(using: proxy) }
            .mask(PickyHUDDockScrollFadeMask(orientation: orientation, fades: fades, length: metrics.scrollFadeLength))
            .onAppear { revealActiveSession(using: proxy) }
            .onChange(of: activeSessionID) { _, _ in revealActiveSession(using: proxy) }
        }
    }

    private static let listViewportSpace = "PickyHUDDockListViewport"

    private func revealActiveSession(using proxy: ScrollViewProxy) {
        guard let activeSessionID,
              let targetID = projection.scrollTargetID(forSessionID: activeSessionID)
        else { return }
        let reduceMotion = accessibilityReduceMotion
        DispatchQueue.main.async {
            if reduceMotion {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(targetID, anchor: .center) }
            } else {
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(targetID, anchor: .center) }
            }
        }
    }

    /// One entry per top-level item: a Pickle row, or a group block (header
    /// plus inline members when expanded).
    @ViewBuilder
    private var listEntries: some View {
        let items = projection.items
        ForEach(Array(items.enumerated()), id: \.element.stableID) { index, item in
            switch item {
            case .session(let id):
                if let session = session(withID: id) {
                    sessionRow(session, container: .topLevel(index: layoutIndex(ofSession: id)))
                        .publishDockTopEntryExtent(entryID: "session:\(id)", orientation: orientation)
                        .transaction { applySlotShiftAnimation(&$0, to: item) }
                }
            case .group(let group):
                groupBlock(group, isFirst: index == 0)
                    .publishDockTopEntryExtent(entryID: "group:\(group.id)", orientation: orientation)
                    .transaction { applySlotShiftAnimation(&$0, to: item) }
            }
        }
    }

    private func session(withID id: String) -> PickyHUDDockSession? {
        sessions.first { $0.id == id }
    }

    private func layoutIndex(ofSession id: String) -> Int {
        layout.entries.firstIndex { if case .session(id) = $0 { return true } else { return false } }
            ?? layout.entries.count
    }

    // MARK: - Group block

    @ViewBuilder
    private func groupBlock(_ group: PickyDockGroup, isFirst: Bool) -> some View {
        let memberIDs = group.memberSessionIDs.filter(activeSessionIDSet.contains)
        let members = memberIDs.compactMap(session(withID:))
        let renderedMemberIDs = projection.visibleMemberIDs(inGroup: group.id)
        let header = groupHeader(group, members: members)
        let block = Group {
            if orientation == .horizontal {
                HStack(spacing: 0) {
                    header
                    if !group.isCollapsed { groupMembers(group, renderedMemberIDs: renderedMemberIDs) }
                }
                .background(
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius + 1, style: .continuous)
                        .fill(group.color.accent.opacity(group.isCollapsed ? 0 : 0.08))
                        .allowsHitTesting(false)
                )
            } else {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    header
                    if !group.isCollapsed {
                        groupMembers(group, renderedMemberIDs: renderedMemberIDs)
                            .padding(dockSide == .left ? .trailing : .leading, metrics.groupMemberIndent)
                    }
                }
                .padding(.top, isFirst ? 0 : metrics.groupHeaderTopGap)
            }
        }
        let isDraggingGroup = draggingGroupID == group.id
        let axisOrientation = orientation
        let translation = groupDragTranslation
        let startCenter = groupDragStartCenter
        block
            .id("group:\(group.id)")
            .opacity(isDraggingGroup && groupPullOutArmed ? 0.5 : 1)
            .visualEffect { content, geometry in
                // Keep the dragged block under the cursor even after the
                // preview reorders it to a new home in the same layout pass.
                let frame = geometry.frame(in: .named(PickyHUDDockRailCoordinateSpace))
                let currentHomeCenter = axisOrientation == .horizontal ? frame.midX : frame.midY
                let offset = isDraggingGroup
                    ? PickyHUDDockDragGeometry.cursorLockedOffset(
                        translation: translation,
                        dragStartCenter: startCenter,
                        currentHomeCenter: currentHomeCenter,
                        orientation: axisOrientation
                    )
                    : .zero
                return content.offset(x: offset.width, y: offset.height)
            }
            .zIndex(draggingGroupID == group.id ? 220 : 0)
            .overlay(alignment: .top) {
                if draggingGroupID == group.id && groupPullOutArmed {
                    PickyHUDDockPullOutBadge(text: L10n.t("dock.drag.remove.label"))
                        .offset(y: -18)
                }
            }
    }

    private func groupHeader(_ group: PickyDockGroup, members: [PickyHUDDockSession]) -> some View {
        let unreadCount = PickyHUDDockRowStatusPresentation.groupUnreadCount(
            members: members,
            unreadSessionIDs: unreadSessionIDs
        )
        return PickyHUDDockGroupHeaderRow(
            group: group,
            orientation: orientation,
            members: members,
            unreadCount: unreadCount,
            metrics: metrics,
            isSelected: selectedGroupID == group.id,
            isDropTargeted: dropTargetedGroupID == group.id,
            isAddPresented: isPickerPresented(anchorGroupID: group.id),
            onToggleCollapsed: { onSetDockGroupCollapsed(group.id, !group.isCollapsed) },
            onSetColor: { onSetDockGroupColor(group.id, $0) },
            onReorderBegan: { handleGroupDragBegin(groupID: group.id) },
            onReorderChanged: { handleGroupDragChanged(groupID: group.id, translation: $0) },
            onReorderEnded: { handleGroupDragEnded(groupID: group.id, translation: $0) },
            onHoverChanged: { horizontalHover(.group(group.id), inside: $0) }
        ) {
            newPicklePicker(
                anchoredTo: PickyHUDDockGroupAddButton(side: metrics.rowActionSide) {
                    showRecentPickleFolderPicker(anchorGroupID: group.id)
                },
                anchorGroupID: group.id
            )
        }
        .publishDockGroupDropFrame(groupID: group.id)
        .pickyDockGroupContextMenu(
            group: group,
            activeSessionIDs: activeSessionIDSet,
            onRename: { presentRenameDialog(for: group) },
            onSetColor: { onSetDockGroupColor(group.id, $0) },
            onUngroup: { onRemoveDockGroup(group.id, true) },
            onDeleteWithArchive: { onRemoveDockGroup(group.id, false) }
        )
        .accessibilityAction(named: Text(L10n.t("group.folder.action.rename"))) {
            presentRenameDialog(for: group)
        }
        .accessibilityAction(named: Text(L10n.t("group.list.newPickle.accessibilityLabel"))) {
            showRecentPickleFolderPicker(anchorGroupID: group.id)
        }
    }

    @ViewBuilder
    private func groupMembers(_ group: PickyDockGroup, renderedMemberIDs: [String]) -> some View {
        if renderedMemberIDs.isEmpty {
            PickyHUDDockEmptyGroupPlaceholder(
                orientation: orientation,
                metrics: metrics,
                isDropTargeted: dropTargetedGroupID == group.id,
                onCreatePickle: { showRecentPickleFolderPicker(anchorGroupID: group.id) }
            )
            .onHover { horizontalHover(.group(group.id), inside: $0) }
        } else {
            ForEach(renderedMemberIDs, id: \.self) { id in
                if let session = session(withID: id),
                   let memberIndex = group.memberSessionIDs.firstIndex(of: id) {
                    sessionRow(session, container: .group(id: group.id, memberIndex: memberIndex))
                }
            }
        }
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

    // MARK: - Session row

    private var rowSize: CGSize {
        switch orientation {
        case .vertical: CGSize(width: listCrossLength, height: metrics.rowHeight(fontScale: fontScale))
        case .horizontal: CGSize(width: horizontalCellSide, height: horizontalCellSide)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: PickyHUDDockSession, container: PickyDockContainer) -> some View {
        if draggingSessionID == session.id {
            // The dragged Pickle floats in a stable overlay; the flow keeps a
            // clear placeholder so neighbors make room at the landing spot.
            Color.clear
                .frame(
                    width: orientation == .horizontal ? rowSize.width : nil,
                    height: rowSize.height
                )
                .frame(maxWidth: orientation == .vertical ? .infinity : nil)
                .id("session:\(session.id)")
                .publishDockSlotCenter(sessionID: session.id)
        } else {
            let currentGroupID: String? = {
                if case .group(let id, _) = container { return id }
                return nil
            }()
            PickyHUDDockSessionRow(
                session: session,
                orientation: orientation,
                isActive: activeSessionID == session.id,
                isOpened: openedSessionID == session.id,
                isScreenContextArmed: screenContextTargetSessionID == session.id && !screenContextTargetSticky,
                isScreenContextSticky: screenContextTargetSessionID == session.id && screenContextTargetSticky,
                shortcutNumber: projection.shortcutNumber(forSessionID: session.id),
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                isUnread: unreadSessionIDs.contains(session.id),
                metrics: metrics,
                moveTargetGroups: layout.groups.filter { $0.id != currentGroupID },
                onMoveToGroup: { groupID in
                    let memberCount = layout.group(withID: groupID)?.memberSessionIDs.count ?? 0
                    onMoveSessionInDock(session.id, .group(id: groupID, memberIndex: memberCount))
                },
                onUngroup: currentGroupID.map { groupID in
                    { onMoveSessionInDock(session.id, .topLevel(index: ungroupDestinationIndex(groupID: groupID))) }
                },
                onOpen: { onOpenSession(session.id) },
                onToggleScreenContextTarget: { onToggleScreenContextTarget(session.id) },
                onToggleStickyScreenContextTarget: { onToggleStickyScreenContextTarget(session.id) },
                onCompact: { onCompactSession(session.id) },
                onArchive: { onArchiveSession(session.id) },
                onStop: { onStopSession(session.id) },
                onDoneFlashConsumed: { onDoneFlashConsumed(session.id) },
                onReorderHandoff: { anchorScreenPoint in
                    reorderController.begin(sessionID: session.id, anchorScreenPoint: anchorScreenPoint)
                },
                onHoverChanged: { horizontalHover(.session(session.id), inside: $0) }
            )
            .id("session:\(session.id)")
            .publishDockSlotCenter(sessionID: session.id)
        }
    }

    /// An ungrouped Pickle lands right after its former group.
    private func ungroupDestinationIndex(groupID: String) -> Int {
        guard let index = layout.entries.firstIndex(where: {
            if case .group(let group) = $0 { return group.id == groupID }
            return false
        }) else { return layout.entries.count }
        return index + 1
    }

    /// The real dragged Pickle, floating above the rail at the cursor.
    @ViewBuilder
    private var draggedFloatingRowOverlay: some View {
        if let id = draggingSessionID, let session = session(withID: id) {
            GeometryReader { geo in
                PickyHUDDockSessionRow(
                    session: session,
                    orientation: orientation,
                    isActive: activeSessionID == id,
                    isOpened: false,
                    isScreenContextArmed: false,
                    isScreenContextSticky: false,
                    shortcutNumber: nil,
                    isCommandShortcutHintVisible: false,
                    shouldFlashCompletion: false,
                    isUnread: unreadSessionIDs.contains(id),
                    metrics: metrics,
                    isDragging: true
                )
                .frame(width: rowSize.width)
                .opacity(sessionPullOutArmed ? 0.5 : 1)
                .position(floatingRowCenter(in: geo.size))

                if sessionPullOutArmed {
                    PickyHUDDockPullOutBadge(text: L10n.t("dock.drag.archive.label"))
                        .position(
                            x: floatingRowCenter(in: geo.size).x,
                            y: floatingRowCenter(in: geo.size).y - (rowSize.height / 2 + 14)
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func floatingRowCenter(in overlaySize: CGSize) -> CGPoint {
        let fallback = CGPoint(
            x: orientation == .vertical ? overlaySize.width / 2 : dragStartCenter,
            y: orientation == .vertical ? dragStartCenter : overlaySize.height / 2
        )
        return PickyHUDDockDragGeometry.floatingIconCenter(
            dragStartCenter: dragStartSourceCenter ?? fallback,
            translation: dragTranslation
        )
    }

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

    // MARK: - Session reorder

    private func handleReorderPhase(_ phase: PickyDockReorderDragController.Phase) {
        switch phase {
        case .idle:
            break
        case .dragging(let sessionID, let translation):
            if activeReorderSessionID != sessionID {
                activeReorderSessionID = sessionID
                guard handleReorderBegin(sessionID: sessionID) else {
                    // Geometry can arrive after the native handoff. Reject this
                    // pickup completely so a later pickup can retry.
                    activeReorderSessionID = nil
                    reorderController.reset()
                    return
                }
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

    @discardableResult
    private func handleReorderBegin(sessionID: String) -> Bool {
        guard baseProjection.slots.contains(where: { $0.sessionID == sessionID }),
              let sourceCenter = PickyHUDDockDragGeometry.validSourceCenter(slotCenters[sessionID])
        else { return false }
        draggingSessionID = sessionID
        pendingDropContainer = layout.container(forSessionID: sessionID)
        dragTranslation = .zero
        dragStartCenter = orientation == .vertical ? sourceCenter.y : sourceCenter.x
        dragStartSourceCenter = sourceCenter
        dragReferenceSlots = baseProjection.slots
        dragReferenceTopEntryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: baseProjection.items)
        dragReferenceCenters = slotCenters
        dragReferenceTopEntryExtents = topEntryExtents
        dragReferenceGroupDropFrames = groupDropFrames
        dragStartScrollOffset = listScrollOffset
        return true
    }

    private func handleReorderChanged(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID else { return }
        dragTranslation = translation

        if PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: dockSide)
            > PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics, orientation: orientation, fontScale: fontScale) {
            pendingDropContainer = layout.container(forSessionID: sessionID)
            scheduleSessionPullOutDwell()
            updateAutoScroll(railCursorAxis: nil)
            return
        }
        cancelSessionPullOutDwell()
        if sessionPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { sessionPullOutArmed = false }
        }

        let railCursorAxis = dragStartCenter + PickyHUDDockDragGeometry.axisDelta(translation, orientation: orientation)
        updateAutoScroll(railCursorAxis: railCursorAxis)
        let cursorAxis = PickyHUDDockAutoScrollPolicy.frozenAxis(
            cursorAxis: railCursorAxis,
            startOffset: dragStartScrollOffset,
            currentOffset: listScrollOffset
        )
        let slotCandidates: [PickyDockDropResolver.SlotCandidate] = dragReferenceSlots.compactMap { slot in
            guard let id = slot.sessionID,
                  let container = slot.container,
                  let center = dragReferenceCenters[id]
            else { return nil }
            return .init(container: container, center: orientation == .vertical ? center.y : center.x)
        }
        let topLevelInsertionCandidates = PickyHUDDockRenderPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: dragReferenceTopEntryIDs,
            referenceExtents: dragReferenceTopEntryExtents,
            draggedSessionID: sessionID,
            layout: layout
        )
        let activeSessionIDs = activeSessionIDSet
        let emptyGroupCandidates = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: dragReferenceSlots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: dragReferenceGroupDropFrames,
            topEntryExtents: dragReferenceTopEntryExtents,
            orientation: orientation,
            metrics: metrics,
            fontScale: fontScale
        )
        let nonEmptyGroupCandidates = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: dragReferenceSlots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: dragReferenceGroupDropFrames,
            topEntryExtents: dragReferenceTopEntryExtents,
            orientation: orientation,
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
            slotPitch: PickyHUDDockDragGeometry.slotPitch(orientation: orientation, metrics: metrics, fontScale: fontScale)
        )
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
            onArchiveSession(sessionID)
        } else if let destination = pendingDropContainer,
                  destination != layout.container(forSessionID: sessionID) {
            onMoveSessionInDock(sessionID, destination)
        }
        resetSessionDrag()
    }

    private func handleReorderCanceled() {
        guard draggingSessionID != nil else { return }
        cancelSessionPullOutDwell()
        sessionPullOutArmed = false
        resetSessionDrag()
        activeReorderSessionID = nil
        reorderController.reset()
    }

    private func resetSessionDrag() {
        updateAutoScroll(railCursorAxis: nil)
        draggingSessionID = nil
        pendingDropContainer = nil
        dragTranslation = .zero
        dragReferenceSlots = []
        dragReferenceTopEntryIDs = []
        dragReferenceCenters = [:]
        dragStartSourceCenter = nil
        dragReferenceTopEntryExtents = [:]
        dragReferenceGroupDropFrames = [:]
    }

    // MARK: - Group reorder

    private func handleGroupDragBegin(groupID: String) {
        guard let layoutIndex = layout.entries.firstIndex(where: { entry in
            if case .group(let group) = entry, group.id == groupID { return true }
            return false
        }) else { return }
        // Without measured geometry the drag would start from rail origin 0 and
        // jump the block to the top. Reject the pickup so a later one can retry.
        guard let extent = topEntryExtents["group:\(groupID)"], extent.isFinite else { return }
        let startCenter = extent.center
        if draggingSessionID != nil { handleReorderCanceled() }
        draggingGroupID = groupID
        groupDragStartLayoutIndex = layoutIndex
        pendingGroupTopLevelIndex = layoutIndex
        groupDragReferenceTopEntryExtents = topEntryExtents
        groupDragReferenceTopEntryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: baseProjection.items)
        groupDragTranslation = .zero
        groupDragStartCenter = startCenter
        dragStartScrollOffset = listScrollOffset
    }

    private func handleGroupDragChanged(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }
        if PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: dockSide)
            > PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics, orientation: orientation, fontScale: fontScale) {
            if !groupPullOutArmed {
                withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = true }
            }
            groupDragTranslation = translation
            updateAutoScroll(railCursorAxis: nil)
            return
        }
        if groupPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = false }
        }
        groupDragTranslation = translation

        let railCursorAxis = groupDragStartCenter + PickyHUDDockDragGeometry.axisDelta(translation, orientation: orientation)
        updateAutoScroll(railCursorAxis: railCursorAxis)
        let cursorAxis = PickyHUDDockAutoScrollPolicy.frozenAxis(
            cursorAxis: railCursorAxis,
            startOffset: dragStartScrollOffset,
            currentOffset: listScrollOffset
        )
        guard let nearestLayoutIndex = PickyHUDDockRenderPolicy.nearestLayoutEntryIndex(
            cursorAxis: cursorAxis,
            visibleTopEntryIDs: groupDragReferenceTopEntryIDs,
            referenceExtents: groupDragReferenceTopEntryExtents,
            layout: layout
        ) else { return }
        if pendingGroupTopLevelIndex != nearestLayoutIndex {
            pendingGroupTopLevelIndex = nearestLayoutIndex
        }
    }

    private func handleGroupDragEnded(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }
        let didRemove = groupPullOutArmed
        let destination = pendingGroupTopLevelIndex
        resetGroupDrag()
        if didRemove {
            let activeSessionIDs = activeSessionIDSet
            if let group = layout.group(withID: groupID),
               PickyHUDDockGroupDeletePrompt.requiresConfirmation(group: group, activeSessionIDs: activeSessionIDs) {
                // Let the block spring back before the confirmation appears.
                DispatchQueue.main.async {
                    PickyHUDDockGroupDeletePrompt.delete(group: group, activeSessionIDs: activeSessionIDs) {
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

    private func resetGroupDrag() {
        updateAutoScroll(railCursorAxis: nil)
        groupPullOutArmed = false
        groupDragTranslation = .zero
        draggingGroupID = nil
        pendingGroupTopLevelIndex = nil
        groupDragReferenceTopEntryExtents = [:]
        groupDragReferenceTopEntryIDs = []
    }

    // MARK: - Drag autoscroll

    /// Starts, keeps, or stops edge autoscroll for the current drag cursor.
    /// `nil` stops it (drag ended or the row is pulled out of the dock).
    private func updateAutoScroll(railCursorAxis: CGFloat?) {
        var direction = 0
        if let railCursorAxis, overflowLayout.needsScroll, let viewport = listViewportExtent {
            direction = PickyHUDDockAutoScrollPolicy.direction(
                cursorAxis: railCursorAxis,
                viewport: viewport,
                offset: listScrollOffset,
                contentLength: PickyHUDDockRailLayoutPolicy.listLength(
                    projection: projection,
                    activeSessionIDs: activeSessionIDSet,
                    orientation: orientation,
                    metrics: metrics,
                    fontScale: fontScale
                )
            )
        }
        guard direction != autoScrollDirection else { return }
        autoScrollDirection = direction
        autoScrollTask?.cancel()
        autoScrollTask = nil
        guard direction != 0 else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                autoScrollTick &+= 1
                try? await Task.sleep(for: PickyHUDDockAutoScrollPolicy.stepInterval)
            }
        }
    }

    private func performAutoScrollStep(using proxy: ScrollViewProxy) {
        guard autoScrollDirection != 0, let viewport = listViewportExtent else { return }
        var rowCenters: [String: CGFloat] = [:]
        for (id, center) in slotCenters {
            rowCenters["session:\(id)"] = orientation == .vertical ? center.y : center.x
        }
        let headerHalf = orientation == .vertical
            ? metrics.groupHeaderHeight(fontScale: fontScale) / 2
            : horizontalCellSide / 2
        for (entryID, extent) in topEntryExtents where entryID.hasPrefix("group:") {
            rowCenters[entryID] = extent.lower + headerHalf
        }
        guard let target = PickyHUDDockAutoScrollPolicy.targetRowID(
            direction: autoScrollDirection,
            viewport: viewport,
            rowCenters: rowCenters
        ) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(target, anchor: autoScrollDirection > 0 ? .bottom : .top)
        }
    }

    private func reresolveDragAfterScroll() {
        if let draggingSessionID {
            handleReorderChanged(sessionID: draggingSessionID, translation: dragTranslation)
        } else if let draggingGroupID {
            handleGroupDragChanged(groupID: draggingGroupID, translation: groupDragTranslation)
        }
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
        ), draggingGroupID != nil {
            resetGroupDrag()
        }
    }

    // MARK: - Resize tab

    /// The tab lives on the dock's free edge: the side facing the screen
    /// interior, where the conversation card opens.
    private var resizeTabAlignment: Alignment {
        switch dockSide {
        case .right: .leading
        case .left: .trailing
        case .bottom: .top
        case .top: .bottom
        }
    }

    private var resizeTabOffset: CGSize {
        let depth = metrics.resizeTabDepth - 0.5
        switch dockSide {
        case .right: return CGSize(width: -depth, height: 0)
        case .left: return CGSize(width: depth, height: 0)
        case .bottom: return CGSize(width: 0, height: -depth)
        case .top: return CGSize(width: 0, height: depth)
        }
    }

    /// How long the tab stays reachable after the pointer leaves the rail.
    /// The tab sticks out past the rail, so `isDockHovered` drops a moment
    /// before the pointer lands on it; without the grace, reaching the tab is
    /// a race. Keeping it hit-testable at all times instead would leave a
    /// transparent strip beside the dock that swallows clicks meant for the
    /// app underneath.
    private static let resizeTabGrace: Duration = .milliseconds(350)

    private func updateResizeTabGrace(isDockHovered hovering: Bool) {
        guard !hovering else {
            cancelResizeTabGrace()
            return
        }
        resizeTabGraceTask?.cancel()
        isResizeTabGraced = true
        resizeTabGraceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resizeTabGrace)
            guard !Task.isCancelled else { return }
            isResizeTabGraced = false
            resizeTabGraceTask = nil
        }
    }

    private func cancelResizeTabGrace() {
        resizeTabGraceTask?.cancel()
        resizeTabGraceTask = nil
        isResizeTabGraced = false
    }

    @ViewBuilder
    private var resizeTab: some View {
        let isDragging = resizeDragStartPreset != nil
        // Hit testing and the chrome frame follow visibility: an invisible tab
        // must not block the window underneath or pull focus to the HUD.
        let isVisible = expansion.isExpanded
            && (isDockHovered || isResizeTabHovered || isResizeTabGraced || isDragging)
        PickyHUDDockResizeTab(
            dockSide: dockSide,
            metrics: metrics,
            isActive: isResizeTabHovered || isDragging
        )
        .opacity(isVisible ? 1 : 0)
        .overlay {
            PickyHUDCardResizeHandleHost(
                onHoverChanged: { hovering in
                    isResizeTabHovered = hovering
                    if hovering { cancelResizeTabGrace() }
                },
                onDragChanged: handleResizeDragChanged,
                onDragEnded: { resizeDragStartPreset = nil },
                onDoubleClick: {},
                cursor: orientation == .vertical ? .resizeLeftRight : .resizeUpDown
            )
        }
        .background {
            if isVisible { PickyHUDVisibleChromeFrameReporter() }
        }
        .allowsHitTesting(isVisible)
        .offset(resizeTabOffset)
        .onDisappear { cancelResizeTabGrace() }
        .help(L10n.t("dock.resize.help"))
        .accessibilityElement()
        .accessibilityLabel(L10n.t("dock.resize.accessibility"))
        .accessibilityValue(metrics.preset.displayName)
        .accessibilityAdjustableAction { direction in
            let presets = PickyHUDDockSizePreset.allCases
            guard let index = presets.firstIndex(of: metrics.preset) else { return }
            switch direction {
            case .increment where index + 1 < presets.count: onChangeDockSizePreset(presets[index + 1])
            case .decrement where index > 0: onChangeDockSizePreset(presets[index - 1])
            default: break
            }
        }
    }

    /// Steps live while dragging: every `stepDistance` of pointer travel away
    /// from the drag's starting preset applies the next one, so the dock
    /// follows the pointer without reacting to a twitch.
    private func handleResizeDragChanged(_ screenDelta: CGPoint) {
        if resizeDragStartPreset == nil { resizeDragStartPreset = metrics.preset }
        guard let start = resizeDragStartPreset else { return }
        let next = PickyHUDDockResizePolicy.preset(
            start: start,
            current: metrics.preset,
            screenDelta: screenDelta,
            dockSide: dockSide
        )
        if next != metrics.preset { onChangeDockSizePreset(next) }
    }

    // MARK: - Move handle

    /// Drag handle inside the dock capsule's top (or leading) row. Backed by
    /// an `NSViewRepresentable` so AppKit owns hit testing and cursor rects.
    private var dockAnchorHandle: some View {
        let isActive = isHandleHovered || isHandleDragging
        let notchWidth = orientation == .horizontal
            ? horizontalCellSide
            : PickyHUDDockCompactLayout.iconColumnWidth
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
        .frame(
            width: orientation == .horizontal ? metrics.horizontalCompactHandleWidth : notchWidth,
            height: orientation == .horizontal ? notchWidth : metrics.handleInset
        )
        .overlay(alignment: orientation == .horizontal ? .leading : .top) {
            if orientation == .vertical {
                Capsule().fill(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: 14, height: metrics.handleHeight)
                    .padding(.top, DS.Spacing.space2) // design-token-exception: compact rail grip from the approved A proposal.
                    .allowsHitTesting(false)
            } else {
                Capsule().fill(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: metrics.handleHeight, height: 14) // design-token-exception: compact horizontal grip from the approved A proposal.
                    .frame(width: metrics.horizontalCompactHandleWidth, height: horizontalCellSide)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear {
            isHandleHovered = false
            if isHandleDragging {
                isHandleDragging = false
                onDockHandleDragEnded()
            }
        }
        .accessibilityLabel(L10n.t("dock.handle.accessibility"))
        .accessibilityHint(L10n.t("dock.handle.help"))
    }
}
