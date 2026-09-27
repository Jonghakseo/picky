//
//  PickyHUDDockGroupViews.swift
//  Picky
//
//  Group-rendering primitives for the dock rail. Folder identity and member
//  status share the same square footprint as a session tile.
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

/// Publishes the square folder and its embedded identity as one interaction area.
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

    /// Publishes the visible square folder in rail coordinates, including its
    /// embedded label, as the grouping drop zone.
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

/// Identity typography and geometry inside the folder tile. The AppKit font
/// gives layout and regression tests the same measurement source SwiftUI renders.
enum PickyHUDDockGroupHeaderPresentation {
    static var font: Font { PickyHUDTypography.dockGroupIdentity }

    static func labelFont(fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale) -> NSFont {
        PickyHUDTypography.dockGroupIdentityNSFont(fontScale: fontScale)
    }

    /// The identity stays inset inside the tile at every app font scale.
    /// Longer names truncate; the full name remains available via help and accessibility.
    static func labelWidth(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        metrics.sessionTileWidth - 6
    }

    static func labelHeight(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        ceil(lineHeight(for: labelFont(fontScale: fontScale)))
    }

    static func bottomInset(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        max(0, (metrics.sessionTileHeight - metrics.groupPreviewHeight
            - metrics.groupHeaderContentSpacing - labelHeight(metrics: metrics, fontScale: fontScale)) / 2)
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }
}

enum PickyHUDDockGroupSurfacePresentation {
    static let tintOpacity = 0.04
    static let borderOpacity = 1.0
}

/// Identity inset into the bottom of a folder tile. The rail owns the
/// label's tap, context menu, and group-reorder gesture.
struct PickyHUDDockGroupHeader: View {
    let group: PickyDockGroup
    let metrics: PickyHUDDockMetrics
    let fontScale: CGFloat

    var body: some View {
        Text(group.displayName)
            .font(Font(PickyHUDDockGroupHeaderPresentation.labelFont(fontScale: fontScale)))
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
            .help(group.displayName)
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
    let isLifted: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isLifted ? DS.Colors.surface3 : DS.Colors.surface2)
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
                        lineWidth: 0.75
                    )
            )
    }
}

extension View {
    func pickyDockGroupDrawer(
        tint: Color,
        cornerRadius: CGFloat,
        isLifted: Bool = false
    ) -> some View {
        modifier(PickyDockGroupDrawerBackground(
            tint: tint,
            cornerRadius: cornerRadius,
            isLifted: isLifted
        ))
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

/// Folder preview of the leading members in the shared group display order.
struct PickyHUDDockFolderBadgeViewModel {
    let glyphMemberIDs: [String]
    let overflowCount: Int

    init(memberIDs: [String]) {
        self.glyphMemberIDs = Array(memberIDs.prefix(2))
        self.overflowCount = PickyDockFolderGlyphPolicy.overflowCount(
            memberCount: memberIDs.count,
            glyphCellCount: 2
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
        let animation = reduceMotion ? nil : Animation.easeOut(duration: DS.Animation.fast)
        content
            .overlay {
                shape
                    .fill(isEmphasized ? DS.Colors.accentSubtle : Color.clear)
                    .animation(animation, value: isEmphasized)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(
                        isEmphasized ? DS.Colors.accentText : Color.clear,
                        lineWidth: 1.5
                    )
                    .animation(animation, value: isEmphasized)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
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
/// slot. Two recent member glyphs and the group name form one centered block.
/// The member list retains the complete group; unread and shortcut badges remain visible.
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

    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hover and pinned share one visual so a peek needs no vocabulary of its
    /// own: while the pointer is on the folder the two are indistinguishable,
    /// and the difference the user cares about is that a pinned tile stays lit.
    private var isLifted: Bool { isHovered || isListPinned }

    var body: some View {
        let preview = PickyHUDDockFolderBadgeViewModel(memberIDs: members.map(\.id))
        let visibleMembers = members.filter { preview.glyphMemberIDs.contains($0.id) }
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: metrics.groupHeaderContentSpacing) {
                HStack(spacing: 3) {
                    ForEach(visibleMembers, id: \.id) { member in
                        PickyDockMiniPickleGlyph(status: member.status, side: metrics.groupPreviewGlyphSide)
                    }
                }
                .frame(height: metrics.groupPreviewHeight)
                Color.clear.frame(height: PickyHUDDockGroupHeaderPresentation.labelHeight(
                    metrics: metrics, fontScale: fontScale
                ))
            }
            .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
            .background {
                Color.clear.pickyDockGroupDrawer(
                    tint: tint,
                    cornerRadius: metrics.iconCornerRadius,
                    isLifted: isLifted
                )
            }

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
                    .accessibilityLabel(L10n.t("dock.group.unreadCount", unreadCount))
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
        .overlay {
            // One AppKit owner arbitrates click versus reorder. Keeping this
            // above the badge content avoids the old child Button competing
            // with a parent high-priority SwiftUI drag recognizer.
            PickyHUDDockGroupTileClickHost(
                onHoverChanged: { hovering in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast)) {
                        isHovered = hovering
                    }
                    onHoverChanged(hovering)
                },
                onActivate: onTap,
                onReorderBegan: onReorderBegan,
                onReorderChanged: onReorderChanged,
                onReorderEnded: onReorderEnded
            )
        }
    }

}

/// The empty group keeps the same centered composition and drop target.
/// Clicking creates a Pickle assigned to this group.
struct PickyHUDDockGroupEmptySlot: View {
    let color: PickyDockGroupColor
    let metrics: PickyHUDDockMetrics
    var isDropTargeted: Bool = false
    let onCreatePickle: () -> Void

    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        Button(action: onCreatePickle) {
            VStack(spacing: metrics.groupHeaderContentSpacing) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 16)) // design-token-exception: approved empty-folder glyph inside the fixed 20pt preview row.
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(height: metrics.groupPreviewHeight)
                Color.clear.frame(height: PickyHUDDockGroupHeaderPresentation.labelHeight(
                    metrics: metrics, fontScale: fontScale
                ))
            }
            .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
            .pickyDockGroupDrawer(tint: color.accent, cornerRadius: metrics.iconCornerRadius)
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
