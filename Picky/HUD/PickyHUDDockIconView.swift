import AppKit
import SwiftUI

struct PickyHUDDockIconView: View {
    let session: PickySessionListViewModel.SessionCard
    let index: Int
    let isActive: Bool
    let isOpened: Bool
    let isPreviewed: Bool
    let isScreenContextArmed: Bool
    let isScreenContextSticky: Bool
    let dockSide: PickyHUDDockSide
    let shortcutNumber: Int?
    let isCommandShortcutHintVisible: Bool
    let shouldFlashCompletion: Bool
    let isUnread: Bool
    let metrics: PickyHUDDockMetrics
    /// True while this icon is the live drag target. The rail applies the
    /// scale/shadow/zIndex transforms via this flag and feeds the offset.
    var isDragging: Bool = false
    var dragOffset: CGSize = .zero
    let onHover: () -> Void
    let onOpen: () -> Void
    let onToggleScreenContextTarget: () -> Void
    let onToggleStickyScreenContextTarget: () -> Void
    let onCompact: () -> Void
    let onArchive: () -> Void
    let onStop: () -> Void
    let onDoneFlashConsumed: () -> Void
    /// Fired once when the cursor crosses the reorder threshold. The argument
    /// is the mouse-down anchor in screen space; the rail hands the drag off
    /// to its rail-level controller from here so it survives this icon's
    /// NSView being recreated mid-drag.
    var onReorderHandoff: (NSPoint) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @State private var archiveFeedbackStartTask: Task<Void, Never>?
    @State private var isArchivePressing = false
    @State private var archiveProgress: Double = 0
    @State private var didCompleteArchiveHold = false
    @State private var isHovered = false

    private enum DockPickleAsset: String {
        case help = "PickleDockHelp"
        case wait = "PickleDockWait"
        case wink = "PickleDockWink"
    }

    var body: some View {
        let _ = PickyPerf.event("dock_icon_body")
        dockIconContent
            .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
            .background(dockIconBackground)
            .opacity(session.status == .cancelled ? 0.55 : 1)
            .scaleEffect(tileScale * (isDragging ? 1.1 : 1.0))
            .shadow(color: Color.black.opacity(isDragging ? 0.32 : 0), radius: isDragging ? 14 : 0, x: 0, y: isDragging ? 6 : 0)
            .offset(x: dragOffset.width, y: dragOffset.height)
            .zIndex(isDragging ? 200 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isDragging)
            .onHover { isHovered = $0 }
            // Do not attach implicit hover/shortcut animations to the whole tile.
            // Session switches resize the outer HUD panel in the same update cycle;
            // a whole-tile animation can then animate the dock slot's placement and
            // make the Pickle rail appear to shift vertically. Keep animations scoped
            // to drawing-only subviews such as `dockIconBackground` and badges.
            .overlay(alignment: .topLeading) {
                if isArchivePressing {
                    archiveBadge
                        .offset(x: -5, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCommandShortcutHintVisible, let shortcutNumber {
                    commandShortcutBadge(number: shortcutNumber)
                        .offset(x: 5, y: -5)
                        .transition(.scale(scale: 0.88, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                // Render the unread dot in its own overlay so its appearance and
                // removal animations don't share a transition slot with the
                // command shortcut badge or any other sibling overlay. The dot's
                // own opacity drives the transition explicitly, which keeps the
                // animation scoped to a single drawing-only subview and avoids
                // the per-tile implicit animation warned about above.
                unreadDot
                    .offset(x: 4, y: -4)
                    .opacity(isUnread && !isCommandShortcutHintVisible ? 1 : 0)
                    .scaleEffect(isUnread && !isCommandShortcutHintVisible ? 1 : 0.6, anchor: .topTrailing)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isUnread)
                    .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                    .allowsHitTesting(false)
            }
        .overlay(alignment: .center) {
            archiveProgressRing
        }
        .overlay(alignment: .center) {
            if isPreviewed {
                PickyHUDMiniPreviewCardView(session: session, metrics: metrics)
                    .offset(x: miniPreviewOffset.width, y: miniPreviewOffset.height)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isPreviewed ? 100 : 0)
        .contentShape(RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous))
        .overlay {
            PickyHUDDockIconClickHost(
                onHover: onHover,
                onOpen: onOpen,
                isScreenContextArmed: isScreenContextArmed,
                isScreenContextSticky: isScreenContextSticky,
                canCompact: session.canRequestDockCompaction,
                canStop: !session.status.isTerminal,
                onToggleScreenContextTarget: onToggleScreenContextTarget,
                onToggleStickyScreenContextTarget: onToggleStickyScreenContextTarget,
                onCompact: onCompact,
                onArchivePressing: handleArchivePressing,
                onArchive: completeArchiveHold,
                onStop: onStop,
                onReorderHandoff: onReorderHandoff
            )
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
            cancelArchiveHoldFeedback()
            didCompleteArchiveHold = false
            // Do NOT cancel an in-flight reorder here. The drag is owned by the
            // rail-level controller; this icon disappears precisely because the
            // live preview reparented it across a group boundary, and the drag
            // must keep going until the user releases.
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: isArchivePressing)
        .accessibilityLabel("Preview \(session.title)")
        .accessibilityHint("Click to open or close. Press and hold for 1.5 seconds to archive this Pickle.")
        .accessibilityAddTraits(.isButton)
    }

    private var archiveProgressRing: some View {
        ZStack {
            archiveRingArc(progress: 1)
                .opacity(0.18)
            archiveRingArc(progress: archiveProgress)
        }
        .frame(width: metrics.archiveRingSide, height: metrics.archiveRingSide)
        .opacity(isArchivePressing || archiveProgress > 0 ? 1 : 0)
        .shadow(color: DS.Colors.warning.opacity(0.34), radius: 4, x: 0, y: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func archiveRingArc(progress: Double) -> some View {
        Circle()
            .trim(
                from: PickyHUDArchiveHoldPolicy.ringGapStartFraction,
                to: PickyHUDArchiveHoldPolicy.ringGapStartFraction + (max(0, min(progress, 1)) * PickyHUDArchiveHoldPolicy.ringUsableFraction)
            )
            .stroke(
                DS.Colors.warning,
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
            )
            .rotationEffect(.degrees(-90))
    }

    private var archiveBadge: some View {
        Image(systemName: "archivebox.fill")
            .font(.system(size: max(6.5, 7.5 * metrics.scale), weight: .bold))
            .foregroundColor(DS.Colors.warningText)
            .frame(width: metrics.archiveBadgeSide, height: metrics.archiveBadgeSide)
            .background(Circle().fill(DS.Colors.surface1.opacity(0.96)))
            .overlay(Circle().stroke(DS.Colors.warning.opacity(0.65), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func commandShortcutBadge(number: Int) -> some View {
        commandShortcutBadge(label: "\(number)")
    }

    /// Small accent dot rendered at the dock icon's top-trailing corner while
    /// the Pickle is in an attention state (completed / failed / waiting for
    /// input) and has not been opened yet. Sourced from the shared view-model
    /// set so every dock instance shows the same indicator.
    private var unreadDot: some View {
        Circle()
            .fill(DS.Colors.notification)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(DS.Colors.background, lineWidth: 1.2)
            )
            .shadow(color: DS.Colors.notification.opacity(0.45), radius: 2.5, x: 0, y: 0)
            .accessibilityLabel("Unread")
            .accessibilityHint("This Pickle has updates you haven't seen yet.")
    }

    private func commandShortcutBadge(label: String) -> some View {
        PickyShortcutKeyBadge(label: label)
    }

    private var dockIconContent: some View {
        VStack(spacing: max(1, 2 * metrics.scale)) {
            ZStack {
                // Drive the breath from a `TimelineView` instead of a
                // `withAnimation(.repeatForever)` toggle. The previous toggle
                // approach leaked SwiftUI's repeating animation: once started,
                // the implicit repeat kept interpolating the halo + glyph even
                // after the state flag was reset, so the dock icon kept
                // breathing after the Pickle finished. With `TimelineView` the
                // animation is purely a function of time, and removing the view
                // (when `session.status != .running`) hard-stops it.
                if isScreenContextArmed {
                    ZStack {
                        dockTodoProgressRing
                        Image("PickyCursorNormal")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(DS.Colors.accentText)
                            .scaledToFit()
                            .frame(width: metrics.sessionLogoSide * 0.96, height: metrics.sessionLogoSide * 0.96)
                            .shadow(color: DS.Colors.accentText.opacity(isSelected ? 0.18 : 0.10), radius: 2.0, x: 0, y: 0.7)
                    }
                } else if session.status == .running {
                    if accessibilityReduceMotion {
                        runningDockGlyph(phase: 0.5, isWinkVisible: false)
                    } else {
                        TimelineView(.animation) { context in
                            let _ = PickyPerf.event("dock_icon_timeline_tick")
                            runningDockGlyph(
                                phase: breathingPhase(at: context.date),
                                isWinkVisible: isRunningWinkVisible(at: context.date)
                            )
                        }
                    }
                } else {
                    ZStack {
                        dockTodoProgressRing
                        if let asset = dockStatusAsset {
                            dockPickleAsset(asset)
                        } else {
                            normalPickleGlyph()
                        }
                    }
                }
            }

            Text(dockLabel)
                .font(dockLabelFont)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: metrics.sessionTileWidth - 4, alignment: .center)
        }
        .opacity(isArchivePressing ? 0.64 : 1)
    }

    private func runningDockGlyph(phase: CGFloat, isWinkVisible: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(statusColor.opacity(0.16 + 0.36 * phase), lineWidth: 1.0)
                .frame(width: metrics.sessionLogoSide, height: metrics.sessionLogoSide)
                .scaleEffect(1.0 + 0.12 * phase)
            dockTodoProgressRing
            Group {
                if isWinkVisible {
                    dockPickleAsset(.wink)
                } else {
                    normalPickleGlyph()
                }
            }
            .scaleEffect(0.965 + 0.08 * phase)
        }
    }

    private var todoProgressPresentation: PickyTodoProgressPresentation? {
        PickyTodoProgressPresentation(state: session.todoState)
    }

    @ViewBuilder
    private var dockTodoProgressRing: some View {
        if let todoProgressPresentation {
            let lineWidth = max(1.2, 1.45 * metrics.scale)
            ZStack {
                Circle()
                    .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: lineWidth)
                if todoProgressPresentation.fraction > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(todoProgressPresentation.fraction))
                        .stroke(
                            todoProgressPresentation.isComplete ? DS.Colors.success : DS.Colors.info,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: todoProgressPresentation.fraction)
                }
            }
            .frame(width: metrics.sessionLogoSide, height: metrics.sessionLogoSide)
            .accessibilityHidden(true)
        }
    }

    private var dockIconBackground: some View {
        // Session tile in the dock: quiet transparent by default, subtle neutral
        // plate on hover/preview, and a status-tinted selected outline while the
        // Pickle is open. The old standalone accent dot is intentionally omitted;
        // status now lives in the pickle glyph + selected outline.
        RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
            .fill((isSelected || isSoftHighlighted) ? DS.Colors.surface1.opacity(0.24) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .fill(tileFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.20 * archiveProgress))
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .fill(DS.Colors.success.opacity(0.34 * completionFlashIntensity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .strokeBorder(tileStrokeColor, lineWidth: tileStrokeWidth)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .strokeBorder(DS.Colors.warning.opacity(0.76 * archiveProgress), lineWidth: 1.35)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .strokeBorder(DS.Colors.success.opacity(0.85 * completionFlashIntensity), lineWidth: 1.4)
            )
            .shadow(color: DS.Colors.warning.opacity(0.30 * archiveProgress), radius: 5, x: 0, y: 0)
            .shadow(color: DS.Colors.success.opacity(0.55 * completionFlashIntensity), radius: 6, x: 0, y: 0)
            .animation(.easeInOut(duration: 0.18), value: isSoftHighlighted)
    }

    private func handleArchivePressing(_ isPressing: Bool) {
        if isPressing {
            scheduleArchiveHoldFeedbackStart()
        } else if !didCompleteArchiveHold {
            cancelArchiveHoldFeedback()
        }
    }

    private func scheduleArchiveHoldFeedbackStart() {
        archiveFeedbackStartTask?.cancel()
        didCompleteArchiveHold = false
        archiveProgress = 0
        archiveFeedbackStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PickyHUDArchiveHoldPolicy.feedbackStartDelayNanoseconds)
            guard !Task.isCancelled else { return }
            archiveFeedbackStartTask = nil
            beginArchiveHoldFeedback()
        }
    }

    private func beginArchiveHoldFeedback() {
        isArchivePressing = true
        withAnimation(.linear(duration: PickyHUDArchiveHoldPolicy.feedbackAnimationDuration)) {
            archiveProgress = 1
        }
    }

    private func cancelArchiveHoldFeedback() {
        archiveFeedbackStartTask?.cancel()
        archiveFeedbackStartTask = nil
        isArchivePressing = false
        withAnimation(.easeOut(duration: 0.18)) {
            archiveProgress = 0
        }
    }

    private func completeArchiveHold() {
        archiveFeedbackStartTask?.cancel()
        archiveFeedbackStartTask = nil
        didCompleteArchiveHold = true
        archiveProgress = 1
        onArchive()
    }

    private func normalPickleGlyph(sideScale: CGFloat = 1.0) -> some View {
        PickleLogoGlyph()
            .fill(statusColor, style: FillStyle(eoFill: true))
            .frame(width: metrics.sessionLogoSide * sideScale, height: metrics.sessionLogoSide * sideScale)
            .shadow(color: statusColor.opacity(isSelected ? 0.20 : 0.10), radius: 2.2, x: 0, y: 0.8)
    }

    private func dockPickleAsset(_ asset: DockPickleAsset, sideScale: CGFloat = 1.0) -> some View {
        Image(asset.rawValue)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(statusColor)
            .scaledToFit()
            .frame(width: metrics.sessionLogoSide * sideScale, height: metrics.sessionLogoSide * sideScale)
            .shadow(color: statusColor.opacity(isSelected ? 0.20 : 0.10), radius: 2.2, x: 0, y: 0.8)
    }

    private var dockStatusAsset: DockPickleAsset? {
        switch session.status {
        case .waiting_for_input:
            return .wait
        case .blocked, .failed:
            return .help
        case .queued, .running, .completed, .cancelled:
            return nil
        }
    }

    /// `0...1` triangular-eased phase driven purely by wall-clock time. Used by
    /// the running-state `TimelineView` so the breath halts immediately when
    /// the view is removed, instead of leaking an implicit repeating animation.
    private func breathingPhase(at date: Date) -> CGFloat {
        let period: TimeInterval = 2.1
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let raw = sin(t * 2 * .pi - .pi / 2) * 0.5 + 0.5
        return CGFloat(raw)
    }

    /// Deterministic, wall-clock driven wink window for running Pickles.
    /// Keeping this stateless avoids timer tasks that can outlive status changes.
    private func isRunningWinkVisible(at date: Date) -> Bool {
        let period: TimeInterval = 7.25
        let duration: TimeInterval = 0.34
        let raw = (date.timeIntervalSinceReferenceDate + runningWinkPhaseOffset)
            .truncatingRemainder(dividingBy: period)
        let phase = raw < 0 ? raw + period : raw
        return phase < duration
    }

    private var runningWinkPhaseOffset: TimeInterval {
        let seed = session.id.unicodeScalars.reduce(0) { partial, scalar in
            ((partial &* 31) &+ Int(scalar.value)) & 0x7fffffff
        }
        return TimeInterval(seed % 5_000) / 1_000
    }

    private func runCompletionFlash() {
        completionFlashTask?.cancel()
        onDoneFlashConsumed()
        let task = Task { @MainActor in
            // Two pulses: rise quickly, fall slowly. Rough total duration ~1.4s so it lingers
            // long enough to register but doesn't compete with the dock's animated borders.
            for _ in 0..<2 {
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.18)) { completionFlashIntensity = 1.0 }
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.45)) { completionFlashIntensity = 0.0 }
                try? await Task.sleep(nanoseconds: 480_000_000)
            }
        }
        completionFlashTask = task
    }

    private var tileFillColor: Color {
        if isSelected { return statusColor.opacity(0.10) }
        if isSoftHighlighted { return DS.Colors.surface1.opacity(0.58) }
        return .clear
    }

    private var tileStrokeColor: Color {
        if isSelected { return statusColor.opacity(0.92) }
        if isSoftHighlighted { return DS.Colors.borderSubtle.opacity(0.66) }
        return .clear
    }

    private var tileStrokeWidth: CGFloat {
        isSelected ? 1.35 : (isSoftHighlighted ? 0.85 : 0)
    }

    private var isSelected: Bool {
        isOpened || isActive
    }

    private var isSoftHighlighted: Bool {
        isHovered || isPreviewed
    }

    private var statusColor: Color {
        PickyDockPickleStatusVisual.color(session.status)
    }

    private var dockLabel: String {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwdLeaf = (session.cwd ?? "")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let source = trimmedTitle.isEmpty ? cwdLeaf : trimmedTitle
        return Self.compactDockLabel(source.isEmpty ? "Pickle" : source)
    }

    private var dockLabelFont: Font {
        PickyHUDDockLabelPolicy.containsHangul(dockLabel)
            ? .system(size: metrics.sessionLabelFontSize, weight: .medium)
            : .system(size: metrics.sessionLabelFontSize, weight: .medium, design: .rounded)
    }

    private var tileScale: CGFloat {
        if isArchivePressing { return 0.92 }
        return 1.0
    }

    /// Preview pops out on the side OPPOSITE the conversation card so it never
    /// overlaps the open HUD or the neighboring dock icons.
    /// - vertical: card sits inward, preview points outward (left for `.right`,
    ///   right for `.left`).
    /// - horizontal: card sits opposite the anchored edge (`.top` -> card below
    ///   the dock, so preview goes above), so preview points back toward the
    ///   anchored edge (negative Y for `.top`, positive Y for `.bottom`).
    /// Preview pops into the same area where the conversation card opens so it
    /// lands in the panel region that already has room reserved for it.
    /// - vertical: card sits inward, preview also points inward (left for
    ///   `.right`, right for `.left`).
    /// - horizontal: card sits opposite the anchored edge (`.top` -> card
    ///   below, so preview points down too; `.bottom` -> card above, preview
    ///   points up).
    private var miniPreviewOffset: CGSize {
        let iconHalfWidth = metrics.sessionTileWidth / 2
        let iconHalfHeight = metrics.sessionTileHeight / 2
        let xDistance = (metrics.previewCardWidth / 2) + iconHalfWidth + PickyHUDDockLayout.panelGap
        // Preview is a single-line title+status card, so its height is dominated
        // by `titleFontSize + secondaryFontSize + verticalPadding * 2` from
        // `PickyHUDMiniPreviewCardView`. ~50pt at medium scale matches what the
        // card actually renders to within a few points across S/M/L presets.
        let estimatedPreviewHalfHeight = max(20, 25 * metrics.scale)
        let yDistance = estimatedPreviewHalfHeight + iconHalfHeight + PickyHUDDockLayout.panelGap
        switch dockSide {
        case .right: return CGSize(width: -xDistance, height: 0)
        case .left: return CGSize(width: xDistance, height: 0)
        case .top: return CGSize(width: 0, height: yDistance)
        case .bottom: return CGSize(width: 0, height: -yDistance)
        }
    }

    private static func compactDockLabel(_ string: String) -> String {
        PickyHUDDockLabelPolicy.compactLabel(string)
    }
}

#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}

// MARK: - Dock icon clicks (AppKit-backed for immediate single-click open)

struct PickyHUDDockIconClickHost: NSViewRepresentable {
    var onHover: () -> Void
    var onOpen: () -> Void
    var isScreenContextArmed: Bool
    var isScreenContextSticky: Bool
    var canCompact: Bool
    var canStop: Bool
    var onToggleScreenContextTarget: () -> Void
    var onToggleStickyScreenContextTarget: () -> Void
    var onCompact: () -> Void
    var onArchivePressing: (Bool) -> Void
    var onArchive: () -> Void
    var onStop: () -> Void
    /// Fired once when the cursor leaves the archive hold's stationary
    /// tolerance, signalling "this drag is now a reorder, not a long-press
    /// archive". Argument is the mouse-down point in screen coordinates,
    /// which the rail uses as the anchor for its rail-level drag tracker. All
    /// subsequent drag/up handling happens there, not on this NSView, so the
    /// drag survives this view being recreated when the preview reparents the
    /// icon across a group boundary.
    var onReorderHandoff: (NSPoint) -> Void = { _ in }

    final class Coordinator: NSObject {
        var onHover: (() -> Void)?
        var onOpen: (() -> Void)?
        var isScreenContextArmed = false
        var isScreenContextSticky = false
        var canCompact = false
        var canStop = false
        var onToggleScreenContextTarget: (() -> Void)?
        var onToggleStickyScreenContextTarget: (() -> Void)?
        var onCompact: (() -> Void)?
        var onArchivePressing: ((Bool) -> Void)?
        var onArchive: (() -> Void)?
        var onStop: (() -> Void)?
        var onReorderHandoff: ((NSPoint) -> Void)?

        func clearCallbacks() {
            onHover = nil
            onOpen = nil
            onToggleScreenContextTarget = nil
            onToggleStickyScreenContextTarget = nil
            onCompact = nil
            onArchivePressing = nil
            onArchive = nil
            onStop = nil
            onReorderHandoff = nil
        }

        @objc func toggleScreenContextTarget(_ sender: NSMenuItem) {
            onToggleScreenContextTarget?()
        }

        @objc func toggleStickyScreenContextTarget(_ sender: NSMenuItem) {
            onToggleStickyScreenContextTarget?()
        }

        @objc func compact(_ sender: NSMenuItem) {
            guard canCompact else { return }
            onCompact?()
        }

        @objc func archive(_ sender: NSMenuItem) {
            onArchive?()
        }

        @objc func stop(_ sender: NSMenuItem) {
            guard canStop else { return }
            onStop?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        applyCallbacks(to: context.coordinator)
        let view = PickyHUDDockIconClickNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyCallbacks(to: context.coordinator)
    }

    private func applyCallbacks(to coordinator: Coordinator) {
        coordinator.onHover = onHover
        coordinator.onOpen = onOpen
        coordinator.isScreenContextArmed = isScreenContextArmed
        coordinator.isScreenContextSticky = isScreenContextSticky
        coordinator.canCompact = canCompact
        coordinator.canStop = canStop
        coordinator.onToggleScreenContextTarget = onToggleScreenContextTarget
        coordinator.onToggleStickyScreenContextTarget = onToggleStickyScreenContextTarget
        coordinator.onCompact = onCompact
        coordinator.onArchivePressing = onArchivePressing
        coordinator.onArchive = onArchive
        coordinator.onStop = onStop
        coordinator.onReorderHandoff = onReorderHandoff
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let view = nsView as? PickyHUDDockIconClickNSView {
            view.cancelTransientInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.clearCallbacks()
    }
}

final class PickyHUDDockIconClickNSView: NSView {
    weak var coordinator: PickyHUDDockIconClickHost.Coordinator?
    private var trackingArea: NSTrackingArea?
    private var archiveWorkItem: DispatchWorkItem?
    /// Captured at mouseDown in **screen coordinates** (`NSEvent.mouseLocation`).
    /// Screen-space is essential because the moment a reorder lands, this
    /// NSView itself moves to a new slot — any local- or window-space anchor
    /// would become stale and produce wildly wrong deltas, which manifests as
    /// jitter and the icon falling behind the cursor.
    private var mouseDownScreenPoint: NSPoint?
    private var didCompleteArchiveHold = false
    /// True once the drag crossed the reorder threshold and was handed off to
    /// the rail-level drag controller. From that point this view does nothing
    /// for the drag — an app-level event monitor owns it — so the drag is
    /// unaffected when SwiftUI recreates this view.
    private var handedOffReorder = false

    override var isFlipped: Bool { false }

    deinit {
        cancelTransientInteraction(notifyingCallbacks: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        mouseDownScreenPoint = NSEvent.mouseLocation
        didCompleteArchiveHold = false
        handedOffReorder = false
        guard event.clickCount == 1 else { return }
        coordinator?.onArchivePressing?(true)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.didCompleteArchiveHold = true
            self.coordinator?.onArchive?()
        }
        archiveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PickyHUDArchiveHoldPolicy.duration, execute: item)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        cancelArchiveHoldFeedback()
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        handedOffReorder = false
        coordinator?.onHover?()
        guard let coordinator else { return }

        let menu = NSMenu()
        let stickyConversationItem = menuItem(
            title: coordinator.isScreenContextSticky ? "Stop Talking to This Pickle" : "Keep Talking to This Pickle",
            action: #selector(PickyHUDDockIconClickHost.Coordinator.toggleStickyScreenContextTarget(_:)),
            target: coordinator
        )
        stickyConversationItem.state = coordinator.isScreenContextSticky ? .on : .off
        menu.addItem(stickyConversationItem)

        // A sticky conversation target already owns the screen-context route,
        // so its explicit stop action above replaces the otherwise duplicate
        // one-shot context toggle.
        if !coordinator.isScreenContextSticky {
            menu.addItem(menuItem(
                title: coordinator.isScreenContextArmed ? "Stop Sending Context to This Pickle" : "Send Context to This Pickle",
                action: #selector(PickyHUDDockIconClickHost.Coordinator.toggleScreenContextTarget(_:)),
                target: coordinator
            ))
        }
        menu.addItem(menuItem(
            title: "Compact",
            action: #selector(PickyHUDDockIconClickHost.Coordinator.compact(_:)),
            target: coordinator,
            isEnabled: coordinator.canCompact
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: "Archive",
            action: #selector(PickyHUDDockIconClickHost.Coordinator.archive(_:)),
            target: coordinator
        ))
        menu.addItem(menuItem(
            title: "Stop",
            action: #selector(PickyHUDDockIconClickHost.Coordinator.stop(_:)),
            target: coordinator,
            isEnabled: coordinator.canStop
        ))

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(title: String, action: Selector, target: AnyObject, isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = isEnabled
        return item
    }

    override func mouseDragged(with event: NSEvent) {
        guard !handedOffReorder, let anchor = mouseDownScreenPoint else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // Same threshold as archive cancel — so the moment the user clearly
        // commits to moving the cursor, archive intent gives way to reorder.
        // Hand the drag off to the rail-level controller and stop tracking it
        // here; the controller's app-level monitor takes over from the next
        // event onward (and swallows it so we don't double-handle).
        if distance > PickyHUDArchiveHoldPolicy.maximumDistance {
            cancelArchiveHoldFeedback()
            handedOffReorder = true
            coordinator?.onReorderHandoff?(anchor)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedArchive = didCompleteArchiveHold
        let wasHandedOff = handedOffReorder
        cancelArchiveHoldFeedback()
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        handedOffReorder = false
        // When the drag was handed off the rail controller owns its end; the
        // app-level monitor normally swallows this mouseUp before it reaches
        // us, but guard anyway so a click isn't synthesized.
        if wasHandedOff { return }
        guard !completedArchive else { return }
        coordinator?.onOpen?()
    }

    private func cancelArchiveHoldFeedback() {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        coordinator?.onArchivePressing?(false)
    }

    func cancelTransientInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        // Note: a handed-off reorder is owned by the rail-level controller, so
        // tearing this view down does NOT cancel the drag. That is the whole
        // point — the drag must survive the icon being recreated.
        handedOffReorder = false
        guard shouldNotify else { return }
        coordinator?.onArchivePressing?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // If SwiftUI removes the icon while a gesture is active, clear only the
        // AppKit-side state here. The SwiftUI state is reset by the icon's
        // onDisappear path, avoiding synchronous @State writes from teardown.
        if window == nil {
            cancelTransientInteraction(notifyingCallbacks: false)
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Dock anchor handle (AppKit-backed for reliable hit testing)

/// AppKit-backed handle for dragging the HUD dock's vertical anchor. Wrapping an
/// `NSView` directly avoids SwiftUI's transparent-view hit-testing quirks: AppKit's
/// `hitTest`, `NSTrackingArea`, and `addCursorRect` all key off the same NSView
/// bounds, so click + hover + cursor reliably react to the entire frame instead of
/// just the visible 22×4 capsule that SwiftUI's gesture system kept latching onto.
struct PickyHUDDockAnchorHandleHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onDragChanged: (CGPoint) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    final class Coordinator {
        var onHoverChanged: ((Bool) -> Void)?
        var onDragChanged: ((CGPoint) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
        let view = PickyHUDDockAnchorHandleNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let view = nsView as? PickyHUDDockAnchorHandleNSView {
            view.cancelInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.onHoverChanged = nil
        coordinator.onDragChanged = nil
        coordinator.onDragEnded = nil
        coordinator.onDoubleClick = nil
    }
}

struct PickyHUDCardResizeHandleHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onDragChanged: (CGPoint) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    final class Coordinator {
        var onHoverChanged: ((Bool) -> Void)?
        var onDragChanged: ((CGPoint) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
        let view = PickyHUDCardResizeHandleNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // SwiftUI may dismantle the representable while it is already reading the
        // body that owns these closures. Calling back into `@State` from this
        // teardown path can trip Swift's exclusivity checker, so only clear the
        // AppKit-side interaction state here. The SwiftUI state is reset by the
        // card's `onDisappear` handler.
        if let view = nsView as? PickyHUDCardResizeHandleNSView {
            view.cancelInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.onHoverChanged = nil
        coordinator.onDragChanged = nil
        coordinator.onDragEnded = nil
        coordinator.onDoubleClick = nil
    }
}

final class PickyHUDCardResizeHandleNSView: NSView {
    weak var coordinator: PickyHUDCardResizeHandleHost.Coordinator?
    private var dragStartScreenPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

    deinit {
        cancelInteraction(notifyingCallbacks: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelInteraction(notifyingCallbacks: false)
        } else {
            reconcileHoverState()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        reconcileHoverState()
    }

    func cancelInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        let wasDragging = dragStartScreenPoint != nil
        dragStartScreenPoint = nil
        guard shouldNotify else { return }
        coordinator?.onHoverChanged?(false)
        if wasDragging {
            coordinator?.onDragEnded?()
        }
    }

    private func reconcileHoverState() {
        guard let window else {
            coordinator?.onHoverChanged?(false)
            return
        }
        let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        coordinator?.onHoverChanged?(bounds.contains(pointInView))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragStartScreenPoint = nil
            coordinator?.onDoubleClick?()
            return
        }
        dragStartScreenPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = dragStartScreenPoint else { return }
        coordinator?.onDragChanged?(
            CGPoint(
                x: NSEvent.mouseLocation.x - startPoint.x,
                y: NSEvent.mouseLocation.y - startPoint.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragStartScreenPoint != nil
        dragStartScreenPoint = nil
        if wasDragging {
            coordinator?.onDragEnded?()
        }
        reconcileHoverState()
    }

    override var acceptsFirstResponder: Bool { false }
}

final class PickyHUDDockAnchorHandleNSView: NSView {
    weak var coordinator: PickyHUDDockAnchorHandleHost.Coordinator?
    private var dragStartScreenPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var hasClosedHandPushed = false

    override var isFlipped: Bool { false }

    deinit {
        cancelInteraction(notifyingCallbacks: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelInteraction(notifyingCallbacks: false)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capture all hits inside our bounds. Without this, AppKit could fall
        // through to a sibling/parent view if some subview opts out.
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragStartScreenPoint = nil
            coordinator?.onDoubleClick?()
            return
        }
        dragStartScreenPoint = NSEvent.mouseLocation
        if !hasClosedHandPushed {
            NSCursor.closedHand.push()
            hasClosedHandPushed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = dragStartScreenPoint else { return }
        let delta = CGPoint(
            x: NSEvent.mouseLocation.x - startPoint.x,
            y: NSEvent.mouseLocation.y - startPoint.y
        )
        coordinator?.onDragChanged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragStartScreenPoint != nil
        if hasClosedHandPushed {
            NSCursor.pop()
            hasClosedHandPushed = false
        }
        dragStartScreenPoint = nil
        if wasDragging {
            coordinator?.onDragEnded?()
        }
    }

    func cancelInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        let wasDragging = dragStartScreenPoint != nil
        if hasClosedHandPushed {
            NSCursor.pop()
            hasClosedHandPushed = false
        }
        dragStartScreenPoint = nil
        guard shouldNotify else { return }
        coordinator?.onHoverChanged?(false)
        if wasDragging {
            coordinator?.onDragEnded?()
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

private struct PickyHUDMiniPreviewCardView: View {
    let session: PickySessionListViewModel.SessionCard
    let metrics: PickyHUDDockMetrics
    @State private var gitStatus: PickyGitRepositoryStatus?

    init(session: PickySessionListViewModel.SessionCard, metrics: PickyHUDDockMetrics) {
        self.session = session
        self.metrics = metrics
        _gitStatus = State(initialValue: PickyGitRepositoryStatus.cached(cwd: session.cwd))
    }

    private static let gitRefreshBucketSeconds: TimeInterval = 20

    private var scale: CGFloat { metrics.scale }
    private var cornerRadius: CGFloat { max(12, 16 * scale) }
    private var titleFontSize: CGFloat { max(12, 14 * scale) }
    private var secondaryFontSize: CGFloat { max(10, 11 * scale) }
    // Dock-preset-scaled fonts (S/M/L). These intentionally scale with the dock
    // size preset rather than the app font scale, so they are component-level
    // geometry exceptions to `PickyHUDTypography`'s fixed roles.
    private var titleFont: Font { .system(size: titleFontSize, weight: .semibold) }
    private var secondaryFont: Font { .system(size: secondaryFontSize, weight: .medium) }
    private var secondaryMonoFont: Font { .system(size: secondaryFontSize, weight: .medium, design: .monospaced) }
    private var statusDotSide: CGFloat { max(6, 7 * scale) }
    private var horizontalPadding: CGFloat { max(8, 10 * scale) }
    private var verticalPadding: CGFloat { max(7, 9 * scale) }

    private var gitRefreshKey: String {
        let updatedAtBucket = Int(session.updatedAt.timeIntervalSince1970 / Self.gitRefreshBucketSeconds)
        let todoKey = session.todoState.map { String($0.updatedAt.timeIntervalSince1970) } ?? "none"
        return "\(session.cwd ?? "")|\(updatedAtBucket)|todo:\(todoKey)"
    }

    var body: some View {
        let _ = PickyPerf.event("mini_preview_body")
        HStack(spacing: max(6, 8 * scale)) {
            Circle()
                .fill(statusColor)
                .frame(width: statusDotSide, height: statusDotSide)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: max(2, 3 * scale)) {
                HStack(spacing: max(5, 7 * scale)) {
                    Text(session.title)
                        .font(titleFont)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(statusLabel)
                        .font(secondaryFont)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                contextLine
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: metrics.previewCardWidth)
        .background {
            PickyHUDMaterialFill(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                fallback: DS.Colors.surface1
            )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DS.Colors.surface3.opacity(0.62))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
                )
        }
        .task(id: gitRefreshKey) {
            guard todoProgressPresentation == nil else { return }
            PickyPerf.event("mini_preview_git_task_start")
            if gitStatus == nil, let cached = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cached
            }
            let freshGit = await PickyPerf.interval("mini_preview_git_load") {
                await PickyGitRepositoryStatus.load(cwd: session.cwd)
            }
            guard !Task.isCancelled else { return }
            gitStatus = freshGit
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview \(session.title), \(statusLabel), \(contextAccessibilityLabel)")
    }

    @ViewBuilder
    private var contextLine: some View {
        if let todoProgressPresentation {
            HStack(spacing: max(3, 4 * scale)) {
                Text(todoProgressPresentation.countText)
                    .font(secondaryMonoFont)
                    .foregroundColor(todoProgressPresentation.isComplete ? DS.Colors.successText : DS.Colors.info)
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                    .font(secondaryMonoFont)
                    .foregroundColor(DS.Colors.textTertiary)
                Text(todoProgressPresentation.isComplete ? L10n.t("hud.todo.complete") : todoProgressPresentation.activeText)
                    .font(secondaryFont)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let gitStatus {
            HStack(spacing: max(3, 4 * scale)) {
                Text(gitStatus.repositoryDisplayName)
                    .font(secondaryMonoFont)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(2)
                Text("·")
                    .font(secondaryMonoFont)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(gitStatus.branchDisplayName)
                    .font(secondaryMonoFont)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
            }
        } else if let cwd = session.compactCwdDescription {
            Text(cwd)
                .font(secondaryMonoFont)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var todoProgressPresentation: PickyTodoProgressPresentation? {
        PickyTodoProgressPresentation(state: session.todoState)
    }

    private var contextAccessibilityLabel: String {
        if let todoProgressPresentation {
            let summary = todoProgressPresentation.isComplete ? L10n.t("hud.todo.complete") : todoProgressPresentation.activeText
            return "\(todoProgressPresentation.countText), \(summary)"
        }
        if let gitStatus {
            return "\(gitStatus.repositoryDisplayName), \(gitStatus.branchDisplayName)"
        }
        return session.compactCwdDescription ?? "No folder"
    }

    private var statusLabel: String {
        switch session.status {
        case .queued: return "queued"
        case .running: return "running"
        case .waiting_for_input: return "waiting"
        case .blocked: return "blocked"
        case .completed: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return DS.Colors.accentText
        case .running:
            return DS.Colors.overlayCursorBlue
        case .waiting_for_input, .blocked:
            return DS.Colors.warning
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }
}
