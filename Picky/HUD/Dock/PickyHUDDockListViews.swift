//
//  PickyHUDDockListViews.swift
//  Picky
//
//  Rows, group headers, and placeholders of the list-style dock. Vertical
//  docks stack full-width rows; horizontal docks lay the same content out as
//  fixed-width chips, or as bounded square icon cells when the rail opts into
//  `pickyDockHorizontalLayout`.
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
        // Shared formatter: re-apply the app language on every call so a
        // runtime language switch is honored.
        formatter.locale = LocaleManager.nonisolatedEffectiveLocale
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
    /// Mirrors the native host's hover so the rail can show this Pickle's name
    /// in its shared title preview. Hover still drives the row's own visuals.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// Test-only body probe; production callers use the no-op default.
    var onBodyEvaluation: () -> Void = {}

    @State private var isHovered = false
    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @StateObject private var archiveFeedback = PickyHUDArchiveHoldFeedback()
    @StateObject private var archiveReveal = PickyHUDArchiveHoverReveal()
    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.pickyDockCompactLayout) private var environmentCompactLayout
    @Environment(\.pickyDockHorizontalLayout) private var environmentHorizontalLayout

    private var isScreenContextTarget: Bool { isScreenContextArmed || isScreenContextSticky }
    private var isSelected: Bool { isOpened || isActive }
    private var showsDetailLine: Bool { metrics.showsRowDetailLine }
    private var showsShortcut: Bool { isCommandShortcutHintVisible && shortcutNumber != nil }

    /// Compact placement only applies to the vertical list. A horizontal rail
    /// draws fixed-width chips and has no edge lane to collapse into.
    private var compactLayout: PickyHUDDockCompactLayout? {
        orientation == .vertical ? environmentCompactLayout : nil
    }

    /// Bounded horizontal rail: one fixed square cell, no inline title. The
    /// name is read from the rail's shared preview instead.
    private var isHorizontalCompact: Bool {
        orientation == .horizontal && environmentHorizontalLayout
    }

    private var horizontalCompactCellSide: CGFloat {
        metrics.horizontalCompactCellSide(fontScale: fontScale)
    }

    /// The archive affordance lives in the label lane, so a compact dock only
    /// offers it while the labels are actually on screen. The fixed icon lane
    /// keeps showing the Pickle's status glyph at every width. A bounded
    /// horizontal cell has no label lane at all: the rail puts a visible
    /// archive action in its shared preview, and holding the cell still
    /// archives natively.
    private var showsArchiveAction: Bool {
        isHovered && archiveReveal.isRevealed && !showsShortcut && !isDragging && !isHorizontalCompact
            && (compactLayout?.showsLabels ?? true)
    }

    private var frameWidth: CGFloat? {
        if isHorizontalCompact { return horizontalCompactCellSide }
        return orientation == .horizontal ? metrics.chipWidth : nil
    }

    private var frameHeight: CGFloat {
        if isHorizontalCompact { return horizontalCompactCellSide }
        return orientation == .horizontal
            ? metrics.chipHeight(fontScale: fontScale)
            : metrics.rowHeight(fontScale: fontScale)
    }

    var body: some View {
        let _ = onBodyEvaluation()
        let _ = PickyPerf.event("dock_row_body")
        content
            .padding(.horizontal, compactLayout == nil && !isHorizontalCompact ? metrics.rowHorizontalPadding : 0)
            .frame(width: frameWidth, height: frameHeight)
            .frame(maxWidth: orientation == .vertical ? .infinity : nil)
            .background(
                rowBackground
                    .padding(isHorizontalCompact ? PickyHUDDockHorizontalCompactLayout.fillInset : 0)
            )
            .opacity(session.status == .cancelled ? 0.6 : 1)
            .scaleEffect(isDragging ? 1.03 : (archiveFeedback.isPressing ? 0.97 : 1))
            .shadow(color: .black.opacity(isDragging ? 0.28 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 3 : 0)
            .contentShape(RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous))
            .overlay {
                if !isDragging {
                    PickyHUDDockIconClickHost(
                        onHoverChanged: { updateHover($0) },
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
                    .padding(.trailing, archiveTrailingInset)
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
                archiveReveal.cancel()
                // The native host is gone, so it can no longer report the
                // exit. Without this the rail would keep this Pickle's name in
                // its shared preview after the row disappears.
                if isHovered { updateHover(false) }
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: archiveReveal.isRevealed)
            // The horizontal rail already shows the name in its preview row;
            // a tooltip there only repeats it. VoiceOver reads the label below.
            .help(isHorizontalCompact ? "" : PickyHUDDockRowStatusPresentation.title(for: session))
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
            inset: archiveTrailingInset,
            width: metrics.rowActionSide,
            height: metrics.rowActionSide
        ))
    }

    /// Shared by the archive button's own padding and by the hole the click
    /// host punches for it, so the declined rect always matches the button.
    private var archiveTrailingInset: CGFloat {
        let outer = metrics.rowHorizontalPadding - 2
        guard let compactLayout else { return outer }
        return compactLayout.rowTrailingInset(outer: outer)
    }

    private func updateHover(_ hovering: Bool) {
        if isHovered != hovering { isHovered = hovering }
        archiveReveal.setHovering(hovering)
        onHoverChanged(hovering)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if isHorizontalCompact {
                horizontalCompactContent
            } else if let compactLayout {
                compactContent(compactLayout)
            } else {
                standardContent
            }
        }
        .opacity(archiveFeedback.isPressing ? 0.7 : 1)
    }

    private var standardContent: some View {
        HStack(spacing: metrics.rowContentSpacing) {
            glyph
            titleBlock
            Spacer(minLength: 2)
            trailingAccessory
                .opacity(showsArchiveAction ? 0 : 1)
        }
    }

    /// Same glyph, title, and accessories as the classic row, split across the
    /// fixed icon lane and the label lane. Unread and attention marks ride on
    /// the glyph so they stay readable while the labels are clipped away.
    private func compactContent(_ layout: PickyHUDDockCompactLayout) -> some View {
        PickyHUDDockCompactLanes(layout: layout) {
            glyph
                .overlay(alignment: layout.badgeAlignment) {
                    compactIconBadge
                        .offset(
                            x: layout.badgeOffset(2).width,
                            y: layout.badgeOffset(2).height
                        )
                }
        } label: {
            HStack(spacing: metrics.rowContentSpacing) {
                titleBlock
                Spacer(minLength: 2)
                compactLabelAccessory
                    .opacity(showsArchiveAction ? 0 : 1)
            }
            // design-token-exception: approved 2pt inset for compact row titles.
            .padding(.leading, layout.labelLeadingPadding(outer: metrics.rowHorizontalPadding) + 2)
            .padding(.trailing, layout.labelTrailingPadding(outer: metrics.rowHorizontalPadding))
        }
    }

    /// Bounded horizontal cell: the same glyph and marks as every other
    /// layout, with the title and the inline archive button dropped. The ⌘
    /// hint replaces the glyph the way it replaces the trailing accessory in a
    /// classic row, because a 36pt cell cannot show both.
    private var horizontalCompactContent: some View {
        ZStack {
            if showsShortcut, let shortcutNumber {
                PickyShortcutKeyBadge(label: "\(shortcutNumber)")
                    .transition(.opacity)
            } else {
                glyph
                    .overlay(alignment: PickyHUDDockHorizontalCompactLayout.badgeAlignment) {
                        compactIconBadge
                            .offset(
                                x: PickyHUDDockHorizontalCompactLayout.badgeOffset(2).width,
                                y: PickyHUDDockHorizontalCompactLayout.badgeOffset(2).height
                            )
                    }
                    .overlay(alignment: PickyHUDDockHorizontalCompactLayout.markerAlignment) {
                        if isScreenContextSticky {
                            stickyMark
                                .offset(
                                    x: PickyHUDDockHorizontalCompactLayout.markerOffset(2).width,
                                    y: PickyHUDDockHorizontalCompactLayout.markerOffset(2).height
                                )
                        }
                    }
            }
        }
        .frame(width: horizontalCompactCellSide, height: horizontalCompactCellSide)
    }

    private var glyph: some View {
        PickyHUDDockRowGlyph(
            status: session.status,
            todoState: session.todoState,
            isScreenContextTarget: isScreenContextTarget,
            side: metrics.rowGlyphSide
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PickyHUDDockRowStatusPresentation.title(for: session))
                .pickyFont(size: metrics.pickleTitleFontSize, weight: .medium)
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

    /// Unread wins over the status mark, matching the classic row's trailing
    /// accessory. The command-number hint is not mirrored here: it is a
    /// label-lane hint and would not fit beside a 15pt glyph.
    @ViewBuilder
    private var compactIconBadge: some View {
        if isUnread {
            Circle()
                .fill(DS.Colors.notification)
                .frame(width: metrics.rowUnreadDotSide, height: metrics.rowUnreadDotSide)
        } else if PickyHUDDockRowStatusPresentation.needsResponse(session.status) {
            Circle()
                .fill(PickyDockPickleStatusVisual.color(session.status))
                .frame(width: metrics.rowAttentionDotSide, height: metrics.rowAttentionDotSide)
        }
    }

    /// Label-lane half of the trailing accessory. Unread and attention marks
    /// moved to the glyph, so only the sticky pin and the ⌘ number remain.
    @ViewBuilder
    private var compactLabelAccessory: some View {
        HStack(spacing: 4) {
            if isScreenContextSticky {
                stickyMark
            }
            if showsShortcut, let shortcutNumber {
                PickyShortcutKeyBadge(label: "\(shortcutNumber)")
                    .transition(.opacity)
            }
        }
    }

    /// Sticky screen-context mark, shared by every layout so the pin reads the
    /// same whether it sits beside a title or on a bounded cell.
    private var stickyMark: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold)) // design-token-exception: optical pin mark beside the row title.
            .foregroundStyle(DS.Colors.accentText)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        HStack(spacing: 4) {
            if isScreenContextSticky {
                stickyMark
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
    /// Mirrors the native host's hover so the rail can show this group's name
    /// in its shared title preview. Hover still drives the header's own visuals.
    var onHoverChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let addButton: () -> AddButton

    @State private var isHovered = false
    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.pickyDockCompactLayout) private var environmentCompactLayout
    @Environment(\.pickyDockHorizontalLayout) private var environmentHorizontalLayout

    private var showsActions: Bool { isHovered || isAddPresented }

    private var compactLayout: PickyHUDDockCompactLayout? {
        orientation == .vertical ? environmentCompactLayout : nil
    }

    /// Bounded horizontal rail: one fixed square folder cell. The name, the
    /// color control, and `+` move to the rail's shared preview, so the native
    /// host keeps the whole cell as a single collapse/expand and reorder target.
    private var isHorizontalCompact: Bool {
        orientation == .horizontal && environmentHorizontalLayout
    }

    private var horizontalCompactCellSide: CGFloat {
        metrics.horizontalCompactCellSide(fontScale: fontScale)
    }

    /// Hover affordances that live in the label lane. A compact header keeps
    /// its hover tint on the visible lane, but never leaves the `+` or the
    /// color swatch behind the clip as a click, keyboard, or VoiceOver target.
    private var showsLabelActions: Bool {
        showsActions && !isHorizontalCompact && (compactLayout?.showsLabels ?? true)
    }

    private var showsColorSwatch: Bool {
        !isHorizontalCompact && (compactLayout?.showsLabels ?? true)
    }

    /// A compact list has no padding of its own, so the classic 1pt leading
    /// inset would push the swatch onto the shell border.
    private var headerOuterPadding: CGFloat { metrics.rowHorizontalPadding }

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

    /// Only color and add controls decline native header clicks. Compact
    /// headers use the folder for disclosure; classic headers retain a chevron.
    private var clickHostHoles: PickyHUDDockClickHostHoles {
        // A bounded cell draws no SwiftUI control of its own, so the host owns
        // every point of the square.
        guard !isHorizontalCompact else { return .none }
        let swatchSlot = metrics.groupHeaderSwatchSide + PickyHUDDockGroupHeaderLayout.swatchHitPadding * 2
        let actionWidth = orientation == .horizontal
            ? PickyHUDDockGroupHeaderLayout.horizontalSummarySlotWidth(metrics: metrics)
            : metrics.rowActionSide
        return PickyHUDDockClickHostHoles(
            leading: showsColorSwatch
                ? .init(inset: leadingControlInset, width: swatchSlot, height: swatchSlot)
                : nil,
            trailing: showsLabelActions
                ? .init(
                    inset: trailingControlInset + (compactLayout == nil
                        ? PickyHUDDockGroupHeaderLayout.chevronWidth + contentSpacing : 0),
                    width: actionWidth,
                    height: metrics.rowActionSide
                )
                : nil
        )
    }

    /// Holes are measured from the header's own bounds, so a compact header has
    /// to add the fixed icon lane back in on whichever side it occupies.
    private var leadingControlInset: CGFloat {
        guard let compactLayout else { return leadingPadding }
        return compactLayout.rowLeadingInset(outer: headerOuterPadding)
    }

    private var trailingControlInset: CGFloat {
        guard let compactLayout else { return trailingPadding }
        return compactLayout.rowTrailingInset(outer: headerOuterPadding)
    }

    private var frameWidth: CGFloat? {
        isHorizontalCompact ? horizontalCompactCellSide : nil
    }

    private var frameHeight: CGFloat {
        if isHorizontalCompact { return horizontalCompactCellSide }
        return orientation == .horizontal
            ? metrics.chipHeight(fontScale: fontScale)
            : metrics.groupHeaderHeight(fontScale: fontScale)
    }

    var body: some View {
        Group {
            if isHorizontalCompact {
                folderIcon(
                    badgeAlignment: PickyHUDDockHorizontalCompactLayout.badgeAlignment,
                    badgeOffset: PickyHUDDockHorizontalCompactLayout.badgeOffset(2)
                )
            } else if let compactLayout {
                PickyHUDDockCompactLanes(layout: compactLayout) {
                    folderIcon(
                        badgeAlignment: compactLayout.badgeAlignment,
                        badgeOffset: compactLayout.badgeOffset(3)
                    )
                } label: {
                    headerContent
                        .padding(.leading, compactLayout.labelLeadingPadding(outer: headerOuterPadding))
                        .padding(.trailing, compactLayout.labelTrailingPadding(outer: headerOuterPadding))
                        .accessibilityHidden(!compactLayout.showsLabels)
                }
            } else {
                headerContent
                    .padding(.leading, leadingPadding)
                    .padding(.trailing, trailingPadding)
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .frame(maxWidth: orientation == .vertical ? .infinity : nil)
        .background {
            // The native host owns click (toggle) versus drag (group reorder),
            // except in the holes it leaves for the color menu and the `+`.
            // The folder lane deliberately keeps no hole, so clicking the
            // folder toggles the group like the rest of the header.
            ZStack {
                headerBackground
                    .padding(isHorizontalCompact ? PickyHUDDockHorizontalCompactLayout.fillInset : 0)
                    .allowsHitTesting(false)
                PickyHUDDockGroupTileClickHost(
                    onHoverChanged: { updateHover($0) },
                    onActivate: onToggleCollapsed,
                    holes: clickHostHoles,
                    onReorderBegan: onReorderBegan,
                    onReorderChanged: onReorderChanged,
                    onReorderEnded: onReorderEnded
                )
            }
        }
        .onDisappear {
            // The native host can no longer report the exit, so the rail would
            // otherwise keep this group's name in its shared preview.
            if isHovered { updateHover(false) }
        }
        .animation(.easeOut(duration: 0.12), value: showsActions)
        .help(isHorizontalCompact ? "" : group.displayName)
        .accessibilityElement(children: isHorizontalCompact ? .ignore : .contain)
        .accessibilityLabel(group.displayName)
        .accessibilityValue(
            L10n.t("group.folder.accessibility.value", members.count, unreadCount) + ", "
                + L10n.t(group.isCollapsed ? "common.collapsed" : "common.expanded")
        )
        .accessibilityAddTraits(isSelected ? [.isHeader, .isSelected] : .isHeader)
        .accessibilityAction(named: Text(L10n.t(group.isCollapsed ? "group.menu.expand" : "group.menu.collapse")), onToggleCollapsed)
    }

    private func updateHover(_ hovering: Bool) {
        if isHovered != hovering { isHovered = hovering }
        onHoverChanged(hovering)
    }

    /// Group identity that survives a layout with no room for the name: the
    /// group color on a folder, plus the collapsed unread mark that would
    /// otherwise sit in the labels.
    private func folderIcon(badgeAlignment: Alignment, badgeOffset: CGSize) -> some View {
        PickyHUDDockGroupFolderGlyph(
            group: group,
            unreadCount: unreadCount,
            side: metrics.rowActionSide,
            unreadDotSide: metrics.rowUnreadDotSide,
            badgeAlignment: badgeAlignment,
            badgeOffset: badgeOffset
        )
    }

    private var headerContent: some View {
        HStack(spacing: contentSpacing) {
            if showsColorSwatch {
                colorMenu
            }
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
            if compactLayout == nil { chevron }
        }
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(PickyHUDDockGroupContextMenuPresentation.colorTitle)
        .accessibilityLabel(PickyHUDDockGroupContextMenuPresentation.colorTitle)
        .accessibilityValue(group.color.localizedName)
    }

    private var hasTrailingSummary: Bool {
        if compactLayout != nil { return showsLabelActions }
        return showsActions || (group.isCollapsed && unreadCount > 0)
    }

    /// A collapsed header shows one unread dot; per-Pickle status lives in
    /// the expanded rows. A compact header moves that dot onto the folder in
    /// the fixed lane, where it stays visible at the resting width.
    @ViewBuilder
    private var trailingSummary: some View {
        if showsLabelActions {
            addButton()
        } else if compactLayout == nil, group.isCollapsed, unreadCount > 0 {
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

/// Always-present `+` at the end of an expanded group in the horizontal rail.
/// It sits next to the group's cells, so starting a Pickle in the group never
/// depends on the hover-driven preview row staying on that group.
struct PickyHUDDockGroupAddSlot: View {
    let metrics: PickyHUDDockMetrics
    let isPresented: Bool
    let onHoverChanged: (Bool) -> Void
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.pickyAppFontScale) private var fontScale

    private var isHighlighted: Bool { isHovered || isPresented }

    var body: some View {
        let cell = metrics.horizontalCompactCellSide(fontScale: fontScale)
        let width = metrics.horizontalGroupAddSlotWidth(fontScale: fontScale)
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold)) // design-token-exception: optical glyph inside the narrow group add slot.
                .foregroundStyle(isHighlighted ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(width: width - 4, height: max(metrics.rowActionSide, cell - 14))
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous)
                        .fill(isHighlighted ? DS.Colors.surface3 : Color.clear)
                )
                .frame(width: width, height: cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            if isHovered != hovering { isHovered = hovering }
            onHoverChanged(hovering)
        }
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
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
    @Environment(\.pickyDockCompactLayout) private var environmentCompactLayout
    @Environment(\.pickyDockHorizontalLayout) private var environmentHorizontalLayout

    private var compactLayout: PickyHUDDockCompactLayout? {
        orientation == .vertical ? environmentCompactLayout : nil
    }

    /// Bounded horizontal rail: the drop hint shrinks to the same square cell
    /// as every other entry, keeping only the `+`.
    private var isHorizontalCompact: Bool {
        orientation == .horizontal && environmentHorizontalLayout
    }

    private var frameWidth: CGFloat? {
        if isHorizontalCompact { return metrics.horizontalCompactCellSide(fontScale: fontScale) }
        return orientation == .horizontal ? metrics.chipWidth : nil
    }

    private var frameHeight: CGFloat {
        if isHorizontalCompact { return metrics.horizontalCompactCellSide(fontScale: fontScale) }
        return orientation == .horizontal
            ? metrics.chipHeight(fontScale: fontScale)
            : metrics.rowHeight(fontScale: fontScale)
    }

    private var tint: Color {
        isDropTargeted ? DS.Colors.accentText : DS.Colors.textTertiary
    }

    /// Keeps a bounded cell's dashed outline off its neighbours, matching the
    /// inset the session and group cells use for their fills.
    private var chromeInset: CGFloat {
        isHorizontalCompact ? PickyHUDDockHorizontalCompactLayout.fillInset : 0
    }

    var body: some View {
        Button(action: onCreatePickle) {
            content
                .frame(width: frameWidth, height: frameHeight)
                .frame(maxWidth: orientation == .vertical ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                        .fill(isDropTargeted ? DS.Colors.accentSubtle : Color.clear)
                        .padding(chromeInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? DS.Colors.accentText : DS.Colors.borderStrong,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                        .padding(chromeInset)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
    }

    /// A compact placeholder keeps a `+` in the resting lane, so an empty group
    /// still shows where its next Pickle lands while the labels are clipped.
    @ViewBuilder
    private var content: some View {
        if isHorizontalCompact {
            plusMark
        } else if let compactLayout {
            PickyHUDDockCompactLanes(layout: compactLayout) {
                plusMark
            } label: {
                hint
                    .padding(.leading, compactLayout.labelLeadingPadding(outer: DS.Spacing.space1))
                    .padding(.trailing, compactLayout.labelTrailingPadding(outer: DS.Spacing.space1))
                    .accessibilityHidden(!compactLayout.showsLabels)
            }
        } else {
            hint.padding(.horizontal, DS.Spacing.space1)
        }
    }

    private var plusMark: some View {
        Image(systemName: "plus")
            .font(PickyHUDTypography.supporting)
            .foregroundStyle(tint)
    }

    private var hint: some View {
        Text(L10n.t("dock.group.empty.dropHint"))
            .font(PickyHUDTypography.meta)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}
