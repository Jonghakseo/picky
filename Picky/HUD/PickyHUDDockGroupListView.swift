//
//  PickyHUDDockGroupListView.swift
//  Picky
//
//  Transient member list for a collapsed dock group. The list is hosted in a
//  child NSPanel so it never changes the HUD panel's footprint.
//

import Combine
import SwiftUI

@MainActor
struct PickyHUDDockGroupListRowModel: Identifiable {
    let session: PickyHUDDockSession
    let updatedAt: Date

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

    func subtitle(relativeTime: String) -> String {
        guard let cwdLeaf else { return relativeTime }
        return "\(cwdLeaf) · \(relativeTime)"
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
final class PickyHUDDockGroupListPanelModel: ObservableObject {
    @Published private(set) var content: PickyHUDDockGroupListPanelContent

    init(content: PickyHUDDockGroupListPanelContent) {
        self.content = content
    }

    func update(content: PickyHUDDockGroupListPanelContent) {
        self.content = content
    }
}

enum PickyHUDDockGroupListInteractionPolicy {
    static func selectionResult(sessionID: String, openGroupID: String?) -> (openedSessionID: String, openGroupID: String?) {
        (sessionID, PickyHUDDockGroupListOpenPolicy.afterSelectingRow(openGroupID: openGroupID))
    }

    static func openGroupIDAfterDockSideChanged() -> String? {
        PickyHUDDockGroupListOpenPolicy.afterAnchorInvalidated()
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
}

let PickyHUDDockGroupListCoordinateSpace = "PickyHUDDockGroupList"

struct PickyHUDDockGroupListRowCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Rows always measure on Y: the list is vertical even when the dock is
    /// horizontal, so the rail's orientation branch does not apply here.
    func publishDockGroupListRowCenter(sessionID: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PickyHUDDockGroupListRowCenterPreferenceKey.self,
                    value: [sessionID: proxy.frame(in: .named(PickyHUDDockGroupListCoordinateSpace)).midY]
                )
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
    let convertScreenPointToPanel: (CGPoint) -> CGPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pickyAppFontScale) private var fontScale
    @State private var isPresented = false

    private var panelSize: CGSize {
        PickyHUDDockGroupListPolicy.panelSize(
            memberCount: max(1, model.content.rows.count),
            metrics: model.content.metrics,
            fontScale: fontScale
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
            convertScreenPointToPanel: convertScreenPointToPanel
        )
        .frame(width: panelSize.width, height: panelSize.height)
        .opacity(isPresented ? 1 : 0)
        .scaleEffect(reduceMotion ? 1 : (isPresented ? 1 : 0.98), anchor: .topLeading)
        .animation(.easeOut(duration: 0.12), value: isPresented)
        .onAppear { isPresented = true }
    }
}

struct PickyHUDDockGroupListView: View {
    private static let relativeDateFormatter = RelativeDateTimeFormatter()

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
    /// Screen point to panel-local point. The overlay manager owns the child
    /// panel, so it is the only place that knows the live frame.
    let convertScreenPointToPanel: (CGPoint) -> CGPoint

    @State private var rowCenters: [String: CGFloat] = [:]
    @State private var draggingRowID: String?
    /// Ordered visible membership frozen at pickup. Row centers and insertion
    /// markers are meaningful only for this exact identity/order structure.
    @State private var dragReferenceRowIDs: [String] = []
    @State private var dragInsertionMarkerIndex: Int?
    @State private var isLeavingGroup = false
    @State private var leftPanelAt: Date?
    @State private var dragMonitors: [Any] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pickyAppFontScale) private var fontScale

    private var panelSize: CGSize {
        PickyHUDDockGroupListPolicy.panelSize(
            memberCount: max(1, rows.count),
            metrics: metrics,
            fontScale: fontScale
        )
    }

    private var rowHeight: CGFloat {
        PickyHUDDockGroupListPolicy.rowHeight(metrics: metrics, fontScale: fontScale)
    }

    var body: some View {
        VStack(spacing: metrics.groupListHeaderBottomSpacing) {
            header
            if rows.isEmpty {
                emptyState
            } else {
                memberRows
            }
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
        guard draggingRowID == nil else { return }
        draggingRowID = rowID
        dragReferenceRowIDs = rows.map(\.id)
        dragInsertionMarkerIndex = rows.firstIndex(where: { $0.id == rowID })
        isLeavingGroup = false
        leftPanelAt = nil
        installDragMonitors(rowID: rowID)
    }

    private func installDragMonitors(rowID: String) {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        removeDragMonitors()
        let handleMove: (NSEvent) -> Void = { _ in
            updateDragState(rowID: rowID, location: currentPanelPoint())
        }
        let handleUp: (NSEvent) -> Void = { _ in
            commitDrag(rowID: rowID, location: currentPanelPoint())
        }
        dragMonitors = [
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
        ].compactMap { $0 }
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

    private func updateDragState(rowID: String, location: CGPoint) {
        let isInside = panelBounds.contains(location)
        isLeavingGroup = !isInside
        if isInside {
            leftPanelAt = nil
            // Keep the live ForEach in stored order. Reordering those views on
            // every pointer event made SwiftUI animate changing row frames;
            // the marker communicates the same drop target without layout shift.
            dragInsertionMarkerIndex = rawInsertionIndex(pointerY: location.y)
        } else if leftPanelAt == nil {
            leftPanelAt = Date()
        }
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

    private func commitDrag(rowID: String, location: CGPoint) {
        let isInside = panelBounds.contains(location)
        let timeOutside = leftPanelAt.map { Date().timeIntervalSince($0) } ?? 0
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: isInside,
            timeOutsidePanel: timeOutside,
            insertionIndex: insertionIndex(for: rowID, pointerY: location.y),
            isDraggedRowStillPresent: rows.contains { $0.id == rowID }
        )
        resetDrag()
        switch outcome {
        case .reorder(let visibleIndex):
            onReorderSession(rowID, visibleIndex)
        case .ungroup:
            onUngroupSession(rowID)
        case .cancel:
            break
        }
    }

    private func resetDrag() {
        removeDragMonitors()
        draggingRowID = nil
        dragReferenceRowIDs = []
        dragInsertionMarkerIndex = nil
        isLeavingGroup = false
        leftPanelAt = nil
    }

    private var panelBackground: some View {
        PickyHUDMaterialFill(
            shape: RoundedRectangle(cornerRadius: metrics.groupListPanelCornerRadius, style: .continuous),
            fallback: DS.Colors.surface1
        )
    }

    private var header: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(group.color.accent)
                    .frame(width: metrics.groupListHeaderAccentSide, height: metrics.groupListHeaderAccentSide)
                Text(group.displayName)
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(rows.count)")
                    .font(PickyHUDTypography.meta)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            Button(action: onCreatePickle) {
                Image(systemName: "plus")
                    .font(.system(size: max(10, metrics.groupListHeaderHeight * 0.42), weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: metrics.groupListHeaderHeight, height: metrics.groupListHeaderHeight)
                    .background(DS.Colors.surface2, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverAffordance()
            .help(L10n.t("group.list.newPickle"))
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
                    relativeTime: Self.relativeDateFormatter.localizedString(for: row.updatedAt, relativeTo: Date()),
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
                    onReorderHandoff: { _ in beginRowDrag(rowID: row.id) }
                )
                .publishDockGroupListRowCenter(sessionID: row.id)
                .opacity(draggingRowID == row.id && !isLeavingGroup ? 0.35 : 1)
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

    private var emptyState: some View {
        Button(L10n.t("group.list.newPickle"), action: onCreatePickle)
            .buttonStyle(.plain)
            .font(PickyHUDTypography.supporting)
            .foregroundStyle(DS.Colors.accentText)
            .frame(maxWidth: .infinity, minHeight: rowHeight)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: metrics.groupListRowCornerRadius, style: .continuous))
            .hoverAffordance()
            .accessibilityHint(L10n.t("group.list.newPickle.hint"))
    }
}

private struct PickyHUDDockGroupListRow: View {
    let row: PickyHUDDockGroupListRowModel
    let isUnread: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let shortcutNumber: Int?
    let isLeavingGroup: Bool
    let minimumHeight: CGFloat
    let metrics: PickyHUDDockMetrics
    let relativeTime: String
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

    var body: some View {
        HStack(spacing: metrics.groupListRowContentSpacing) {
            statusGlyph
                .frame(width: metrics.groupListRowGlyphSide, height: metrics.groupListRowGlyphSide)
                .overlay {
                    PickyHUDArchiveHoldProgressRing(
                        isPressing: archiveFeedback.isPressing,
                        progress: archiveFeedback.progress,
                        side: metrics.groupListRowGlyphSide
                    )
                }
            VStack(alignment: .leading, spacing: metrics.groupListRowVerticalPadding) {
                Text(row.title)
                    .font(PickyHUDTypography.body)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subtitle(relativeTime: relativeTime))
                    .font(PickyHUDTypography.meta)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(
                width: PickyHUDDockGroupListPolicy.titleColumnWidth(
                    metrics: metrics,
                    isUnread: isUnread,
                    fontScale: fontScale
                ),
                alignment: .leading
            )
            if isUnread {
                Circle()
                    .fill(DS.Colors.notification)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Group {
                if let shortcutNumber {
                    Text("⌘\(shortcutNumber)")
                        .font(PickyHUDTypography.badgeSemibold)
                        .foregroundStyle(DS.Colors.textTertiary)
                } else {
                    Color.clear
                }
            }
            .frame(
                width: PickyHUDDockGroupListPolicy.shortcutHintWidth(fontScale: fontScale),
                alignment: .trailing
            )
            .accessibilityHidden(true)
        }
        .padding(.vertical, metrics.groupListRowVerticalPadding)
        .frame(minHeight: minimumHeight)
        .contentShape(RoundedRectangle(cornerRadius: metrics.groupListRowCornerRadius, style: .continuous))
        .background(rowBackground)
        .overlay {
            PickyHUDDockIconClickHost(
                onHover: { isHovered = true },
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
        .overlay(alignment: .bottomTrailing) {
            if isLeavingGroup {
                Text(L10n.t("group.list.drag.leaveGroup"))
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundStyle(DS.Colors.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.Colors.surface3, in: RoundedRectangle(cornerRadius: metrics.groupListRowCornerRadius, style: .continuous))
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovered = $0 }
        .onDisappear { archiveFeedback.cancel() }
        .help(row.title)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(L10n.t("group.list.action.open")), onSelect)
        .accessibilityAction(named: Text(L10n.t("group.list.action.archive")), onArchive)
        .accessibilityAction(named: Text(L10n.t("group.list.action.stop"))) {
            guard presentation.actionAvailability.canStop else { return }
            onStop()
        }
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
