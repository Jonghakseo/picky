//
//  PickyHUDView.swift
//  Picky
//
//  SwiftUI composition for the long-running session HUD.
//

import AppKit
import SwiftUI

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var panelIdentifier: NSUserInterfaceItemIdentifier?
    /// Per-panel reactive placement state. The overlay manager updates
    /// `placement.availableCardMaxHeight` whenever the dock anchor or the screen
    /// configuration changes; the conversation card binds to it so it grows or
    /// shrinks within whatever space remains below the dock's top edge.
    @ObservedObject var placement: PickyHUDPlacement = PickyHUDPlacement()
    var onSizeChange: (CGSize) -> Void = { _ in }
    /// Live delta callback for the dock anchor handle. Argument is the cursor's
    /// screen delta from drag start in both X and Y (`NSEvent.mouseLocation` based).
    /// The overlay manager converts the Y delta into an anchor percent and the X
    /// delta into a horizontal offset, then updates placement across every panel.
    var onDockHandleDragChanged: (CGPoint) -> Void = { _ in }
    var onDockHandleDragEnded: () -> Void = { }
    var onDockHandleDoubleClick: () -> Void = { }
    var onArchiveUndoRequested: (_ sessionID: String, _ title: String) -> Void = { _, _ in }
    @State private var heldSession: PickyHUDDockHold?
    @State private var hoverPreviewSessionID: String?
    @State private var suppressedHoverSessionID: String?
    @State private var isHUDHovered = false
    @State private var isDockHovered = false
    @State private var closeExpansionTask: Task<Void, Never>?
    @State private var keyDownMonitor: Any?
    @State private var modifierFlagsMonitor: Any?
    @State private var isCommandShortcutHintVisible = false
    @State private var composerFocusRequestID = 0
    @State private var sizeReporter = PickyHUDSizeReporter()

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(PickyHUDDockLayout.visibleSessionLimit).reversed())
    }

    private var activeSessionID: String? {
        PickyHUDDockLayout.activeSessionID(
            visibleIDs: visibleSessions.map(\.id),
            held: heldSession,
            previewID: nil
        )
    }

    private var openedSessionID: String? {
        if case let .open(sessionID) = heldSession { return sessionID }
        return nil
    }

    private var activeSession: PickySessionListViewModel.SessionCard? {
        guard let activeSessionID else { return nil }
        return visibleSessions.first { $0.id == activeSessionID }
    }

    var body: some View {
        hudContent
            // Measure the HUD's intrinsic content height before the hosting view
            // applies the current panel height. Without this, active streaming
            // updates can report the already-clipped height and prevent growth.
            .fixedSize(horizontal: false, vertical: true)
            .background(PickyHUDSizeReader())
            // Keep content stuck to the dock edge during the shouldHoldHeight phase.
            // With dock-top-anchored placement we want the dock to coincide with the
            // panel top (after vertical padding); a default .center alignment would
            // float the content vertically inside the held panel and break the dock
            // anchor math. Horizontal alignment mirrors when the dock is on the left.
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: placement.dockSide == .left ? .topLeading : .topTrailing
            )
            // Do not implicitly animate the initial card insertion. The card contains
            // ScrollView/TextEditor subtrees that perform one-frame measurement and
            // bottom-pinning on appear; animating that first layout exposes transient
            // pre-scroll positions as rows/composer floating outside the card.
            .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: handleHUDSizeChange)
            .onAppear(perform: installCloseShortcutMonitor)
            .onDisappear {
                closeExpansionTask?.cancel()
                closeExpansionTask = nil
                uninstallCloseShortcutMonitor()
                sizeReporter.cancelPendingReport()
            }
    }

    private func handleHUDSizeChange(_ size: CGSize) {
        sizeReporter.handleMeasuredSize(
            size,
            activeSessionID: activeSession?.id,
            shouldHoldHeight: shouldHoldPanelHeightDuringActiveTurn,
            onSizeChange: onSizeChange
        )
    }

    private var shouldHoldPanelHeightDuringActiveTurn: Bool {
        switch activeSession?.status {
        case .running, .queued, .waiting_for_input:
            return true
        case .completed, .blocked, .cancelled, .failed, nil:
            return false
        }
    }

    private var hudContent: some View {
        // alignment: .top so the card and the dock-rail stack both anchor at the HStack
        // top edge. The conversation card sits inward from the dock side, keeping the
        // rail pinned to the chosen screen edge whether the dock is left or right.
        HStack(alignment: .top, spacing: PickyHUDDockLayout.panelGap) {
            if placement.dockSide == .right {
                conversationCard
            }
            // Keep the dock rail at a stable syntactic position in the SwiftUI tree.
            // When the handle drag crosses the snap threshold, only the optional
            // conversation-card side changes; the AppKit-backed handle view that owns
            // the active mouse drag stays alive instead of being recreated mid-drag.
            dockRail
            if placement.dockSide == .left {
                conversationCard
            }
        }
        .padding(PickyHUDExpansion.dockShadowInsets)
        .onHover(perform: handleHUDHover)
    }

    @ViewBuilder
    private var conversationCard: some View {
        if let activeSession {
            PickyConversationCardView(
                viewModel: viewModel,
                session: activeSession,
                onArchiveSession: archiveSession,
                maxHeight: placement.availableCardMaxHeight,
                isPreviewMode: false,
                focusRequestID: composerFocusRequestID
            )
            .id(activeSession.id)
            .frame(width: PickyHUDDockLayout.detailWidth)
            .transition(.identity)
        }
    }

    @ViewBuilder
    private var dockRail: some View {
        if !viewModel.isLoadingInitialSessionSnapshot {
            PickyHUDDockRailView(
                sessions: visibleSessions,
                activeSessionID: activeSession?.id,
                openedSessionID: openedSessionID,
                previewSessionID: hoverPreviewSessionID,
                dockSide: placement.dockSide,
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                pendingDoneFlashSessionIDs: viewModel.pendingDoneFlashSessionIDs,
                onHoverSession: previewDockSession,
                onOpenSession: toggleOpenSession,
                onArchiveSession: archiveSession,
                onCreatePickle: chooseFolderForEmptyPickle,
                onDockHoverChanged: handleDockHover,
                onDoneFlashConsumed: viewModel.markDoneFlashConsumed(sessionID:),
                onDockHandleDragChanged: onDockHandleDragChanged,
                onDockHandleDragEnded: onDockHandleDragEnded,
                onDockHandleDoubleClick: onDockHandleDoubleClick
            )
            .frame(width: PickyHUDDockLayout.railWidth)
            .zIndex(10)
            // Keep rail state changes instantaneous; the conversation card handles
            // its own sizing and scroll stabilization when it appears.
            .transaction(value: activeSession?.id) { transaction in
                transaction.animation = nil
            }
        }
    }

    private var isPointerInsideHUDSurface: Bool {
        isHUDHovered || isDockHovered
    }

    private func handleHUDHover(_ isHovering: Bool) {
        isHUDHovered = isHovering
        if isHovering {
            cancelPendingClose()
        } else {
            scheduleCloseIfNeeded()
        }
    }

    private func handleDockHover(_ isHovering: Bool) {
        isDockHovered = isHovering
        if isHovering {
            cancelPendingClose()
        } else {
            scheduleCloseIfNeeded()
        }
    }

    private func isHoverPreviewSession(_ sessionID: String) -> Bool {
        hoverPreviewSessionID == sessionID && heldSession?.sessionID != sessionID
    }

    private func chooseFolderForEmptyPickle() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a working folder"
        panel.prompt = "Start"
        panel.message = "Choose the folder where the new Pickle should run."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { try? await viewModel.createEmptyPickleSession(cwd: url.path) }
        }
    }

    private func previewDockSession(_ sessionID: String) {
        isDockHovered = true
        cancelPendingClose()
        if heldSession?.sessionID == sessionID {
            if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
            return
        }
        if suppressedHoverSessionID == sessionID { return }
        suppressedHoverSessionID = nil
        hoverPreviewSessionID = PickyHUDDockLayout.previewSessionIDAfterDockHover(
            current: hoverPreviewSessionID,
            sessionID: sessionID
        )
    }

    private func toggleOpenSession(_ sessionID: String) {
        cancelPendingClose()
        let nextHeldSession = PickyHUDDockLayout.heldSessionAfterClick(
            current: heldSession,
            clicked: sessionID
        )
        heldSession = nextHeldSession
        if nextHeldSession == nil {
            if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
            suppressedHoverSessionID = sessionID
        } else {
            hoverPreviewSessionID = nil
            suppressedHoverSessionID = nil
        }
    }

    private func archiveSession(_ sessionID: String) {
        cancelPendingClose()
        let title = (visibleSessions + viewModel.sessions).first(where: { $0.id == sessionID })?.title ?? "Pickle"
        viewModel.archive(sessionID: sessionID)
        if heldSession?.sessionID == sessionID { heldSession = nil }
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        if suppressedHoverSessionID == sessionID { suppressedHoverSessionID = nil }
        onArchiveUndoRequested(sessionID, title)
    }

    private func scheduleCloseIfNeeded() {
        closeExpansionTask?.cancel()
        closeExpansionTask = Task {
            do {
                try await Task.sleep(nanoseconds: PickyHUDDockLayout.closeDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let isStillInsideHUD = isPointerInsideHUDSurface
                hoverPreviewSessionID = PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(
                    current: hoverPreviewSessionID,
                    isDockHovered: isDockHovered
                )
                heldSession = PickyHUDDockLayout.heldSessionAfterCloseTimeout(
                    current: heldSession,
                    isHUDHovered: isStillInsideHUD
                )
                if !isStillInsideHUD { suppressedHoverSessionID = nil }
                closeExpansionTask = nil
            }
        }
    }

    private func closeHeldSession() {
        guard let sessionID = heldSession?.sessionID else { return }
        heldSession = nil
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        suppressedHoverSessionID = sessionID
    }

    private func installCloseShortcutMonitor() {
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard handleKeyboardShortcut(event) else { return event }
                return nil
            }
        }

        if modifierFlagsMonitor == nil {
            modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                updateCommandShortcutHintVisibility(modifierFlags: event.modifierFlags)
                return event
            }
        }
    }

    private func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        updateCommandShortcutHintVisibility(modifierFlags: event.modifierFlags)
        guard let keyWindow = NSApp.keyWindow as? PickyHUDPanel else { return false }
        if let panelIdentifier, keyWindow.identifier != panelIdentifier { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let visibleIDs = visibleSessions.map(\.id)

        if PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: event.keyCode, modifiers: flags),
           activeSession != nil,
           !isTextInputFocused(in: keyWindow) {
            focusActiveComposer()
            return true
        }

        if flags == .command, event.keyCode == Self.wKeyCode, heldSession != nil {
            closeHeldSession()
            return true
        }

        if flags == .command,
           let number = Self.numberShortcutValue(for: event),
           PickyHUDDockLayout.sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: number) != nil {
            let next = PickyHUDDockLayout.heldSessionAfterNumberShortcut(
                current: heldSession,
                visibleIDs: visibleIDs,
                number: number
            )
            if let next {
                openHeldSession(next)
            } else {
                closeHeldSession()
            }
            return true
        }

        if flags == [.command, .shift], let direction = Self.cycleDirection(for: event) {
            let next = PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: heldSession, visibleIDs: visibleIDs, direction: direction)
            if let next { openHeldSession(next) }
            return next != nil
        }

        return false
    }

    private func openHeldSession(_ next: PickyHUDDockHold) {
        cancelPendingClose()
        heldSession = next
        hoverPreviewSessionID = nil
        suppressedHoverSessionID = nil
    }

    private func focusActiveComposer() {
        composerFocusRequestID &+= 1
    }

    private func isTextInputFocused(in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }

    private func uninstallCloseShortcutMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let modifierFlagsMonitor {
            NSEvent.removeMonitor(modifierFlagsMonitor)
            self.modifierFlagsMonitor = nil
        }
        isCommandShortcutHintVisible = false
    }

    private func updateCommandShortcutHintVisibility(modifierFlags: NSEvent.ModifierFlags) {
        guard let keyWindow = NSApp.keyWindow as? PickyHUDPanel else {
            isCommandShortcutHintVisible = false
            return
        }
        if let panelIdentifier, keyWindow.identifier != panelIdentifier {
            isCommandShortcutHintVisible = false
            return
        }
        isCommandShortcutHintVisible = modifierFlags.contains(.command)
    }

    private func cancelPendingClose() {
        closeExpansionTask?.cancel()
        closeExpansionTask = nil
    }

    private static func numberShortcutValue(for event: NSEvent) -> Int? {
        switch event.keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    private static func cycleDirection(for event: NSEvent) -> Int? {
        PickyHUDKeyboardShortcutPolicy.cycleDirection(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
    }

    private static let wKeyCode: UInt16 = 13
}

enum PickyHUDKeyboardShortcutPolicy {
    private static let leftBracketKeyCode: UInt16 = 33
    private static let rightBracketKeyCode: UInt16 = 30
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    static func isComposerFocusShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && (keyCode == returnKeyCode || keyCode == keypadEnterKeyCode)
    }

    static func cycleDirection(keyCode: UInt16, charactersIgnoringModifiers: String?) -> Int? {
        switch keyCode {
        case leftBracketKeyCode: return -1
        case rightBracketKeyCode: return 1
        default: break
        }

        switch charactersIgnoringModifiers {
        case "[", "{": return -1
        case "]", "}": return 1
        default: return nil
        }
    }
}

private struct PickyHUDMiniPreviewCardView: View {
    static let cardWidth: CGFloat = 238
    static var totalWidth: CGFloat { cardWidth }

    let session: PickySessionListViewModel.SessionCard
    @State private var gitStatus: PickyGitRepositoryStatus?

    init(session: PickySessionListViewModel.SessionCard) {
        self.session = session
        _gitStatus = State(initialValue: PickyGitRepositoryStatus.cached(cwd: session.cwd))
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                contextLine
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: Self.cardWidth)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(DS.Colors.surface3.opacity(0.62))
                )
        }
        .task(id: "\(session.cwd ?? "")|\(session.updatedAt.timeIntervalSince1970)") {
            if gitStatus == nil, let cached = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cached
            }
            let freshGit = await PickyGitRepositoryStatus.load(cwd: session.cwd)
            guard !Task.isCancelled else { return }
            gitStatus = freshGit
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview \(session.title), \(statusLabel), \(contextAccessibilityLabel)")
    }

    @ViewBuilder
    private var contextLine: some View {
        if let gitStatus {
            HStack(spacing: 4) {
                Text(gitStatus.repositoryDisplayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(2)
                Text("·")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(gitStatus.branchDisplayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
            }
        } else if let cwd = session.compactCwdDescription {
            Text(cwd)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var contextAccessibilityLabel: String {
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

@MainActor
final class PickyHUDSizeReporter {
    private let coalescingDelayNanoseconds: UInt64

    private var lastReportedHUDSize: CGSize = .zero
    private var lastReportedActiveSessionID: String?
    private var pendingReportTask: Task<Void, Never>?
    private var pendingReportedSize: CGSize?
    private var pendingOnSizeChange: ((CGSize) -> Void)?

    init(coalescingDelayNanoseconds: UInt64 = 16_000_000) {
        self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
    }

    func handleMeasuredSize(
        _ measuredSize: CGSize,
        activeSessionID: String?,
        shouldHoldHeight: Bool,
        onSizeChange: @escaping (CGSize) -> Void
    ) {
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }

        let activeSessionChanged = activeSessionID != lastReportedActiveSessionID
        if activeSessionChanged {
            lastReportedActiveSessionID = activeSessionID
        }

        let targetSize = PickyHUDExpansion.reportedHUDSize(
            measuredSize: measuredSize,
            previousReportedSize: lastReportedHUDSize,
            activeSessionChanged: activeSessionChanged,
            shouldHoldHeight: shouldHoldHeight
        )

        guard activeSessionChanged || !lastReportedHUDSize.isApproximatelyEqual(to: targetSize) else { return }
        lastReportedHUDSize = targetSize

        if activeSessionChanged {
            // First hover opens the conversation card while the NSPanel is still at
            // its dock-only collapsed height. If we coalesce this resize for a frame,
            // SwiftUI can draw the newly inserted ScrollView/TextEditor against the
            // stale panel bounds, exposing transient pre-scroll layout outside the
            // card. Grow the outer panel immediately for session switches; keep
            // coalescing only for streaming/content churn after the card is visible.
            cancelPendingReport()
            onSizeChange(targetSize)
            return
        }

        scheduleReport(targetSize, onSizeChange: onSizeChange)
    }

    func cancelPendingReport() {
        pendingReportTask?.cancel()
        pendingReportTask = nil
        pendingReportedSize = nil
        pendingOnSizeChange = nil
    }

    private func scheduleReport(_ size: CGSize, onSizeChange: @escaping (CGSize) -> Void) {
        pendingReportedSize = size
        pendingOnSizeChange = onSizeChange
        pendingReportTask?.cancel()
        pendingReportTask = Task { @MainActor [weak self] in
            guard let delay = self?.coalescingDelayNanoseconds else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            guard let reportedSize = self.pendingReportedSize, let onSizeChange = self.pendingOnSizeChange else { return }
            self.pendingReportTask = nil
            self.pendingReportedSize = nil
            self.pendingOnSizeChange = nil
            onSizeChange(reportedSize)
        }
    }
}

private struct PickyHUDSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct PickyHUDSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PickyHUDSizePreferenceKey.self, value: proxy.size)
        }
    }
}

private struct PickyHUDCollapsibleContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct PickyHUDCollapsibleContent<Content: View>: View {
    let isExpanded: Bool
    private let content: Content
    @State private var measuredHeight: CGFloat = 0

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PickyHUDCollapsibleContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .frame(
                height: PickyHUDExpansion.contentFrameHeight(
                    isExpanded: isExpanded,
                    measuredHeight: measuredHeight
                ),
                alignment: .top
            )
            .opacity(isExpanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(PickyHUDExpansion.animation, value: isExpanded)
            .onPreferenceChange(PickyHUDCollapsibleContentHeightPreferenceKey.self) { height in
                measuredHeight = height
            }
    }
}

enum PickyHUDArchiveHoldPolicy {
    static let duration: TimeInterval = 1.5
    static let feedbackStartDelay: TimeInterval = 0.2
    static let feedbackStartDelayNanoseconds: UInt64 = 200_000_000
    static let maximumDistance: CGFloat = 10
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73

    static var feedbackAnimationDuration: TimeInterval {
        max(0, duration - feedbackStartDelay)
    }
}

private struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let activeSessionID: String?
    let openedSessionID: String?
    let previewSessionID: String?
    let dockSide: PickyHUDDockSide
    let isCommandShortcutHintVisible: Bool
    let pendingDoneFlashSessionIDs: Set<String>
    let onHoverSession: (String) -> Void
    let onOpenSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onCreatePickle: () -> Void
    let onDockHoverChanged: (Bool) -> Void
    let onDoneFlashConsumed: (String) -> Void
    let onDockHandleDragChanged: (CGPoint) -> Void
    let onDockHandleDragEnded: () -> Void
    let onDockHandleDoubleClick: () -> Void

    @State private var isAddSlotExpanded = false
    @State private var isHandleHovered = false
    @State private var isHandleDragging = false

    var body: some View {
        // The handle is the first child INSIDE the dock capsule (after a small top
        // padding) so the dock body itself acts as the hit target. The capsule
        // background is opaque, which sidesteps SwiftUI's transparent-view hit-
        // testing quirks: clicks anywhere in the handle's row hit the NSView
        // backing the handle, not the empty space outside an external pill.
        VStack(spacing: 2) {
            dockAnchorHandle
            sessionsAndAddSlot
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(dockGlassBackground)
        .onHover(perform: onDockHoverChanged)
    }

    @ViewBuilder
    private var sessionsAndAddSlot: some View {
        if sessions.isEmpty {
            // Empty state still lives inside the capsule so the handle has somewhere
            // to anchor visually. Use the full-size add button (not the collapsible
            // one) since there are no sessions to keep it compact for.
            addAgentSlotButton
        } else {
            VStack(spacing: 7) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    PickyHUDDockIconView(
                        session: session,
                        index: index,
                        isActive: activeSessionID == session.id,
                        isOpened: openedSessionID == session.id,
                        isPreviewed: previewSessionID == session.id,
                        dockSide: dockSide,
                        shortcutNumber: PickyHUDDockLayout.numberShortcutForSessionIndex(index),
                        isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                        shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                        onHover: { onHoverSession(session.id) },
                        onOpen: { onOpenSession(session.id) },
                        onArchive: { onArchiveSession(session.id) },
                        onDoneFlashConsumed: { onDoneFlashConsumed(session.id) }
                    )
                }
            }
            collapsibleAddAgentSlot
                .padding(.top, 7)
        }
    }

    /// Drag handle that lives inside the dock capsule's top row. Backed by an
    /// `NSViewRepresentable` so AppKit handles hit testing, tracking area, and
    /// cursor rects — the same NSView bounds drive all three, which avoids the
    /// SwiftUI hit-test quirks that plagued earlier overlay-based attempts.
    /// The visible 22×4 pill is overlaid with `.allowsHitTesting(false)` so it's
    /// purely decorative and never claims clicks.
    private var dockAnchorHandle: some View {
        let isActive = isHandleHovered || isHandleDragging
        return PickyHUDDockAnchorHandleHost(
            onHoverChanged: { hovering in isHandleHovered = hovering },
            onDragChanged: { delta in
                if !isHandleDragging { isHandleDragging = true }
                onDockHandleDragChanged(delta)
            },
            onDragEnded: {
                isHandleDragging = false
                onDockHandleDragEnded()
            },
            onDoubleClick: onDockHandleDoubleClick
        )
        // Fill the capsule's available inner width (railWidth minus the dock's
        // 6pt horizontal padding on each side) so the handle row spans the
        // entire top of the capsule.
        .frame(maxWidth: .infinity)
        .frame(height: PickyHUDExpansion.dockHandleAreaHeight)
        .overlay {
            // Quiet by default — the pill should hint at draggability without
            // shouting. Hover and drag expand and darken it for a clear cue.
            Capsule(style: .continuous)
                .fill(DS.Colors.textTertiary.opacity(isActive ? 0.7 : 0.22))
                .frame(width: isActive ? 24 : 18, height: 3)
                .animation(.easeOut(duration: 0.14), value: isHandleHovered)
                .animation(.easeOut(duration: 0.14), value: isHandleDragging)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("HUD dock handle")
        .accessibilityHint("Drag to move the Pickle dock. Crossing the middle of the screen switches the dock edge. Double-click to reset the dock to its default position.")
    }

    /// Frosted-glass capsule that hosts the dock icons. Uses .ultraThinMaterial
    /// so the desktop / app underneath actually shows through, then layers a
    /// gradient stroke (bright top, dimmer bottom) for the macOS-style top
    /// gloss, and an ambient shadow so the dock no longer disappears against
    /// light backgrounds.
    private var dockGlassBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
            )
            .compositingGroup()
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockShadowOpacity),
                radius: PickyHUDExpansion.dockShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockShadowYOffset
            )
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockTightShadowOpacity),
                radius: PickyHUDExpansion.dockTightShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockTightShadowYOffset
            )
    }

    private var addAgentSlotButton: some View {
        Button(action: onCreatePickle) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        DS.Colors.textTertiary.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: PickyHUDDockLayout.addSlotButtonSide, height: PickyHUDDockLayout.addSlotButtonSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Start Pickle")
        .accessibilityHint("Choose a working folder and start an empty Pickle")
    }

    private var collapsibleAddAgentSlot: some View {
        Button(action: onCreatePickle) {
            ZStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            DS.Colors.textTertiary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: PickyHUDDockLayout.addSlotButtonSide, height: PickyHUDDockLayout.addSlotButtonSide)
                .opacity(isAddSlotExpanded ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(DS.Colors.textSecondary.opacity(0.78))
                    .frame(width: 18, height: 1)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, y: 0.4)
                    .opacity(isAddSlotExpanded ? 0 : 1)
            }
            .frame(
                width: PickyHUDDockLayout.addSlotButtonSide,
                height: PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = hovering
            }
        }
        .accessibilityLabel("Start Pickle")
        .accessibilityHint("Choose a working folder and start an empty Pickle")
    }
}

private struct PickyHUDDockIconView: View {
    let session: PickySessionListViewModel.SessionCard
    let index: Int
    let isActive: Bool
    let isOpened: Bool
    let isPreviewed: Bool
    let dockSide: PickyHUDDockSide
    let shortcutNumber: Int?
    let isCommandShortcutHintVisible: Bool
    let shouldFlashCompletion: Bool
    let onHover: () -> Void
    let onOpen: () -> Void
    let onArchive: () -> Void
    let onDoneFlashConsumed: () -> Void

    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @State private var archiveFeedbackStartTask: Task<Void, Never>?
    @State private var isArchivePressing = false
    @State private var archiveProgress: Double = 0
    @State private var didCompleteArchiveHold = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            dockIconBackground
            Text(initials)
                .font(labelFont)
                .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .opacity(isArchivePressing ? 0.64 : 1)
        }
        .frame(width: 36, height: 36)
        .opacity(session.status == .cancelled ? 0.55 : 1)
        .scaleEffect(tileScale)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
        .overlay(alignment: .topTrailing) {
            statusDot.offset(x: -1.3, y: 1.3)
        }
        .overlay(alignment: .topLeading) {
            if isArchivePressing {
                archiveBadge
                    .offset(x: -5, y: -5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isCommandShortcutHintVisible, let shortcutNumber {
                commandShortcutBadge(number: shortcutNumber)
                    .offset(x: -5, y: 5)
                    .transition(.scale(scale: 0.88, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .overlay(alignment: .center) {
            archiveProgressRing
        }
        .overlay(alignment: .center) {
            if isPreviewed {
                PickyHUDMiniPreviewCardView(session: session)
                    .offset(x: miniPreviewXOffset)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isPreviewed ? 100 : 0)
        .contentShape(Circle())
        .overlay {
            PickyHUDDockIconClickHost(
                onHover: onHover,
                onOpen: onOpen,
                onArchivePressing: handleArchivePressing,
                onArchive: completeArchiveHold
            )
        }
        .pointerCursor()
        .onAppear {
            if shouldFlashCompletion { runCompletionFlash() }
        }
        .onChange(of: shouldFlashCompletion) { _, shouldFlash in
            if shouldFlash { runCompletionFlash() }
        }
        .onDisappear {
            completionFlashTask?.cancel()
            completionFlashTask = nil
            archiveFeedbackStartTask?.cancel()
            archiveFeedbackStartTask = nil
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
        .frame(width: 42, height: 42)
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
            .font(.system(size: 7.5, weight: .bold))
            .foregroundColor(DS.Colors.warningText)
            .frame(width: 14, height: 14)
            .background(Circle().fill(DS.Colors.surface1.opacity(0.96)))
            .overlay(Circle().stroke(DS.Colors.warning.opacity(0.65), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func commandShortcutBadge(number: Int) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: "command")
                .font(.system(size: 6.5, weight: .bold))
            Text("\(number)")
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.70))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }

    private var dockIconBackground: some View {
        // Glass icon: ultraThinMaterial base + (active) status-tinted glaze +
        // (inactive) faint white film. The stroke is a top-bright / status-tinted
        // bottom gradient so the icon reads as a small piece of glass on the
        // bigger glass capsule rather than a flat fill.
        // The completion flash temporarily boosts the success-tinted glaze + stroke
        // and adds an ambient glow so a Done transition feels celebratory without
        // disturbing the layout.
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(statusColor.opacity(isActive ? 0.22 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.0 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.20 * archiveProgress))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.success.opacity(0.34 * completionFlashIntensity))
            )
            .overlay {
                if usesAnimatedStatusBorder {
                    PickyHUDAnimatedStatusBorderView(
                        baseColor: statusColor,
                        highlightColor: statusLoadingHighlightColor,
                        duration: statusBorderAnimationDuration,
                        cornerRadius: 12
                    )
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isActive ? statusColor.opacity(0.55) : statusColor.opacity(0.30),
                            lineWidth: isActive ? 1.0 : 0.7
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DS.Colors.warning.opacity(0.76 * archiveProgress), lineWidth: 1.35)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DS.Colors.success.opacity(0.85 * completionFlashIntensity), lineWidth: 1.4)
            )
            .shadow(color: DS.Colors.warning.opacity(0.30 * archiveProgress), radius: 5, x: 0, y: 0)
            .shadow(color: DS.Colors.success.opacity(0.55 * completionFlashIntensity), radius: 6, x: 0, y: 0)
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

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(DS.Colors.surface1.opacity(0.94), lineWidth: 2))
            .accessibilityHidden(true)
    }

    private var usesAnimatedStatusBorder: Bool {
        session.status == .queued || session.status == .running
    }

    private var statusBorderAnimationDuration: Double {
        session.status == .running ? 2.4 : 4.2
    }

    private var statusLoadingHighlightColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .queued:
            return DS.Colors.floatingGradientPurple
        default:
            return statusColor
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return DS.Colors.accentText
        case .running:
            return DS.Colors.overlayCursorBlue
        case .waiting_for_input:
            return DS.Colors.warning
        case .blocked:
            return DS.Colors.warningText
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }

    private var initials: String {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwdLeaf = (session.cwd ?? "")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let source = trimmedTitle.isEmpty ? cwdLeaf : trimmedTitle
        guard !source.isEmpty else { return "··" }
        let prefix = String(source.prefix(2))
        return Self.containsHangul(prefix) ? prefix : prefix.uppercased()
    }

    private var labelFont: Font {
        Self.containsHangul(initials)
            ? .system(size: PickyHUDTypography.Size.status, weight: .bold)
            : .system(size: PickyHUDTypography.Size.status, weight: .bold, design: .monospaced)
    }

    private var tileScale: CGFloat {
        if isArchivePressing { return 0.92 }
        return isHovered ? 1.03 : 1.0
    }

    private var miniPreviewXOffset: CGFloat {
        let iconHalfWidth: CGFloat = 18
        let distance = (PickyHUDMiniPreviewCardView.totalWidth / 2) + iconHalfWidth + PickyHUDDockLayout.panelGap
        return dockSide == .right ? -distance : distance
    }

    private static func containsHangul(_ string: String) -> Bool {
        string.unicodeScalars.contains { 0xAC00...0xD7A3 ~= $0.value }
    }
}

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

private struct PickyHUDAnimatedStatusBorderView: View {
    let baseColor: Color
    let highlightColor: Color
    let duration: Double
    var cornerRadius: CGFloat = 14
    @State private var isFlowing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(baseColor.opacity(0.24), lineWidth: 1)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: baseColor.opacity(0.20), location: 0.00),
                            .init(color: highlightColor.opacity(0.85), location: 0.11),
                            .init(color: Color.white.opacity(0.64), location: 0.17),
                            .init(color: baseColor.opacity(0.86), location: 0.24),
                            .init(color: baseColor.opacity(0.18), location: 0.42),
                            .init(color: highlightColor.opacity(0.30), location: 0.62),
                            .init(color: highlightColor.opacity(0.82), location: 0.79),
                            .init(color: baseColor.opacity(0.24), location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(isFlowing ? 360 : 0)
                    ),
                    lineWidth: 1.45
                )
                .shadow(color: highlightColor.opacity(0.26), radius: 3.4, x: 0, y: 0)
        }
        .onAppear {
            guard !isFlowing else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                isFlowing = true
            }
        }
        .accessibilityHidden(true)
    }
}


#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}

// MARK: - Dock icon clicks (AppKit-backed for immediate single-click open)

private struct PickyHUDDockIconClickHost: NSViewRepresentable {
    var onHover: () -> Void
    var onOpen: () -> Void
    var onArchivePressing: (Bool) -> Void
    var onArchive: () -> Void

    final class Coordinator {
        var onHover: (() -> Void)?
        var onOpen: (() -> Void)?
        var onArchivePressing: ((Bool) -> Void)?
        var onArchive: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHover = onHover
        context.coordinator.onOpen = onOpen
        context.coordinator.onArchivePressing = onArchivePressing
        context.coordinator.onArchive = onArchive
        let view = PickyHUDDockIconClickNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHover = onHover
        context.coordinator.onOpen = onOpen
        context.coordinator.onArchivePressing = onArchivePressing
        context.coordinator.onArchive = onArchive
    }
}

private final class PickyHUDDockIconClickNSView: NSView {
    weak var coordinator: PickyHUDDockIconClickHost.Coordinator?
    private var trackingArea: NSTrackingArea?
    private var archiveWorkItem: DispatchWorkItem?
    private var mouseDownPoint: NSPoint?
    private var didCompleteArchiveHold = false

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
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
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didCompleteArchiveHold = false
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

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint, archiveWorkItem != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > PickyHUDArchiveHoldPolicy.maximumDistance {
            cancelArchiveHoldFeedback()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedArchive = didCompleteArchiveHold
        cancelArchiveHoldFeedback()
        mouseDownPoint = nil
        didCompleteArchiveHold = false
        guard !completedArchive else { return }
        guard event.clickCount < 2 else { return }
        coordinator?.onOpen?()
    }

    private func cancelArchiveHoldFeedback() {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        coordinator?.onArchivePressing?(false)
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Dock anchor handle (AppKit-backed for reliable hit testing)

/// AppKit-backed handle for dragging the HUD dock's vertical anchor. Wrapping an
/// `NSView` directly avoids SwiftUI's transparent-view hit-testing quirks: AppKit's
/// `hitTest`, `NSTrackingArea`, and `addCursorRect` all key off the same NSView
/// bounds, so click + hover + cursor reliably react to the entire frame instead of
/// just the visible 22×4 capsule that SwiftUI's gesture system kept latching onto.
private struct PickyHUDDockAnchorHandleHost: NSViewRepresentable {
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
}

private final class PickyHUDDockAnchorHandleNSView: NSView {
    weak var coordinator: PickyHUDDockAnchorHandleHost.Coordinator?
    private var dragStartScreenPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var hasClosedHandPushed = false

    override var isFlipped: Bool { false }

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

    override var acceptsFirstResponder: Bool { false }
}
