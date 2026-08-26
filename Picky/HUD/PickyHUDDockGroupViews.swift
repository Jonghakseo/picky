//
//  PickyHUDDockGroupViews.swift
//  Picky
//
//  Slim group-rendering primitives for the dock rail. Each visual block is
//  designed to add at most ~14px of vertical chrome above its members so the
//  dock stays compact even with 3+ groups stacked.
//

import SwiftUI
import AppKit

/// Named SwiftUI coordinate space the rail establishes so child tiles can
/// publish their layout centers in a single shared frame.
let PickyHUDDockRailCoordinateSpace = "PickyHUDDockRail"
/// Root coordinate space shared with the overlay manager's child-panel geometry.
let PickyHUDVisibleChromeCoordinateSpaceName = "PickyHUDVisibleChrome"

/// Publishes every folder badge in HUD-root coordinates.
struct PickyHUDDockGroupBadgeFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Publishes each folder tile plus its label as the owning interaction area.
/// This intentionally differs from the badge-only frame used to anchor a child panel.
struct PickyHUDDockGroupInteractionFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Publishes the rail frame in the same HUD-root coordinate space as folder badges.
struct PickyHUDDockRailFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct PickyHUDDockGroupFrameReporter<Key: PreferenceKey>: View where Key.Value == [String: CGRect] {
    let groupID: String
    let key: Key.Type

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: key,
                value: [groupID: proxy.frame(in: .named(PickyHUDVisibleChromeCoordinateSpaceName))]
            )
        }
    }
}

struct PickyHUDDockRailFrameReporter: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PickyHUDDockRailFramePreferenceKey.self,
                value: proxy.frame(in: .named(PickyHUDVisibleChromeCoordinateSpaceName))
            )
        }
    }
}

extension View {
    func publishDockGroupBadgeFrame(groupID: String) -> some View {
        background(PickyHUDDockGroupFrameReporter(
            groupID: groupID,
            key: PickyHUDDockGroupBadgeFramePreferenceKey.self
        ))
    }

    func publishDockGroupInteractionFrame(groupID: String) -> some View {
        background(PickyHUDDockGroupFrameReporter(
            groupID: groupID,
            key: PickyHUDDockGroupInteractionFramePreferenceKey.self
        ))
    }

    func publishDockSlotCenter(
        sessionID: String,
        dockSide: PickyHUDDockSide
    ) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))
                let axis = dockSide.orientation == .vertical ? frame.midY : frame.midX
                Color.clear.preference(
                    key: PickyDockSlotCenterPreferenceKey.self,
                    value: [sessionID: axis]
                )
            }
        }
    }

    func publishDockTopEntryCenter(
        entryID: String,
        dockSide: PickyHUDDockSide
    ) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))
                let axis = dockSide.orientation == .vertical ? frame.midY : frame.midX
                Color.clear.preference(
                    key: PickyDockTopEntryCenterPreferenceKey.self,
                    value: [entryID: axis]
                )
            }
        }
    }
}

struct PickyDockSlotCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PickyDockTopEntryCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Quiet identity typography and geometry for a folder tile label. The AppKit
/// font gives layout and regression tests the same measurement source SwiftUI renders.
enum PickyHUDDockGroupHeaderPresentation {
    static var font: Font { PickyHUDTypography.dockGroupIdentity }

    static func labelFont(fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale) -> NSFont {
        PickyHUDTypography.dockGroupIdentityNSFont(fontScale: fontScale)
    }

    static func labelWidth(metrics: PickyHUDDockMetrics) -> CGFloat {
        metrics.sessionTileWidth
    }

    /// The accessible label hit area is the exact rendered line height plus a
    /// `space.1` inset above and below. This same metric drives rail geometry.
    static func labelHeight(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        lineHeight(for: labelFont(fontScale: fontScale)) + (metrics.groupHeaderVerticalInset * 2)
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }
}

/// Quiet, centered identity label beneath a folder tile. The rail supplies
/// the tap and group-reorder gesture so this label follows the tile's exact
/// interaction path without acquiring a separate context menu.
struct PickyHUDDockGroupHeader: View {
    let group: PickyDockGroup
    let metrics: PickyHUDDockMetrics
    let fontScale: CGFloat

    var body: some View {
        Text(group.displayName)
            .font(PickyHUDDockGroupHeaderPresentation.font)
            .foregroundStyle(DS.Colors.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(
                width: PickyHUDDockGroupHeaderPresentation.labelWidth(metrics: metrics),
                height: PickyHUDDockGroupHeaderPresentation.labelHeight(
                    metrics: metrics,
                    fontScale: fontScale
                ),
                alignment: .center
            )
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// Shared status -> dock visual mapping so the full dock icon and the
/// collapsed-group folder mini glyph stay in sync.
enum PickyDockPickleStatusVisual {
    static func color(_ status: PickySessionStatus) -> Color {
        switch status {
        case .queued: return DS.Colors.accentText
        case .running: return DS.Colors.overlayCursorBlue
        case .waiting_for_input: return DS.Colors.warning
        case .blocked: return DS.Colors.warningText
        case .completed: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    /// Template asset for the states that swap the plain pickle glyph for an
    /// expressive one (waiting / needs-attention). `nil` uses the logo glyph.
    static func statusAssetName(_ status: PickySessionStatus) -> String? {
        switch status {
        case .waiting_for_input: return "PickleDockWait"
        case .blocked, .failed: return "PickleDockHelp"
        default: return nil
        }
    }
}

/// Shared folder surface for a dock group: a subtle neutral fill with a faint
/// group-color tint and a weak border.
struct PickyDockGroupDrawerBackground: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.16))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.32), lineWidth: 0.5)
            )
    }
}

extension View {
    func pickyDockGroupDrawer(tint: Color, cornerRadius: CGFloat) -> some View {
        modifier(PickyDockGroupDrawerBackground(tint: tint, cornerRadius: cornerRadius))
    }
}

/// A single member rendered inside the collapsed-group folder grid: the
/// pickle glyph (or status asset) tinted by the member's status color.
struct PickyDockMiniPickleGlyph: View {
    let status: PickySessionStatus
    let side: CGFloat

    var body: some View {
        let color = PickyDockPickleStatusVisual.color(status)
        Group {
            if let asset = PickyDockPickleStatusVisual.statusAssetName(status) {
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
        .frame(width: side, height: side)
    }
}

/// Presentation-only folder glyph model. It ranks member states without ever
/// mutating the persisted group membership order.
struct PickyHUDDockFolderBadgeViewModel {
    let glyphMemberIDs: [String]
    let overflowCount: Int

    init(memberIDs: [String], statuses: [PickySessionStatus]) {
        let indices = PickyDockFolderGlyphPolicy.glyphIndices(statuses: statuses, cellCount: 3)
        self.glyphMemberIDs = indices.compactMap { memberIDs.indices.contains($0) ? memberIDs[$0] : nil }
        self.overflowCount = PickyDockFolderGlyphPolicy.overflowCount(
            memberCount: memberIDs.count,
            glyphCellCount: 3
        )
    }
}

/// App-drawer style badge that represents a group as a single dock
/// slot. Member pickles are shown as mini glyphs inside a rounded folder
/// container laid out as a 2x2 grid; the visible glyph count communicates
/// the member count (so the header no longer needs a count chip). When more
/// than four members exist, the fourth cell collapses into a `+N` tile. An
/// unread chip in the top-right corner mirrors the per-Pickle blue
/// unread dot pattern.
struct PickyHUDDockCollapsedGroupBadge: View {
    let members: [PickyHUDDockSession]
    let unreadCount: Int
    let tint: Color
    let metrics: PickyHUDDockMetrics
    /// ⌘N number this folder occupies. Pressing it opens the member list,
    /// so the badge advertises the top-level slot it owns.
    var shortcutNumber: Int? = nil
    var isCommandShortcutHintVisible: Bool = false
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private enum GridCell: Identifiable {
        case member(PickyHUDDockSession)
        case overflow(Int)
        case empty(Int)

        var id: String {
            switch self {
            case .member(let card): return "m-\(card.id)"
            case .overflow(let n): return "o-\(n)"
            case .empty(let i): return "e-\(i)"
            }
        }
    }

    /// Up to four cells: the three most important members are shown first,
    /// then a `+N` cell for every member behind them.
    private var cells: [GridCell] {
        let presentation = PickyHUDDockFolderBadgeViewModel(
            memberIDs: members.map { $0.id },
            statuses: members.map { $0.status }
        )
        let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var result = presentation.glyphMemberIDs.compactMap { membersByID[$0] }.map { GridCell.member($0) }
        if presentation.overflowCount > 0 {
            result.append(.overflow(presentation.overflowCount))
        }
        var pad = 0
        while result.count < 4 {
            result.append(.empty(pad))
            pad += 1
        }
        return Array(result.prefix(4))
    }

    var body: some View {
        let containerSide = min(metrics.sessionTileWidth, metrics.sessionTileHeight)
        let inset = max(4, containerSide * 0.11)
        let gap = max(3, containerSide * 0.06)
        let cellSide = max(8, (containerSide - inset * 2 - gap) / 2)
        let glyphSide = cellSide * 0.74
        let grid = cells

        ZStack(alignment: .topTrailing) {
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { col in
                            cellView(grid[row * 2 + col], side: cellSide, glyphSide: glyphSide)
                        }
                    }
                }
            }
            .frame(width: containerSide, height: containerSide)
            .pickyDockGroupDrawer(tint: tint, cornerRadius: metrics.iconCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.06 : 0))
            )

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(PickyHUDTypography.badgeSemibold)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Colors.notification)
                    )
                    .foregroundColor(DS.Colors.notificationText)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DS.Colors.background, lineWidth: 0.8)
                    )
                    .shadow(color: DS.Colors.notification.opacity(0.45), radius: 2.5, x: 0, y: 0)
                    .offset(x: 4, y: -4)
                    .opacity(isCommandShortcutHintVisible ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(unreadCount) unread")
            }
        }
        .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
        .overlay(alignment: .topTrailing) {
            if isCommandShortcutHintVisible, let shortcutNumber {
                PickyShortcutKeyBadge(label: "\(shortcutNumber)")
                    .offset(x: 5, y: -5)
                    .transition(.scale(scale: 0.88, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .brightness(isHovered ? 0.04 : 0)
        .contentShape(RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private func cellView(_ entry: GridCell, side: CGFloat, glyphSide: CGFloat) -> some View {
        switch entry {
        case .member(let card):
            PickyDockMiniPickleGlyph(status: card.status, side: glyphSide)
                .frame(width: side, height: side)
        case .overflow(let n):
            RoundedRectangle(cornerRadius: max(3, side * 0.28), style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: side, height: side)
                .overlay(
                    Text("+\(n)")
                        .pickyFont(size: max(8, side * 0.42), weight: .medium)
                        .foregroundColor(DS.Colors.textSecondary)
                )
        case .empty:
            Color.clear
                .frame(width: side, height: side)
        }
    }
}

/// Dashed-outline create button rendered for a group that currently has no
/// visible members. It remains a stable drop target while also letting the
/// user start a Pickle that will be assigned to this group automatically.
struct PickyHUDDockGroupEmptySlot: View {
    let color: PickyDockGroupColor
    let metrics: PickyHUDDockMetrics
    let onCreatePickle: () -> Void

    var body: some View {
        Button(action: onCreatePickle) {
            RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                .strokeBorder(
                    color.accent.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .fill(color.accent.opacity(0.06))
                )
                .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: metrics.plusFontSize, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                )
                .contentShape(RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
        .hoverAffordance()
    }
}

/// Right-click context menu for a group folder tile.
struct PickyHUDDockGroupContextMenu: View {
    let group: PickyDockGroup
    let onRename: () -> Void
    let onSetColor: (PickyDockGroupColor) -> Void
    let onUngroup: () -> Void
    let onDeleteWithArchive: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        Button(L10n.t("group.menu.rename"), action: onRename)
        Menu(L10n.t("group.menu.color")) {
            ForEach(PickyDockGroupColor.palette) { color in
                Button {
                    onSetColor(color)
                } label: {
                    Label {
                        Text(color.localizedName)
                    } icon: {
                        Image(nsImage: color.menuSwatchImage)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
        }
        Divider()
        Button(L10n.t("group.menu.ungroup"), action: onUngroup)
        Button(L10n.t("group.menu.delete"), role: .destructive) {
            // Empty group: nothing to archive, so delete without confirmation.
            guard !group.memberSessionIDs.isEmpty else {
                onDeleteWithArchive()
                return
            }
            PickyHUDDockGroupDeletePrompt.confirmDeleteWithArchive(
                groupName: group.displayName,
                onConfirm: onDeleteWithArchive
            )
        }
    }
}

/// Shared confirmation for removing a non-empty dock group and archiving its
/// Pickles. Used by both the header context menu and the drag-out gesture so
/// the prompt stays identical no matter how the removal is triggered.
enum PickyHUDDockGroupDeletePrompt {
    @MainActor
    static func confirmDeleteWithArchive(groupName: String, onConfirm: () -> Void) {
        // Surface a quick confirmation by routing through an NSAlert so we
        // don't silently archive a user's work.
        let alert = NSAlert()
        alert.messageText = L10n.t("group.delete.confirm.title", groupName)
        alert.informativeText = L10n.t("group.delete.confirm.message")
        alert.addButton(withTitle: L10n.t("group.delete.confirm.archive"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }
}

/// Small capsule label floated over a dock item (Pickle or group) once a
/// destructive drag-out release is armed, mirroring the macOS Dock "Remove"
/// cue. Shared by the icon overlay and the group container.
struct PickyHUDDockPullOutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .pickyFont(size: 11, weight: .semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .fixedSize()
    }
}
