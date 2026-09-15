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

struct PickyHUDDockGroupListRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func publishDockGroupListRowFrame(sessionID: String) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(PickyHUDDockGroupListCoordinateSpace))
                Color.clear.preference(key: PickyHUDDockGroupListRowFramePreferenceKey.self, value: [sessionID: frame])
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

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingRowID: String?
    /// Ordered visible membership frozen at pickup so an external drag never
    /// promotes after its source group has changed.
    @State private var dragReferenceRowIDs: [String] = []
    @State private var isLeavingGroup = false
    @State private var dragToken: UUID?
    @State private var dragLease = PickyHUDDockGroupListDragLease()
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
        .coordinateSpace(name: PickyHUDDockGroupListCoordinateSpace)
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
        isLeavingGroup = false
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
        // synchronously before promoting so an external drag cannot use an
        // obsolete source membership.
        guard PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: dragReferenceRowIDs,
            currentRowIDs: liveRowIDs()
        ) else {
            resetDrag()
            return
        }
        let isOutsidePanel = PickyHUDDockGroupListDragPolicy.isOutsidePanelHorizontally(
            pointerX: location.x,
            panelWidth: panelBounds.width
        )
        isLeavingGroup = isOutsidePanel
        if isOutsidePanel {
            promoteRowDrag(rowID: rowID, token: token)
        }
    }

    private func commitDrag(rowID: String, token: UUID, location: CGPoint) {
        guard PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: dragReferenceRowIDs,
            currentRowIDs: liveRowIDs()
        ) else {
            resetDrag()
            return
        }
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isOutsidePanelHorizontally: PickyHUDDockGroupListDragPolicy.isOutsidePanelHorizontally(
                pointerX: location.x,
                panelWidth: panelBounds.width
            ),
            isDraggedRowStillPresent: liveRowIDs().contains(rowID)
        )
        switch outcome {
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
        isLeavingGroup = false
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
                .publishDockGroupListRowFrame(sessionID: row.id)
                .opacity(((draggingRowID == row.id && !isLeavingGroup)
                    || externalDragPresentationStore.presentation?.sessionID == row.id) ? 0.35 : 1)
                .zIndex(draggingRowID == row.id ? 1 : 0)
            }
        }
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
            onHoverChanged: { hovering in
                isHovered = PickyHUDDockGroupListRowHoverPolicy.isHovered(
                    current: isHovered,
                    clickHostHovering: hovering
                )
            },
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
