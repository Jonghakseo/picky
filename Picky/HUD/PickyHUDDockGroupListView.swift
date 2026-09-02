//
//  PickyHUDDockGroupListView.swift
//  Picky
//
//  Transient member list for a collapsed dock group. The list is hosted in a
//  child NSPanel so it never changes the HUD panel's footprint.
//

import Combine
import SwiftUI

struct PickyHUDDockGroupListSurface<FillShape: Shape>: View {
    let shape: FillShape

    var body: some View {
        // Mini previews live inside the HUD panel while group lists live in a
        // detached child panel. A translucent material samples a different
        // backdrop in those two windows, so the same token can render as two
        // visibly different colors. This shared semantic fill is intentionally
        // opaque to keep both surfaces identical across hosting boundaries.
        shape.fill(DS.Colors.surface1)
    }
}

@MainActor
enum PickyHUDDockGroupListRelativeTimePresentation {
    private static let formatter = RelativeDateTimeFormatter()

    /// Returns `nil` when the session has no known timestamp, so the row can
    /// omit the field instead of rendering a fabricated age.
    static func text(for updatedAt: Date?, relativeTo now: Date = .now) -> String? {
        guard let updatedAt else { return nil }
        guard abs(updatedAt.timeIntervalSince(now)) >= 60 else {
            return L10n.t("hud.groupList.time.justNow")
        }
        return formatter.localizedString(for: updatedAt, relativeTo: now)
    }
}

@MainActor
struct PickyHUDDockGroupListRowModel: Identifiable {
    let session: PickyHUDDockSession
    let updatedAt: Date?

    var id: String { session.id }

    var title: String {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty else { return session.title }
        if let cwdLeaf, !cwdLeaf.isEmpty { return cwdLeaf }
        return "Pickle"
    }

    var cwdLeaf: String? {
        guard let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty,
              cwd != "/"
        else { return nil }
        let leaf = URL(fileURLWithPath: cwd).lastPathComponent
        return leaf.isEmpty || leaf == "/" ? nil : leaf
    }

}

/// Stable render data for one open child panel. The overlay manager updates
/// this object in place so SwiftUI preserves scroll, hover, and drag state
/// through unrelated dock snapshots.
@MainActor
struct PickyHUDDockGroupListPanelContent {
    let group: PickyDockGroup
    let rows: [PickyHUDDockGroupListRowModel]
    let unreadSessionIDs: Set<String>
    let openedSessionID: String?
    let metrics: PickyHUDDockMetrics
    let moveTargetGroups: [PickyDockGroup]
    let screenContextTargetSessionID: String?
    let screenContextTargetSticky: Bool
}

@MainActor
final class PickyHUDDockGroupListLiveMembership {
    private(set) var rowIDs: [String]

    init(rowIDs: [String]) {
        self.rowIDs = rowIDs
    }

    func update(rowIDs: [String]) {
        self.rowIDs = rowIDs
    }
}

@MainActor
final class PickyHUDDockGroupListPanelModel: ObservableObject {
    @Published private(set) var content: PickyHUDDockGroupListPanelContent
    /// App-level drag monitors outlive an individual SwiftUI value. This
    /// reference remains current even in the gap before the next render pass.
    let liveMembership: PickyHUDDockGroupListLiveMembership

    init(content: PickyHUDDockGroupListPanelContent) {
        self.content = content
        self.liveMembership = PickyHUDDockGroupListLiveMembership(rowIDs: content.rows.map(\.id))
    }

    func update(content: PickyHUDDockGroupListPanelContent) {
        liveMembership.update(rowIDs: content.rows.map(\.id))
        self.content = content
    }
}

enum PickyHUDDockGroupListSelectionAction: Equatable {
    case open(sessionID: String)
    case close(sessionID: String)
}

enum PickyHUDDockGroupListInteractionPolicy {
    static func selectionResult(
        sessionID: String,
        openedSessionID: String?,
        openGroupID: String?
    ) -> (sessionAction: PickyHUDDockGroupListSelectionAction, openGroupID: String?) {
        let sessionAction: PickyHUDDockGroupListSelectionAction = openedSessionID == sessionID
            ? .close(sessionID: sessionID)
            : .open(sessionID: sessionID)
        return (
            sessionAction,
            PickyHUDDockGroupListOpenPolicy.afterSelectingRow(openGroupID: openGroupID)
        )
    }

    static func openGroupIDAfterDockSideChanged() -> String? {
        PickyHUDDockGroupListOpenPolicy.afterAnchorInvalidated()
    }
}

/// Pure header-edit decisions stay independent of SwiftUI focus timing and the
/// dock-layout persistence controller. An empty committed name is intentional:
/// `PickyDockGroup.displayName` supplies the localized Untitled fallback.
enum PickyHUDDockGroupListHeaderEditPolicy {
    static func committedName(
        draft: String,
        currentStoredName: String,
        shouldCommit: Bool
    ) -> String? {
        guard shouldCommit else { return nil }
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrent = currentStoredName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDraft == trimmedCurrent ? nil : trimmedDraft
    }

    static func colorMenuItems(currentColor: PickyDockGroupColor) -> [ColorMenuItem] {
        PickyDockGroupColor.palette.map { ColorMenuItem(color: $0, isSelected: $0 == currentColor) }
    }

    struct ColorMenuItem: Equatable, Identifiable {
        let color: PickyDockGroupColor
        let isSelected: Bool

        var id: PickyDockGroupColor { color }
    }
}

/// Converts a panel origin expressed in the HUD root's top-left coordinate
/// system into AppKit's screen-space, bottom-left frame.
enum PickyHUDDockGroupListScreenLayout {
    static func screenFrame(
        hudPanelFrame: CGRect,
        swiftUIOrigin: CGPoint,
        panelSize: CGSize
    ) -> CGRect {
        CGRect(
            x: hudPanelFrame.minX + swiftUIOrigin.x,
            y: hudPanelFrame.maxY - swiftUIOrigin.y - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    static func hudRootBounds(visibleFrame: CGRect, hudPanelFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.minX - hudPanelFrame.minX,
            y: hudPanelFrame.maxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    /// The child hosting view fills its NSPanel at `(0, 0)`, and this panel
    /// root owns `PickyHUDDockGroupListCoordinateSpace`. Its top-left local
    /// coordinates therefore match this conversion exactly.
    static func panelLocalPoint(screenPoint: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(
            x: screenPoint.x - panelFrame.minX,
            y: panelFrame.maxY - screenPoint.y
        )
    }

    static func screenFrame(panelLocalFrame: CGRect, panelFrame: CGRect) -> CGRect {
        CGRect(
            x: panelFrame.minX + panelLocalFrame.minX,
            y: panelFrame.maxY - panelLocalFrame.maxY,
            width: panelLocalFrame.width,
            height: panelLocalFrame.height
        )
    }
}

struct PickyHUDDockGroupListPromotionRequest {
    let token: UUID
    let session: PickyHUDDockSession
    let sourceGroupID: String
    let sourceRowScreenFrame: CGRect
    let pointerScreenPoint: CGPoint
    let referenceRowIDs: [String]
}

let PickyHUDDockGroupListCoordinateSpace = "PickyHUDDockGroupList"

struct PickyHUDDockGroupListRowCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PickyHUDDockGroupListRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Rows always measure on Y: the list is vertical even when the dock is
    /// horizontal, so the rail's orientation branch does not apply here.
    func publishDockGroupListRowCenter(sessionID: String) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(PickyHUDDockGroupListCoordinateSpace))
                Color.clear
                    .preference(key: PickyHUDDockGroupListRowCenterPreferenceKey.self, value: [sessionID: frame.midY])
                    .preference(key: PickyHUDDockGroupListRowFramePreferenceKey.self, value: [sessionID: frame])
            }
        }
    }
}

struct PickyHUDDockGroupListPanelRoot: View {
    @ObservedObject var model: PickyHUDDockGroupListPanelModel
    let displayID: CGDirectDisplayID
    @ObservedObject var focusStore: PickyHUDDockGroupListFocusStore
    let onSelectSession: (String) -> Void
    let onCreatePickle: () -> Void
    let onToggleScreenContextTarget: (String) -> Void
    let onToggleStickyScreenContextTarget: (String) -> Void
    let onCompactSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onStopSession: (String) -> Void
    let onMoveSessionToGroup: (String, String) -> Void
    let onUngroupSession: (String) -> Void
    let onReorderSession: (_ sessionID: String, _ visibleIndex: Int) -> Void
    let onBeginGroupNameEditing: () -> Void
    let onEndGroupNameEditing: () -> Void
    let onRenameGroup: (String, String) -> Void
    let onSetGroupColor: (String, PickyDockGroupColor) -> Void
    let convertScreenPointToPanel: (CGPoint) -> CGPoint
    var panelScreenFrame: () -> CGRect = { .zero }
    var onPromoteRowDrag: (PickyHUDDockGroupListPromotionRequest) -> Bool = { _ in false }
    var onFinishPromotedRowDrag: (UUID) -> Bool = { _ in false }
    @ObservedObject var externalDragPresentationStore = PickyHUDDockExternalDragRailPresentationStore()

    @Environment(\.pickyAppFontScale) private var fontScale

    private var panelSize: CGSize {
        PickyHUDDockGroupListPolicy.panelSize(
            group: model.content.group,
            rows: model.content.rows,
            unreadSessionIDs: model.content.unreadSessionIDs,
            metrics: model.content.metrics,
            fontScale: fontScale,
            relativeTime: { PickyHUDDockGroupListRelativeTimePresentation.text(for: $0) }
        )
    }

    var body: some View {
        let content = model.content
        PickyHUDDockGroupListView(
            group: content.group,
            rows: content.rows,
            unreadSessionIDs: content.unreadSessionIDs,
            openedSessionID: content.openedSessionID,
            highlightedRowID: focusStore.focus(for: displayID).highlightedRowID,
            metrics: content.metrics,
            onSelectSession: onSelectSession,
            onCreatePickle: onCreatePickle,
            moveTargetGroups: content.moveTargetGroups,
            screenContextTargetSessionID: content.screenContextTargetSessionID,
            screenContextTargetSticky: content.screenContextTargetSticky,
            onToggleScreenContextTarget: onToggleScreenContextTarget,
            onToggleStickyScreenContextTarget: onToggleStickyScreenContextTarget,
            onCompactSession: onCompactSession,
            onArchiveSession: onArchiveSession,
            onStopSession: onStopSession,
            onMoveSessionToGroup: onMoveSessionToGroup,
            onUngroupSession: onUngroupSession,
            onReorderSession: onReorderSession,
            onBeginGroupNameEditing: onBeginGroupNameEditing,
            onEndGroupNameEditing: onEndGroupNameEditing,
            onRenameGroup: onRenameGroup,
            onSetGroupColor: onSetGroupColor,
            liveRowIDs: { model.liveMembership.rowIDs },
            convertScreenPointToPanel: convertScreenPointToPanel,
            panelScreenFrame: panelScreenFrame,
            onPromoteRowDrag: onPromoteRowDrag,
            onFinishPromotedRowDrag: onFinishPromotedRowDrag,
            externalDragPresentationStore: externalDragPresentationStore
        )
        .frame(width: panelSize.width, height: panelSize.height)
    }
}

struct PickyHUDDockGroupListView: View {
    let group: PickyDockGroup
    let rows: [PickyHUDDockGroupListRowModel]
    let unreadSessionIDs: Set<String>
    let openedSessionID: String?
    let highlightedRowID: String?
    let metrics: PickyHUDDockMetrics
    let onSelectSession: (String) -> Void
    let onCreatePickle: () -> Void
    let moveTargetGroups: [PickyDockGroup]
    let screenContextTargetSessionID: String?
    let screenContextTargetSticky: Bool
    let onToggleScreenContextTarget: (String) -> Void
    let onToggleStickyScreenContextTarget: (String) -> Void
    let onCompactSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onStopSession: (String) -> Void
    let onMoveSessionToGroup: (String, String) -> Void
    let onUngroupSession: (String) -> Void
    let onReorderSession: (_ sessionID: String, _ visibleIndex: Int) -> Void
    /// These default callbacks keep offscreen production-component galleries
    /// independent of the overlay manager's persistence wiring.
    var onBeginGroupNameEditing: () -> Void = { }
    var onEndGroupNameEditing: () -> Void = { }
    var onRenameGroup: (String, String) -> Void = { _, _ in }
    var onSetGroupColor: (String, PickyDockGroupColor) -> Void = { _, _ in }
    /// Production uses the current time. Offscreen render fixtures inject a
    /// fixed reference so their row metadata remains deterministic.
    var relativeTime: (Date?) -> String? = {
        PickyHUDDockGroupListRelativeTimePresentation.text(for: $0)
    }
    /// Reads identity from the stable panel model, not the SwiftUI value
    /// captured by app-level drag monitors.
    let liveRowIDs: () -> [String]
    /// Screen point to panel-local point. The overlay manager owns the child
    /// panel, so it is the only place that knows the live frame.
    let convertScreenPointToPanel: (CGPoint) -> CGPoint
    var panelScreenFrame: () -> CGRect = { .zero }
    var onPromoteRowDrag: (PickyHUDDockGroupListPromotionRequest) -> Bool = { _ in false }
    var onFinishPromotedRowDrag: (UUID) -> Bool = { _ in false }
    @ObservedObject var externalDragPresentationStore = PickyHUDDockExternalDragRailPresentationStore()

    @State private var rowCenters: [String: CGFloat] = [:]
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingRowID: String?
    /// Ordered visible membership frozen at pickup. Row centers and insertion
    /// markers are meaningful only for this exact identity/order structure.
    @State private var dragReferenceRowIDs: [String] = []
    @State private var dragInsertionMarkerIndex: Int?
    @State private var isLeavingGroup = false
    @State private var dragToken: UUID?
    @State private var dragLease = PickyHUDDockGroupListDragLease()
    @State private var scrollController = PickyHUDDockGroupListScrollController()
    @State private var dragAutoScrollTicker = PickyHUDDockGroupListDragAutoScrollTicker()
    @State private var dragMonitors: [Any] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pickyAppFontScale) private var fontScale

    private var panelSize: CGSize {
        PickyHUDDockGroupListPolicy.panelSize(
            group: group,
            rows: rows,
            unreadSessionIDs: unreadSessionIDs,
            metrics: metrics,
            fontScale: fontScale,
            relativeTime: relativeTime
        )
    }

    private var rowHeight: CGFloat {
        PickyHUDDockGroupListPolicy.rowHeight(metrics: metrics, fontScale: fontScale)
    }

    var body: some View {
        VStack(spacing: metrics.groupListHeaderBottomSpacing) {
            header
            memberRows
        }
        .padding(metrics.groupListPanelPadding)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: metrics.groupListPanelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.groupListPanelCornerRadius, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .overlay { insertionMarker }
        .coordinateSpace(name: PickyHUDDockGroupListCoordinateSpace)
        .onPreferenceChange(PickyHUDDockGroupListRowCenterPreferenceKey.self) { centers in
            rowCenters = centers
        }
        .onPreferenceChange(PickyHUDDockGroupListRowFramePreferenceKey.self) { frames in
            rowFrames = frames
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            // A status/title/unread update leaves the identity structure alone,
            // but any member add, removal, or reorder invalidates frozen drag
            // geometry before mouse-up can commit against stale row centers.
            if draggingRowID != nil,
               PickyHUDDockGroupListDragPolicy.shouldCancelDrag(
                   referenceRowIDs: dragReferenceRowIDs,
                   currentRowIDs: ids
               ) {
                resetDrag()
            }
        }
        .onDisappear { resetDrag() }
        .onReceive(dragAutoScrollTicker.ticks) { autoScroll(at: $0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("group.list.accessibility.label", group.displayName, rows.count))
    }

    /// The row's click host is an AppKit view that swallows mouse events, so a
    /// SwiftUI drag gesture would never fire here. Rows hand the drag off the
    /// same way rail tiles do, and this controller tracks it from app-level
    /// monitors until mouse-up.
    private func beginRowDrag(rowID: String) {
        guard draggingRowID == nil, externalDragPresentationStore.presentation == nil else { return }
        let token = UUID()
        guard dragLease.begin(token: token) else { return }
        draggingRowID = rowID
        dragToken = token
        dragReferenceRowIDs = rows.map(\.id)
        dragInsertionMarkerIndex = rows.firstIndex(where: { $0.id == rowID })
        isLeavingGroup = false
        scrollController.resetClock()
        dragAutoScrollTicker.setDragging(true)
        guard installDragMonitors(rowID: rowID, token: token) else {
            resetDrag(token: token)
            return
        }
    }

    private func installDragMonitors(rowID: String, token: UUID) -> Bool {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }
        removeDragMonitors()
        let handleMove: (NSEvent) -> Void = { _ in
            guard dragLease.ownsList(token: token) else { return }
            updateDragState(rowID: rowID, token: token, location: currentPanelPoint())
        }
        let handleUp: (NSEvent) -> Void = { _ in
            guard dragLease.ownsList(token: token) else { return }
            commitDrag(rowID: rowID, token: token, location: currentPanelPoint())
        }
        let installed: [Any?] = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { event in
                handleMove(event)
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
                handleUp(event)
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: handleMove),
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: handleUp),
        ]
        guard let completeSet = PickyHUDDockGroupListDragMonitorPolicy.completeSet(
            from: installed,
            remove: { NSEvent.removeMonitor($0) }
        ) else { return false }
        dragMonitors = completeSet
        return true
    }

    private func removeDragMonitors() {
        for monitor in dragMonitors { NSEvent.removeMonitor(monitor) }
        dragMonitors = []
    }

    private func currentPanelPoint() -> CGPoint {
        convertScreenPointToPanel(NSEvent.mouseLocation)
    }

    private var panelBounds: CGRect {
        CGRect(origin: .zero, size: panelSize)
    }

    private func updateDragState(rowID: String, token: UUID, location: CGPoint) {
        // A dock snapshot can change between SwiftUI render passes. Validate
        // synchronously before consuming frozen centers so a mouse-up in that
        // gap cannot commit against an obsolete membership order.
        guard PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: dragReferenceRowIDs,
            currentRowIDs: liveRowIDs()
        ) else {
            resetDrag()
            return
        }
        let isWithinReorderLane = PickyHUDDockGroupListDragPolicy.isWithinReorderLane(
            pointerX: location.x,
            panelWidth: panelBounds.width
        )
        isLeavingGroup = !isWithinReorderLane
        if isWithinReorderLane {
            // Keep the live ForEach in stored order. Reordering those views on
            // every pointer event made SwiftUI animate changing row frames;
            // the marker communicates the same drop target without layout shift.
            dragInsertionMarkerIndex = rawInsertionIndex(pointerY: location.y)
        } else {
            promoteRowDrag(rowID: rowID, token: token)
        }
    }

    private func autoScroll(at date: Date) {
        guard let rowID = draggingRowID else {
            scrollController.resetClock()
            return
        }
        guard PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: dragReferenceRowIDs,
            currentRowIDs: liveRowIDs()
        ) else {
            resetDrag()
            return
        }

        let location = currentPanelPoint()
        guard PickyHUDDockGroupListDragPolicy.isWithinReorderLane(
            pointerX: location.x,
            panelWidth: panelBounds.width
        ) else {
            scrollController.resetClock()
            return
        }

        guard let viewportFrame = scrollController.viewportFrame(
            convertScreenPointToPanel: convertScreenPointToPanel
        ) else {
            scrollController.resetClock()
            return
        }
        let velocity = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(
            pointerY: location.y,
            viewportFrame: viewportFrame
        )
        guard velocity != 0 else {
            scrollController.resetClock()
            return
        }
        guard let elapsed = scrollController.elapsed(since: date) else { return }

        guard elapsed > 0,
              let scrollResult = scrollController.scroll(by: velocity, elapsed: elapsed)
        else { return }

        // SwiftUI preferences arrive after the native clip view moves. Keep
        // the cached centers in the same visual coordinate space until that
        // next preference update replaces them.
        rowCenters = PickyHUDDockGroupListDragPolicy.rowCenters(
            afterVisualOffsetDelta: scrollResult.visualOffsetDelta,
            from: rowCenters
        )
        rowFrames = PickyHUDDockGroupListDragPolicy.rowFrames(
            afterVisualOffsetDelta: scrollResult.visualOffsetDelta,
            from: rowFrames
        )
        guard let dragToken, dragLease.ownsList(token: dragToken) else { return }
        updateDragState(rowID: rowID, token: dragToken, location: location)
    }

    private func rawInsertionIndex(pointerY: CGFloat) -> Int {
        let orderedIDs = rows.map(\.id)
        let centers = orderedIDs.compactMap { rowCenters[$0] }
        guard centers.count == orderedIDs.count else { return 0 }
        return PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: pointerY, rowCenters: centers)
    }

    private func insertionIndex(for rowID: String, pointerY: CGFloat) -> Int {
        let orderedIDs = rows.map(\.id)
        guard let draggedIndex = orderedIDs.firstIndex(of: rowID) else { return 0 }
        return PickyHUDDockGroupListDragPolicy.normalizedInsertionIndex(
            rawInsertionIndex(pointerY: pointerY),
            draggedRowIndex: draggedIndex
        )
    }

    private func commitDrag(rowID: String, token: UUID, location: CGPoint) {
        guard PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: dragReferenceRowIDs,
            currentRowIDs: liveRowIDs()
        ) else {
            resetDrag()
            return
        }
        let isWithinReorderLane = PickyHUDDockGroupListDragPolicy.isWithinReorderLane(
            pointerX: location.x,
            panelWidth: panelBounds.width
        )
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: isWithinReorderLane,
            insertionIndex: insertionIndex(for: rowID, pointerY: location.y),
            isDraggedRowStillPresent: liveRowIDs().contains(rowID)
        )
        switch outcome {
        case .reorder(let visibleIndex):
            resetDrag(token: token)
            onReorderSession(rowID, visibleIndex)
        case .promote:
            _ = promoteRowDrag(rowID: rowID, token: token, finishPhysicalMouseUp: true)
        case .cancel:
            resetDrag(token: token)
        }
    }

    @discardableResult
    private func promoteRowDrag(
        rowID: String,
        token: UUID,
        finishPhysicalMouseUp: Bool = false
    ) -> Bool {
        guard dragLease.transferToExternal(token: token),
              let row = rows.first(where: { $0.id == rowID }),
              let rowFrame = rowFrames[rowID]
        else {
            resetDrag(token: token)
            return false
        }
        let request = PickyHUDDockGroupListPromotionRequest(
            token: token,
            session: row.session,
            sourceGroupID: group.id,
            sourceRowScreenFrame: PickyHUDDockGroupListScreenLayout.screenFrame(
                panelLocalFrame: rowFrame,
                panelFrame: panelScreenFrame()
            ),
            pointerScreenPoint: NSEvent.mouseLocation,
            referenceRowIDs: dragReferenceRowIDs
        )
        guard onPromoteRowDrag(request) else {
            resetDrag(token: token)
            return false
        }
        // The coordinator owns terminal events now. Existing monitor callbacks
        // retain this token but fail the lease check before they can commit.
        dragLease.reset(token: token)
        resetLocalDragState()
        return !finishPhysicalMouseUp || onFinishPromotedRowDrag(token)
    }

    private func resetDrag(token: UUID? = nil) {
        if let token { dragLease.reset(token: token) }
        else if let dragToken { dragLease.reset(token: dragToken) }
        resetLocalDragState()
    }

    private func resetLocalDragState() {
        removeDragMonitors()
        draggingRowID = nil
        dragToken = nil
        dragReferenceRowIDs = []
        dragInsertionMarkerIndex = nil
        isLeavingGroup = false
        scrollController.resetClock()
        dragAutoScrollTicker.setDragging(false)
    }

    private var panelBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: metrics.groupListPanelCornerRadius,
            style: .continuous
        )
        return PickyHUDDockGroupListSurface(shape: shape)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.space1) {
            PickyHUDDockGroupListHeader(
                group: group,
                memberCount: rows.count,
                metrics: metrics,
                onBeginEditing: onBeginGroupNameEditing,
                onEndEditing: onEndGroupNameEditing,
                onRename: onRenameGroup,
                onSetColor: onSetGroupColor
            )

            Spacer(minLength: 0)

            Button(action: onCreatePickle) {
                Image(systemName: "plus")
                    .font(PickyHUDTypography.dockGroupListHeaderAddSymbol(size: metrics.groupListHeaderAddSymbolSize))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: metrics.groupListHeaderHeight, height: metrics.groupListHeaderHeight)
                    .background(DS.Colors.surface2, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverAffordance()
            .help(L10n.t("group.list.newPickle.accessibilityLabel"))
            .accessibilityLabel(L10n.t("group.list.newPickle.accessibilityLabel"))
            .accessibilityHint(L10n.t("group.list.newPickle.hint"))
        }
        .frame(maxWidth: .infinity, minHeight: metrics.groupListHeaderHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var memberRows: some View {
        let content = VStack(spacing: metrics.groupListRowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                PickyHUDDockGroupListRow(
                    row: row,
                    isUnread: unreadSessionIDs.contains(row.id),
                    isSelected: openedSessionID == row.id,
                    isHighlighted: highlightedRowID == row.id,
                    shortcutNumber: PickyHUDDockGroupListKeyboardPolicy.shortcutNumber(forRowIndex: index),
                    isLeavingGroup: draggingRowID == row.id && isLeavingGroup,
                    minimumHeight: rowHeight,
                    metrics: metrics,
                    relativeTime: relativeTime(row.updatedAt),
                    isScreenContextArmed: screenContextTargetSessionID == row.id,
                    isScreenContextSticky: screenContextTargetSessionID == row.id && screenContextTargetSticky,
                    moveTargetGroups: moveTargetGroups,
                    onSelect: { onSelectSession(row.id) },
                    onToggleScreenContextTarget: { onToggleScreenContextTarget(row.id) },
                    onToggleStickyScreenContextTarget: { onToggleStickyScreenContextTarget(row.id) },
                    onCompact: { onCompactSession(row.id) },
                    onArchive: { onArchiveSession(row.id) },
                    onStop: { onStopSession(row.id) },
                    onMoveToGroup: { onMoveSessionToGroup(row.id, $0) },
                    onUngroup: { onUngroupSession(row.id) },
                    onReorderHandoff: { _ in beginRowDrag(rowID: row.id) },
                    panelWidth: panelSize.width
                )
                .publishDockGroupListRowCenter(sessionID: row.id)
                .opacity(((draggingRowID == row.id && !isLeavingGroup)
                    || externalDragPresentationStore.presentation?.sessionID == row.id) ? 0.35 : 1)
                .zIndex(draggingRowID == row.id ? 1 : 0)
            }
        }
        .background(PickyHUDDockGroupListScrollHost(controller: scrollController))
        if PickyHUDDockGroupListPolicy.needsScroll(memberCount: rows.count) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) { content }
                    .onChange(of: highlightedRowID) { _, rowID in
                        guard let rowID else { return }
                        switch PickyHUDDockGroupListKeyboardPolicy.scrollMotion(reduceMotion: reduceMotion) {
                        case .none:
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(rowID, anchor: .center)
                            }
                        case .fast:
                            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                                proxy.scrollTo(rowID, anchor: .center)
                            }
                        }
                    }
            }
        } else {
            content
        }
    }

    private var insertionMarker: some View {
        GeometryReader { proxy in
            if let insertionMarkerY, draggingRowID != nil, !isLeavingGroup {
                Capsule(style: .continuous)
                    .fill(DS.Colors.accentText)
                    .frame(
                        width: max(0, proxy.size.width - (metrics.groupListPanelPadding * 2)),
                        height: 2
                    )
                    .position(x: proxy.size.width / 2, y: insertionMarkerY)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private var insertionMarkerY: CGFloat? {
        guard let index = dragInsertionMarkerIndex, !rows.isEmpty else { return nil }
        let orderedIDs = rows.map(\.id)
        let centers = orderedIDs.compactMap { rowCenters[$0] }
        guard centers.count == orderedIDs.count else { return nil }
        if index <= 0 { return centers[0] - (rowHeight / 2) }
        if index >= centers.count { return centers[centers.count - 1] + (rowHeight / 2) }
        return centers[index] - (rowHeight / 2)
    }

}

private struct PickyHUDDockGroupListHeader: View {
    let group: PickyDockGroup
    let memberCount: Int
    let metrics: PickyHUDDockMetrics
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    let onRename: (String, String) -> Void
    let onSetColor: (String, PickyDockGroupColor) -> Void

    @State private var isEditingName = false
    @State private var nameDraft = ""
    @State private var nameSelectionRequestID: UUID?
    @State private var isNameHovered = false
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            colorMenu
            nameControl
            Text("\(memberCount)")
                .font(PickyHUDTypography.meta)
                .foregroundStyle(DS.Colors.textSecondary)
                // The containing group-list element already announces the
                // group name and count, so this visual count stays singular.
                .accessibilityHidden(true)
        }
        .frame(minHeight: metrics.groupListHeaderHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onDisappear { finishNameEditing(commit: true) }
    }

    private var colorMenu: some View {
        ZStack {
            Circle()
                .fill(group.color.accent)
                .frame(width: metrics.groupListHeaderAccentSide, height: metrics.groupListHeaderAccentSide)

            Menu {
                ForEach(PickyHUDDockGroupListHeaderEditPolicy.colorMenuItems(currentColor: group.color)) { item in
                    Button {
                        onSetColor(group.id, item.color)
                    } label: {
                        HStack {
                            Image(nsImage: item.color.menuSwatchImage)
                            Text(item.color.localizedName)
                            if item.isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                }
            } label: {
                Color.clear
                    .frame(width: metrics.groupListHeaderHeight, height: metrics.groupListHeaderHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: metrics.groupListHeaderHeight, height: metrics.groupListHeaderHeight)
            .fixedSize()
            .help(PickyHUDDockGroupContextMenuPresentation.colorTitle)
            .accessibilityLabel(PickyHUDDockGroupContextMenuPresentation.colorTitle)
            .accessibilityValue(group.color.localizedName)
        }
        .frame(width: metrics.groupListHeaderHeight, height: metrics.groupListHeaderHeight)
        .fixedSize()
        .contentShape(Rectangle())
        .hoverAffordance()
    }

    @ViewBuilder
    private var nameControl: some View {
        if isEditingName {
            TextField("", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.labelSemibold)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, DS.Spacing.space1)
                .padding(.vertical, DS.Spacing.space1)
                .background(DS.Colors.surface3, in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous))
                .focused($isNameFieldFocused)
                .onAppear { focusAndSelectNameField() }
                .onDisappear { nameSelectionRequestID = nil }
                .onSubmit { finishNameEditing(commit: true) }
                .onExitCommand { finishNameEditing(commit: false) }
                .onChange(of: isNameFieldFocused) { _, focused in
                    if !focused && isEditingName { finishNameEditing(commit: true) }
                }
                .accessibilityLabel(PickyHUDDockGroupContextMenuPresentation.renameTitle)
                .accessibilityValue(nameDraft)
        } else {
            Button(action: beginNameEditing) {
                Text(group.displayName)
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, DS.Spacing.space1)
                    .padding(.vertical, DS.Spacing.space1)
                    .background(
                        isNameHovered ? DS.Colors.surface3 : .clear,
                        in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isNameHovered = $0 }
            .help(PickyHUDDockGroupContextMenuPresentation.renameTitle)
            .accessibilityLabel(PickyHUDDockGroupContextMenuPresentation.renameTitle)
            .accessibilityValue(group.displayName)
        }
    }

    private func beginNameEditing() {
        onBeginEditing()
        nameDraft = group.name
        isEditingName = true
    }

    private func focusAndSelectNameField() {
        let expectedWindow = NSApp.keyWindow
        let requestID = UUID()
        nameSelectionRequestID = requestID
        DispatchQueue.main.async {
            guard isEditingName, nameSelectionRequestID == requestID else { return }
            isNameFieldFocused = true
            DispatchQueue.main.async {
                let editor = PickyTitleFieldSelectionPolicy.eligibleEditor(
                    expectedWindow: expectedWindow,
                    currentKeyWindow: NSApp.keyWindow,
                    firstResponder: expectedWindow?.firstResponder,
                    isEditing: isEditingName,
                    isFocused: isNameFieldFocused,
                    isCurrentRequest: nameSelectionRequestID == requestID
                )
                editor?.selectAll(nil)
            }
        }
    }

    private func finishNameEditing(commit: Bool) {
        guard isEditingName else { return }
        let committedName = PickyHUDDockGroupListHeaderEditPolicy.committedName(
            draft: nameDraft,
            currentStoredName: group.name,
            shouldCommit: commit
        )
        isEditingName = false
        isNameFieldFocused = false
        nameSelectionRequestID = nil
        nameDraft = ""
        onEndEditing()
        if let committedName {
            onRename(group.id, committedName)
        }
    }
}

/// Owns the display-paced tick only while a row drag is active. The timer's
/// callback captures this object weakly, while teardown always invalidates the
/// timer, so an abandoned panel cannot keep either resource alive.
@MainActor
final class PickyHUDDockGroupListDragAutoScrollTicker {
    typealias TimerFactory = (@escaping (Date) -> Void) -> () -> Void

    let ticks = PassthroughSubject<Date, Never>()
    private let makeTimer: TimerFactory
    private var cancelTimer: (() -> Void)?

    var isRunning: Bool { cancelTimer != nil }

    init() {
        makeTimer = Self.makeMainRunLoopTimer
    }

    init(makeTimer: @escaping TimerFactory) {
        self.makeTimer = makeTimer
    }

    func setDragging(_ isDragging: Bool) {
        guard isDragging else {
            stop()
            return
        }
        guard cancelTimer == nil else { return }
        cancelTimer = makeTimer { [weak self] date in
            self?.ticks.send(date)
        }
    }

    func stop() {
        cancelTimer?()
        cancelTimer = nil
    }

    deinit {
        cancelTimer?()
    }

    private static func makeMainRunLoopTimer(tick: @escaping (Date) -> Void) -> () -> Void {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            tick(timer.fireDate)
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// The exact visual row displacement caused by one native clip-view move.
/// Positive values move a row down in the group's top-left coordinate space.
struct PickyHUDDockGroupListScrollResult: Equatable {
    let visualOffsetDelta: CGFloat
}

/// Holds the native scroll view that SwiftUI creates for an overflowing member
/// list. This keeps the drag path in the same AppKit coordinate space as the
/// app-level mouse monitors and applies the policy velocity without rebuilding
/// or reordering the row views.
@MainActor
final class PickyHUDDockGroupListScrollController {
    private weak var scrollView: NSScrollView?
    private var lastTick: Date?

    func attach(to scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    func detach() {
        scrollView = nil
        resetClock()
    }

    func resetClock() {
        lastTick = nil
    }

    /// Converts the native clip view's live viewport into the panel's top-left
    /// coordinate space, which is also used by the app-level pointer monitor.
    func viewportFrame(convertScreenPointToPanel: (CGPoint) -> CGPoint) -> CGRect? {
        guard let scrollView,
              let window = scrollView.window
        else { return nil }

        let clipView = scrollView.contentView
        let viewportInWindow = clipView.convert(clipView.bounds, to: nil)
        let viewportOnScreen = window.convertToScreen(viewportInWindow)
        let topLeading = convertScreenPointToPanel(
            CGPoint(x: viewportOnScreen.minX, y: viewportOnScreen.maxY)
        )
        let bottomTrailing = convertScreenPointToPanel(
            CGPoint(x: viewportOnScreen.maxX, y: viewportOnScreen.minY)
        )
        return CGRect(
            x: topLeading.x,
            y: topLeading.y,
            width: bottomTrailing.x - topLeading.x,
            height: bottomTrailing.y - topLeading.y
        ).standardized
    }

    /// Do not catch up a paused main run loop with an unexpectedly large jump.
    /// The next display-paced tick resumes the direct manipulation.
    func elapsed(since date: Date) -> TimeInterval? {
        defer { lastTick = date }
        guard let lastTick else { return nil }
        return min(max(0, date.timeIntervalSince(lastTick)), 1.0 / 15.0)
    }

    @discardableResult
    func scroll(by velocity: CGFloat, elapsed: TimeInterval) -> PickyHUDDockGroupListScrollResult? {
        guard let scrollView,
              let documentView = scrollView.documentView
        else { return nil }

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let visibleBounds = clipView.bounds
        let minimumOriginY = documentBounds.minY
        let maximumOriginY = max(minimumOriginY, documentBounds.maxY - visibleBounds.height)
        let maximumOffset = maximumOriginY - minimumOriginY
        guard maximumOffset > 0 else { return nil }

        let currentOffset = documentView.isFlipped
            ? visibleBounds.minY - minimumOriginY
            : maximumOriginY - visibleBounds.minY
        let nextOffset = PickyHUDDockGroupListDragPolicy.autoScrollPosition(
            currentOffset: currentOffset,
            velocity: velocity,
            elapsed: elapsed,
            maximumOffset: maximumOffset
        )
        guard nextOffset != currentOffset else { return nil }

        let nextOriginY = documentView.isFlipped
            ? minimumOriginY + nextOffset
            : maximumOriginY - nextOffset
        clipView.scroll(to: CGPoint(x: visibleBounds.minX, y: nextOriginY))
        scrollView.reflectScrolledClipView(clipView)

        let actualVisibleBounds = clipView.bounds
        let actualOffset = documentView.isFlipped
            ? actualVisibleBounds.minY - minimumOriginY
            : maximumOriginY - actualVisibleBounds.minY
        return PickyHUDDockGroupListScrollResult(
            visualOffsetDelta: -(actualOffset - currentOffset)
        )
    }
}

private struct PickyHUDDockGroupListScrollHost: NSViewRepresentable {
    let controller: PickyHUDDockGroupListScrollController

    func makeNSView(context: Context) -> PickyHUDDockGroupListScrollHostView {
        let view = PickyHUDDockGroupListScrollHostView()
        view.controller = controller
        view.attachController()
        return view
    }

    func updateNSView(_ nsView: PickyHUDDockGroupListScrollHostView, context: Context) {
        nsView.controller = controller
        nsView.attachController()
    }

    static func dismantleNSView(_ nsView: PickyHUDDockGroupListScrollHostView, coordinator: ()) {
        nsView.controller?.detach()
        nsView.controller = nil
    }
}

private final class PickyHUDDockGroupListScrollHostView: NSView {
    weak var controller: PickyHUDDockGroupListScrollController?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachController()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachController()
    }

    func attachController() {
        controller?.attach(to: enclosingScrollView)
    }
}

private struct PickyHUDGroupListStopAXModifier: ViewModifier {
    let isAvailable: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isAvailable {
            content.accessibilityAction(named: Text(L10n.t("group.list.action.stop")), action)
        } else {
            content
        }
    }
}

private struct PickyHUDDockGroupListQuickActionButtonStyle: ButtonStyle {
    let side: CGFloat
    let cornerRadius: CGFloat

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                configuration.isPressed || isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary
            )
            .frame(width: side, height: side)
            .background(
                configuration.isPressed ? DS.Colors.surface4 : (isHovered ? DS.Colors.surface3 : .clear),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

struct PickyHUDDockGroupListRow: View {
    let row: PickyHUDDockGroupListRowModel
    let isUnread: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let shortcutNumber: Int?
    let isLeavingGroup: Bool
    let minimumHeight: CGFloat
    let metrics: PickyHUDDockMetrics
    let relativeTime: String?
    let isScreenContextArmed: Bool
    let isScreenContextSticky: Bool
    let moveTargetGroups: [PickyDockGroup]
    let onSelect: () -> Void
    let onToggleScreenContextTarget: () -> Void
    let onToggleStickyScreenContextTarget: () -> Void
    let onCompact: () -> Void
    let onArchive: () -> Void
    let onStop: () -> Void
    let onMoveToGroup: (String) -> Void
    let onUngroup: () -> Void
    let onReorderHandoff: (NSPoint) -> Void
    var isPreview = false
    var panelWidth: CGFloat? = nil

    @StateObject private var archiveFeedback = PickyHUDArchiveHoldFeedback()
    @State private var isHovered = false

    @Environment(\.pickyAppFontScale) private var fontScale

    private var presentation: PickyHUDDockGroupListRowPresentation {
        PickyHUDDockGroupListRowPresentation.resolve(
            title: row.title,
            statusText: L10n.t("group.list.status.\(row.session.status.rawValue)"),
            cwdLeaf: row.cwdLeaf,
            relativeTime: relativeTime,
            status: row.session.status,
            canRequestCompaction: row.session.canRequestDockCompaction
        )
    }

    private var trailingContent: PickyHUDDockGroupListRowTrailingContent {
        PickyHUDDockGroupListRowTrailingContent.resolve(
            isHovered: isHovered,
            isHighlighted: isHighlighted,
            shortcutNumber: shortcutNumber
        )
    }

    private var rowInteractionHost: some View {
        PickyHUDDockIconClickHost(
            onHoverChanged: { isHovered = $0 },
            onOpen: onSelect,
            isScreenContextArmed: isScreenContextArmed,
            isScreenContextSticky: isScreenContextSticky,
            canCompact: presentation.actionAvailability.canCompact,
            canStop: presentation.actionAvailability.canStop,
            onToggleScreenContextTarget: onToggleScreenContextTarget,
            onToggleStickyScreenContextTarget: onToggleStickyScreenContextTarget,
            onCompact: onCompact,
            onArchivePressing: archiveFeedback.setPressing,
            onArchive: {
                archiveFeedback.complete()
                onArchive()
            },
            onStop: onStop,
            moveTargetGroups: moveTargetGroups,
            onMoveToGroup: onMoveToGroup,
            onUngroup: onUngroup,
            onReorderHandoff: onReorderHandoff
        )
    }

    var body: some View {
        HStack(spacing: metrics.groupListRowContentSpacing) {
            statusGlyph
                .frame(width: metrics.groupListRowGlyphSide, height: metrics.groupListRowGlyphSide)
                .overlay {
                    if !isPreview {
                        PickyHUDArchiveHoldProgressRing(
                            isPressing: archiveFeedback.isPressing,
                            progress: archiveFeedback.progress,
                            side: metrics.groupListRowGlyphSide
                        )
                    }
                }
            VStack(alignment: .leading, spacing: metrics.groupListRowVerticalPadding) {
                Text(row.title)
                    .font(PickyHUDTypography.bodyCompact)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(presentation.subtitle)
                    .font(PickyHUDTypography.meta)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(
                width: isPreview ? nil : PickyHUDDockGroupListPolicy.titleColumnWidth(
                    metrics: metrics,
                    isUnread: isUnread,
                    fontScale: fontScale,
                    panelWidth: panelWidth
                ),
                alignment: .leading
            )
            .frame(maxWidth: isPreview ? .infinity : nil, alignment: .leading)
            if isUnread {
                Circle()
                    .fill(DS.Colors.notification)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            if !isPreview {
                trailingRail
                    .frame(
                        width: PickyHUDDockGroupListPolicy.trailingRailWidth(metrics: metrics),
                        alignment: .trailing
                    )
            }
        }
        .padding(.horizontal, metrics.groupListRowHorizontalPadding)
        .padding(.vertical, metrics.groupListRowVerticalPadding)
        .frame(minHeight: minimumHeight)
        .contentShape(RoundedRectangle(cornerRadius: metrics.groupListRowCornerRadius, style: .continuous))
        .background(rowBackground)
        .overlay {
            if !isPreview {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        rowInteractionHost
                            .frame(
                                width: PickyHUDDockGroupListPolicy.clickHostWidth(
                                    metrics: metrics,
                                    isUnread: isUnread,
                                    fontScale: fontScale,
                                    panelWidth: panelWidth
                                ),
                                height: proxy.size.height,
                                alignment: .leading
                            )
                        rowInteractionHost
                            .frame(
                                width: PickyHUDDockGroupListPolicy.trailingPaddingClickHostWidth(metrics: metrics),
                                height: proxy.size.height
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isPreview, isLeavingGroup {
                Text(L10n.t("group.list.drag.leaveGroup"))
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundStyle(DS.Colors.accentText)
                    .padding(.horizontal, DS.Spacing.space2)
                    .padding(.vertical, DS.Spacing.space1)
                    .background(DS.Colors.surface3, in: RoundedRectangle(cornerRadius: metrics.groupListRowCornerRadius, style: .continuous))
                    .padding(DS.Spacing.space1)
                    .accessibilityHidden(true)
            }
        }
        .onHover { if !isPreview { isHovered = $0 } }
        .onDisappear { archiveFeedback.cancel() }
        .help(row.title)
        .accessibilityHidden(isPreview)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(L10n.t("group.list.action.open")), onSelect)
        .accessibilityAction(named: Text(L10n.t("group.list.menu.ungroup")), onUngroup)
        .accessibilityAction(named: Text(L10n.t("group.list.action.archive")), onArchive)
        .modifier(
            PickyHUDGroupListStopAXModifier(
                isAvailable: presentation.accessibilityActions.contains(.stop),
                action: onStop
            )
        )
    }

    @ViewBuilder
    private var trailingRail: some View {
        switch trailingContent {
        case .shortcut(let number):
            Text("⌘\(number)")
                .font(PickyHUDTypography.badgeSemibold)
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
        case .quickActions:
            HStack(spacing: metrics.groupListRowQuickActionSpacing) {
                quickAction(
                    symbol: "rectangle.portrait.and.arrow.forward",
                    label: L10n.t("group.list.menu.ungroup"),
                    action: onUngroup
                )
                quickAction(
                    symbol: "archivebox",
                    label: L10n.t("group.list.action.archive"),
                    action: onArchive
                )
            }
        case .empty:
            Color.clear
        }
    }

    private func quickAction(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(
                    PickyHUDTypography.dockGroupListQuickActionSymbol(
                        size: metrics.groupListRowQuickActionSymbolSize
                    )
                )
        }
        .buttonStyle(
            PickyHUDDockGroupListQuickActionButtonStyle(
                side: metrics.groupListRowQuickActionSide,
                cornerRadius: metrics.groupListRowCornerRadius
            )
        )
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        let color = PickyDockPickleStatusVisual.color(row.session.status)
        if let asset = PickyDockPickleStatusVisual.statusAssetName(row.session.status) {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(color)
                .scaledToFit()
        } else {
            PickleLogoGlyph()
                .fill(color, style: FillStyle(eoFill: true))
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: metrics.groupListRowCornerRadius, style: .continuous)
            .fill(
                isHighlighted
                    ? DS.Colors.surface4
                    : (isSelected ? DS.Colors.accentSubtle : (isHovered ? DS.Colors.surface3 : .clear))
            )
    }
}
