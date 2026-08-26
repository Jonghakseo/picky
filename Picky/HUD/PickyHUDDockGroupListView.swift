//
//  PickyHUDDockGroupListView.swift
//  Picky
//
//  Transient member list for a collapsed dock group. The list is hosted in a
//  child NSPanel so it never changes the HUD panel's footprint.
//

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
    let group: PickyDockGroup
    let rows: [PickyHUDDockGroupListRowModel]
    let unreadSessionIDs: Set<String>
    let openedSessionID: String?
    let isCommandShortcutHintVisible: Bool
    let displayID: CGDirectDisplayID
    @ObservedObject var focusStore: PickyHUDDockGroupListFocusStore
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
    let convertScreenPointToPanel: (CGPoint) -> CGPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    var body: some View {
        PickyHUDDockGroupListView(
            group: group,
            rows: rows,
            unreadSessionIDs: unreadSessionIDs,
            openedSessionID: openedSessionID,
            isCommandShortcutHintVisible: isCommandShortcutHintVisible,
            highlightedRowID: focusStore.focus(for: displayID).highlightedRowID,
            metrics: metrics,
            onSelectSession: onSelectSession,
            onCreatePickle: onCreatePickle,
            moveTargetGroups: moveTargetGroups,
            screenContextTargetSessionID: screenContextTargetSessionID,
            screenContextTargetSticky: screenContextTargetSticky,
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
        .frame(
            width: PickyHUDDockGroupListPolicy.panelSize(memberCount: max(1, rows.count), metrics: metrics).width,
            height: PickyHUDDockGroupListPolicy.panelSize(memberCount: max(1, rows.count), metrics: metrics).height
        )
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
    let isCommandShortcutHintVisible: Bool
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
    @State private var previewRowIDs: [String] = []
    @State private var leftPanelAt: Date?
    @State private var dragMonitors: [Any] = []

    /// Rows in their drag-preview order while a drag is live, otherwise the
    /// stored order.
    private var displayedRows: [PickyHUDDockGroupListRowModel] {
        guard draggingRowID != nil, !previewRowIDs.isEmpty else { return rows }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return previewRowIDs.compactMap { rowsByID[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if rows.isEmpty {
                emptyState
            } else {
                memberRows
            }
        }
        .padding(metrics.groupListPanelPadding)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .coordinateSpace(name: PickyHUDDockGroupListCoordinateSpace)
        .onPreferenceChange(PickyHUDDockGroupListRowCenterPreferenceKey.self) { centers in
            rowCenters = centers
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            // A member that vanishes mid-drag cancels the drag instead of
            // committing a move against a row that no longer exists.
            if let draggingRowID, !ids.contains(draggingRowID) { resetDrag() }
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
        previewRowIDs = rows.map(\.id)
        leftPanelAt = nil
        installDragMonitors(rowID: rowID)
    }

    private func installDragMonitors(rowID: String) {
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
        let size = PickyHUDDockGroupListPolicy.panelSize(memberCount: max(1, rows.count), metrics: metrics)
        return CGRect(origin: .zero, size: size)
    }

    private func updateDragState(rowID: String, location: CGPoint) {
        let isInside = panelBounds.contains(location)
        if isInside {
            leftPanelAt = nil
        } else if leftPanelAt == nil {
            leftPanelAt = Date()
        }
        guard isInside else { return }
        previewRowIDs = PickyHUDDockGroupListDragPolicy.previewOrder(
            rowIDs: rows.map(\.id),
            draggedRowID: rowID,
            insertionIndex: insertionIndex(for: rowID, pointerY: location.y)
        )
    }

    private func insertionIndex(for rowID: String, pointerY: CGFloat) -> Int {
        let orderedIDs = rows.map(\.id)
        let centers = orderedIDs.compactMap { rowCenters[$0] }
        guard centers.count == orderedIDs.count, let draggedIndex = orderedIDs.firstIndex(of: rowID) else {
            return orderedIDs.firstIndex(of: rowID) ?? 0
        }
        let raw = PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: pointerY, rowCenters: centers)
        return PickyHUDDockGroupListDragPolicy.normalizedInsertionIndex(raw, draggedRowIndex: draggedIndex)
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
        previewRowIDs = []
        leftPanelAt = nil
    }

    private var panelBackground: some View {
        PickyHUDMaterialFill(
            shape: RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous),
            fallback: DS.Colors.surface2
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(group.color.accent)
                .frame(width: 8, height: 8)
            Text(group.displayName)
                .pickyFont(size: 12, weight: .medium)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(rows.count)")
                .pickyFont(size: 11, weight: .regular)
                .foregroundStyle(DS.Colors.textTertiary)
        }
        .frame(height: metrics.groupListHeaderHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var memberRows: some View {
        let content = VStack(spacing: 0) {
            ForEach(Array(displayedRows.enumerated()), id: \.element.id) { index, row in
                PickyHUDDockGroupListRow(
                    row: row,
                    isUnread: unreadSessionIDs.contains(row.id),
                    isSelected: openedSessionID == row.id,
                    isHighlighted: highlightedRowID == row.id,
                    shortcutNumber: isCommandShortcutHintVisible
                        ? PickyHUDDockGroupListKeyboardPolicy.shortcutNumber(forRowIndex: index)
                        : nil,
                    minimumHeight: metrics.groupListRowHeight,
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
                .opacity(draggingRowID == row.id ? 0.35 : 1)
                .zIndex(draggingRowID == row.id ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.12), value: previewRowIDs)
        if PickyHUDDockGroupListPolicy.needsScroll(memberCount: rows.count) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) { content }
                    .onChange(of: highlightedRowID) { _, rowID in
                        guard let rowID else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rowID, anchor: .center) }
                    }
            }
        } else {
            content
        }
    }

    private var emptyState: some View {
        Button(L10n.t("group.list.newPickle"), action: onCreatePickle)
            .buttonStyle(.plain)
            .pickyFont(size: 12, weight: .medium)
            .foregroundStyle(DS.Colors.accentText)
            .frame(maxWidth: .infinity, minHeight: metrics.groupListRowHeight)
            .background(DS.Colors.surface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        HStack(spacing: 8) {
            statusGlyph
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .pickyFont(size: 13, weight: .regular)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subtitle(relativeTime: relativeTime))
                    .pickyFont(size: 11, weight: .regular)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isUnread {
                Circle()
                    .fill(DS.Colors.notification)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .pickyFont(size: 11, weight: .regular)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: minimumHeight)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .overlay {
            PickyHUDArchiveHoldProgressRing(
                isPressing: archiveFeedback.isPressing,
                progress: archiveFeedback.progress,
                side: metrics.archiveRingSide
            )
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
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? DS.Colors.overlayCursorBlue.opacity(0.14) : (isHovered ? DS.Colors.surface3 : .clear))
            .overlay {
                // Keyboard highlight is drawn as a ring so it stays legible on
                // top of the selected row's fill.
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DS.Colors.overlayCursorBlue.opacity(0.7), lineWidth: 1)
                }
            }
    }
}
