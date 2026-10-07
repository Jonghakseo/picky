//
//  PickyHUDDockGroupViews.swift
//  Picky
//
//  Shared primitives for the list dock: geometry preferences, status visuals,
//  the group context menu, and the drag-out badge.
//

import SwiftUI
import AppKit

/// Named SwiftUI coordinate space the rail establishes so child tiles can
/// publish their layout centers in a single shared frame.
let PickyHUDDockRailCoordinateSpace = "PickyHUDDockRail"
/// Root coordinate space shared with the overlay manager's child-panel geometry.
let PickyHUDVisibleChromeCoordinateSpaceName = "PickyHUDVisibleChrome"

/// Publishes the rail frame in HUD-root coordinates.
struct PickyHUDDockRailFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
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

    /// Publishes a top-level entry's primary-axis span. A group spans its
    /// header and any expanded member rows.
    func publishDockTopEntryExtent(
        entryID: String,
        orientation: PickyHUDDockOrientation
    ) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(PickyHUDDockRailCoordinateSpace))
                let extent = orientation == .vertical
                    ? PickyDockAxisExtent(lower: frame.minY, upper: frame.maxY)
                    : PickyDockAxisExtent(lower: frame.minX, upper: frame.maxX)
                Color.clear.preference(
                    key: PickyDockTopEntryExtentPreferenceKey.self,
                    value: [entryID: extent]
                )
            }
        }
    }

    /// Publishes a group header in rail coordinates as its "drop into group" zone.
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

struct PickyDockTopEntryExtentPreferenceKey: PreferenceKey {
    static let defaultValue: [String: PickyDockAxisExtent] = [:]
    static func reduce(value: inout [String: PickyDockAxisExtent], nextValue: () -> [String: PickyDockAxisExtent]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Scroll offset of an overflowing dock list along its primary axis.
struct PickyDockListScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct PickyDockGroupDropFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Shared status -> dock visual mapping for rows and group-header glyphs.
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

/// The pickle glyph (or status asset) tinted by the status color.
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

/// Group header context menu.
private struct PickyHUDDockGroupContextMenuModifier: ViewModifier {
    let group: PickyDockGroup
    let activeSessionIDs: Set<String>
    let onRename: () -> Void
    let onSetColor: (PickyDockGroupColor) -> Void
    let onUngroup: () -> Void
    let onDeleteWithArchive: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            PickyHUDDockGroupContextMenu(
                group: group,
                activeSessionIDs: activeSessionIDs,
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
        activeSessionIDs: Set<String>,
        onRename: @escaping () -> Void,
        onSetColor: @escaping (PickyDockGroupColor) -> Void,
        onUngroup: @escaping () -> Void,
        onDeleteWithArchive: @escaping () -> Void
    ) -> some View {
        modifier(PickyHUDDockGroupContextMenuModifier(
            group: group,
            activeSessionIDs: activeSessionIDs,
            onRename: onRename,
            onSetColor: onSetColor,
            onUngroup: onUngroup,
            onDeleteWithArchive: onDeleteWithArchive
        ))
    }
}

/// Group context-menu action labels.
enum PickyHUDDockGroupContextMenuPresentation {
    static var renameTitle: String { L10n.t("group.menu.rename") }
    static var colorTitle: String { L10n.t("group.menu.color") }
    static var ungroupTitle: String { L10n.t("group.menu.ungroup") }
    static var deleteTitle: String { L10n.t("group.menu.delete") }

    static var actionTitles: [String] {
        [renameTitle, colorTitle, ungroupTitle, deleteTitle]
    }
}

/// Right-click context menu content for a group header.
struct PickyHUDDockGroupContextMenu: View {
    let group: PickyDockGroup
    let activeSessionIDs: Set<String>
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
            PickyHUDDockGroupDeletePrompt.delete(
                group: group,
                activeSessionIDs: activeSessionIDs,
                onConfirm: onDeleteWithArchive
            )
        }
    }
}

/// Shared confirmation for removing a non-empty dock group and archiving its
/// Pickles. Used by both the header context menu and the drag-out gesture so
/// the prompt stays identical no matter how the removal is triggered.
enum PickyHUDDockGroupDeletePrompt {
    static func requiresConfirmation(group: PickyDockGroup, activeSessionIDs: Set<String>) -> Bool {
        group.memberSessionIDs.contains { activeSessionIDs.contains($0) }
    }

    @MainActor
    static func delete(group: PickyDockGroup, activeSessionIDs: Set<String>, onConfirm: () -> Void) {
        guard requiresConfirmation(group: group, activeSessionIDs: activeSessionIDs) else {
            onConfirm()
            return
        }
        confirmDeleteWithArchive(groupName: group.displayName, onConfirm: onConfirm)
    }

    @MainActor
    private static func confirmDeleteWithArchive(groupName: String, onConfirm: () -> Void) {
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
/// cue.
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
