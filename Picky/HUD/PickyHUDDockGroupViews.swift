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

/// Visual height of the thin group title above an expanded group's member
/// icons. Its interaction row is taller so the compact label remains easy to
/// click without making the title itself visually heavier.
let PickyHUDDockGroupHeaderHeight: CGFloat = 14
/// Actual layout and hit-test height of a group header. Keeping this separate
/// from `PickyHUDDockGroupHeaderHeight` preserves the quiet 14pt title while
/// reserving a 24pt target that cannot overlap the first member icon.
let PickyHUDDockGroupHeaderHitAreaHeight: CGFloat = 24
let PickyHUDDockGroupContentSpacing: CGFloat = 2

/// Named SwiftUI coordinate space the rail establishes so child icons and
/// group headers can publish their layout centers in a single shared frame.
let PickyHUDDockRailCoordinateSpace = "PickyHUDDockRail"

/// Maps a session id to the primary-axis center (Y for vertical docks, X for
/// horizontal) of its rendered slot in the rail coordinate space. Drives
/// precise drag hit-testing so reorders work correctly even when group
/// headers introduce non-uniform vertical chrome between icons.
struct PickyDockSlotCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(
        value: inout [String: CGFloat],
        nextValue: () -> [String: CGFloat]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Maps a top-level entry id (`"session:<id>"` or `"group:<id>"`) to its
/// primary-axis center in the rail coordinate space. Drives precise drop
/// hit-testing for the group-header drag that reorders entire groups
/// within the layout.
struct PickyDockTopEntryCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(
        value: inout [String: CGFloat],
        nextValue: () -> [String: CGFloat]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publishes this view's primary-axis center (Y for vertical docks,
    /// X for horizontal) to the named coordinate space via the
    /// `PickyDockSlotCenterPreferenceKey`. Apply on every draggable dock
    /// icon so the rail can hit-test the cursor against measured centers.
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

    /// Publishes a top-level entry's primary-axis center for group-header
    /// drag hit-testing. Pass either `"session:<id>"` for an ungrouped
    /// session slot or `"group:<id>"` for a group container.
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

/// A render unit emitted by `PickyHUDDockRailView.buildRenderUnits` — either
/// an ungrouped session slot or a group block that wraps members in a single
/// accent-bar container.
struct PickyHUDDockRenderUnit: Identifiable {
    enum Kind {
        case session(id: String)
        case group(group: PickyDockGroup, members: [PickyHUDDockGroupMemberRef])
    }
    let kind: Kind

    var id: String {
        switch kind {
        case .session(let id): return "session:\(id)"
        case .group(let group, _): return "group:\(group.id)"
        }
    }
}

struct PickyHUDDockGroupMemberRef {
    let sessionID: String
}

/// Wraps a group's member icons (or its collapsed badge) with a 2px accent
/// bar and a thin header chip. The header carries the group name, member
/// count, collapse chevron, and the right-click context menu.
struct PickyHUDDockGroupContainer<Content: View>: View {
    let group: PickyDockGroup
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    /// Long-axis span of the drawer that hosts this group's members (or
    /// collapsed/empty placeholder). The header chip is sized to match this
    /// span so the group title sits centered above the drawer regardless of
    /// member count. For vertical docks this is just `sessionTileWidth`; for
    /// horizontal docks it grows with the member count so the title spans the
    /// full HStack of members.
    let drawerSpan: CGFloat
    /// When true, the header should focus its rename input as soon as the
    /// view appears. Used after `+ → New Group` so the user can type a
    /// name without an extra click.
    let isRenamingOnAppear: Bool
    let onRenameCommit: (String) -> Void
    let onRenameCancel: () -> Void
    let onToggleCollapsed: () -> Void
    let onSetColor: (PickyDockGroupColor) -> Void
    let onUngroup: () -> Void
    let onDeleteWithArchive: () -> Void
    /// Header drag callbacks. The rail uses them to reorder the entire
    /// group block within the top-level layout while the user holds the
    /// header chip and drags. Default no-ops keep the container usable in
    /// previews/tests that don't wire reorder.
    var onHeaderDragBegin: () -> Void = {}
    var onHeaderDragChanged: (CGSize) -> Void = { _ in }
    var onHeaderDragEnded: (CGSize) -> Void = { _ in }
    var onHeaderDragCanceled: () -> Void = {}
    /// True while this group's header is the live drag target. The rail
    /// flips it on so the container can apply a small drag-state effect
    /// (lifted shadow, faint scale) and the icon row can dim slightly so
    /// the user sees the whole block following the cursor.
    var isHeaderDragging: Bool = false
    var headerDragOffset: CGSize = .zero
    /// When non-nil the group has been dragged out of the dock and a release
    /// will remove it; the block dims and floats this label as a cue.
    var pullOutBadgeText: String? = nil
    @ViewBuilder var content: () -> Content

    /// Tracks whether the current drag gesture has already reported its
    /// `begin` event. SwiftUI's `DragGesture` only exposes `onChanged` /
    /// `onEnded`, so we synthesize a single begin from the first onChanged
    /// callback.
    @State private var hasReportedHeaderDragBegin: Bool = false

    var body: some View {
        // Group block: the name header sits above the app-drawer container
        // that holds the members. The group color is carried as a subtle
        // tint on the drawer (see `pickyDockGroupDrawer`), so there is no
        // left accent bar and no chevron.
        VStack(alignment: .leading, spacing: PickyHUDDockGroupContentSpacing) {
            header
            collapsibleContent
        }
        .opacity(pullOutBadgeText != nil ? 0.5 : 1)
        .overlay(alignment: .top) {
            if let pullOutBadgeText {
                PickyHUDDockPullOutBadge(text: pullOutBadgeText)
                    .offset(y: -22)
            }
        }
        .scaleEffect(isHeaderDragging ? 1.03 : 1.0)
        .shadow(
            color: Color.black.opacity(isHeaderDragging ? 0.28 : 0),
            radius: isHeaderDragging ? 12 : 0,
            x: 0,
            y: isHeaderDragging ? 4 : 0
        )
        .offset(x: headerDragOffset.width, y: headerDragOffset.height)
        .zIndex(isHeaderDragging ? 220 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isHeaderDragging)
        .onAppear {
            // Brand-new groups ("+ → New Group") open the rename dialog
            // immediately so the user can name the group before its first
            // member arrives. Defer past the current layout pass so the modal
            // isn't presented mid-`onAppear`.
            if isRenamingOnAppear {
                DispatchQueue.main.async { presentRenameDialog() }
            }
        }
    }

    /// Present a dedicated rename dialog instead of editing inline. The dock
    /// rail is only ~54pt wide, so an inline `NSTextField` was far too small
    /// to read or edit comfortably. An `NSAlert` with an accessory text
    /// field gives a normal-sized, keyboard-focused input.
    @MainActor
    private func presentRenameDialog() {
        let alert = NSAlert()
        alert.messageText = L10n.t("group.rename.dialog.title")
        alert.informativeText = L10n.t("group.rename.dialog.message")
        alert.alertStyle = .informational

        let field = NSTextField(string: group.name)
        field.placeholderString = L10n.t("group.rename.dialog.placeholder")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field

        alert.addButton(withTitle: L10n.t("group.rename.dialog.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            onRenameCommit(trimmed)
        } else {
            onRenameCancel()
        }
    }

    /// Wraps the group body so the collapsed folder badge (or collapsed empty
    /// slot) carries the same right-click settings menu as the header. When
    /// expanded, members keep their own per-Pickle menus untouched.
    @ViewBuilder
    private var collapsibleContent: some View {
        if group.isCollapsed {
            content()
                .contextMenu {
                    PickyHUDDockGroupContextMenu(
                        group: group,
                        onRename: { presentRenameDialog() },
                        onToggleCollapsed: onToggleCollapsed,
                        onSetColor: onSetColor,
                        onUngroup: onUngroup,
                        onDeleteWithArchive: onDeleteWithArchive
                    )
                }
        } else {
            content()
        }
    }

    @ViewBuilder
    private var header: some View {
        // The group name renders inline above the members, centered over the
        // drawer. No chevron, accent dot, or hover label: the drawer's tint +
        // border below carries the grouping cue. Long names truncate within
        // the rail width.
        Text(group.displayName)
            .pickyFont(size: 11, weight: .medium)
            .foregroundColor(DS.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: PickyHUDDockGroupHeaderHeight, alignment: .center)
            // The visual title stays 14pt high, while this surrounding row
            // reserves a 24pt target. As a layout row (rather than an overlay),
            // it never reaches into the first member icon below.
            .frame(width: drawerSpan, height: PickyHUDDockGroupHeaderHitAreaHeight, alignment: .center)
            .contentShape(Rectangle())
            // A reorder drag takes precedence over the collapse tap once it
            // crosses the 4pt threshold; a stationary click still collapses.
            // Right-click remains owned by the context menu below.
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if !hasReportedHeaderDragBegin {
                            hasReportedHeaderDragBegin = true
                            onHeaderDragBegin()
                        }
                        onHeaderDragChanged(value.translation)
                    }
                    .onEnded { value in
                        hasReportedHeaderDragBegin = false
                        onHeaderDragEnded(value.translation)
                    }
            )
            // Tap anywhere on the header row toggles collapse. The rename
            // affordance lives in the right-click context menu ("Rename").
            .onTapGesture {
                onToggleCollapsed()
            }
            .accessibilityLabel(
                group.isCollapsed
                    ? "Expand group \(group.displayName)"
                    : "Collapse group \(group.displayName)"
            )
            .contextMenu {
            PickyHUDDockGroupContextMenu(
                group: group,
                onRename: { presentRenameDialog() },
                onToggleCollapsed: onToggleCollapsed,
                onSetColor: onSetColor,
                onUngroup: onUngroup,
                onDeleteWithArchive: onDeleteWithArchive
            )
        }
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

/// Shared "app drawer" surface for a dock group: a subtle neutral fill with
/// a faint group-color tint and a weak border. Used by both the collapsed
/// folder badge and the expanded member column so an expanded group reads as
/// the same drawer extended downward.
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

/// App-drawer style badge that represents a collapsed group as a single dock
/// slot. Member pickles are shown as mini glyphs inside a rounded folder
/// container laid out as a 2x2 grid; the visible glyph count communicates
/// the member count (so the header no longer needs a count chip). When more
/// than four members exist, the fourth cell collapses into a `+N` tile. An
/// unread chip in the top-right corner mirrors the per-Pickle blue
/// unread dot pattern.
struct PickyHUDDockCollapsedGroupBadge: View {
    let members: [PickySessionListViewModel.SessionCard]
    let unreadCount: Int
    let tint: Color
    let metrics: PickyHUDDockMetrics
    /// ⌘N number this collapsed group occupies. Pressing it expands the group
    /// rather than opening a member, so the badge advertises the slot the
    /// group consumes and keeps the numbering legible.
    var shortcutNumber: Int? = nil
    var isCommandShortcutHintVisible: Bool = false
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private enum GridCell: Identifiable {
        case member(PickySessionListViewModel.SessionCard)
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

    /// Up to four cells: members fill in order; a 5th+ member collapses the
    /// last cell into `+N`; trailing slots pad with empties so the grid keeps
    /// its 2x2 shape.
    private var cells: [GridCell] {
        var result: [GridCell]
        if members.count > 4 {
            result = members.prefix(3).map { .member($0) }
            result.append(.overflow(members.count - 3))
        } else {
            result = members.map { .member($0) }
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

/// Dashed-outline placeholder rendered for a group that currently has no
/// visible members. Provides a stable drop target so the user can drag
/// pickles into a brand-new group before its first member arrives.
struct PickyHUDDockGroupEmptySlot: View {
    let color: PickyDockGroupColor
    let metrics: PickyHUDDockMetrics

    var body: some View {
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
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(color.accent.opacity(0.6))
            )
    }
}

/// Right-click context menu for a group header. Lives in its own builder so
/// the menu items can be shared between the rename inline view and the
/// non-editing header chip.
struct PickyHUDDockGroupContextMenu: View {
    let group: PickyDockGroup
    let onRename: () -> Void
    let onToggleCollapsed: () -> Void
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
        Button(group.isCollapsed ? L10n.t("group.menu.expand") : L10n.t("group.menu.collapse"), action: onToggleCollapsed)
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
