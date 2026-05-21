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
    var onCardMeasuredSize: (CGSize) -> Void = { _ in }
    var onCardResizeDragChanged: (CGPoint) -> Void = { _ in }
    var onCardResizeDragEnded: () -> Void = { }
    var onCardResizeReset: () -> Void = { }
    var onArchiveUndoRequested: (_ sessionID: String, _ title: String) -> Void = { _, _ in }
    @State private var heldSession: PickyHUDDockHold?
    @State private var pendingManualAutoOpenSessionID: String?
    @State private var pendingRequestedOpenSessionID: String?
    @State private var hoverPreviewSessionID: String?
    @State private var suppressedHoverSessionID: String?
    @State private var isHUDHovered = false
    @State private var isDockHovered = false
    @State private var closeExpansionTask: Task<Void, Never>?
    @State private var keyDownMonitor: Any?
    @State private var modifierFlagsMonitor: Any?
    @State private var isCommandShortcutHintVisible = false
    @State private var composerFocusRequestID = 0
    @State private var noteOpenSessionIDs: Set<String> = []
    @State private var isDockAddSlotExpanded = false
    @State private var cardResizeInteraction = PickyHUDCardResizeInteractionState()
    @State private var sizeReporter = PickyHUDSizeReporter()

    private var dockMetrics: PickyHUDDockMetrics {
        PickyHUDDockMetrics(preset: placement.dockSizePreset)
    }

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(PickyHUDDockLayout.visibleSessionLimit).reversed())
    }

    private var visibleSessionIDs: [String] {
        visibleSessions.map(\.id)
    }

    private var activeSessionID: String? {
        PickyHUDDockLayout.activeSessionID(
            visibleIDs: visibleSessionIDs,
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
            .frame(width: placement.panelWidth, alignment: hudFrameAlignment)
            .frame(maxHeight: .infinity, alignment: hudFrameAlignment)
            // Do not implicitly animate the initial card insertion. The card contains
            // ScrollView/TextEditor subtrees that perform one-frame measurement and
            // bottom-pinning on appear; animating that first layout exposes transient
            // pre-scroll positions as rows/composer floating outside the card.
            .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: handleHUDSizeChange)
            .onPreferenceChange(PickyHUDCardSizePreferenceKey.self, perform: handleCardMeasuredSize)
            .onAppear {
                installCloseShortcutMonitor()
                handleOpenSessionRequest(viewModel.openSessionRequest)
                markFocusedActiveSessionReadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard isCurrentHUDPanel(notification.object) else { return }
                markFocusedActiveSessionReadIfNeeded()
            }
            .onChange(of: activeSessionID) { _, _ in
                resetCardResizeInteraction()
                markFocusedActiveSessionReadIfNeeded()
            }
            .onChange(of: viewModel.unreadSessionIDs) { _, _ in
                markFocusedActiveSessionReadIfNeeded()
            }
            .onChange(of: visibleSessionIDs) { _, _ in
                openPendingManualPickleIfVisible()
                openPendingRequestedSessionIfVisible()
            }
            .onChange(of: viewModel.openSessionRequest) { _, request in
                handleOpenSessionRequest(request)
            }
            .onChange(of: viewModel.screenContextArmCollapseToken) { _, _ in
                // Arming a Pickle (one-shot or sticky) from any entry point —
                // header tap/long-press, dock context menu, ⌘K — collapses
                // the expanded card so the user can immediately drive the
                // armed Pickle from whatever app they're focused on.
                cancelPendingClose()
                heldSession = nil
            }
            .onDisappear {
                closeExpansionTask?.cancel()
                closeExpansionTask = nil
                uninstallCloseShortcutMonitor()
                sizeReporter.cancelPendingReport()
                resetCardResizeInteraction()
            }
    }

    private func handleHUDSizeChange(_ size: CGSize) {
        let activeID = activeSession?.id
        let panelSize = PickyHUDDockLayout.contentSizeReservingAddSlotExpansion(
            measuredSize: size,
            activeSessionID: activeID,
            hasVisibleSessions: !visibleSessions.isEmpty,
            isAddSlotExpanded: isDockAddSlotExpanded,
            metrics: dockMetrics
        )

        sizeReporter.handleMeasuredSize(
            panelSize,
            activeSessionID: activeID,
            extensionUiRequestID: activeSession?.pendingExtensionUiRequest?.id,
            shouldHoldHeight: shouldHoldPanelHeightDuringActiveTurn,
            onSizeChange: onSizeChange
        )
    }

    private func handleCardMeasuredSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onCardMeasuredSize(size)
    }

    private var shouldHoldPanelHeightDuringActiveTurn: Bool {
        switch activeSession?.status {
        case .running, .queued, .waiting_for_input:
            return true
        case .completed, .blocked, .cancelled, .failed, nil:
            return false
        }
    }

    private var hudFrameAlignment: Alignment {
        switch placement.dockSide {
        case .left: .topLeading
        case .right: .topTrailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private var hudContent: some View {
        Group {
            switch placement.dockSide.orientation {
            case .vertical:
                verticalHUDContent
            case .horizontal:
                horizontalHUDContent
            }
        }
        .padding(PickyHUDExpansion.dockShadowInsets)
        .onHover(perform: handleHUDHover)
    }

    private var verticalHUDContent: some View {
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
    }

    private var horizontalHUDContent: some View {
        VStack(alignment: .center, spacing: PickyHUDDockLayout.panelGap) {
            if placement.dockSide == .bottom {
                cardOrPreviewReserve
            }
            dockRail
            if placement.dockSide == .top {
                cardOrPreviewReserve
            }
        }
    }

    /// Either the active conversation card, or — when nothing is open — a
    /// transparent placeholder of preview height. The placeholder mirrors the
    /// vertical mode's behavior of always reserving 540pt of panel width: it
    /// keeps the NSPanel tall enough that the dock-icon hover preview can pop
    /// into the area below/above the dock without being clipped at the panel
    /// boundary.
    @ViewBuilder
    private var cardOrPreviewReserve: some View {
        if activeSession != nil {
            conversationCard
        } else {
            Color.clear
                .frame(
                    width: placement.cardWidth,
                    height: horizontalPreviewReserveHeight
                )
                .accessibilityHidden(true)
        }
    }

    private var horizontalPreviewReserveHeight: CGFloat {
        // Match the Y distance in `PickyHUDDockIconView.miniPreviewOffset`
        // (preview half-height + panelGap) plus another preview half-height
        // for the card's own extent on the far side of its center, plus a
        // small breathing margin so the preview doesn't sit flush against
        // the panel's outer shadow inset.
        let estimatedPreviewHalfHeight = max(20, 25 * dockMetrics.scale)
        return (estimatedPreviewHalfHeight * 2) + PickyHUDDockLayout.panelGap + 8
    }

    @ViewBuilder
    private var conversationCard: some View {
        if let activeSession {
            let noteIsOpen = isNoteOpen(sessionID: activeSession.id)
            VStack(alignment: .leading, spacing: 8) {
                PickyConversationCardView(
                    viewModel: viewModel,
                    session: activeSession,
                    onArchiveSession: archiveSession,
                    maxHeight: conversationCardMaxHeight(isNoteOpen: noteIsOpen),
                    width: placement.cardWidth,
                    fixedHeight: placement.fixedCardHeight,
                    isPreviewMode: false,
                    focusRequestID: composerFocusRequestID,
                    isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                    isNoteOpen: noteIsOpen,
                    onToggleNote: { toggleNote(sessionID: activeSession.id) }
                )
                .background(PickyHUDCardSizeReader())
                .overlay(alignment: resizeHandleAlignment) {
                    PickyHUDCardResizeHandleHost(
                        onHoverChanged: { hovering in cardResizeInteraction.setHovered(hovering) },
                        onDragChanged: { delta in
                            cardResizeInteraction.beginDragging()
                            onCardResizeDragChanged(delta)
                        },
                        onDragEnded: {
                            if cardResizeInteraction.endDragging() {
                                onCardResizeDragEnded()
                            }
                        },
                        onDoubleClick: onCardResizeReset
                    )
                    .frame(width: 24, height: 24)
                    .background(resizeHandleBackground.opacity(isCardResizeHandleVisible ? 1 : 0))
                    .overlay(resizeHandleGlyph.opacity(isCardResizeHandleVisible ? 1 : 0).allowsHitTesting(false))
                    .animation(.easeOut(duration: 0.12), value: isCardResizeHandleVisible)
                    .offset(resizeHandleOffset)
                }
                .accessibilityHint("Drag the corner to resize this Pickle card. Double-click to reset the size.")

                if noteIsOpen {
                    noteAddon(for: activeSession.id)
                }
            }
            .environment(\.pickyHUDDetailWidth, placement.cardWidth)
            .id(activeSession.id)
            .transition(.identity)
            .onDisappear(perform: resetCardResizeInteraction)
        }
    }

    private var isCardResizeHandleVisible: Bool {
        cardResizeInteraction.isVisible
    }

    private func resetCardResizeInteraction() {
        if cardResizeInteraction.reset() {
            onCardResizeDragEnded()
        }
    }

    private var resizeHandleAlignment: Alignment {
        switch placement.dockSide {
        case .right: .bottomLeading
        case .left, .top: .bottomTrailing
        case .bottom: .topTrailing
        }
    }

    private var resizeHandleOffset: CGSize {
        switch placement.dockSide {
        case .right: CGSize(width: -8, height: 8)
        case .left, .top: CGSize(width: 8, height: 8)
        case .bottom: CGSize(width: 8, height: -8)
        }
    }

    private var resizeHandleBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(DS.Colors.accentSubtle.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(DS.Colors.info.opacity(0.45), lineWidth: 0.7)
            )
    }

    private var resizeHandleGlyph: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DS.Colors.info)
            .rotationEffect(resizeHandleGlyphRotation)
    }

    private var resizeHandleGlyphRotation: Angle {
        switch placement.dockSide {
        case .right: .degrees(90)
        case .left, .top: .zero
        case .bottom: .degrees(180)
        }
    }

    private func conversationCardMaxHeight(isNoteOpen: Bool) -> CGFloat {
        guard isNoteOpen else { return placement.availableCardMaxHeight }
        return max(
            320,
            placement.availableCardMaxHeight - PickyHUDDockLayout.noteAddonHeight - 8
        )
    }

    private func noteAddon(for sessionID: String) -> some View {
        PickySessionNoteAddonView(sessionID: sessionID, viewModel: viewModel)
            .transition(.opacity)
    }

    @ViewBuilder
    private var dockRail: some View {
        // The rail is intentionally suppressed while the very first
        // `sessionSnapshot` is still in flight so the dock doesn't briefly
        // flash an empty capsule before the persisted Pickles fade in. The
        // `isLoadingInitialSessionSnapshot` flag is paired with a 4s safety
        // watchdog in `PickySessionListViewModel` so a stalled handshake can
        // never leave the dock permanently invisible.
        if !viewModel.isLoadingInitialSessionSnapshot {
            PickyHUDDockRailView(
                sessions: visibleSessions,
                activeSessionID: activeSession?.id,
                openedSessionID: openedSessionID,
                previewSessionID: hoverPreviewSessionID,
                screenContextTargetSessionID: viewModel.screenContextTargetSessionID,
                dockSide: placement.dockSide,
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                pendingDoneFlashSessionIDs: viewModel.pendingDoneFlashSessionIDs,
                unreadSessionIDs: viewModel.unreadSessionIDs,
                metrics: dockMetrics,
                onHoverSession: previewDockSession,
                onOpenSession: toggleOpenSession,
                onToggleScreenContextTarget: toggleScreenContextTarget,
                onCompactSession: compactSession,
                onArchiveSession: archiveSession,
                onStopSession: stopSession,
                onCreatePickle: chooseFolderForEmptyPickle,
                recentPickleCwds: visibleRecentPickleCwds,
                onCreatePickleInRecentFolder: startEmptyPickle,
                onRemoveRecentPickleFolder: viewModel.removeRecentPickleFolder,
                onDockHoverChanged: handleDockHover,
                onAddSlotExpandedChanged: { isDockAddSlotExpanded = $0 },
                onDoneFlashConsumed: viewModel.markDoneFlashConsumed(sessionID:),
                onDockHandleDragChanged: onDockHandleDragChanged,
                onDockHandleDragEnded: onDockHandleDragEnded,
                onDockHandleDoubleClick: onDockHandleDoubleClick,
                onMoveSession: { sessionID, visibleIndex in
                    viewModel.moveSession(sessionID: sessionID, toVisibleIndex: visibleIndex)
                }
            )
            .frame(
                width: placement.dockSide.orientation == .horizontal
                    ? PickyHUDDockLayout.horizontalDockRailLength(
                        sessionCount: visibleSessions.count,
                        isAddSlotExpanded: isDockAddSlotExpanded,
                        metrics: dockMetrics
                    )
                    : dockMetrics.railWidth,
                height: placement.dockSide.orientation == .horizontal ? dockMetrics.railWidth : nil
            )
            // In horizontal mode the mini hover preview is centered on each dock
            // icon (`miniPreviewOffset` x = 0), so previewing an edge icon makes
            // the card extend up to `previewCardWidth/2 - sessionTileWidth/2`
            // beyond the rail's leading/trailing edge. Without explicit slack on
            // both sides, the NSPanel content view ends at the rail edge and the
            // preview gets clipped — visible in long horizontal docks where the
            // first/last session's hover card lost its right/left portion.
            // Reserve the worst-case overflow symmetrically so the panel widens
            // enough to let the preview render in full.
            .padding(.horizontal, miniPreviewHorizontalReserve)
            .zIndex(10)
            // Keep rail state changes instantaneous; the conversation card handles
            // its own sizing and scroll stabilization when it appears.
            .transaction(value: activeSession?.id) { transaction in
                transaction.animation = nil
            }
        }
    }

    /// Symmetric horizontal slack reserved around the dock rail in horizontal
    /// mode so a hover-preview card popping out of an edge dock icon stays
    /// inside the NSPanel content bounds. Returns 0 in vertical mode because
    /// the preview pops sideways into the conversation card area, which already
    /// has `detailWidth` of room.
    private var miniPreviewHorizontalReserve: CGFloat {
        guard placement.dockSide.orientation == .horizontal else { return 0 }
        return PickyHUDDockLayout.miniPreviewHorizontalReserve(metrics: dockMetrics)
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

    private func isCurrentHUDPanel(_ window: Any?) -> Bool {
        guard let panel = window as? PickyHUDPanel else { return false }
        if let panelIdentifier {
            return panel.identifier == panelIdentifier
        }
        return true
    }

    private func markFocusedActiveSessionReadIfNeeded() {
        guard isCurrentHUDPanel(NSApp.keyWindow), let activeSessionID else { return }
        viewModel.markSessionRead(sessionID: activeSessionID)
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

    private var visibleRecentPickleCwds: [String] {
        PickyRecentPickleFolderPolicy.visibleCwds(viewModel.recentPickleCwds, exists: Self.isExistingDirectory)
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
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
            startEmptyPickle(cwd: url.path)
        }
    }

    private func startEmptyPickle(cwd: String) {
        Task {
            do {
                let sessionID = try await viewModel.createEmptyPickleSession(cwd: cwd)
                await MainActor.run {
                    requestManualAutoOpen(sessionID: sessionID)
                }
            } catch {
                // `createEmptyPickleSession` already surfaces the error through the shared
                // view model; keep the currently-open card untouched when creation fails.
            }
        }
    }

    private func requestManualAutoOpen(sessionID: String) {
        pendingManualAutoOpenSessionID = sessionID
        openPendingManualPickleIfVisible()
    }

    private func openPendingManualPickleIfVisible() {
        guard let next = PickyHUDDockLayout.manualAutoOpenResolution(
            pendingSessionID: pendingManualAutoOpenSessionID,
            visibleIDs: visibleSessionIDs
        ) else { return }
        pendingManualAutoOpenSessionID = nil
        openHeldSession(next)
    }

    private func handleOpenSessionRequest(_ request: PickyHUDOpenSessionRequest?) {
        guard let request else { return }
        pendingRequestedOpenSessionID = request.sessionID
        openPendingRequestedSessionIfVisible()
    }

    private func openPendingRequestedSessionIfVisible() {
        guard let next = PickyHUDDockLayout.requestedOpenResolution(
            pendingSessionID: pendingRequestedOpenSessionID,
            visibleIDs: visibleSessionIDs
        ) else { return }
        pendingRequestedOpenSessionID = nil
        openHeldSession(next)
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
        pendingManualAutoOpenSessionID = nil
        cancelPendingClose()
        let nextHeldSession = PickyHUDDockLayout.heldSessionAfterClick(
            current: heldSession,
            clicked: sessionID
        )
        heldSession = nextHeldSession
        if nextHeldSession == nil {
            if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
            suppressedHoverSessionID = sessionID
            // Notify subscribers (e.g. onboarding) that the card was toggled
            // back closed so they can advance to the next CTA.
            viewModel.markSessionClosed(sessionID: sessionID)
        } else {
            hoverPreviewSessionID = nil
            suppressedHoverSessionID = nil
            // Opening any Pickle clears its unread state across every dock.
            viewModel.markSessionRead(sessionID: sessionID)
        }
    }

    private func toggleScreenContextTarget(_ sessionID: String) {
        cancelPendingClose()
        // Arm path collapses the expanded card via the
        // `screenContextArmCollapseToken` onChange handler above; nothing else
        // to do here. Disarm taps leave the card visible so users can keep
        // reading.
        viewModel.toggleScreenContextTarget(sessionID: sessionID)
    }

    private func compactSession(_ sessionID: String) {
        cancelPendingClose()
        guard let session = viewModel.sessions.first(where: { $0.id == sessionID }), session.canRequestDockCompaction else { return }
        Task {
            switch session.status {
            case .failed, .cancelled:
                try? await viewModel.steer(text: "/compact", sessionID: sessionID)
            case .completed, .blocked:
                try? await viewModel.followUp(text: "/compact", sessionID: sessionID)
            case .queued, .running, .waiting_for_input:
                break
            }
        }
    }

    private func archiveSession(_ sessionID: String) {
        cancelPendingClose()
        let title = (visibleSessions + viewModel.sessions).first(where: { $0.id == sessionID })?.title ?? "Pickle"
        viewModel.archive(sessionID: sessionID)
        noteOpenSessionIDs.remove(sessionID)
        if heldSession?.sessionID == sessionID { heldSession = nil }
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        if suppressedHoverSessionID == sessionID { suppressedHoverSessionID = nil }
        onArchiveUndoRequested(sessionID, title)
    }

    private func stopSession(_ sessionID: String) {
        cancelPendingClose()
        Task { try? await viewModel.abort(sessionID: sessionID) }
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
        pendingManualAutoOpenSessionID = nil
        pendingRequestedOpenSessionID = nil
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
        if isTerminalInputFocused(in: keyWindow),
           PickyHUDKeyboardShortcutPolicy.shouldPassThroughToFocusedTerminal(modifiers: flags) {
            return false
        }
        let visibleIDs = visibleSessions.map(\.id)

        if PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: event.keyCode, modifiers: flags),
           let activeSession,
           !viewModel.isInlineTerminalMode(sessionID: activeSession.id),
           !isTextInputFocused(in: keyWindow) {
            focusActiveComposer()
            return true
        }

        if flags == .command, event.keyCode == Self.wKeyCode, heldSession != nil {
            closeHeldSession()
            return true
        }

        // Esc closes the expanded Pickle card just like Cmd+W, but only when no
        // text input is focused. The composer's own .onKeyPress(.escape) handles
        // autocomplete dismissal and stop-if-possible while the input is focused;
        // intercepting here would steal that behavior.
        if flags.isEmpty,
           event.keyCode == Self.escKeyCode,
           heldSession != nil,
           !isTextInputFocused(in: keyWindow) {
            closeHeldSession()
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession,
           activeSession.hasLatestAgentResponseReport {
            openLatestAgentResponseReport(sessionID: activeSession.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession,
           activeSession.piSessionFilePath != nil {
            viewModel.toggleInlineTerminalMode(sessionID: activeSession.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession,
           activeSession.piSessionFilePath != nil {
            viewModel.openTerminalOverlay(sessionID: activeSession.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession {
            toggleNotifyOnCompletion(session: activeSession)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isSessionNoteShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession {
            toggleNote(sessionID: activeSession.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession {
            viewModel.toggleThinkingBlocks(sessionID: activeSession.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession,
           !isTextInputFocused(in: keyWindow) {
            toggleScreenContextTarget(activeSession.id)
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
        pendingManualAutoOpenSessionID = nil
        pendingRequestedOpenSessionID = nil
        cancelPendingClose()
        heldSession = next
        hoverPreviewSessionID = nil
        suppressedHoverSessionID = nil
        viewModel.markSessionRead(sessionID: next.sessionID)
    }

    private func focusActiveComposer() {
        composerFocusRequestID &+= 1
    }

    private func isNoteOpen(sessionID: String) -> Bool {
        noteOpenSessionIDs.contains(sessionID)
    }

    private func toggleNote(sessionID: String) {
        cancelPendingClose()
        if noteOpenSessionIDs.contains(sessionID) {
            noteOpenSessionIDs.remove(sessionID)
        } else {
            noteOpenSessionIDs.insert(sessionID)
            viewModel.markSessionRead(sessionID: sessionID)
        }
    }

    private func toggleNotifyOnCompletion(session: PickySessionListViewModel.SessionCard) {
        let enabled = !(session.notifyMainOnCompletion == true)
        Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
    }

    private func openLatestAgentResponseReport(sessionID: String) {
        cancelPendingClose()
        Task { try? await viewModel.openLatestAgentResponseReport(sessionID: sessionID) }
    }

    private func isTextInputFocused(in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }

    private func isTerminalInputFocused(in window: NSWindow) -> Bool {
        var currentView = window.firstResponder as? NSView
        while let view = currentView {
            if view is PickySwiftTermView { return true }
            currentView = view.superview
        }
        return false
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
    private static let escKeyCode: UInt16 = 53
}

enum PickyHUDKeyboardShortcutPolicy {
    private static let leftBracketKeyCode: UInt16 = 33
    private static let rightBracketKeyCode: UInt16 = 30
    private static let rKeyCode: UInt16 = 15
    private static let tKeyCode: UInt16 = 17
    private static let eKeyCode: UInt16 = 14
    private static let nKeyCode: UInt16 = 45
    private static let kKeyCode: UInt16 = 40
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    static func isComposerFocusShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && (keyCode == returnKeyCode || keyCode == keypadEnterKeyCode)
    }

    static func shouldPassThroughToFocusedTerminal(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.contains(.command)
    }

    static func isLatestResponseReportShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == rKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "r"
    }

    static func isTerminalOverlayShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == [.command, .shift] else { return false }
        if keyCode == tKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "t"
    }

    static func isInlineTerminalToggleShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == tKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "t"
    }

    static func isThinkingToggleShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .control else { return false }
        if keyCode == tKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "t"
    }

    static func isNotifyOnCompletionShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == nKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "n"
    }

    static func isSessionNoteShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == eKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "e"
    }

    static func isScreenContextTargetShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == kKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "k"
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
    let session: PickySessionListViewModel.SessionCard
    let metrics: PickyHUDDockMetrics
    @State private var gitStatus: PickyGitRepositoryStatus?

    init(session: PickySessionListViewModel.SessionCard, metrics: PickyHUDDockMetrics) {
        self.session = session
        self.metrics = metrics
        _gitStatus = State(initialValue: PickyGitRepositoryStatus.cached(cwd: session.cwd))
    }

    private var scale: CGFloat { metrics.scale }
    private var cornerRadius: CGFloat { max(12, 16 * scale) }
    private var titleFontSize: CGFloat { max(12, 14 * scale) }
    private var secondaryFontSize: CGFloat { max(10, 11 * scale) }
    private var statusDotSide: CGFloat { max(6, 7 * scale) }
    private var horizontalPadding: CGFloat { max(8, 10 * scale) }
    private var verticalPadding: CGFloat { max(7, 9 * scale) }

    var body: some View {
        HStack(spacing: max(6, 8 * scale)) {
            Circle()
                .fill(statusColor)
                .frame(width: statusDotSide, height: statusDotSide)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: max(2, 3 * scale)) {
                HStack(spacing: max(5, 7 * scale)) {
                    Text(session.title)
                        .font(.system(size: titleFontSize, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(statusLabel)
                        .font(.system(size: secondaryFontSize, weight: .medium))
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
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DS.Colors.surface3.opacity(0.62))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
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
            HStack(spacing: max(3, 4 * scale)) {
                Text(gitStatus.repositoryDisplayName)
                    .font(.system(size: secondaryFontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(2)
                Text("·")
                    .font(.system(size: secondaryFontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(gitStatus.branchDisplayName)
                    .font(.system(size: secondaryFontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
            }
        } else if let cwd = session.compactCwdDescription {
            Text(cwd)
                .font(.system(size: secondaryFontSize, weight: .medium, design: .monospaced))
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
    private var lastReportedExtensionUiRequestID: String?
    private var pendingReportTask: Task<Void, Never>?
    private var pendingReportedSize: CGSize?
    private var pendingOnSizeChange: ((CGSize) -> Void)?

    init(coalescingDelayNanoseconds: UInt64 = 16_000_000) {
        self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
    }

    func handleMeasuredSize(
        _ measuredSize: CGSize,
        activeSessionID: String?,
        extensionUiRequestID: String? = nil,
        shouldHoldHeight: Bool,
        onSizeChange: @escaping (CGSize) -> Void
    ) {
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }

        let activeSessionChanged = activeSessionID != lastReportedActiveSessionID
        if activeSessionChanged {
            lastReportedActiveSessionID = activeSessionID
        }
        // A pending extension-UI request closing (e.g., AskUserQuestion answered) collapses
        // the question bubble by hundreds of points in a single layout pass. The status is
        // still `.running` so `shouldHoldHeight` would otherwise pin the panel at the prior
        // tall size, leaving a large empty band above the conversation list. Treat any
        // change to the active question id (in particular non-nil -> nil) as a one-shot
        // release of the hold so the panel can shrink to the new measured content height.
        let extensionUiRequestChanged = extensionUiRequestID != lastReportedExtensionUiRequestID
        if extensionUiRequestChanged {
            lastReportedExtensionUiRequestID = extensionUiRequestID
        }
        let releaseHold = activeSessionChanged || extensionUiRequestChanged

        let targetSize = PickyHUDExpansion.reportedHUDSize(
            measuredSize: measuredSize,
            previousReportedSize: lastReportedHUDSize,
            activeSessionChanged: releaseHold,
            shouldHoldHeight: shouldHoldHeight
        )

        guard releaseHold || !lastReportedHUDSize.isApproximatelyEqual(to: targetSize) else { return }
        let shouldGrowPanelImmediately = lastReportedHUDSize.height > 0
            && targetSize.height > lastReportedHUDSize.height + 1
        lastReportedHUDSize = targetSize

        if releaseHold || shouldGrowPanelImmediately {
            // First hover opens the conversation card while the NSPanel is still at
            // its dock-only collapsed height. If we coalesce this resize for a frame,
            // SwiftUI can draw the newly inserted ScrollView/TextEditor against the
            // stale panel bounds, exposing transient pre-scroll layout outside the
            // card. The same rule applies to in-card expansions (for example, opening
            // a collapsed turn): SwiftUI starts laying out the taller subtree in the
            // current transaction, so the transparent outer panel must grow before the
            // next frame instead of after the coalescing delay. Keep coalescing for
            // shrink/steady churn after the card is visible.
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

private struct PickyHUDCardSizePreferenceKey: PreferenceKey {
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

private struct PickyHUDCardSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PickyHUDCardSizePreferenceKey.self, value: proxy.size)
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
    static let duration: TimeInterval = 1.2
    static let feedbackStartDelay: TimeInterval = 0.2
    static let feedbackStartDelayNanoseconds: UInt64 = 200_000_000
    static let maximumDistance: CGFloat = 10
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73

    static var feedbackAnimationDuration: TimeInterval {
        max(0, duration - feedbackStartDelay)
    }
}

private extension PickySessionListViewModel.SessionCard {
    var canRequestDockCompaction: Bool {
        guard !isCompacting else { return false }
        switch status {
        case .completed, .blocked, .failed, .cancelled:
            return true
        case .queued, .running, .waiting_for_input:
            return false
        }
    }
}

private struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let activeSessionID: String?
    let openedSessionID: String?
    let previewSessionID: String?
    let screenContextTargetSessionID: String?
    let dockSide: PickyHUDDockSide
    let isCommandShortcutHintVisible: Bool
    let pendingDoneFlashSessionIDs: Set<String>
    let unreadSessionIDs: Set<String>
    let metrics: PickyHUDDockMetrics
    let onHoverSession: (String) -> Void
    let onOpenSession: (String) -> Void
    let onToggleScreenContextTarget: (String) -> Void
    let onCompactSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onStopSession: (String) -> Void
    let onCreatePickle: () -> Void
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (String) -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    let onDockHoverChanged: (Bool) -> Void
    let onAddSlotExpandedChanged: (Bool) -> Void
    let onDoneFlashConsumed: (String) -> Void
    let onDockHandleDragChanged: (CGPoint) -> Void
    let onDockHandleDragEnded: () -> Void
    let onDockHandleDoubleClick: () -> Void
    /// Called when the user drags an icon into a new visible slot. Argument
    /// is the visible index in the rail's current orientation (= the index
    /// in `sessions`, which is already in `prefix.reversed()` order).
    let onMoveSession: (_ sessionID: String, _ toVisibleIndex: Int) -> Void

    @State private var isAddSlotExpanded = false
    @State private var isRecentPickleFolderPickerPresented = false
    @State private var isHandleHovered = false
    @State private var isHandleDragging = false
    @State private var draggingSessionID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dragStartVisibleIndex: Int = 0
    @State private var dragCurrentVisibleIndex: Int = 0

    var body: some View {
        Group {
            if dockSide.orientation == .horizontal {
                HStack(spacing: 2) {
                    dockAnchorHandle
                    sessionsAndAddSlot
                }
                // Symmetric leading/trailing in horizontal so the dock doesn't
                // look lopsided. Vertical's larger `bottomPadding` exists to
                // give the `+` button breathing room below the dash; in
                // horizontal the equivalent breathing room comes from the
                // empty panel area to the right of the dock, not from internal
                // padding.
                .padding(.horizontal, metrics.topPadding)
                .padding(.vertical, metrics.horizontalPadding)
                .frame(width: railHeight, height: metrics.railWidth, alignment: .center)
            } else {
                // The handle is the first child INSIDE the dock capsule (after a small top
                // padding) so the dock body itself acts as the hit target. The capsule
                // background is opaque, which sidesteps SwiftUI's transparent-view hit-
                // testing quirks: clicks anywhere in the handle's row hit the NSView
                // backing the handle, not the empty space outside an external pill.
                VStack(spacing: 2) {
                    dockAnchorHandle
                    sessionsAndAddSlot
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, metrics.topPadding)
                .padding(.bottom, metrics.bottomPadding)
                .frame(width: metrics.railWidth, height: railHeight, alignment: .top)
            }
        }
        .background(dockGlassBackground)
        .onHover(perform: onDockHoverChanged)
        .onChange(of: isRecentPickleFolderPickerPresented) { _, isPresented in
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = isPresented
            }
            onAddSlotExpandedChanged(isPresented)
        }
    }

    private var railHeight: CGFloat {
        if dockSide.orientation == .horizontal {
            return PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: sessions.count,
                isAddSlotExpanded: isAddSlotExpanded,
                metrics: metrics
            )
        }
        return PickyHUDDockLayout.dockRailHeight(
            sessionCount: sessions.count,
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        )
    }

    @ViewBuilder
    private var sessionsAndAddSlot: some View {
        if sessions.isEmpty {
            // Empty state still lives inside the capsule so the handle has somewhere
            // to anchor visually. Use the full-size add button (not the collapsible
            // one) since there are no sessions to keep it compact for.
            addAgentSlotButton
        } else {
            if dockSide.orientation == .horizontal {
                HStack(spacing: metrics.sessionSpacing) {
                    sessionIcons
                }
                // No extra leading pad in horizontal — the parent HStack's
                // 2pt spacing is enough separation between the last session
                // and the collapsed `|` slot.
                collapsibleAddAgentSlot
            } else {
                VStack(spacing: metrics.sessionSpacing) {
                    sessionIcons
                }
                collapsibleAddAgentSlot
                    .padding(.top, metrics.addSlotTopPadding)
            }
        }
    }

    /// Distance between successive icon centers along the dock's primary
    /// axis. Drives the threshold at which a drag tips the icon into the
    /// next visible slot.
    private var slotPitchAlongAxis: CGFloat {
        switch dockSide.orientation {
        case .horizontal: return metrics.sessionTileWidth + metrics.sessionSpacing
        case .vertical:   return metrics.sessionTileHeight + metrics.sessionSpacing
        }
    }

    /// Animation applied to each non-dragged icon's slot transition. The
    /// dragged icon must NOT be animated because its visual position is
    /// already driven explicitly by `dragOffset`; spring-interpolating its
    /// slot on top of the offset desyncs the icon from the cursor and causes
    /// the visible lag/jitter. We attach the animation per-child via the
    /// `transaction` modifier so siblings slide while the dragged one snaps.
    private var slotShiftAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.78)
    }

    @ViewBuilder
    private var sessionIcons: some View {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            PickyHUDDockIconView(
                session: session,
                index: index,
                isActive: activeSessionID == session.id,
                isOpened: openedSessionID == session.id,
                isPreviewed: previewSessionID == session.id,
                isScreenContextArmed: screenContextTargetSessionID == session.id,
                dockSide: dockSide,
                shortcutNumber: PickyHUDDockLayout.numberShortcutForSessionIndex(index),
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                isUnread: unreadSessionIDs.contains(session.id),
                metrics: metrics,
                isDragging: draggingSessionID == session.id,
                dragOffset: draggingSessionID == session.id ? dragOffset : .zero,
                onHover: { onHoverSession(session.id) },
                onOpen: { onOpenSession(session.id) },
                onToggleScreenContextTarget: { onToggleScreenContextTarget(session.id) },
                onCompact: { onCompactSession(session.id) },
                onArchive: { onArchiveSession(session.id) },
                onStop: { onStopSession(session.id) },
                onDoneFlashConsumed: { onDoneFlashConsumed(session.id) },
                onReorderBegin: { handleReorderBegin(sessionID: session.id) },
                onReorderChanged: { handleReorderChanged(sessionID: session.id, translation: $0) },
                onReorderEnded: { handleReorderEnded(sessionID: session.id, translation: $0) },
                onReorderCanceled: { handleReorderCanceled() }
            )
            // Other icons spring into their new slot when the order changes,
            // but the dragged icon snaps so its `dragOffset` lands the icon
            // exactly under the cursor instead of trailing the spring. The
            // override is scoped to an active drag — otherwise this modifier
            // would clobber unrelated transactions (e.g. the archive hold's
            // `withAnimation(.linear(duration: 1.0))` that fills the progress
            // ring) and replace them with the slot-shift spring.
            .transaction { transaction in
                guard let draggingID = draggingSessionID else { return }
                if draggingID == session.id {
                    transaction.animation = nil
                } else {
                    transaction.animation = slotShiftAnimation
                }
            }
        }
    }

    // MARK: - Reorder gestures

    /// Cursor delta projected onto the dock's primary axis, in points. SwiftUI
    /// top-down y is already applied at the NSView boundary, so we just pick
    /// the relevant component here. Positive = later visible slot (right in
    /// horizontal, down in vertical).
    private func axisDelta(_ translation: CGSize) -> CGFloat {
        switch dockSide.orientation {
        case .horizontal: return translation.width
        case .vertical:   return translation.height
        }
    }

    private func handleReorderBegin(sessionID: String) {
        guard let visibleIdx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        draggingSessionID = sessionID
        dragStartVisibleIndex = visibleIdx
        dragCurrentVisibleIndex = visibleIdx
        dragOffset = .zero
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func handleReorderChanged(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID, !sessions.isEmpty else { return }
        let pitch = slotPitchAlongAxis
        guard pitch > 0 else { return }
        let axis = axisDelta(translation)
        let steps = Int((axis / pitch).rounded())
        let targetIdx = max(0, min(sessions.count - 1, dragStartVisibleIndex + steps))
        if targetIdx != dragCurrentVisibleIndex {
            onMoveSession(sessionID, targetIdx)
            // No `withAnimation` here: the per-icon `.transaction` modifier on
            // sessionIcons disables animations for the dragged icon (so its
            // dragOffset can land it exactly under the cursor) and applies a
            // spring to the other icons sliding into their new slots.
            dragCurrentVisibleIndex = targetIdx
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // Subtract the slot shift already absorbed by the reorder so the icon
        // stays glued under the cursor: the SwiftUI rail has already moved
        // the icon to its new slot, and `dragOffset` only needs to cover the
        // *remaining* distance between that slot and the cursor.
        let slotShift = CGFloat(dragCurrentVisibleIndex - dragStartVisibleIndex) * pitch
        switch dockSide.orientation {
        case .horizontal:
            dragOffset = CGSize(width: translation.width - slotShift, height: translation.height)
        case .vertical:
            dragOffset = CGSize(width: translation.width, height: translation.height - slotShift)
        }
    }

    private func handleReorderEnded(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            dragOffset = .zero
        }
        draggingSessionID = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func handleReorderCanceled() {
        guard draggingSessionID != nil else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            dragOffset = .zero
        }
        draggingSessionID = nil
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
        .frame(
            maxWidth: dockSide.orientation == .horizontal ? nil : .infinity,
            maxHeight: dockSide.orientation == .horizontal ? .infinity : nil
        )
        .frame(
            width: dockSide.orientation == .horizontal ? metrics.handleAreaHeight : nil,
            height: dockSide.orientation == .horizontal ? nil : metrics.handleAreaHeight
        )
        .overlay {
            // Quiet by default — the pill should hint at draggability without
            // shouting. Hover and drag expand and darken it for a clear cue.
            Capsule(style: .continuous)
                .fill(DS.Colors.textTertiary.opacity(isActive ? 0.7 : 0.22))
                .frame(
                    width: dockSide.orientation == .horizontal
                        ? metrics.handleHeight
                        : (isActive ? metrics.handleActiveWidth : metrics.handleIdleWidth),
                    height: dockSide.orientation == .horizontal
                        ? (isActive ? metrics.handleActiveWidth : metrics.handleIdleWidth)
                        : metrics.handleHeight
                )
                .animation(.easeOut(duration: 0.14), value: isHandleHovered)
                .animation(.easeOut(duration: 0.14), value: isHandleDragging)
                .allowsHitTesting(false)
        }
        .onDisappear {
            isHandleHovered = false
            if isHandleDragging {
                isHandleDragging = false
                onDockHandleDragEnded()
            }
        }
        .accessibilityLabel("HUD dock handle")
        .accessibilityHint("Drag to move the Pickle dock. Crossing the middle of the screen switches the dock edge. Double-click to toggle between vertical and horizontal layouts.")
    }

    /// Frosted-glass panel that hosts the dock icons. Uses .ultraThinMaterial
    /// so the desktop / app underneath actually shows through, then layers a
    /// gradient stroke (bright top, dimmer bottom) for the macOS-style top
    /// gloss, and an ambient shadow so the dock no longer disappears against
    /// light backgrounds. Outer shape is a refined rounded rectangle (radius
    /// scales with the preset) for a more polished panel feel than a full pill.
    private var dockGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape
                    .fill(DS.Colors.surface1.opacity(0.18))
            )
            .overlay(
                shape
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

    private func showRecentPickleFolderPicker() {
        withAnimation(PickyHUDExpansion.animation) {
            isAddSlotExpanded = true
        }
        onAddSlotExpandedChanged(true)
        isRecentPickleFolderPickerPresented = true
    }

    private var addAgentSlotButton: some View {
        Button(action: showRecentPickleFolderPicker) {
            ZStack {
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .strokeBorder(
                        DS.Colors.textTertiary.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                    )
                Image(systemName: "plus")
                    .font(.system(size: metrics.plusFontSize, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: metrics.addSlotButtonSide, height: metrics.addSlotButtonSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .recentPickleFolderPicker(
            isPresented: $isRecentPickleFolderPickerPresented,
            arrowEdge: recentPickleFolderPickerArrowEdge,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
            onChooseFolder: onCreatePickle,
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder
        )
        .accessibilityLabel("Start Pickle")
        .accessibilityHint("Choose a recent working folder or browse for a new one")
    }

    private var collapsibleAddAgentSlot: some View {
        Button(action: showRecentPickleFolderPicker) {
            ZStack {
                ZStack {
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .strokeBorder(
                            DS.Colors.textTertiary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: metrics.plusFontSize, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: metrics.addSlotButtonSide, height: metrics.addSlotButtonSide)
                .opacity(isAddSlotExpanded ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(DS.Colors.textSecondary.opacity(0.78))
                    .frame(
                        width: dockSide.orientation == .horizontal ? metrics.collapsedDashHeight : metrics.collapsedDashWidth,
                        height: dockSide.orientation == .horizontal ? metrics.collapsedDashWidth : metrics.collapsedDashHeight
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 1, y: 0.4)
                    .opacity(isAddSlotExpanded ? 0 : 1)
            }
            .frame(
                width: dockSide.orientation == .horizontal
                    ? PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
                    : metrics.addSlotButtonSide,
                height: dockSide.orientation == .horizontal
                    ? metrics.addSlotButtonSide
                    : PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .recentPickleFolderPicker(
            isPresented: $isRecentPickleFolderPickerPresented,
            arrowEdge: recentPickleFolderPickerArrowEdge,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
            onChooseFolder: onCreatePickle,
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder
        )
        .onHover { hovering in
            let expanded = hovering || isRecentPickleFolderPickerPresented
            onAddSlotExpandedChanged(expanded)
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = expanded
            }
        }
        .accessibilityLabel("Start Pickle")
        .accessibilityHint("Choose a recent working folder or browse for a new one")
    }

    private var recentPickleFolderPickerArrowEdge: Edge {
        switch dockSide {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }
}

struct PickyRecentPickleFolderPolicy {
    static func visibleCwds(_ cwds: [String], exists: (String) -> Bool) -> [String] {
        Array(cwds.filter(exists).prefix(PickySettings.maxVisibleRecentPickleCwds))
    }
}

private extension View {
    func recentPickleFolderPicker(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        recentPickleCwds: [String],
        onCreatePickleInRecentFolder: @escaping (String) -> Void,
        onChooseFolder: @escaping () -> Void,
        onRemoveRecentPickleFolder: @escaping (String) -> Void
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            PickyRecentPickleFolderPickerView(
                isPresented: isPresented,
                recentPickleCwds: recentPickleCwds,
                onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
                onChooseFolder: onChooseFolder,
                onRemoveRecentPickleFolder: onRemoveRecentPickleFolder
            )
        }
    }
}

private struct PickyRecentPickleFolderPickerView: View {
    @Binding var isPresented: Bool
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (String) -> Void
    let onChooseFolder: () -> Void
    let onRemoveRecentPickleFolder: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if recentPickleCwds.isEmpty {
                emptyState
            } else {
                VStack(spacing: 2) {
                    ForEach(recentPickleCwds, id: \.self) { cwd in
                        PickyRecentPickleFolderRow(
                            cwd: cwd,
                            onCreate: {
                                isPresented = false
                                onCreatePickleInRecentFolder(cwd)
                            },
                            onRemove: {
                                onRemoveRecentPickleFolder(cwd)
                            }
                        )
                    }
                }
            }
            Divider()
            Button {
                isPresented = false
                onChooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)
            .accessibilityHint("Open the macOS folder picker")
        }
        .padding(14)
        .frame(width: 286)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recent folders")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Text("Start Pickle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private var emptyState: some View {
        Text("No recent folders yet. Choose a working folder to start your first Pickle.")
            .font(.system(size: 12))
            .foregroundStyle(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}

private struct PickyRecentPickleFolderRow: View {
    let cwd: String
    let onCreate: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCreate) {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Colors.accentText)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(compactPath)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start Pickle in \(displayName)")
            .accessibilityHint(compactPath)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.35)
            .accessibilityLabel("Remove from recent folders")
            .accessibilityHint("This does not delete the folder")
        }
        .background(isHovered ? DS.Colors.surface2 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var displayName: String {
        let last = URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    private var compactPath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardizedPath = NSString(string: cwd).standardizingPath
        if standardizedPath == homePath { return "~" }
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return cwd
    }
}

private struct PickyHUDDockIconView: View {
    let session: PickySessionListViewModel.SessionCard
    let index: Int
    let isActive: Bool
    let isOpened: Bool
    let isPreviewed: Bool
    let isScreenContextArmed: Bool
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
    let onCompact: () -> Void
    let onArchive: () -> Void
    let onStop: () -> Void
    let onDoneFlashConsumed: () -> Void
    var onReorderBegin: () -> Void = {}
    var onReorderChanged: (CGSize) -> Void = { _ in }
    var onReorderEnded: (CGSize) -> Void = { _ in }
    var onReorderCanceled: () -> Void = {}

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
                canCompact: session.canRequestDockCompaction,
                canStop: !session.status.isTerminal,
                onToggleScreenContextTarget: onToggleScreenContextTarget,
                onCompact: onCompact,
                onArchivePressing: handleArchivePressing,
                onArchive: completeArchiveHold,
                onStop: onStop,
                onReorderBegin: onReorderBegin,
                onReorderChanged: onReorderChanged,
                onReorderEnded: onReorderEnded,
                onReorderCanceled: onReorderCanceled
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
            cancelArchiveHoldFeedback()
            didCompleteArchiveHold = false
            if isDragging {
                onReorderCanceled()
            }
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
            .fill(DS.Colors.accent)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(DS.Colors.background, lineWidth: 1.2)
            )
            .shadow(color: DS.Colors.accent.opacity(0.45), radius: 2.5, x: 0, y: 0)
            .accessibilityLabel("Unread")
            .accessibilityHint("This Pickle has updates you haven't seen yet.")
    }

    private func commandShortcutBadge(label: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: "command")
                .font(.system(size: 6.5, weight: .bold))
            Text(label)
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
                    Image("PickyCursorNormal")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(DS.Colors.accentText)
                        .scaledToFit()
                        .frame(width: metrics.sessionLogoSide * 0.96, height: metrics.sessionLogoSide * 0.96)
                        .shadow(color: DS.Colors.accentText.opacity(isSelected ? 0.18 : 0.10), radius: 2.0, x: 0, y: 0.7)
                } else if session.status == .running {
                    TimelineView(.animation) { context in
                        let phase = breathingPhase(at: context.date)
                        ZStack {
                            Circle()
                                .stroke(statusColor.opacity(0.16 + 0.36 * phase), lineWidth: 1.0)
                                .frame(width: metrics.sessionLogoSide, height: metrics.sessionLogoSide)
                                .scaleEffect(1.0 + 0.12 * phase)
                            Group {
                                if isRunningWinkVisible(at: context.date) {
                                    dockPickleAsset(.wink)
                                } else {
                                    normalPickleGlyph()
                                }
                            }
                            .scaleEffect(0.965 + 0.08 * phase)
                        }
                    }
                } else if let asset = dockStatusAsset {
                    dockPickleAsset(asset)
                } else {
                    normalPickleGlyph()
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
        return isHovered ? 1.03 : 1.0
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

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}

// MARK: - Dock icon clicks (AppKit-backed for immediate single-click open)

private struct PickyHUDDockIconClickHost: NSViewRepresentable {
    var onHover: () -> Void
    var onOpen: () -> Void
    var isScreenContextArmed: Bool
    var canCompact: Bool
    var canStop: Bool
    var onToggleScreenContextTarget: () -> Void
    var onCompact: () -> Void
    var onArchivePressing: (Bool) -> Void
    var onArchive: () -> Void
    var onStop: () -> Void
    /// Fired when the cursor leaves the archive hold's stationary tolerance,
    /// signalling "this drag is now a reorder, not a long-press archive".
    /// Argument is the window-space point where the drag started, which the
    /// parent uses purely as a deterministic anchor for haptic alignment.
    var onReorderBegin: () -> Void = {}
    /// Cumulative drag offset (in points) from the original mouse-down point,
    /// in window coordinates: (dx, dy). The parent decides which axis is
    /// relevant based on the dock's orientation.
    var onReorderChanged: (CGSize) -> Void = { _ in }
    /// Drag ended (mouse up) while in reorder mode. Argument matches the
    /// final cumulative offset from mouseDown.
    var onReorderEnded: (CGSize) -> Void = { _ in }
    /// Drag canceled (e.g. due to window losing focus, view disappearing).
    var onReorderCanceled: () -> Void = {}

    final class Coordinator: NSObject {
        var onHover: (() -> Void)?
        var onOpen: (() -> Void)?
        var isScreenContextArmed = false
        var canCompact = false
        var canStop = false
        var onToggleScreenContextTarget: (() -> Void)?
        var onCompact: (() -> Void)?
        var onArchivePressing: ((Bool) -> Void)?
        var onArchive: (() -> Void)?
        var onStop: (() -> Void)?
        var onReorderBegin: (() -> Void)?
        var onReorderChanged: ((CGSize) -> Void)?
        var onReorderEnded: ((CGSize) -> Void)?
        var onReorderCanceled: (() -> Void)?

        func clearCallbacks() {
            onHover = nil
            onOpen = nil
            onToggleScreenContextTarget = nil
            onCompact = nil
            onArchivePressing = nil
            onArchive = nil
            onStop = nil
            onReorderBegin = nil
            onReorderChanged = nil
            onReorderEnded = nil
            onReorderCanceled = nil
        }

        @objc func toggleScreenContextTarget(_ sender: NSMenuItem) {
            onToggleScreenContextTarget?()
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
        coordinator.canCompact = canCompact
        coordinator.canStop = canStop
        coordinator.onToggleScreenContextTarget = onToggleScreenContextTarget
        coordinator.onCompact = onCompact
        coordinator.onArchivePressing = onArchivePressing
        coordinator.onArchive = onArchive
        coordinator.onStop = onStop
        coordinator.onReorderBegin = onReorderBegin
        coordinator.onReorderChanged = onReorderChanged
        coordinator.onReorderEnded = onReorderEnded
        coordinator.onReorderCanceled = onReorderCanceled
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let view = nsView as? PickyHUDDockIconClickNSView {
            view.cancelTransientInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.clearCallbacks()
    }
}

private final class PickyHUDDockIconClickNSView: NSView {
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
    private var isReordering = false

    override var isFlipped: Bool { false }

    deinit {
        cancelTransientInteraction(notifyingCallbacks: false)
    }

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
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        mouseDownScreenPoint = NSEvent.mouseLocation
        didCompleteArchiveHold = false
        isReordering = false
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
        isReordering = false
        coordinator?.onHover?()
        guard let coordinator else { return }

        let menu = NSMenu()
        menu.addItem(menuItem(
            title: coordinator.isScreenContextArmed ? "Stop Sending Context to This Pickle" : "Send Context to This Pickle",
            action: #selector(PickyHUDDockIconClickHost.Coordinator.toggleScreenContextTarget(_:)),
            target: coordinator
        ))
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

    /// Cursor delta since `mouseDownScreenPoint`, in screen coordinates and
    /// then flipped to SwiftUI top-down y. Stable across view position
    /// changes because both anchor and current sample are screen-space.
    private func swiftUIDelta() -> CGSize? {
        guard let anchor = mouseDownScreenPoint else { return nil }
        let current = NSEvent.mouseLocation
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        return CGSize(width: dx, height: -dy)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delta = swiftUIDelta() else { return }
        let distance = (delta.width * delta.width + delta.height * delta.height).squareRoot()
        if isReordering {
            coordinator?.onReorderChanged?(delta)
            return
        }
        // Same threshold as archive cancel — so the moment the user clearly
        // commits to moving the cursor, archive intent gives way to reorder.
        if distance > PickyHUDArchiveHoldPolicy.maximumDistance {
            cancelArchiveHoldFeedback()
            isReordering = true
            coordinator?.onReorderBegin?()
            coordinator?.onReorderChanged?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedArchive = didCompleteArchiveHold
        let wasReordering = isReordering
        let finalOffset = wasReordering ? (swiftUIDelta() ?? .zero) : .zero
        cancelArchiveHoldFeedback()
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        isReordering = false
        if wasReordering {
            coordinator?.onReorderEnded?(finalOffset)
            return
        }
        guard !completedArchive else { return }
        guard event.clickCount < 2 else { return }
        coordinator?.onOpen?()
    }

    private func cancelArchiveHoldFeedback() {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        coordinator?.onArchivePressing?(false)
    }

    func cancelTransientInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        let wasReordering = isReordering
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        isReordering = false
        guard shouldNotify else { return }
        coordinator?.onArchivePressing?(false)
        if wasReordering {
            coordinator?.onReorderCanceled?()
        }
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

struct PickyHUDCardResizeInteractionState: Equatable {
    private(set) var isHovered = false
    private(set) var isDragging = false

    var isVisible: Bool { isHovered || isDragging }

    mutating func setHovered(_ hovering: Bool) {
        isHovered = hovering
    }

    mutating func beginDragging() {
        isDragging = true
    }

    @discardableResult
    mutating func endDragging() -> Bool {
        let wasDragging = isDragging
        isDragging = false
        return wasDragging
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasDragging = isDragging
        isHovered = false
        isDragging = false
        return wasDragging
    }
}

private struct PickyHUDCardResizeHandleHost: NSViewRepresentable {
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

private final class PickyHUDCardResizeHandleNSView: NSView {
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

private final class PickyHUDDockAnchorHandleNSView: NSView {
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
