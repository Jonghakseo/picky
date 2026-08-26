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

struct PickyHUDDockGroupListPanelRoot: View {
    let group: PickyDockGroup
    let rows: [PickyHUDDockGroupListRowModel]
    let unreadSessionIDs: Set<String>
    let openedSessionID: String?
    let isCommandShortcutHintVisible: Bool
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    var body: some View {
        PickyHUDDockGroupListView(
            group: group,
            rows: rows,
            unreadSessionIDs: unreadSessionIDs,
            openedSessionID: openedSessionID,
            isCommandShortcutHintVisible: isCommandShortcutHintVisible,
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
            onUngroupSession: onUngroupSession
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("group.list.accessibility.label", group.displayName, rows.count))
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
            ForEach(rows) { row in
                // List-relative Command-number routing arrives with keyboard navigation.
                PickyHUDDockGroupListRow(
                    row: row,
                    isUnread: unreadSessionIDs.contains(row.id),
                    isSelected: openedSessionID == row.id,
                    shortcutNumber: nil,
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
                    onUngroup: { onUngroupSession(row.id) }
                )
            }
        }
        if PickyHUDDockGroupListPolicy.needsScroll(memberCount: rows.count) {
            ScrollView(.vertical, showsIndicators: true) { content }
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
                onUngroup: onUngroup
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
    }
}
