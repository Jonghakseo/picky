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

/// Height of the thin group header chip rendered above an expanded group's
/// member icons. Used by both the rendered view and `railHeight` math so the
/// dock capsule reserves matching vertical space.
let PickyHUDDockGroupHeaderHeight: CGFloat = 14

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
    @ViewBuilder var content: () -> Content

    @State private var draftName: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        Group {
            if dockSide.orientation == .horizontal {
                // Horizontal rail: accent renders as a thin TOP bar above
                // the header + members so the group block stays compact in
                // the cross-axis direction.
                VStack(alignment: .leading, spacing: 2) {
                    accentBar
                        .frame(height: 2)
                    header
                    content()
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    accentBar
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        header
                        content()
                    }
                }
            }
        }
        .onAppear {
            draftName = group.name
            if isRenamingOnAppear { isEditing = true }
        }
        .onChange(of: group.name) { _, newName in
            if !isEditing { draftName = newName }
        }
    }

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(group.color.accent.opacity(0.78))
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 3) {
            if isEditing {
                PickyHUDDockGroupRenameField(
                    text: $draftName,
                    onCommit: {
                        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        isEditing = false
                        onRenameCommit(trimmed)
                    },
                    onCancel: {
                        draftName = group.name
                        isEditing = false
                        onRenameCancel()
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(group.displayName)
                    .pickyFont(size: 9, weight: .medium)
                    .foregroundColor(group.color.accent.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        draftName = group.name
                        isEditing = true
                    }
                Text("\(group.memberSessionIDs.count)")
                    .pickyFont(size: 8, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                Spacer(minLength: 2)
                Button(action: onToggleCollapsed) {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 10, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.isCollapsed ? "Expand group" : "Collapse group")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: PickyHUDDockGroupHeaderHeight, alignment: .center)
        .contextMenu {
            PickyHUDDockGroupContextMenu(
                group: group,
                onRename: {
                    draftName = group.name
                    isEditing = true
                },
                onToggleCollapsed: onToggleCollapsed,
                onSetColor: onSetColor,
                onUngroup: onUngroup,
                onDeleteWithArchive: onDeleteWithArchive
            )
        }
    }
}

/// Tiny rename input rendered inline in a group header. Wraps an
/// `NSTextField` so we can pull keyboard focus immediately and commit on
/// Return / Escape without dragging in the full `PickyConversationComposer`
/// machinery.
struct PickyHUDDockGroupRenameField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        field.textColor = NSColor.white
        field.placeholderString = "Group name"
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onCommit: () -> Void
        let onCancel: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            _text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }

        // Click-out commits the current draft so users can't accidentally
        // lose a half-typed name by clicking elsewhere in the dock.
        func controlTextDidEndEditing(_ obj: Notification) {
            onCommit()
        }
    }
}

/// Stacked-card badge that represents a collapsed group as a single dock
/// slot. The top member icon renders normally; two muted "card" rectangles
/// sit behind it to hint at the hidden siblings, and a small accent-colored
/// count chip lives in the bottom-right corner.
struct PickyHUDDockCollapsedGroupBadge<Inner: View>: View {
    let memberCount: Int
    let color: PickyDockGroupColor
    let metrics: PickyHUDDockMetrics
    @ViewBuilder var topIcon: () -> Inner

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Back-most card: smaller, dimmer.
            RoundedRectangle(cornerRadius: metrics.iconCornerRadius * 0.85, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: metrics.sessionTileWidth - 6, height: metrics.sessionTileHeight - 6)
                .offset(x: 0, y: -3)
            // Mid card.
            RoundedRectangle(cornerRadius: metrics.iconCornerRadius * 0.9, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: metrics.sessionTileWidth - 3, height: metrics.sessionTileHeight - 3)
                .offset(x: 0, y: -1.5)
            topIcon()
            Text("\(memberCount)")
                .pickyFont(size: 8, weight: .medium)
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(color.accent)
                )
                .foregroundColor(.black.opacity(0.78))
                .offset(x: 4, y: 4)
                .allowsHitTesting(false)
        }
        .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
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
        Button("Rename", action: onRename)
        Menu("Color") {
            ForEach(PickyDockGroupColor.palette) { color in
                Button(color.displayName) { onSetColor(color) }
            }
        }
        Button(group.isCollapsed ? "Expand" : "Collapse", action: onToggleCollapsed)
        Divider()
        Button("Ungroup (keep pickles)", action: onUngroup)
        Button("Delete group + archive pickles", role: .destructive) {
            // Surface a quick confirmation by routing through an NSAlert so
            // we don't silently archive a user's work in a single click.
            let alert = NSAlert()
            alert.messageText = "Delete \"\(group.displayName)\" and archive its Pickles?"
            alert.informativeText = "All Pickles inside this group will be archived. You can restore them from the archive list."
            alert.addButton(withTitle: "Archive Pickles")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                onDeleteWithArchive()
            }
        }
    }
}
