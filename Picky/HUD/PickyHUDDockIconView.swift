import AppKit
import SwiftUI

struct PickyHUDDockIconView: View {
    let session: PickyHUDDockSession
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
    let onHoverChanged: (Bool) -> Void
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
    /// Test-only body probe; production callers use the no-op default.
    var onBodyEvaluation: () -> Void = {}

    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @StateObject private var archiveFeedback = PickyHUDArchiveHoldFeedback()
    @State private var isHovered = false
    @Environment(\.pickyAppFontScale) private var fontScale

    private enum DockPickleAsset: String {
        case help = "PickleDockHelp"
        case wait = "PickleDockWait"
    }

    var body: some View {
        let _ = onBodyEvaluation()
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
            // Do not attach implicit hover/shortcut animations to the whole tile.
            // Session switches resize the outer HUD panel in the same update cycle;
            // a whole-tile animation can then animate the dock slot's placement and
            // make the Pickle rail appear to shift vertically. Keep animations scoped
            // to drawing-only subviews such as `dockIconBackground` and badges.
            .overlay(alignment: .topLeading) {
                if archiveFeedback.isPressing {
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
            PickyHUDArchiveHoldProgressRing(
                isPressing: archiveFeedback.isPressing,
                progress: archiveFeedback.progress,
                side: metrics.archiveRingSide
            )
        }
        .overlay(alignment: .center) {
            if isPreviewed {
                PickyHUDMiniPreviewResolver(
                    session: session,
                    metrics: metrics
                )
                    .offset(x: miniPreviewOffset.width, y: miniPreviewOffset.height)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isPreviewed ? 100 : 0)
        .contentShape(RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous))
        .overlay {
            PickyHUDDockIconClickHost(
                onHoverChanged: { hovering in
                    isHovered = hovering
                    onHoverChanged(hovering)
                },
                onOpen: onOpen,
                isScreenContextArmed: isScreenContextArmed,
                isScreenContextSticky: isScreenContextSticky,
                canCompact: actionAvailability.canCompact,
                canStop: actionAvailability.canStop,
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
            archiveFeedback.cancel()
            // Do NOT cancel an in-flight reorder here. The drag is owned by the
            // rail-level controller; this icon disappears precisely because the
            // live preview reparented it across a group boundary, and the drag
            // must keep going until the user releases.
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: archiveFeedback.isPressing)
        .accessibilityLabel("Preview \(session.title)")
        .accessibilityValue(accessibilityStatusLabel)
        .accessibilityHint("Click to open or close. Press and hold for 1.5 seconds to archive this Pickle.")
        .accessibilityAddTraits(.isButton)
    }

    private var actionAvailability: PickyHUDDockSessionActionAvailability {
        PickyHUDDockSessionActionAvailability.resolve(
            status: session.status,
            canRequestCompaction: session.canRequestDockCompaction
        )
    }

    private var accessibilityStatusLabel: String {
        switch session.status {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting_for_input: "Waiting for input"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
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
        let todoProgressPresentation = PickyTodoProgressPresentation(state: session.todoState)

        return VStack(spacing: max(1, 2 * metrics.scale)) {
            ZStack {
                if isScreenContextArmed {
                    ZStack {
                        dockTodoProgressRing(todoProgressPresentation)
                        Image("PickyCursorNormal")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(DS.Colors.accentText)
                            .scaledToFit()
                            .frame(width: metrics.sessionLogoSide * 0.96, height: metrics.sessionLogoSide * 0.96)
                            .shadow(color: DS.Colors.accentText.opacity(isSelected ? 0.18 : 0.10), radius: 2.0, x: 0, y: 0.7)
                    }
                } else if session.status == .running {
                    ZStack {
                        // The active ring gives running Pickles a shape-based,
                        // static cue. It is larger than the TODO progress ring,
                        // so both states remain legible without sustained motion.
                        runningDockGlyph()
                        dockTodoProgressRing(todoProgressPresentation)
                    }
                } else {
                    ZStack {
                        dockTodoProgressRing(todoProgressPresentation)
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
        .opacity(archiveFeedback.isPressing ? 0.64 : 1)
    }

    private func runningDockGlyph() -> some View {
        ZStack {
            Circle()
                .stroke(statusColor.opacity(0.72), lineWidth: max(1.1, 1.25 * metrics.scale))
                .frame(width: metrics.sessionLogoSide * 1.18, height: metrics.sessionLogoSide * 1.18)
                .accessibilityHidden(true)
            normalPickleGlyph()
        }
    }

    @ViewBuilder
    private func dockTodoProgressRing(_ todoProgressPresentation: PickyTodoProgressPresentation?) -> some View {
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
                    .fill(DS.Colors.warning.opacity(0.20 * archiveFeedback.progress))
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
                    .strokeBorder(DS.Colors.warning.opacity(0.76 * archiveFeedback.progress), lineWidth: 1.35)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.sessionTileCornerRadius, style: .continuous)
                    .strokeBorder(DS.Colors.success.opacity(0.85 * completionFlashIntensity), lineWidth: 1.4)
            )
            .shadow(
                color: DS.Colors.warning.opacity(DS.Elevation.dockArchiveFeedbackShadowOpacity * archiveFeedback.progress),
                radius: DS.Elevation.dockArchiveFeedbackShadowRadius
            )
            .shadow(color: DS.Colors.success.opacity(0.55 * completionFlashIntensity), radius: 6, x: 0, y: 0)
            .animation(.easeInOut(duration: 0.18), value: isSoftHighlighted)
    }

    private func handleArchivePressing(_ isPressing: Bool) {
        archiveFeedback.setPressing(isPressing)
    }

    private func completeArchiveHold() {
        archiveFeedback.complete()
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
        if archiveFeedback.isPressing { return 0.92 }
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
        let previewWidth = PickyHUDDockGroupListPolicy.previewWidth(
            session: session,
            relativeTime: PickyHUDDockGroupListRelativeTimePresentation.text(for: session.previewUpdatedAt),
            metrics: metrics,
            fontScale: fontScale
        )
        let xDistance = (previewWidth / 2) + iconHalfWidth + PickyHUDDockLayout.panelGap
        // Preview reuses one group-list session row plus the group's panel
        // padding. ~50pt at medium scale keeps placement stable across S/M/L.
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
    let viewModel = PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
    PickyHUDView(
        viewModel: viewModel,
        dockState: viewModel.dockState
    )
}

// MARK: - Dock icon clicks (AppKit-backed for immediate single-click open)

struct PickyHUDDockIconClickHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
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
    /// Optional group-list actions appended to the shared Dock Pickle menu.
    var moveTargetGroups: [PickyDockGroup] = []
    var onMoveToGroup: (String) -> Void = { _ in }
    var onUngroup: (() -> Void)?
    /// Fired once when the cursor leaves the archive hold's stationary
    /// tolerance, signalling "this drag is now a reorder, not a long-press
    /// archive". Argument is the mouse-down point in screen coordinates,
    /// which the rail uses as the anchor for its rail-level drag tracker. All
    /// subsequent drag/up handling happens there, not on this NSView, so the
    /// drag survives this view being recreated when the preview reparents the
    /// icon across a group boundary.
    var onReorderHandoff: (NSPoint) -> Void = { _ in }

    final class Coordinator: NSObject {
        var onHoverChanged: ((Bool) -> Void)?
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
        var moveTargetGroups: [PickyDockGroup] = []
        var onMoveToGroup: ((String) -> Void)?
        var onUngroup: (() -> Void)?
        var onReorderHandoff: ((NSPoint) -> Void)?

        func clearCallbacks() {
            onHoverChanged = nil
            onOpen = nil
            onToggleScreenContextTarget = nil
            onToggleStickyScreenContextTarget = nil
            onCompact = nil
            onArchivePressing = nil
            onArchive = nil
            onStop = nil
            moveTargetGroups = []
            onMoveToGroup = nil
            onUngroup = nil
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

        @objc func moveToGroup(_ sender: NSMenuItem) {
            guard let groupID = sender.representedObject as? String else { return }
            onMoveToGroup?(groupID)
        }

        @objc func ungroup(_ sender: NSMenuItem) {
            onUngroup?()
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
        coordinator.onHoverChanged = onHoverChanged
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
        coordinator.moveTargetGroups = moveTargetGroups
        coordinator.onMoveToGroup = onMoveToGroup
        coordinator.onUngroup = onUngroup
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
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
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
        coordinator?.onHoverChanged?(true)
        guard let coordinator else { return }

        let menu = NSMenu()
        let stickyConversationItem = menuItem(
            title: L10n.t(
                coordinator.isScreenContextSticky
                    ? "dock.contextMenu.unpinInput"
                    : "dock.contextMenu.pinInput"
            ),
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
                title: L10n.t(
                    coordinator.isScreenContextArmed
                        ? "dock.contextMenu.cancelNextInput"
                        : "dock.contextMenu.sendNextInput"
                ),
                action: #selector(PickyHUDDockIconClickHost.Coordinator.toggleScreenContextTarget(_:)),
                target: coordinator
            ))
        }
        menu.addItem(menuItem(
            title: L10n.t("dock.contextMenu.compact"),
            action: #selector(PickyHUDDockIconClickHost.Coordinator.compact(_:)),
            target: coordinator,
            isEnabled: coordinator.canCompact
        ))
        if !coordinator.moveTargetGroups.isEmpty || coordinator.onUngroup != nil {
            menu.addItem(.separator())
            if !coordinator.moveTargetGroups.isEmpty {
                let moveItem = NSMenuItem(title: L10n.t("group.list.menu.move"), action: nil, keyEquivalent: "")
                let moveMenu = NSMenu(title: L10n.t("group.list.menu.move"))
                for group in coordinator.moveTargetGroups {
                    let item = menuItem(
                        title: group.displayName,
                        action: #selector(PickyHUDDockIconClickHost.Coordinator.moveToGroup(_:)),
                        target: coordinator
                    )
                    item.representedObject = group.id
                    moveMenu.addItem(item)
                }
                moveItem.submenu = moveMenu
                menu.addItem(moveItem)
            }
            if coordinator.onUngroup != nil {
                menu.addItem(menuItem(
                    title: L10n.t("group.list.menu.ungroup"),
                    action: #selector(PickyHUDDockIconClickHost.Coordinator.ungroup(_:)),
                    target: coordinator
                ))
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: L10n.t("dock.contextMenu.archive"),
            action: #selector(PickyHUDDockIconClickHost.Coordinator.archive(_:)),
            target: coordinator
        ))
        menu.addItem(menuItem(
            title: L10n.t("dock.contextMenu.stop"),
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

/// Mounted only for a hovered preview. Its session handle resolves from the
/// same lightweight per-session dock store as the icon, keeping full detail
/// publications out of every icon and rail.
private struct PickyHUDMiniPreviewResolver: View {
    let session: PickyHUDDockSession
    let metrics: PickyHUDDockMetrics

    var body: some View {
        PickyHUDMiniPreviewCardView(session: session, metrics: metrics)
            .id("\(session.id)|\(session.cwd ?? "")")
    }
}

struct PickyHUDMiniPreviewCardView: View {
    let session: PickyHUDDockSession
    let metrics: PickyHUDDockMetrics
    var relativeTime: String?

    @Environment(\.pickyAppFontScale) private var fontScale

    init(
        session: PickyHUDDockSession,
        metrics: PickyHUDDockMetrics,
        relativeTime: String? = nil
    ) {
        self.session = session
        self.metrics = metrics
        self.relativeTime = relativeTime
    }

    private var cornerRadius: CGFloat { metrics.groupListPanelCornerRadius }
    private var resolvedRelativeTime: String {
        relativeTime ?? PickyHUDDockGroupListRelativeTimePresentation.text(for: session.previewUpdatedAt)
    }
    private var previewWidth: CGFloat {
        PickyHUDDockGroupListPolicy.previewWidth(
            session: session,
            relativeTime: resolvedRelativeTime,
            metrics: metrics,
            fontScale: fontScale
        )
    }

    var body: some View {
        let _ = PickyPerf.event("mini_preview_body")
        PickyHUDDockGroupListRow(
            row: PickyHUDDockGroupListRowModel(
                session: session,
                updatedAt: session.previewUpdatedAt
            ),
            isUnread: false,
            isSelected: false,
            isHighlighted: false,
            shortcutNumber: nil,
            isLeavingGroup: false,
            minimumHeight: PickyHUDDockGroupListPolicy.rowHeight(metrics: metrics, fontScale: fontScale),
            metrics: metrics,
            relativeTime: resolvedRelativeTime,
            isScreenContextArmed: false,
            isScreenContextSticky: false,
            moveTargetGroups: [],
            onSelect: {},
            onToggleScreenContextTarget: {},
            onToggleStickyScreenContextTarget: {},
            onCompact: {},
            onArchive: {},
            onStop: {},
            onMoveToGroup: { _ in },
            onUngroup: {},
            onReorderHandoff: { _ in },
            isPreview: true
        )
        .padding(metrics.groupListPanelPadding)
        .frame(width: previewWidth)
        .background(previewBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private var previewBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return PickyHUDDockGroupListSurface(shape: shape)
    }

}
