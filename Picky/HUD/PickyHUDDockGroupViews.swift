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
    @ViewBuilder var content: () -> Content

    @State private var draftName: String = ""
    @State private var isEditing: Bool = false
    /// Hover-tracked so the floating name label appears next to the dock
    /// only while the user points at the group's header. The header chip
    /// itself stays tiny (chevron + color dot + collapsed count) so the
    /// group name has no width pressure from the narrow rail.
    @State private var isHeaderHovered: Bool = false
    /// Tracks whether the current drag gesture has already reported its
    /// `begin` event. SwiftUI's `DragGesture` only exposes `onChanged` /
    /// `onEnded`, so we synthesize a single begin from the first onChanged
    /// callback.
    @State private var hasReportedHeaderDragBegin: Bool = false

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
                // Vertical rail: header chip sits across the full width so
                // the chevron lives at the same left column as the accent
                // bar that follows. The bar only renders alongside the
                // member content, leaving the header row clear of any
                // vertical line above it. `maxHeight: .infinity` on the
                // accent bar forces it to claim the HStack's resolved
                // height — SwiftUI's Shape preferred-size is nil, which
                // could otherwise let the bar render at zero (or shrink
                // during transitions) when a sibling group elsewhere in
                // the rail collapses.
                VStack(alignment: .leading, spacing: 2) {
                    header
                    HStack(alignment: .top, spacing: 4) {
                        accentBar
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                        content()
                    }
                }
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
        .overlay(alignment: floatingLabelAlignment) {
            floatingNameLabel
        }
        .onAppear {
            draftName = group.name
            if isRenamingOnAppear { isEditing = true }
        }
        .onChange(of: group.name) { _, newName in
            if !isEditing { draftName = newName }
        }
    }

    /// Alignment anchor for the hover-revealed floating label. Vertical
    /// docks anchor the label to the header row; horizontal docks anchor
    /// it just outside the cross-axis edge.
    private var floatingLabelAlignment: Alignment {
        switch dockSide {
        case .right: return .topLeading
        case .left:  return .topTrailing
        case .top:   return .topLeading
        case .bottom: return .topLeading
        }
    }

    /// Width budget the floating label uses for offset math. The chip
    /// itself shrinks to text content; the surrounding `.frame` aligns it
    /// against this width so the leading/trailing offset is deterministic.
    /// Stored as computed vars because `PickyHUDDockGroupContainer` is
    /// generic over its content view, and Swift forbids static stored
    /// properties on generic types.
    private var floatingLabelMaxWidth: CGFloat { 160 }
    private var floatingLabelGap: CGFloat { 8 }

    @ViewBuilder
    private var floatingNameLabel: some View {
        if isHeaderHovered && !isEditing {
            HStack(spacing: 5) {
                Circle()
                    .fill(group.color.accent)
                    .frame(width: 6, height: 6)
                Text(group.displayName)
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Cap the text width inside the chip so very long
                    // group names truncate before the chip itself can
                    // overflow the outer alignment box (160 − chrome).
                    .frame(maxWidth: 130, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 2)
            // `fixedSize` makes the chip honor its intrinsic width
            // regardless of what the .overlay's parent (= the ~60px-wide
            // group container) proposes — without this, the chip was being
            // squeezed down to the container's narrow rail width and the
            // group name would render as "···" instead of its real text.
            .fixedSize(horizontal: true, vertical: false)
            // Fixed-width alignment box (not maxWidth) so the offset math
            // below lines up the chip's trailing/leading edge with the
            // dock rail's edge regardless of the chip's intrinsic size.
            .frame(width: floatingLabelMaxWidth, alignment: floatingChipInternalAlignment)
            .offset(floatingLabelOffset)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: floatingLabelEdge)))
            .zIndex(250)
        }
    }

    private var floatingChipInternalAlignment: Alignment {
        switch dockSide {
        case .right: return .trailing
        case .left:  return .leading
        case .top:   return .leading
        case .bottom: return .leading
        }
    }

    private var floatingLabelOffset: CGSize {
        let width = floatingLabelMaxWidth + floatingLabelGap
        switch dockSide {
        case .right: return CGSize(width: -width, height: 0)
        case .left:  return CGSize(width: width, height: 0)
        case .top:   return CGSize(width: 0, height: 24)
        case .bottom: return CGSize(width: 0, height: -24)
        }
    }

    private var floatingLabelEdge: Edge {
        switch dockSide {
        case .right: return .leading
        case .left:  return .trailing
        case .top:   return .top
        case .bottom: return .bottom
        }
    }

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(group.color.accent.opacity(0.78))
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 3) {
            // Always-visible header is intentionally tiny: chevron + accent
            // dot + (count when collapsed). The group name lives in the
            // hover-revealed floating label so the narrow vertical rail
            // never has to truncate it.
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(group.color.accent.opacity(0.9))

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
                Circle()
                    .fill(group.color.accent.opacity(0.75))
                    .frame(width: 5, height: 5)
                if group.isCollapsed {
                    Text("\(group.memberSessionIDs.count)")
                        .pickyFont(size: 8, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: PickyHUDDockGroupHeaderHeight, alignment: .center)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHeaderHovered = hovering
            }
        }
        // Tap anywhere on the header row toggles collapse. The rename
        // affordance moved to the right-click context menu ("Rename")
        // because the always-visible header no longer has a text label to
        // host a double-tap target.
        .onTapGesture {
            guard !isEditing else { return }
            onToggleCollapsed()
        }
        .accessibilityLabel(
            group.isCollapsed
                ? "Expand group \(group.displayName)"
                : "Collapse group \(group.displayName)"
        )
        // Header drag = reorder the entire group block. `minimumDistance`
        // keeps the single-tap toggle and double-tap rename responsive
        // for short cursor moves; only intentional drags begin reorder.
        .simultaneousGesture(
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
/// sit behind it to hint at the hidden siblings. When any member is unread
/// (completed but not yet opened), a small blue chip in the bottom-right
/// corner shows the unread count — mirroring the per-Pickle blue unread
/// dot pattern. The total member count is intentionally not surfaced here
/// because the stack visual + collapsed header already imply "there are
/// more inside".
struct PickyHUDDockCollapsedGroupBadge<Inner: View>: View {
    let unreadCount: Int
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
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .pickyFont(size: 8, weight: .medium)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Colors.accent)
                    )
                    .foregroundColor(.white)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DS.Colors.background, lineWidth: 0.8)
                    )
                    .shadow(color: DS.Colors.accent.opacity(0.45), radius: 2.5, x: 0, y: 0)
                    .offset(x: 4, y: 4)
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(unreadCount) unread")
            }
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
