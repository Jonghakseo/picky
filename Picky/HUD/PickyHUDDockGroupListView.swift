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
            onCreatePickle: onCreatePickle
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
        .accessibilityLabel("\(group.displayName), \(rows.count) Pickles")
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
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                PickyHUDDockGroupListRow(
                    row: row,
                    isUnread: unreadSessionIDs.contains(row.id),
                    isSelected: openedSessionID == row.id,
                    shortcutNumber: isCommandShortcutHintVisible && index < 9 ? index + 1 : nil,
                    minimumHeight: metrics.groupListRowHeight,
                    relativeTime: Self.relativeDateFormatter.localizedString(for: row.updatedAt, relativeTo: Date()),
                    onSelect: { onSelectSession(row.id) }
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
        Button("New Pickle here", action: onCreatePickle)
            .buttonStyle(.plain)
            .pickyFont(size: 12, weight: .medium)
            .foregroundStyle(DS.Colors.accentText)
            .frame(maxWidth: .infinity, minHeight: metrics.groupListRowHeight)
            .background(DS.Colors.surface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .hoverAffordance()
            .accessibilityHint("Create a Pickle in this group")
    }
}

private struct PickyHUDDockGroupListRow: View {
    let row: PickyHUDDockGroupListRowModel
    let isUnread: Bool
    let isSelected: Bool
    let shortcutNumber: Int?
    let minimumHeight: CGFloat
    let relativeTime: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
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
                        .accessibilityLabel("Unread")
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
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .accessibilityLabel(row.title)
        .accessibilityValue("\(row.session.status.rawValue), \(row.subtitle(relativeTime: relativeTime))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
