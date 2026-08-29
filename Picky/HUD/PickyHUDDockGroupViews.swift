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

/// Folder badge frames in the rail coordinate space. Unlike the HUD-root
/// frames used by the detached child panel, these compare directly with a
/// scroll viewport before choosing a popover anchor.
struct PickyHUDPickerBadgeFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PickyHUDRailViewportFrameKey: PreferenceKey {
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

struct PickyHUDDockRailViewportFrameReporter: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PickyHUDRailViewportFrameKey.self,
                value: proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))
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

    func publishDockGroupPickerBadgeFrame(groupID: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PickyHUDPickerBadgeFrameKey.self,
                    value: [groupID: proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))]
                )
            }
        }
    }

    func publishDockSlotCenter(sessionID: String) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))
                Color.clear.preference(
                    key: PickyDockSlotCenterPreferenceKey.self,
                    value: [sessionID: CGPoint(x: frame.midX, y: frame.midY)]
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

    /// Publishes only the visible folder badge in rail coordinates. The label
    /// remains part of the folder's click area, but not its grouping drop zone.
    func publishDockGroupDropFrame(groupID: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PickyDockGroupDropFramePreferenceKey.self,
                    value: [groupID: proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))]
                )
            }
        }
    }
}

struct PickyDockSlotCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PickyDockTopEntryCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PickyDockGroupDropFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
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

    /// Reserve four representative CJK glyphs using the exact AppKit font
    /// paired with the SwiftUI identity role. A `space.1` optical margin keeps
    /// the label clear of the folder edge without opting out of app font scale.
    static func labelWidth(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        let measuredFourCJKWidth = ("가나다라" as NSString).size(withAttributes: [
            .font: labelFont(fontScale: fontScale),
        ]).width
        let opticalSafety = metrics.groupHeaderContentSpacing
        return ceil(max(metrics.sessionTileWidth, measuredFourCJKWidth + opticalSafety))
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

enum PickyHUDDockGroupSurfacePresentation {
    static let tintOpacity = 0.12
    static let borderOpacity = 0.78
    static let hoverLayerOpacity = 0.72
}

/// Quiet, centered identity label above a folder tile. The rail supplies
/// the tap and group-reorder gesture.
struct PickyHUDDockGroupHeader: View {
    let group: PickyDockGroup
    let metrics: PickyHUDDockMetrics
    let fontScale: CGFloat

    var body: some View {
        Text(group.displayName)
            .font(PickyHUDDockGroupHeaderPresentation.font)
            // A group name is identity, not metadata. Primary text remains
            // readable after the rail adapts its material to the appearance.
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(
                width: PickyHUDDockGroupHeaderPresentation.labelWidth(
                    metrics: metrics,
                    fontScale: fontScale
                ),
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
                    .fill(DS.Colors.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(PickyHUDDockGroupSurfacePresentation.tintOpacity))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        DS.Colors.borderStrong.opacity(
                            PickyHUDDockGroupSurfacePresentation.borderOpacity
                        ),
                        lineWidth: 0.5
                    )
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

/// Shared geometry for the folder's intentionally overlapping unread badge.
/// The render gallery reserves `unreadBadgeTopOverflow` without changing the
/// production badge's offset, shadow, or tile frame.
enum PickyHUDDockFolderBadgePresentation {
    static let unreadBadgeOffset = CGSize(width: 4, height: -4)
    static let unreadBadgeShadowRadius: CGFloat = 2.5
    static var unreadBadgeTopOverflow: CGFloat {
        ceil(abs(unreadBadgeOffset.height) + unreadBadgeShadowRadius)
    }
}

private struct PickyHUDDockGroupEmphasisModifier: ViewModifier {
    let isSelected: Bool
    let isDropTargeted: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isEmphasized = isSelected || isDropTargeted
        content
            .overlay {
                shape
                    .fill(isEmphasized ? DS.Colors.accentSubtle : Color.clear)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(
                        isEmphasized ? DS.Colors.accentText : Color.clear,
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: DS.Animation.fast),
                value: isEmphasized
            )
    }
}

private extension View {
    func pickyDockGroupEmphasis(
        isSelected: Bool,
        isDropTargeted: Bool,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(PickyHUDDockGroupEmphasisModifier(
            isSelected: isSelected,
            isDropTargeted: isDropTargeted,
            cornerRadius: cornerRadius
        ))
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
    var isSelected: Bool = false
    var isDropTargeted: Bool = false
    /// This folder's member list is pinned open. The tile keeps its hover lift
    /// so the persistent state stays readable once the pointer moves away.
    var isListPinned: Bool = false
    var onTap: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onReorderBegan: () -> Void = {}
    var onReorderChanged: (CGSize) -> Void = { _ in }
    var onReorderEnded: (CGSize) -> Void = { _ in }

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hover and pinned share one visual so a peek needs no vocabulary of its
    /// own: while the pointer is on the folder the two are indistinguishable,
    /// and the difference the user cares about is that a pinned tile stays lit.
    private var isLifted: Bool { isHovered || isListPinned }

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
                    .fill(
                        isLifted
                            ? DS.Colors.surface3.opacity(
                                PickyHUDDockGroupSurfacePresentation.hoverLayerOpacity
                            )
                            : Color.clear
                    )
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
                    .shadow( // design-token-exception: preserves the legacy unread badge's status-specific glow while exposing its canvas overflow metric
                        color: DS.Colors.notification.opacity(0.45),
                        radius: PickyHUDDockFolderBadgePresentation.unreadBadgeShadowRadius,
                        x: 0,
                        y: 0
                    )
                    .offset(
                        x: PickyHUDDockFolderBadgePresentation.unreadBadgeOffset.width,
                        y: PickyHUDDockFolderBadgePresentation.unreadBadgeOffset.height
                    )
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
        .pickyDockGroupEmphasis(
            isSelected: isSelected,
            isDropTargeted: isDropTargeted,
            cornerRadius: metrics.iconCornerRadius
        )
        .contentShape(RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isListPinned)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            onHoverChanged(hovering)
        }
        .overlay {
            // One AppKit owner arbitrates click versus reorder. Keeping this
            // above the badge content avoids the old child Button competing
            // with a parent high-priority SwiftUI drag recognizer.
            PickyHUDDockGroupTileClickHost(
                onHover: {
                    isHovered = true
                    onHoverChanged(true)
                },
                onActivate: onTap,
                onReorderBegan: onReorderBegan,
                onReorderChanged: onReorderChanged,
                onReorderEnded: onReorderEnded
            )
        }
    }

    @ViewBuilder
    private func cellView(_ entry: GridCell, side: CGFloat, glyphSide: CGFloat) -> some View {
        switch entry {
        case .member(let card):
            PickyDockMiniPickleGlyph(status: card.status, side: glyphSide)
                .frame(width: side, height: side)
        case .overflow(let n):
            RoundedRectangle(cornerRadius: max(3, side * 0.28), style: .continuous)
                .fill(DS.Colors.surface3)
                .frame(width: side, height: side)
                .overlay(
                    Text("+\(n)")
                        .pickyFont(size: max(8, side * 0.42), weight: .medium)
                        .foregroundColor(DS.Colors.textPrimary)
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
    var isDropTargeted: Bool = false
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
                .frame(width: metrics.sessionTileWidth, height: metrics.emptyGroupSlotHeight)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: metrics.plusFontSize, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                )
                .contentShape(RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pickyDockGroupEmphasis(
            isSelected: false,
            isDropTargeted: isDropTargeted,
            cornerRadius: metrics.iconCornerRadius
        )
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
        .hoverAffordance()
    }
}

/// One menu modifier is applied to both the folder icon and its identity
/// label, preventing the two right-click surfaces from drifting.
private struct PickyHUDDockGroupContextMenuModifier: ViewModifier {
    let group: PickyDockGroup
    let onRename: () -> Void
    let onSetColor: (PickyDockGroupColor) -> Void
    let onUngroup: () -> Void
    let onDeleteWithArchive: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            PickyHUDDockGroupContextMenu(
                group: group,
                onRename: onRename,
                onSetColor: onSetColor,
                onUngroup: onUngroup,
                onDeleteWithArchive: onDeleteWithArchive
            )
        }
    }
}

extension View {
    func pickyDockGroupContextMenu(
        group: PickyDockGroup,
        onRename: @escaping () -> Void,
        onSetColor: @escaping (PickyDockGroupColor) -> Void,
        onUngroup: @escaping () -> Void,
        onDeleteWithArchive: @escaping () -> Void
    ) -> some View {
        modifier(PickyHUDDockGroupContextMenuModifier(
            group: group,
            onRename: onRename,
            onSetColor: onSetColor,
            onUngroup: onUngroup,
            onDeleteWithArchive: onDeleteWithArchive
        ))
    }
}

/// Action labels shared by the tile and identity-label context-menu paths.
enum PickyHUDDockGroupContextMenuPresentation {
    static var renameTitle: String { L10n.t("group.menu.rename") }
    static var colorTitle: String { L10n.t("group.menu.color") }
    static var ungroupTitle: String { L10n.t("group.menu.ungroup") }
    static var deleteTitle: String { L10n.t("group.menu.delete") }

    static var actionTitles: [String] {
        [renameTitle, colorTitle, ungroupTitle, deleteTitle]
    }
}

/// Right-click context menu content for a group folder tile and label.
struct PickyHUDDockGroupContextMenu: View {
    let group: PickyDockGroup
    let onRename: () -> Void
    let onSetColor: (PickyDockGroupColor) -> Void
    let onUngroup: () -> Void
    let onDeleteWithArchive: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        Button(PickyHUDDockGroupContextMenuPresentation.renameTitle, action: onRename)
        Menu(PickyHUDDockGroupContextMenuPresentation.colorTitle) {
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
        Button(PickyHUDDockGroupContextMenuPresentation.ungroupTitle, action: onUngroup)
        Button(PickyHUDDockGroupContextMenuPresentation.deleteTitle, role: .destructive) {
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
