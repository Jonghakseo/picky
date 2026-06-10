//
//  PickyHUDView.swift
//  Picky
//
//  SwiftUI composition for the long-running session HUD.
//

import AppKit
import Combine
import SwiftUI

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var panelIdentifier: NSUserInterfaceItemIdentifier?
    /// Display this panel renders on. Used to route notification-driven open
    /// requests to only the screen the user clicked the banner on.
    var displayID: CGDirectDisplayID?
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
    var onOpenFullscreenSession: (String?) -> Void = { _ in }
    /// Persist this display's dock group collapse overrides. Wired by the
    /// overlay manager to store the map keyed by display ID so collapse state
    /// is independent per monitor and survives relaunch.
    var onDockGroupCollapseChanged: (_ overrides: [String: Bool]) -> Void = { _ in }
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
    @State private var extendedTerminalOpenSessionIDs: Set<String> = []
    @State private var isDockAddSlotExpanded = false
    @State private var cardResizeInteraction = PickyHUDCardResizeInteractionState()
    @State private var sizeReporter = PickyHUDSizeReporter()

    private var dockMetrics: PickyHUDDockMetrics {
        PickyHUDDockMetrics(preset: placement.dockSizePreset)
    }

    /// Universe of session ids the dock is allowed to render this frame.
    /// Capped at `visibleSessionLimit` against the *newest* sessions so the
    /// rail never grows beyond the screen-edge budget. Order matches the
    /// legacy `prefix.reversed()` convention (oldest-of-window first,
    /// newest last) so the projector's fallback branch keeps newcomers at
    /// the bottom of the dock next to the `+` slot.
    private var visibleSessionUniverse: [String] {
        Array(viewModel.sessions.prefix(PickyHUDDockLayout.visibleSessionLimit).reversed().map(\.id))
    }

    /// Projection of the persisted dock layout against the current visible
    /// universe. Drives both render order (groups + ungrouped interleaved)
    /// and shortcut/drag hit-testing.
    private var dockProjection: PickyDockProjection {
        PickyDockProjector.project(
            layout: viewModel.dockLayout,
            visibleSessionIDs: visibleSessionUniverse,
            collapsedOverrides: placement.collapsedGroupOverrides
        )
    }

    /// Toggle a group's collapse state for this panel's display only. Updates
    /// the per-panel placement override (so the projection recomputes for
    /// this monitor) and hands the new override map to the overlay manager
    /// for per-display persistence.
    private func toggleDockGroupCollapsedForThisDisplay(_ groupID: String) {
        let result = PickyHUDDockGroupCollapsePolicy.toggleResult(
            groupID: groupID,
            groups: viewModel.dockLayout.groups,
            overrides: placement.collapsedGroupOverrides,
            openedSessionID: openedSessionID
        )
        placement.collapsedGroupOverrides = result.overrides
        onDockGroupCollapseChanged(result.overrides)

        // Collapsing hides the group's member icons behind the folder badge.
        // If the open HUD card belongs to a member of this group, close it so
        // it isn't left floating with no icon to anchor to.
        if let sessionIDToClose = result.sessionIDToClose {
            closeOpenedSession(sessionIDToClose)
        }
    }

    /// Close the expanded HUD card for `sessionID`, mirroring the manual
    /// close path (clear held/hover state, mark the session closed).
    private func closeOpenedSession(_ sessionID: String) {
        cancelPendingClose()
        pendingManualAutoOpenSessionID = nil
        if heldSession?.sessionID == sessionID { heldSession = nil }
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        suppressedHoverSessionID = sessionID
        viewModel.markSessionClosed(sessionID: sessionID)
    }

    /// Session cards in their final top-to-bottom dock order. Replaces the
    /// pre-grouping `sessions.prefix.reversed()` helper. When the layout is
    /// empty (fresh install or no manual reorders), the projector falls back
    /// to appending sessions in newest-last order so the visual ordering
    /// matches the legacy behavior.
    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        let cardByID = Dictionary(
            viewModel.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        return dockProjection.slots.compactMap { cardByID[$0.sessionID] }
    }

    /// Session ids in dock render order. Used for ⌘N shortcut resolution
    /// (each slot's `visibleIndex` matches its position here) and for
    /// `heldSession` / fullscreen target lookups.
    private var visibleSessionIDs: [String] {
        dockProjection.slots.map(\.sessionID)
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

    private var fullscreenTargetSessionID: String? {
        PickyHUDDockLayout.fullscreenTargetSessionID(
            visibleIDs: visibleSessionIDs,
            held: heldSession,
            hoverPreviewID: hoverPreviewSessionID
        )
    }

    private var activeSession: PickySessionListViewModel.SessionCard? {
        guard let activeSessionID else { return nil }
        return visibleSessions.first { $0.id == activeSessionID }
    }

    var body: some View {
        let _ = PickyPerf.event("hud_root_body")
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
        PickyPerf.event("hud_size_preference_changed")
        let activeID = activeSession?.id
        let panelSize = PickyPerf.interval("hud_size_compute_panel_size") {
            PickyHUDDockLayout.contentSizeReservingAddSlotExpansion(
                measuredSize: size,
                activeSessionID: activeID,
                hasVisibleSessions: !visibleSessions.isEmpty,
                isAddSlotExpanded: isDockAddSlotExpanded,
                metrics: dockMetrics
            )
        }

        PickyPerf.interval("hud_size_reporter_handle") {
            sizeReporter.handleMeasuredSize(
                panelSize,
                activeSessionID: activeID,
                extensionUiRequestID: activeSession?.pendingExtensionUiRequest?.id,
                shouldHoldHeight: shouldHoldPanelHeightDuringActiveTurn,
                onSizeChange: onSizeChange
            )
        }
    }

    private func handleCardMeasuredSize(_ size: CGSize) {
        PickyPerf.event("hud_card_size_preference_changed")
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
            let extendedTerminalIsOpen = isExtendedTerminalOpen(sessionID: activeSession.id)
                && !viewModel.isInlineTerminalMode(sessionID: activeSession.id)
            VStack(alignment: .leading, spacing: 8) {
                PickyConversationCardView(
                    viewModel: viewModel,
                    session: activeSession,
                    onArchiveSession: archiveSession,
                    maxHeight: conversationCardMaxHeight(isExtendedTerminalOpen: extendedTerminalIsOpen),
                    width: placement.cardWidth,
                    fixedHeight: placement.fixedCardHeight,
                    isPreviewMode: false,
                    focusRequestID: composerFocusRequestID,
                    isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                    isExtendedTerminalOpen: extendedTerminalIsOpen,
                    onToggleExtendedTerminal: { toggleExtendedTerminal(sessionID: activeSession.id) }
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

                if extendedTerminalIsOpen {
                    extendedTerminal(for: activeSession)
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
            .pickyFont(size: 10.5, weight: .semibold)
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

    private func conversationCardMaxHeight(isExtendedTerminalOpen: Bool) -> CGFloat {
        guard isExtendedTerminalOpen else { return placement.availableCardMaxHeight }
        return max(
            320,
            placement.availableCardMaxHeight - PickyHUDDockLayout.extendedTerminalHeight - 8
        )
    }

    private func extendedTerminal(for session: PickySessionListViewModel.SessionCard) -> some View {
        PickySessionExtendedTerminalView(session: session, viewModel: viewModel)
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
                allSessions: viewModel.sessions,
                baseProjection: dockProjection,
                layout: viewModel.dockLayout,
                collapsedGroupOverrides: placement.collapsedGroupOverrides,
                activeSessionID: activeSession?.id,
                openedSessionID: openedSessionID,
                previewSessionID: hoverPreviewSessionID,
                fullscreenTargetSessionID: fullscreenTargetSessionID,
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
                pinnedPickleCwds: visiblePinnedPickleCwds,
                recentPickleCwds: visibleRecentPickleCwds,
                onCreatePickleInRecentFolder: startEmptyPickle,
                onRemoveRecentPickleFolder: viewModel.removeRecentPickleFolder,
                onPinPickleFolder: viewModel.pinPickleFolder,
                onUnpinPickleFolder: viewModel.unpinPickleFolder,
                onCreateDockGroup: { name, memberIDs in
                    viewModel.createDockGroup(name: name, withMemberIDs: memberIDs)
                },
                onRenameDockGroup: { id, name in viewModel.renameDockGroup(id: id, to: name) },
                onSetDockGroupColor: { id, color in viewModel.setDockGroupColor(id: id, color: color) },
                onToggleDockGroupCollapsed: { id in toggleDockGroupCollapsedForThisDisplay(id) },
                onRemoveDockGroup: { id, keepMembers in viewModel.removeDockGroup(id: id, keepMembers: keepMembers) },
                onMoveSessionInDock: { sessionID, container in viewModel.moveSessionInDock(sessionID: sessionID, to: container) },
                onMoveDockGroup: { id, target in viewModel.moveDockGroup(id: id, toTopLevelIndex: target) },
                onDockHoverChanged: handleDockHover,
                onAddSlotExpandedChanged: { isDockAddSlotExpanded = $0 },
                onDoneFlashConsumed: viewModel.markDoneFlashConsumed(sessionID:),
                onDockHandleDragChanged: onDockHandleDragChanged,
                onDockHandleDragEnded: onDockHandleDragEnded,
                onDockHandleDoubleClick: onDockHandleDoubleClick,
                onOpenFullscreenSession: onOpenFullscreenSession
            )
            .frame(
                width: placement.dockSide.orientation == .horizontal
                    ? PickyHUDDockLayout.horizontalDockRailLength(
                        sessionCount: visibleSessions.count,
                        isAddSlotExpanded: isDockAddSlotExpanded,
                        metrics: dockMetrics,
                        includesFullscreenControl: PickyFullscreenFeatureFlags.isEnabled
                    )
                    : dockMetrics.railWidth,
                height: placement.dockSide.orientation == .horizontal
                    ? PickyHUDDockLayout.horizontalDockRailCrossSize(
                        hasGroupHeaders: dockProjection.items.contains { item in
                            switch item {
                            case .groupHeader, .collapsedGroup: return true
                            default: return false
                            }
                        },
                        metrics: dockMetrics
                    )
                    : nil
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

    private var visiblePinnedPickleCwds: [String] {
        PickyRecentPickleFolderPolicy.visiblePinnedCwds(viewModel.pinnedPickleCwds, exists: Self.isExistingDirectory)
    }

    private var visibleRecentPickleCwds: [String] {
        PickyRecentPickleFolderPolicy.visibleRecentCwds(
            viewModel.recentPickleCwds,
            pinned: viewModel.pinnedPickleCwds,
            exists: Self.isExistingDirectory
        )
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
        let response = Self.runWithHUDPanelsBelowSystemModal {
            panel.runModal()
        }
        if response == .OK, let url = panel.url {
            startEmptyPickle(cwd: url.path)
        }
    }

    private static func runWithHUDPanelsBelowSystemModal<T>(_ operation: () throws -> T) rethrows -> T {
        let hudPanels = NSApp.windows.compactMap { $0 as? PickyHUDPanel }
        let originalLevels = hudPanels.map { panel in
            (panel: panel, level: panel.level)
        }
        hudPanels.forEach { panel in
            panel.level = .floating
        }
        defer {
            originalLevels.forEach { entry in
                entry.panel.level = entry.level
            }
        }
        return try operation()
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
        // Honor the requested target display so a notification only opens the
        // card on the screen the user clicked. `nil` target opens everywhere.
        if let target = request.targetDisplayID, target != displayID { return }
        pendingRequestedOpenSessionID = request.sessionID
        // Opening a member of a collapsed group must reveal it first, otherwise
        // the session never enters this display's visible slot set and the
        // resolution below can't open it.
        expandGroupForOpeningIfNeeded(request.sessionID)
        openPendingRequestedSessionIfVisible()
    }

    /// If `sessionID` belongs to a collapsed group on this display, expand the
    /// group so the session becomes visible and openable. Persists the change
    /// like a manual expand so it stays consistent per monitor.
    private func expandGroupForOpeningIfNeeded(_ sessionID: String) {
        let result = PickyHUDDockGroupCollapsePolicy.expandResultForOpening(
            sessionID: sessionID,
            groups: viewModel.dockLayout.groups,
            overrides: placement.collapsedGroupOverrides
        )
        guard result.didExpand else { return }
        placement.collapsedGroupOverrides = result.overrides
        onDockGroupCollapseChanged(result.overrides)
    }

    /// Effective collapse state for `groupID` on this panel's display: the
    /// per-display override if present, otherwise the layout default.
    private func isGroupCollapsedOnThisDisplay(_ groupID: String) -> Bool {
        PickyHUDDockGroupCollapsePolicy.isCollapsed(
            groupID: groupID,
            groups: viewModel.dockLayout.groups,
            overrides: placement.collapsedGroupOverrides
        )
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
        extendedTerminalOpenSessionIDs.remove(sessionID)
        if heldSession?.sessionID == sessionID { heldSession = nil }
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        if suppressedHoverSessionID == sessionID { suppressedHoverSessionID = nil }
        onArchiveUndoRequested(sessionID, title)
    }

    private func stopSession(_ sessionID: String) {
        cancelPendingClose()
        Task { try? await viewModel.abortRestoringQueuedInputs(sessionID: sessionID) }
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
        if let focusedTerminal = focusedTerminalView(in: keyWindow) {
            // SwiftTerm drops/misroutes ⌘← ⌘→ ⌘⌫, so translate them to readline
            // control bytes before they reach the (broken) AppKit key-binding path.
            if focusedTerminal.handleMacLineEditingShortcut(event) {
                return true
            }
            if !PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: flags
            ) {
                return false
            }
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

        if PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeSession,
           !viewModel.isInlineTerminalMode(sessionID: activeSession.id) {
            toggleExtendedTerminal(sessionID: activeSession.id)
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

        if flags == .command, let number = Self.numberShortcutValue(for: event) {
            let slots = dockProjection.slots
            guard number >= 1, number <= slots.count else { return false }
            // A collapsed group occupies one ⌘N slot. Pressing it expands the
            // group instead of opening its top member; expanding reassigns a
            // number to every member, so a second ⌘N reaches the individual
            // Pickle. This makes every Pickle ⌘N-reachable in two presses.
            if case let .group(groupID, _) = slots[number - 1].container,
               isGroupCollapsedOnThisDisplay(groupID) {
                toggleDockGroupCollapsedForThisDisplay(groupID)
                return true
            }
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

    private func isExtendedTerminalOpen(sessionID: String) -> Bool {
        extendedTerminalOpenSessionIDs.contains(sessionID)
    }

    private func toggleExtendedTerminal(sessionID: String) {
        cancelPendingClose()
        if extendedTerminalOpenSessionIDs.contains(sessionID) {
            extendedTerminalOpenSessionIDs.remove(sessionID)
        } else {
            extendedTerminalOpenSessionIDs.insert(sessionID)
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
        focusedTerminalView(in: window) != nil
    }

    private func focusedTerminalView(in window: NSWindow) -> PickySwiftTermView? {
        var currentView = window.firstResponder as? NSView
        while let view = currentView {
            if let terminal = view as? PickySwiftTermView { return terminal }
            currentView = view.superview
        }
        return nil
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
