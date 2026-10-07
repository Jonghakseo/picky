//
//  PickyHUDDockListViews.swift
//  Picky
//
//  Rows, group headers, and placeholders of the list-style dock. Vertical
//  docks stack full-width rows; horizontal docks lay the same content out as
//  fixed-width chips.
//

import AppKit
import SwiftUI

// MARK: - Presentation policies

enum PickyHUDDockRowStatusPresentation {
    static func label(_ status: PickySessionStatus) -> String {
        switch status {
        case .queued: L10n.t("hud.state.queued")
        case .running: L10n.t("hud.conversation.status.running")
        case .waiting_for_input: L10n.t("hud.event.awaitingInput")
        case .blocked: L10n.t("hud.state.blocked")
        case .completed: L10n.t("hud.activity.summary.completed")
        case .failed: L10n.t("hud.conversation.status.failed")
        case .cancelled: L10n.t("hud.state.cancelled")
        }
    }

    /// States that ask the user for something. Running is already a blue
    /// glyph, so a trailing dot is reserved for these and for unread.
    static func needsResponse(_ status: PickySessionStatus) -> Bool {
        switch status {
        case .waiting_for_input, .blocked, .failed: true
        case .queued, .running, .completed, .cancelled: false
        }
    }

    /// Members a collapsed group header counts as unread: sessions the user
    /// has not opened since they finished, plus anything still waiting on
    /// the user (input, blocked, failed) even after it was read.
    @MainActor
    static func groupUnreadCount(members: [PickyHUDDockSession], unreadSessionIDs: Set<String>) -> Int {
        members.reduce(0) { count, member in
            count + (unreadSessionIDs.contains(member.id) || needsResponse(member.status) ? 1 : 0)
        }
    }

    /// Display title: the session title, then the cwd leaf, then "Pickle".
    @MainActor
    static func title(for session: PickyHUDDockSession) -> String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let leaf = (session.cwd ?? "").split(separator: "/").last.map(String.init) ?? ""
        return leaf.isEmpty ? "Pickle" : leaf
    }
}

enum PickyHUDDockRelativeTimePresentation {
    private static let formatter = RelativeDateTimeFormatter()

    static func text(for date: Date, relativeTo now: Date = .now) -> String {
        guard abs(date.timeIntervalSince(now)) >= 60 else {
            return L10n.t("hud.groupList.time.justNow")
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum PickyHUDDockGroupHeaderLayout {
    /// Width of a horizontal group-header chip. The name is measured with the
    /// rendered font and capped, so long names truncate instead of widening
    /// the rail.
    /// Leading padding, swatch button, gaps, the fixed summary slot, chevron,
    /// and trailing padding of a horizontal header chip.
    static let horizontalLeadingPadding: CGFloat = 5
    static let horizontalTrailingPadding: CGFloat = 7
    static let horizontalSpacing: CGFloat = 4
    /// Keeps the swatch button's slot at 13pt (S) / 14pt (M, L).
    static let swatchHitPadding: CGFloat = 2.5
    static let chevronWidth: CGFloat = 8

    /// Fixed slot for the collapsed unread dot or the hover `+`, so status
    /// changes never shift a horizontal rail.
    static func horizontalSummarySlotWidth(metrics: PickyHUDDockMetrics) -> CGFloat {
        max(metrics.rowActionSide, metrics.rowUnreadDotSide)
    }

    /// Rendered name width, capped so long names truncate.
    static func horizontalNameWidth(name: String, metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        let nameFont = NSFont.systemFont(
            ofSize: PickyHUDTypography.supportingNSFont(fontScale: fontScale).pointSize,
            weight: .semibold
        )
        return min(
            ceil((name as NSString).size(withAttributes: [.font: nameFont]).width),
            metrics.horizontalHeaderNameMaxWidth
        )
    }

    static func horizontalChipWidth(
        name: String,
        count: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        let countFont = PickyHUDTypography.supportingNSFont(fontScale: fontScale)
        let nameWidth = horizontalNameWidth(name: name, metrics: metrics, fontScale: fontScale)
        let countWidth = ceil(("\(count)" as NSString).size(withAttributes: [.font: countFont]).width)
        let swatch = metrics.groupHeaderSwatchSide + swatchHitPadding * 2
        let width = horizontalLeadingPadding + swatch
            + horizontalSpacing + nameWidth
            + horizontalSpacing + countWidth
            + horizontalSpacing + horizontalSummarySlotWidth(metrics: metrics)
            + horizontalSpacing + chevronWidth
            + horizontalTrailingPadding
        return ceil(width)
    }
}

// MARK: - Session glyph

/// Status glyph shared by rows and chips: the Picky cursor while armed for
/// the next input, a ring around running work, and a TODO progress ring.
struct PickyHUDDockRowGlyph: View {
    let status: PickySessionStatus
    let todoState: PickyTodoState?
    let isScreenContextTarget: Bool
    let side: CGFloat

    var body: some View {
        let color = PickyDockPickleStatusVisual.color(status)
        let progress = PickyTodoProgressPresentation(state: todoState)
        ZStack {
            if let progress {
                todoRing(progress)
            }
            if isScreenContextTarget {
                Image("PickyCursorNormal")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(DS.Colors.accentText)
                    .scaledToFit()
                    .frame(width: side * 0.86, height: side * 0.86)
            } else if status == .running {
                if progress == nil {
                    Circle()
                        .stroke(color.opacity(0.72), lineWidth: 1.1)
                        .frame(width: side * 1.2, height: side * 1.2)
                }
                PickyDockMiniPickleGlyph(status: status, side: progress == nil ? side * 0.82 : side * 0.72)
            } else {
                PickyDockMiniPickleGlyph(status: status, side: progress == nil ? side : side * 0.72)
            }
        }
        .frame(width: side * 1.25, height: side * 1.25)
        .accessibilityHidden(true)
    }

    private func todoRing(_ progress: PickyTodoProgressPresentation) -> some View {
        ZStack {
            Circle().stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1.3)
            if progress.fraction > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(progress.fraction))
                    .stroke(
                        progress.isComplete ? DS.Colors.success : DS.Colors.info,
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress.fraction)
            }
        }
        .frame(width: side * 1.2, height: side * 1.2)
    }
}

// MARK: - Session row

/// One Pickle in the list dock. A vertical dock renders it as a full-width
/// row, a horizontal dock as a fixed-width chip. The AppKit click host owns
/// open, long-press archive, the context menu, and the reorder handoff.
struct PickyHUDDockSessionRow: View {
    let session: PickyHUDDockSession
    let orientation: PickyHUDDockOrientation
    let isActive: Bool
    let isOpened: Bool
    let isScreenContextArmed: Bool
    let isScreenContextSticky: Bool
    let shortcutNumber: Int?
    let isCommandShortcutHintVisible: Bool
    let shouldFlashCompletion: Bool
    let isUnread: Bool
    let metrics: PickyHUDDockMetrics
    /// The floating copy that follows the cursor during a reorder.
    var isDragging: Bool = false
    var moveTargetGroups: [PickyDockGroup] = []
    var onMoveToGroup: (String) -> Void = { _ in }
    var onUngroup: (() -> Void)?
    var onOpen: () -> Void = {}
    var onToggleScreenContextTarget: () -> Void = {}
    var onToggleStickyScreenContextTarget: () -> Void = {}
    var onCompact: () -> Void = {}
    var onArchive: () -> Void = {}
    var onStop: () -> Void = {}
    var onDoneFlashConsumed: () -> Void = {}
    var onReorderHandoff: (NSPoint) -> Void = { _ in }
    /// Test-only body probe; production callers use the no-op default.
    var onBodyEvaluation: () -> Void = {}

    @State private var isHovered = false
    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @StateObject private var archiveFeedback = PickyHUDArchiveHoldFeedback()
    @Environment(\.pickyAppFontScale) private var fontScale

    private var isScreenContextTarget: Bool { isScreenContextArmed || isScreenContextSticky }
    private var isSelected: Bool { isOpened || isActive }
    private var showsDetailLine: Bool { metrics.showsRowDetailLine }
    private var showsShortcut: Bool { isCommandShortcutHintVisible && shortcutNumber != nil }
    private var showsArchiveAction: Bool { isHovered && !showsShortcut && !isDragging }

    var body: some View {
        let _ = onBodyEvaluation()
        let _ = PickyPerf.event("dock_row_body")
        content
            .padding(.horizontal, metrics.rowHorizontalPadding)
            .frame(
                width: orientation == .horizontal ? metrics.chipWidth : nil,
                height: orientation == .horizontal
                    ? metrics.chipHeight(fontScale: fontScale)
                    : metrics.rowHeight(fontScale: fontScale)
            )
            .frame(maxWidth: orientation == .vertical ? .infinity : nil)
            .background(rowBackground)
            .opacity(session.status == .cancelled ? 0.6 : 1)
            .scaleEffect(isDragging ? 1.03 : (archiveFeedback.isPressing ? 0.97 : 1))
            .shadow(color: .black.opacity(isDragging ? 0.28 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 3 : 0)
            .contentShape(RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous))
            .overlay {
                if !isDragging {
                    PickyHUDDockIconClickHost(
                        onHoverChanged: { isHovered = $0 },
                        onOpen: onOpen,
                        holes: clickHostHoles,
                        isScreenContextArmed: isScreenContextArmed,
                        isScreenContextSticky: isScreenContextSticky,
                        canCompact: actionAvailability.canCompact,
                        canStop: actionAvailability.canStop,
                        onToggleScreenContextTarget: onToggleScreenContextTarget,
                        onToggleStickyScreenContextTarget: onToggleStickyScreenContextTarget,
                        onCompact: onCompact,
                        onArchivePressing: { archiveFeedback.setPressing($0) },
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
            }
            .overlay(alignment: .trailing) {
                // The click host declines this slot, so the button owns it.
                if showsArchiveAction {
                    Button(action: onArchive) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 10, weight: .semibold)) // design-token-exception: optical glyph inside the 18pt row action.
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: metrics.rowActionSide, height: metrics.rowActionSide)
                            .background(
                                DS.Colors.surface3,
                                in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact - 1, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(L10n.t("group.list.action.archive"))
                    .accessibilityLabel(L10n.t("group.list.action.archive"))
                    .padding(.trailing, metrics.rowHorizontalPadding - 2)
                }
            }
            .onAppear {
                if shouldFlashCompletion { runCompletionFlash() }
            }
            .onChange(of: shouldFlashCompletion) { _, shouldFlash in
                if shouldFlash { runCompletionFlash() }
            }
            .onDisappear {
                completionFlashTask?.cancel()
                completionFlashTask = nil
                archiveFeedback.cancel()
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help(PickyHUDDockRowStatusPresentation.title(for: session))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("dock.pickle.open.accessibility", PickyHUDDockRowStatusPresentation.title(for: session)))
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(L10n.t("dock.pickle.interaction.help"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: Text(L10n.t("group.list.action.archive")), onArchive)
    }

    /// The hovered archive button's own frame at the trailing edge. The band
    /// above and below it keeps belonging to the row.
    private var clickHostHoles: PickyHUDDockClickHostHoles {
        guard showsArchiveAction else { return .none }
        return PickyHUDDockClickHostHoles(trailing: .init(
            inset: metrics.rowHorizontalPadding - 2,
            width: metrics.rowActionSide,
            height: metrics.rowActionSide
        ))
    }

    private var content: some View {
        HStack(spacing: metrics.rowContentSpacing) {
            PickyHUDDockRowGlyph(
                status: session.status,
                todoState: session.todoState,
                isScreenContextTarget: isScreenContextTarget,
                side: metrics.rowGlyphSide
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(PickyHUDDockRowStatusPresentation.title(for: session))
                    .font(PickyHUDTypography.bodyMedium)
                    .foregroundStyle(
                        session.status == .completed && !isSelected && !isUnread
                            ? DS.Colors.textBody : DS.Colors.textPrimary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsDetailLine {
                    detailLine
                }
            }
            Spacer(minLength: 2)
            trailingAccessory
                .opacity(showsArchiveAction ? 0 : 1)
        }
        .opacity(archiveFeedback.isPressing ? 0.7 : 1)
    }

    private var detailLine: some View {
        HStack(spacing: 0) {
            if session.status != .completed {
                Text(PickyHUDDockRowStatusPresentation.label(session.status))
                    .foregroundStyle(PickyDockPickleStatusVisual.color(session.status))
                Text(" · ").foregroundStyle(DS.Colors.textTertiary)
            }
            Text(PickyHUDDockRelativeTimePresentation.text(for: session.previewUpdatedAt))
                .foregroundStyle(DS.Colors.textTertiary)
        }
        .font(PickyHUDTypography.meta)
        .lineLimit(1)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        HStack(spacing: 4) {
            if isScreenContextSticky {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold)) // design-token-exception: optical pin mark beside the row title.
                    .foregroundStyle(DS.Colors.accentText)
            }
            if showsShortcut, let shortcutNumber {
                PickyShortcutKeyBadge(label: "\(shortcutNumber)")
                    .transition(.opacity)
            } else if isUnread {
                Circle()
                    .fill(DS.Colors.notification)
                    .frame(width: metrics.rowUnreadDotSide, height: metrics.rowUnreadDotSide)
            } else if PickyHUDDockRowStatusPresentation.needsResponse(session.status) {
                Circle()
                    .fill(PickyDockPickleStatusVisual.color(session.status))
                    .frame(width: metrics.rowAttentionDotSide, height: metrics.rowAttentionDotSide)
            }
        }
    }

    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(
                isDragging ? DS.Colors.surface3
                    : isSelected ? DS.Colors.accentSubtle
                    : isHovered ? DS.Colors.surface2 : Color.clear
            )
            shape.fill(DS.Colors.success.opacity(0.24 * completionFlashIntensity))
            if archiveFeedback.isPressing || archiveFeedback.progress > 0 {
                GeometryReader { proxy in
                    shape
                        .fill(DS.Colors.warning.opacity(0.24))
                        .frame(width: proxy.size.width * archiveFeedback.progress)
                }
                .clipShape(shape)
            }
            if isScreenContextTarget {
                shape.strokeBorder(DS.Colors.accentText.opacity(0.85), lineWidth: 1)
            }
        }
    }

    private var actionAvailability: PickyHUDDockSessionActionAvailability {
        PickyHUDDockSessionActionAvailability.resolve(
            status: session.status,
            canRequestCompaction: session.canRequestDockCompaction
        )
    }

    private var accessibilityValue: String {
        var parts = [PickyHUDDockRowStatusPresentation.label(session.status)]
        if isUnread { parts.append(L10n.t("dock.unread")) }
        return parts.joined(separator: ", ")
    }

    private func runCompletionFlash() {
        completionFlashTask?.cancel()
        onDoneFlashConsumed()
        completionFlashTask = Task { @MainActor in
            for _ in 0..<2 {
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.18)) { completionFlashIntensity = 1.0 }
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.45)) { completionFlashIntensity = 0.0 }
                try? await Task.sleep(nanoseconds: 480_000_000)
            }
        }
    }
}

// MARK: - Group header

/// Header of a group section. Clicking toggles the inline member list; the
/// color swatch opens the color menu and `+` creates a Pickle in this group.
/// A collapsed header keeps attention glyphs and an unread dot visible.
struct PickyHUDDockGroupHeaderRow<AddButton: View>: View {
    let group: PickyDockGroup
    let orientation: PickyHUDDockOrientation
    let members: [PickyHUDDockSession]
    /// See `PickyHUDDockRowStatusPresentation.groupUnreadCount`.
    let unreadCount: Int
    let metrics: PickyHUDDockMetrics
    let isSelected: Bool
    let isDropTargeted: Bool
    /// Keeps hover affordances visible while the group's new-Pickle popover is open.
    let isAddPresented: Bool
    let onToggleCollapsed: () -> Void
    let onSetColor: (PickyDockGroupColor) -> Void
    let onReorderBegan: () -> Void
    let onReorderChanged: (CGSize) -> Void
    let onReorderEnded: (CGSize) -> Void
    @ViewBuilder let addButton: () -> AddButton

    @State private var isHovered = false
    @Environment(\.pickyAppFontScale) private var fontScale

    private var showsActions: Bool { isHovered || isAddPresented }

    private var contentSpacing: CGFloat {
        orientation == .horizontal ? PickyHUDDockGroupHeaderLayout.horizontalSpacing : 6
    }

    private var leadingPadding: CGFloat {
        orientation == .horizontal ? PickyHUDDockGroupHeaderLayout.horizontalLeadingPadding : 1
    }

    private var trailingPadding: CGFloat {
        orientation == .horizontal
            ? PickyHUDDockGroupHeaderLayout.horizontalTrailingPadding
            : metrics.rowHorizontalPadding
    }

    /// The color swatch at the leading edge and, while hovered, the `+` that sits
    /// just inside the chevron. The chevron itself stays on the host so it
    /// keeps toggling the group, and so does the band above and below both
    /// buttons.
    private var clickHostHoles: PickyHUDDockClickHostHoles {
        let swatchSlot = metrics.groupHeaderSwatchSide + PickyHUDDockGroupHeaderLayout.swatchHitPadding * 2
        let actionWidth = orientation == .horizontal
            ? PickyHUDDockGroupHeaderLayout.horizontalSummarySlotWidth(metrics: metrics)
            : metrics.rowActionSide
        return PickyHUDDockClickHostHoles(
            leading: .init(inset: leadingPadding, width: swatchSlot, height: swatchSlot),
            trailing: showsActions
                ? .init(
                    inset: trailingPadding + PickyHUDDockGroupHeaderLayout.chevronWidth + contentSpacing,
                    width: actionWidth,
                    height: metrics.rowActionSide
                )
                : nil
        )
    }

    var body: some View {
        HStack(spacing: contentSpacing) {
            colorMenu
            Text(group.displayName)
                .font(PickyHUDTypography.supportingSemibold)
                .foregroundStyle(showsActions || isDropTargeted ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    width: orientation == .horizontal
                        ? PickyHUDDockGroupHeaderLayout.horizontalNameWidth(
                            name: group.displayName, metrics: metrics, fontScale: fontScale)
                        : nil,
                    alignment: .leading
                )
                .allowsHitTesting(false)
            Text("\(members.count)")
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textTertiary)
                .layoutPriority(1)
                .fixedSize()
                .allowsHitTesting(false)
            if orientation == .vertical {
                Spacer(minLength: 2)
                // An empty summary still costs a stack gap, which would
                // truncate a collapsed name earlier than the expanded one.
                if hasTrailingSummary {
                    trailingSummary
                }
            } else {
                // Keep a real view in the slot: a frame on an empty view
                // collapses, so the `+` would widen the chip on hover.
                ZStack { trailingSummary }
                    .frame(
                        width: PickyHUDDockGroupHeaderLayout.horizontalSummarySlotWidth(metrics: metrics),
                        height: metrics.rowActionSide
                    )
            }
            chevron
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(
            height: orientation == .horizontal
                ? metrics.chipHeight(fontScale: fontScale)
                : metrics.groupHeaderHeight(fontScale: fontScale)
        )
        .frame(maxWidth: orientation == .vertical ? .infinity : nil)
        .background {
            // The native host owns click (toggle) versus drag (group reorder),
            // except in the holes it leaves for the color menu and the `+`.
            ZStack {
                headerBackground.allowsHitTesting(false)
                PickyHUDDockGroupTileClickHost(
                    onHoverChanged: { isHovered = $0 },
                    onActivate: onToggleCollapsed,
                    holes: clickHostHoles,
                    onReorderBegan: onReorderBegan,
                    onReorderChanged: onReorderChanged,
                    onReorderEnded: onReorderEnded
                )
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsActions)
        .help(group.displayName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.displayName)
        .accessibilityValue(
            L10n.t("group.folder.accessibility.value", members.count, unreadCount) + ", "
                + L10n.t(group.isCollapsed ? "common.collapsed" : "common.expanded")
        )
        .accessibilityAddTraits(isSelected ? [.isHeader, .isSelected] : .isHeader)
        .accessibilityAction(named: Text(L10n.t(group.isCollapsed ? "group.menu.expand" : "group.menu.collapse")), onToggleCollapsed)
    }

    /// A plain button that opens a native color menu. SwiftUI `Menu` labels
    /// on macOS do not draw arbitrary shapes, so the swatch would disappear.
    private var colorMenu: some View {
        Button {
            PickyHUDDockGroupColorMenu.present(current: group.color, onSelect: onSetColor)
        } label: {
            RoundedRectangle(cornerRadius: metrics.groupHeaderSwatchCornerRadius, style: .continuous)
                .fill(group.color.accent)
                .frame(width: metrics.groupHeaderSwatchSide, height: metrics.groupHeaderSwatchSide)
                .padding(PickyHUDDockGroupHeaderLayout.swatchHitPadding)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.compact - 2, style: .continuous)
                        .fill(showsActions ? DS.Colors.surface3 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(PickyHUDDockGroupContextMenuPresentation.colorTitle)
        .accessibilityLabel(PickyHUDDockGroupContextMenuPresentation.colorTitle)
        .accessibilityValue(group.color.localizedName)
    }

    private var hasTrailingSummary: Bool {
        showsActions || (group.isCollapsed && unreadCount > 0)
    }

    /// A collapsed header shows one unread dot; per-Pickle status lives in
    /// the expanded rows.
    @ViewBuilder
    private var trailingSummary: some View {
        if showsActions {
            addButton()
        } else if group.isCollapsed, unreadCount > 0 {
            Circle()
                .fill(DS.Colors.notification)
                .frame(width: metrics.rowUnreadDotSide, height: metrics.rowUnreadDotSide)
                .allowsHitTesting(false)
        }
    }

    private var chevron: some View {
        Image(systemName: chevronSymbol)
            .font(.system(size: 8, weight: .bold)) // design-token-exception: optical disclosure glyph in a compact header.
            .foregroundStyle(DS.Colors.textTertiary)
            .frame(width: PickyHUDDockGroupHeaderLayout.chevronWidth)
            .allowsHitTesting(false)
    }

    private var chevronSymbol: String {
        switch orientation {
        case .vertical: group.isCollapsed ? "chevron.right" : "chevron.down"
        case .horizontal: group.isCollapsed ? "chevron.right" : "chevron.left"
        }
    }

    private var headerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
        let collapsedChipTint = orientation == .horizontal && group.isCollapsed
        return ZStack {
            shape.fill(
                isDropTargeted ? DS.Colors.accentSubtle
                    : showsActions ? DS.Colors.surface2
                    : isSelected ? DS.Colors.accentSubtle
                    : collapsedChipTint ? group.color.accent.opacity(0.08) : Color.clear
            )
            if isDropTargeted {
                shape.strokeBorder(DS.Colors.accentText, lineWidth: 1.2)
            }
        }
    }
}

/// Native color menu opened from a group header's color swatch.
@MainActor
enum PickyHUDDockGroupColorMenu {
    private final class Target: NSObject {
        let onSelect: (PickyDockGroupColor) -> Void
        init(onSelect: @escaping (PickyDockGroupColor) -> Void) { self.onSelect = onSelect }

        @objc func select(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? Int,
                  let color = PickyDockGroupColor(rawValue: raw) else { return }
            onSelect(color)
        }
    }

    static func present(current: PickyDockGroupColor, onSelect: @escaping (PickyDockGroupColor) -> Void) {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let target = Target(onSelect: onSelect)
        let menu = NSMenu()
        for color in PickyDockGroupColor.palette {
            let item = NSMenuItem(title: color.localizedName, action: #selector(Target.select(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = color.rawValue
            item.image = color.menuSwatchImage
            item.state = color == current ? .on : .off
            menu.addItem(item)
        }
        // Runs a modal tracking loop, so `target` stays alive until a choice is made.
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        withExtendedLifetime(target) {}
    }
}

/// `+` inside a hovered group header.
struct PickyHUDDockGroupAddButton: View {
    let side: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold)) // design-token-exception: optical glyph inside the 18pt header action.
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: side, height: side)
                .background(
                    DS.Colors.surface3,
                    in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact - 1, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.t("group.list.newPickle.accessibilityLabel"))
        .accessibilityLabel(L10n.t("group.list.newPickle.accessibilityLabel"))
        .accessibilityHint(L10n.t("group.list.newPickle.hint"))
    }
}

/// Drop target shown inside an expanded group with no visible members.
/// Clicking it starts a Pickle in this group.
struct PickyHUDDockEmptyGroupPlaceholder: View {
    let orientation: PickyHUDDockOrientation
    let metrics: PickyHUDDockMetrics
    let isDropTargeted: Bool
    let onCreatePickle: () -> Void

    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        Button(action: onCreatePickle) {
            Text(L10n.t("dock.group.empty.dropHint"))
                .font(PickyHUDTypography.meta)
                .foregroundStyle(isDropTargeted ? DS.Colors.accentText : DS.Colors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, DS.Spacing.space1)
                .frame(
                    width: orientation == .horizontal ? metrics.chipWidth : nil,
                    height: orientation == .horizontal
                        ? metrics.chipHeight(fontScale: fontScale)
                        : metrics.rowHeight(fontScale: fontScale)
                )
                .frame(maxWidth: orientation == .vertical ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                        .fill(isDropTargeted ? DS.Colors.accentSubtle : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? DS.Colors.accentText : DS.Colors.borderStrong,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
    }
}
