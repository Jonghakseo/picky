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
        let group = viewModel.dockLayout.groups.first(where: { $0.id == groupID })
        let layoutDefault = group?.isCollapsed ?? false
        let current = placement.collapsedGroupOverrides[groupID] ?? layoutDefault
        let willCollapse = !current
        placement.collapsedGroupOverrides[groupID] = willCollapse
        onDockGroupCollapseChanged(placement.collapsedGroupOverrides)

        // Collapsing hides the group's member icons behind the folder badge.
        // If the open HUD card belongs to a member of this group, close it so
        // it isn't left floating with no icon to anchor to.
        if willCollapse,
           let openedID = openedSessionID,
           group?.memberSessionIDs.contains(openedID) == true {
            closeOpenedSession(openedID)
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
                recentPickleCwds: visibleRecentPickleCwds,
                onCreatePickleInRecentFolder: startEmptyPickle,
                onRemoveRecentPickleFolder: viewModel.removeRecentPickleFolder,
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
        guard let group = viewModel.dockLayout.groups.first(where: {
            $0.memberSessionIDs.contains(sessionID)
        }) else { return }
        let isCollapsed = placement.collapsedGroupOverrides[group.id] ?? group.isCollapsed
        guard isCollapsed else { return }
        placement.collapsedGroupOverrides[group.id] = false
        onDockGroupCollapseChanged(placement.collapsedGroupOverrides)
    }

    /// Effective collapse state for `groupID` on this panel's display: the
    /// per-display override if present, otherwise the layout default.
    private func isGroupCollapsedOnThisDisplay(_ groupID: String) -> Bool {
        let group = viewModel.dockLayout.groups.first { $0.id == groupID }
        return placement.collapsedGroupOverrides[groupID] ?? (group?.isCollapsed ?? false)
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

enum PickyHUDKeyboardShortcutPolicy {
    private static let leftBracketKeyCode: UInt16 = 33
    private static let rightBracketKeyCode: UInt16 = 30
    private static let rKeyCode: UInt16 = 15
    private static let tKeyCode: UInt16 = 17
    private static let eKeyCode: UInt16 = 14
    private static let nKeyCode: UInt16 = 45
    private static let kKeyCode: UInt16 = 40
    private static let wKeyCode: UInt16 = 13
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    static func isComposerFocusShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && (keyCode == returnKeyCode || keyCode == keypadEnterKeyCode)
    }

    /// While a Pi TUI terminal is focused, the HUD forwards virtually every key to
    /// the terminal so cmd-based TUI shortcuts (⌘C, ⌘V, ⌘arrows, etc.) reach Pi.
    /// Only ⌘T (toggle back to chat) and ⌘W (close the held card) stay owned by the
    /// HUD because they have no useful meaning inside the embedded terminal here.
    static func shouldInterceptWhileTerminalFocused(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if isInlineTerminalToggleShortcut(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            return true
        }
        if keyCode == wKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "w"
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

    static func isExtendedTerminalShortcut(
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

/// Owns an in-flight Pickle reorder drag at the dock-rail level. The per-icon
/// click host only detects the reorder threshold and hands off here; from then
/// on an app-level `NSEvent` monitor drives the drag to completion. This is
/// essential because the live drop preview reparents the dragged icon across
/// group boundaries (top-level <-> group member), which tears down and
/// recreates its per-icon NSView. A rail-level monitor is immune to that, so
/// the drag survives crossing into/out of groups and only commits on release.
final class PickyDockReorderDragController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dragging(sessionID: String, translation: CGSize)
        case ended(sessionID: String, translation: CGSize)
    }

    @Published private(set) var phase: Phase = .idle

    private var monitor: Any?
    private var anchorScreenPoint: NSPoint = .zero
    private var sessionID: String?

    /// Begin tracking a reorder for `sessionID`. `anchorScreenPoint` is the
    /// mouse-down location in screen space so deltas stay continuous with the
    /// threshold the icon already crossed.
    func begin(sessionID: String, anchorScreenPoint: NSPoint) {
        if self.sessionID != nil { cancelMonitor() }
        self.sessionID = sessionID
        self.anchorScreenPoint = anchorScreenPoint
        phase = .dragging(sessionID: sessionID, translation: currentTranslation())
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let sessionID = self.sessionID else { return event }
            let translation = self.currentTranslation()
            switch event.type {
            case .leftMouseUp:
                self.phase = .ended(sessionID: sessionID, translation: translation)
                self.cancelMonitor()
                self.sessionID = nil
                return nil
            default:
                self.phase = .dragging(sessionID: sessionID, translation: translation)
                return nil
            }
        }
    }

    /// Acknowledge that the SwiftUI side consumed the terminal phase and return
    /// to idle so the next drag starts clean.
    func reset() {
        phase = .idle
    }

    /// Screen-space delta from the mouse-down anchor, flipped to SwiftUI
    /// top-down y. Screen-space keeps it stable even as the icon's NSView is
    /// recreated mid-drag.
    private func currentTranslation() -> CGSize {
        let current = NSEvent.mouseLocation
        return CGSize(width: current.x - anchorScreenPoint.x, height: -(current.y - anchorScreenPoint.y))
    }

    private func cancelMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { cancelMonitor() }
}

private struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    /// Every live session card, including those hidden inside collapsed
    /// groups. `sessions` only carries the dock-visible slots, so the
    /// collapsed-group folder grid resolves its members from here.
    let allSessions: [PickySessionListViewModel.SessionCard]
    /// Projection of the *persisted* layout. Read through the `projection`
    /// computed property below, which overlays the in-flight drag preview
    /// so callers (render + hit-test) transparently see the prospective
    /// drop while a Pickle is being dragged.
    let baseProjection: PickyDockProjection
    /// Persisted dock layout. The rail uses it to translate visible
    /// top-level entry indices back to `entries` indices when committing
    /// group-header drag reorders.
    let layout: PickyDockLayout
    /// Per-display group collapse overrides. The drag preview projection must
    /// apply these too, or expanded-on-this-display groups would render with
    /// their model (default) collapse state mid-drag and appear to collapse.
    let collapsedGroupOverrides: [String: Bool]
    let activeSessionID: String?
    let openedSessionID: String?
    let previewSessionID: String?
    let fullscreenTargetSessionID: String?
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
    /// Create a new group with a name and (optionally) an initial set of
    /// member sessions. Returns the new group's id so callers can chain
    /// follow-up actions (e.g. focus the new group), though the dock
    /// rail itself ignores the return value.
    let onCreateDockGroup: (_ name: String, _ memberIDs: [String]) -> String
    let onRenameDockGroup: (_ id: String, _ name: String) -> Void
    let onSetDockGroupColor: (_ id: String, _ color: PickyDockGroupColor) -> Void
    let onToggleDockGroupCollapsed: (_ id: String) -> Void
    let onRemoveDockGroup: (_ id: String, _ keepMembers: Bool) -> Void
    /// Persist a session move into a specific dock container/position.
    let onMoveSessionInDock: (_ sessionID: String, _ destination: PickyDockContainer) -> Void
    /// Reorder a group as a whole within the top-level layout.
    let onMoveDockGroup: (_ groupID: String, _ toTopLevelIndex: Int) -> Void
    let onDockHoverChanged: (Bool) -> Void
    let onAddSlotExpandedChanged: (Bool) -> Void
    let onDoneFlashConsumed: (String) -> Void
    let onDockHandleDragChanged: (CGPoint) -> Void
    let onDockHandleDragEnded: () -> Void
    let onDockHandleDoubleClick: () -> Void
    let onOpenFullscreenSession: (String?) -> Void

    @State private var isAddSlotExpanded = false
    @State private var isRecentPickleFolderPickerPresented = false
    @State private var isAddSlotMenuPresented = false
    @State private var isHandleHovered = false
    @State private var isHandleDragging = false
    @State private var draggingSessionID: String?
    /// Raw cursor translation (in points) since the drag began. Positions the
    /// floating dragged icon overlay; the in-flow slot is rendered as an
    /// invisible placeholder so the real icon never reparents (no flicker).
    @State private var dragTranslation: CGSize = .zero
    /// Frozen geometry the drop decision is computed against, captured once at
    /// drag start from the persisted (pre-preview) layout. The drop target is
    /// hit-tested ONLY against this snapshot — never against the live,
    /// self-reflowing preview centers — which breaks the feedback loop where
    /// inserting the placeholder shifted measured centers and flipped the
    /// decision back and forth (the group-boundary oscillation/flicker).
    @State private var dragReferenceSlots: [PickyDockSlot] = []
    @State private var dragReferenceCenters: [String: CGFloat] = [:]
    /// Destination the dragged icon would land in if released *right now*.
    /// Drives the live preview projection so siblings animate to make room
    /// at the landing spot, but the actual `onMoveSessionInDock` commit is
    /// deferred to release — the Pickle's group assignment only changes once
    /// the user lets go, never while the cursor merely crosses a boundary.
    @State private var pendingDropContainer: PickyDockContainer?
    /// Rail-level reorder drag tracker. Survives the dragged icon's NSView
    /// being recreated when the preview reparents it across a group boundary.
    @StateObject private var reorderController = PickyDockReorderDragController()
    /// Session whose reorder drag is currently being driven by
    /// `reorderController`, so the phase handler knows when to fire `begin`.
    @State private var activeReorderSessionID: String?
    /// Primary-axis center the dragged icon occupied at pickup time, in the
    /// dock rail's named coordinate space. Combined with the gesture's
    /// `translation` it gives the current cursor axis position without
    /// needing per-frame global coordinate math.
    @State private var dragStartCenter: CGFloat = 0
    /// Group id whose inline rename input should grab keyboard focus on next
    /// appearance. Set right after `onCreateDockGroup()` so the user can type
    /// a name immediately; cleared on commit/cancel.
    @State private var pendingRenameGroupID: String?
    /// Per-session primary-axis centers measured via `GeometryReader` in the
    /// `PickyHUDDockRailCoordinateSpace`. Updated on every layout pass via
    /// `PickyDockSlotCenterPreferenceKey`. Drives precise drop hit-testing
    /// for icon drags so reorders survive non-uniform group-header chrome.
    @State private var slotCenters: [String: CGFloat] = [:]
    /// Per-top-entry primary-axis centers (one per ungrouped session and
    /// one per group container). Drives the group-header drag's drop
    /// hit-test against other top-level entries.
    @State private var topEntryCenters: [String: CGFloat] = [:]
    /// Currently-dragged group id (header drag). Mutually exclusive with
    /// `draggingSessionID`.
    @State private var draggingGroupID: String?
    @State private var groupDragOffset: CGSize = .zero
    @State private var groupDragStartCenter: CGFloat = 0
    @State private var groupDragStartLayoutIndex: Int = 0
    @State private var groupDragCurrentLayoutIndex: Int = 0

    /// macOS Dock-style pull-out. While dragging an icon or group clearly
    /// away from the dock on the cross axis, we arm a destructive release:
    /// a Pickle archives, a group is removed. Sessions require a short dwell
    /// outside (so a quick wobble never archives); groups arm immediately.
    @State private var sessionPullOutArmed = false
    @State private var groupPullOutArmed = false
    /// Pending dwell timer that arms `sessionPullOutArmed`. Cancelled the
    /// moment the cursor returns inside the pull-out threshold or the drag
    /// ends, so a stale timer can never arm after the fact.
    @State private var sessionPullOutDwellWork: DispatchWorkItem?

    /// Live render/hit-test projection. While a Pickle is being dragged, this
    /// reflects the *prospective* drop (`pendingDropContainer`) so siblings
    /// animate to make room at the landing spot — without persisting the
    /// move. The actual commit happens on release. When not dragging (or the
    /// prospective drop equals the current home) it is the persisted
    /// projection unchanged.
    private var projection: PickyDockProjection {
        guard let draggingSessionID,
              let pendingDropContainer,
              layout.container(forSessionID: draggingSessionID) != pendingDropContainer else {
            return baseProjection
        }
        var preview = layout
        preview.move(session: draggingSessionID, to: pendingDropContainer)
        return PickyDockProjector.project(
            layout: preview,
            visibleSessionIDs: baseProjection.slots.map(\.sessionID),
            collapsedOverrides: collapsedGroupOverrides
        )
    }

    var body: some View {
        Group {
            if dockSide.orientation == .horizontal {
                HStack(spacing: 2) {
                    dockAnchorHandle
                    if PickyFullscreenFeatureFlags.isEnabled {
                        fullscreenButton
                    }
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
                .frame(width: railHeight, height: horizontalRailCrossSize, alignment: .center)
            } else {
                // The handle is the first child INSIDE the dock capsule (after a small top
                // padding) so the dock body itself acts as the hit target. The capsule
                // background is opaque, which sidesteps SwiftUI's transparent-view hit-
                // testing quirks: clicks anywhere in the handle's row hit the NSView
                // backing the handle, not the empty space outside an external pill.
                VStack(spacing: 2) {
                    dockAnchorHandle
                    if PickyFullscreenFeatureFlags.isEnabled {
                        fullscreenButton
                    }
                    sessionsAndAddSlot
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, metrics.topPadding)
                .padding(.bottom, metrics.bottomPadding)
                .frame(width: metrics.railWidth, height: railHeight, alignment: .top)
            }
        }
        .background(dockGlassBackground)
        .coordinateSpace(name: PickyHUDDockRailCoordinateSpace)
        .overlay { draggedFloatingIconOverlay }
        .onPreferenceChange(PickyDockSlotCenterPreferenceKey.self) { centers in
            slotCenters = centers
        }
        .onPreferenceChange(PickyDockTopEntryCenterPreferenceKey.self) { centers in
            topEntryCenters = centers
        }
        .onHover(perform: onDockHoverChanged)
        .onChange(of: isRecentPickleFolderPickerPresented) { _, isPresented in
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = isPresented
            }
            onAddSlotExpandedChanged(isPresented)
        }
        // Drive the reorder drag from the rail-level controller. Running the
        // handlers here (rather than from the per-icon NSView) means they keep
        // firing with fresh layout/slot state even after the dragged icon's
        // view is recreated by a cross-group preview reparent.
        .onChange(of: reorderController.phase) { _, phase in
            handleReorderPhase(phase)
        }
    }

    private func handleReorderPhase(_ phase: PickyDockReorderDragController.Phase) {
        switch phase {
        case .idle:
            break
        case .dragging(let sessionID, let translation):
            if activeReorderSessionID != sessionID {
                activeReorderSessionID = sessionID
                handleReorderBegin(sessionID: sessionID)
            }
            handleReorderChanged(sessionID: sessionID, translation: translation)
        case .ended(let sessionID, let translation):
            if activeReorderSessionID == sessionID {
                handleReorderEnded(sessionID: sessionID, translation: translation)
            }
            activeReorderSessionID = nil
            reorderController.reset()
        }
    }

    /// Number of group header chips rendered in this projection. Every group
    /// renders one header chip regardless of collapse state (an expanded group
    /// emits a `.groupHeader` item; a collapsed group emits `.collapsedGroup`
    /// but still renders the same chip above its badge). The rail height must
    /// account for ALL of them or the bottom `+` slot overflows the capsule
    /// when groups are collapsed.
    private var groupHeaderCount: Int {
        projection.items.reduce(0) { count, item in
            switch item {
            case .groupHeader, .collapsedGroup: return count + 1
            default: return count
            }
        }
    }

    /// Number of empty-group drop tiles rendered (one per expanded group
    /// with zero visible members, plus one per collapsed group whose only
    /// member is outside the visible cap). Each tile occupies a full
    /// session tile slot below its header but does NOT appear in
    /// `projection.slots`, so the rail height must account for them
    /// explicitly or the dashed drop slot overflows the capsule.
    private var emptyGroupDropTileCount: Int {
        var count = 0
        for item in projection.items {
            switch item {
            case .groupHeader(let g):
                if !projection.slots.contains(where: { slot in
                    if case .group(let id, _) = slot.container { return id == g.id }
                    return false
                }) {
                    count += 1
                }
            case .collapsedGroup(_, let topMember):
                if topMember == nil { count += 1 }
            default:
                break
            }
        }
        return count
    }

    private var railHeight: CGFloat {
        if dockSide.orientation == .horizontal {
            // Horizontal: group headers stack ABOVE their drawer (cross axis),
            // so they do not add to long-axis length. Empty-group drop tiles
            // are full-sized tiles inside the drawer and do add one tile
            // worth of long-axis length each (`sessionTileWidth`, not
            // `sessionTileHeight`).
            let emptyDropExtraLength = CGFloat(emptyGroupDropTileCount) * (metrics.sessionTileWidth + metrics.sessionSpacing)
            return PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: sessions.count,
                isAddSlotExpanded: isAddSlotExpanded,
                metrics: metrics,
                includesFullscreenControl: PickyFullscreenFeatureFlags.isEnabled
            ) + emptyDropExtraLength
        }
        let headersExtraLength = CGFloat(groupHeaderCount) * (PickyHUDDockGroupHeaderHeight + metrics.sessionSpacing)
        let emptyDropExtraLength = CGFloat(emptyGroupDropTileCount) * (metrics.sessionTileHeight + metrics.sessionSpacing)
        let base = PickyHUDDockLayout.dockRailHeight(
            sessionCount: sessions.count,
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        )
        let withFullscreen = PickyFullscreenFeatureFlags.isEnabled
            ? base + PickyHUDDockLayout.fullscreenDockControlLength(metrics: metrics)
            : base
        return withFullscreen + headersExtraLength + emptyDropExtraLength
    }

    /// Cross-axis (height) of the dock rail in horizontal mode. Grows by the
    /// group header chip height when any dock group is rendered so the title
    /// sits inside the capsule above its members.
    private var horizontalRailCrossSize: CGFloat {
        PickyHUDDockLayout.horizontalDockRailCrossSize(
            hasGroupHeaders: groupHeaderCount > 0,
            metrics: metrics
        )
    }

    private var fullscreenButton: some View {
        Button {
            onOpenFullscreenSession(fullscreenTargetSessionID)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius * 0.72, style: .continuous)
                    .fill(DS.Colors.accent.opacity(0.16))
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius * 0.72, style: .continuous)
                    .strokeBorder(DS.Colors.accent.opacity(0.42), lineWidth: 1)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: max(10, 12 * metrics.scale), weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
            }
            .frame(width: PickyHUDDockLayout.fullscreenDockControlSide(metrics: metrics), height: PickyHUDDockLayout.fullscreenDockControlSide(metrics: metrics))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Open fullscreen workspace")
        .accessibilityHint("Hides the dock and opens the selected Pickle in fullscreen mode")
    }

    @ViewBuilder
    private var sessionsAndAddSlot: some View {
        if projection.items.isEmpty && projection.slots.isEmpty {
            // Empty state still lives inside the capsule so the handle has somewhere
            // to anchor visually. Use the full-size add button (not the collapsible
            // one) since there are no sessions to keep it compact for.
            addAgentSlotButton
        } else {
            if dockSide.orientation == .horizontal {
                // Bottom-align so ungrouped Pickle icons (`sessionTileHeight`)
                // share the same baseline as the drawer of a grouped block
                // (which sits below its title chip). Without this they
                // floated to the rail's vertical center and looked offset
                // from the grouped Pickles whenever any dock group existed.
                // The collapsible `+` slot is *not* a Pickle and stays
                // vertically centered — flexing its height to fill the
                // wrapper lets the button center itself inside that frame
                // while the body row keeps its bottom-aligned baseline.
                HStack(alignment: .bottom, spacing: 2) {
                    HStack(alignment: .bottom, spacing: metrics.sessionSpacing) {
                        dockBodyItems
                    }
                    collapsibleAddAgentSlot
                        .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: metrics.sessionSpacing) {
                    dockBodyItems
                }
                collapsibleAddAgentSlot
                    .padding(.top, metrics.addSlotTopPadding)
            }
        }
    }

    /// Renders the projection (ungrouped icons + group headers + group
    /// members + collapsed groups) in dock order. Group rendering wraps the
    /// member icons (or the stacked badge) in `PickyHUDDockGroupContainer`
    /// so the 2px accent bar and header chip stay visually unified.
    @ViewBuilder
    private var dockBodyItems: some View {
        // Group the projection items by group so we can render each group as
        // a single visual block with its accent bar. Ungrouped sessions emit
        // standalone slots that pass straight through.
        let renderUnits = Self.buildRenderUnits(from: projection.items)
        ForEach(renderUnits) { unit in
            renderUnitView(unit)
        }
    }

    @ViewBuilder
    private func renderUnitView(_ unit: PickyHUDDockRenderUnit) -> some View {
        switch unit.kind {
        case .session(let id):
            if let card = sessions.first(where: { $0.id == id }),
               let slot = projection.slots.first(where: { $0.sessionID == id }) {
                iconView(for: card, slot: slot)
                    .publishDockTopEntryCenter(
                        entryID: "session:\(id)",
                        dockSide: dockSide
                    )
            }
        case .group(let group, let members):
            PickyHUDDockGroupContainer(
                group: group,
                dockSide: dockSide,
                metrics: metrics,
                drawerSpan: groupDrawerSpan(group: group, members: members),
                isRenamingOnAppear: pendingRenameGroupID == group.id,
                onRenameCommit: { newName in
                    onRenameDockGroup(group.id, newName)
                    if pendingRenameGroupID == group.id { pendingRenameGroupID = nil }
                },
                onRenameCancel: {
                    if pendingRenameGroupID == group.id { pendingRenameGroupID = nil }
                },
                onToggleCollapsed: { onToggleDockGroupCollapsed(group.id) },
                onSetColor: { onSetDockGroupColor(group.id, $0) },
                onUngroup: { onRemoveDockGroup(group.id, true) },
                onDeleteWithArchive: { onRemoveDockGroup(group.id, false) },
                onHeaderDragBegin: { handleGroupHeaderDragBegin(groupID: group.id) },
                onHeaderDragChanged: { handleGroupHeaderDragChanged(groupID: group.id, translation: $0) },
                onHeaderDragEnded: { handleGroupHeaderDragEnded(groupID: group.id, translation: $0) },
                onHeaderDragCanceled: { handleGroupHeaderDragCanceled() },
                isHeaderDragging: draggingGroupID == group.id,
                headerDragOffset: draggingGroupID == group.id ? groupDragOffset : .zero,
                pullOutBadgeText: (draggingGroupID == group.id && groupPullOutArmed)
                    ? L10n.t("dock.drag.remove.label")
                    : nil
            ) {
                if group.isCollapsed {
                    // The collapsed render unit only carries the top member, so
                    // resolve the full visible member set from the group itself
                    // to fill the app-drawer folder grid.
                    let memberCards = group.memberSessionIDs.compactMap { id in
                        allSessions.first(where: { $0.id == id })
                    }
                    let unreadCount = memberCards.reduce(0) { count, card in
                        unreadSessionIDs.contains(card.id) ? count + 1 : count
                    }
                    if let topID = memberCards.first?.id {
                        PickyHUDDockCollapsedGroupBadge(
                            members: memberCards,
                            unreadCount: unreadCount,
                            tint: group.color.accent,
                            metrics: metrics,
                            shortcutNumber: projection.slots
                                .first(where: { $0.sessionID == topID })
                                .flatMap { PickyHUDDockLayout.numberShortcutForSessionIndex($0.visibleIndex) },
                            isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                            onTap: { onToggleDockGroupCollapsed(group.id) }
                        )
                        .publishDockSlotCenter(sessionID: topID, dockSide: dockSide)
                    } else {
                        // Group has no visible members — render a small
                        // empty drop target so the user can still drag
                        // pickles in or expand/rename via the header menu.
                        PickyHUDDockGroupEmptySlot(color: group.color, metrics: metrics)
                            .publishDockSlotCenter(
                                sessionID: Self.emptyGroupDropTargetID(groupID: group.id),
                                dockSide: dockSide
                            )
                    }
                } else if members.isEmpty {
                    PickyHUDDockGroupEmptySlot(color: group.color, metrics: metrics)
                        .publishDockSlotCenter(
                            sessionID: Self.emptyGroupDropTargetID(groupID: group.id),
                            dockSide: dockSide
                        )
                } else {
                    // Expanded group: members live inside the same app-drawer
                    // surface as the collapsed folder, extended along the dock
                    // axis so the grouping stays visible while expanded.
                    Group {
                        if dockSide.orientation == .horizontal {
                            HStack(spacing: metrics.sessionSpacing) {
                                ForEach(members, id: \.sessionID) { member in
                                    if let card = sessions.first(where: { $0.id == member.sessionID }),
                                       let slot = projection.slots.first(where: { $0.sessionID == member.sessionID }) {
                                        iconView(for: card, slot: slot)
                                    }
                                }
                            }
                        } else {
                            VStack(spacing: metrics.sessionSpacing) {
                                ForEach(members, id: \.sessionID) { member in
                                    if let card = sessions.first(where: { $0.id == member.sessionID }),
                                       let slot = projection.slots.first(where: { $0.sessionID == member.sessionID }) {
                                        iconView(for: card, slot: slot)
                                    }
                                }
                            }
                        }
                    }
                    .pickyDockGroupDrawer(tint: group.color.accent, cornerRadius: metrics.iconCornerRadius)
                }
            }
            .publishDockTopEntryCenter(
                entryID: "group:\(group.id)",
                dockSide: dockSide
            )
        }
    }

    @ViewBuilder
    private func iconView(
        for session: PickySessionListViewModel.SessionCard,
        slot: PickyDockSlot
    ) -> some View {
        if draggingSessionID == session.id {
            // The dragged Pickle is rendered as a floating overlay that never
            // reparents (see `draggedFloatingIconOverlay`). In the flow it is
            // an invisible placeholder of identical size so neighbors reflow
            // to make room at the landing spot, but no real icon view crosses
            // the group-container boundary — which is what caused the flicker.
            Color.clear
                .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
                .publishDockSlotCenter(sessionID: session.id, dockSide: dockSide)
        } else {
            PickyHUDDockIconView(
                session: session,
                index: slot.visibleIndex,
                isActive: activeSessionID == session.id,
                isOpened: openedSessionID == session.id,
                isPreviewed: previewSessionID == session.id,
                isScreenContextArmed: screenContextTargetSessionID == session.id,
                dockSide: dockSide,
                shortcutNumber: PickyHUDDockLayout.numberShortcutForSessionIndex(slot.visibleIndex),
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                isUnread: unreadSessionIDs.contains(session.id),
                metrics: metrics,
                isDragging: false,
                dragOffset: .zero,
                onHover: { onHoverSession(session.id) },
                onOpen: { onOpenSession(session.id) },
                onToggleScreenContextTarget: { onToggleScreenContextTarget(session.id) },
                onCompact: { onCompactSession(session.id) },
                onArchive: { onArchiveSession(session.id) },
                onStop: { onStopSession(session.id) },
                onDoneFlashConsumed: { onDoneFlashConsumed(session.id) },
                onReorderHandoff: { anchorScreenPoint in
                    reorderController.begin(sessionID: session.id, anchorScreenPoint: anchorScreenPoint)
                }
            )
            .publishDockSlotCenter(sessionID: session.id, dockSide: dockSide)
            .transaction { transaction in
                // While a drag is in progress, animate sibling slot moves so
                // they slide to make room at the landing spot.
                guard draggingSessionID != nil else { return }
                transaction.animation = slotShiftAnimation
            }
        }
    }

    /// The real dragged Pickle, floating above the rail at the cursor. Lives in
    /// a single stable overlay so it never reparents across group containers
    /// (the in-flow slot is an invisible placeholder). Pure-translation
    /// positioning means it tracks the cursor with no per-frame layout lag.
    @ViewBuilder
    private var draggedFloatingIconOverlay: some View {
        if let id = draggingSessionID,
           let card = sessions.first(where: { $0.id == id }) {
            GeometryReader { geo in
                PickyHUDDockIconView(
                    session: card,
                    index: 0,
                    isActive: activeSessionID == id,
                    isOpened: false,
                    isPreviewed: false,
                    isScreenContextArmed: false,
                    dockSide: dockSide,
                    shortcutNumber: nil,
                    isCommandShortcutHintVisible: false,
                    shouldFlashCompletion: false,
                    isUnread: unreadSessionIDs.contains(id),
                    metrics: metrics,
                    isDragging: true,
                    dragOffset: .zero,
                    onHover: {},
                    onOpen: {},
                    onToggleScreenContextTarget: {},
                    onCompact: {},
                    onArchive: {},
                    onStop: {},
                    onDoneFlashConsumed: {},
                    onReorderHandoff: { _ in }
                )
                // Follow the cursor on both axes so a pull-out reads like
                // the macOS Dock; reorder hit-testing still uses only the
                // primary-axis delta, so cross-axis follow is purely visual.
                .opacity(sessionPullOutArmed ? 0.5 : 1)
                .position(
                    x: dockSide.orientation == .vertical
                        ? geo.size.width / 2 + dragTranslation.width
                        : dragStartCenter + dragTranslation.width,
                    y: dockSide.orientation == .vertical
                        ? dragStartCenter + dragTranslation.height
                        : geo.size.height / 2 + dragTranslation.height
                )

                if sessionPullOutArmed {
                    pullOutBadge(L10n.t("dock.drag.archive.label"))
                        .position(
                            x: dockSide.orientation == .vertical
                                ? geo.size.width / 2 + dragTranslation.width
                                : dragStartCenter + dragTranslation.width,
                            y: (dockSide.orientation == .vertical
                                ? dragStartCenter + dragTranslation.height
                                : geo.size.height / 2 + dragTranslation.height)
                                - (metrics.sessionTileHeight / 2 + 16)
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Small capsule label floated over a dragged Pickle once archive-on-
    /// release is armed, mirroring the macOS Dock cue.
    private func pullOutBadge(_ text: String) -> some View {
        PickyHUDDockPullOutBadge(text: text)
    }

    /// Synthetic id used to publish/look up an empty group's drop tile
    /// center in `slotCenters`. Distinct from any real session id so drag
    /// hit-tests can tell "drop into empty group" apart from "drop onto a
    /// session".
    private static func emptyGroupDropTargetID(groupID: String) -> String {
        "_empty_group:\(groupID)"
    }

    /// Long-axis span of a group block's drawer (the surface that hosts
    /// member icons or the collapsed/empty placeholder). The header chip is
    /// sized to match so the group title sits centered above the drawer. In
    /// vertical mode every group occupies a single column; in horizontal
    /// mode an expanded group with N members spans N tiles plus (N-1) gaps.
    private func groupDrawerSpan(
        group: PickyDockGroup,
        members: [PickyHUDDockGroupMemberRef]
    ) -> CGFloat {
        guard dockSide.orientation == .horizontal else {
            return metrics.sessionTileWidth
        }
        if group.isCollapsed || members.isEmpty {
            return metrics.sessionTileWidth
        }
        let n = CGFloat(members.count)
        return n * metrics.sessionTileWidth + max(0, n - 1) * metrics.sessionSpacing
    }

    /// Extract the group id from a synthetic empty-group drop target id, or
    /// return nil if the input is a real session id.
    private static func parseEmptyGroupDropTargetID(_ id: String) -> String? {
        guard id.hasPrefix("_empty_group:") else { return nil }
        return String(id.dropFirst("_empty_group:".count))
    }

    /// Walk projection items linearly and emit one render unit per ungrouped
    /// session or per group block. Group members get attached to their owning
    /// group, collapsed groups carry the single visible top member as their
    /// only "member".
    private static func buildRenderUnits(from items: [PickyDockRenderItem]) -> [PickyHUDDockRenderUnit] {
        var units: [PickyHUDDockRenderUnit] = []
        var activeGroup: PickyDockGroup?
        var activeMembers: [PickyHUDDockGroupMemberRef] = []

        func flushGroup() {
            if let group = activeGroup {
                units.append(.init(kind: .group(group: group, members: activeMembers)))
                activeGroup = nil
                activeMembers = []
            }
        }

        for item in items {
            switch item {
            case .session(let id):
                flushGroup()
                units.append(.init(kind: .session(id: id)))
            case .groupHeader(let group):
                flushGroup()
                activeGroup = group
                activeMembers = []
            case .groupMember(_, let sid, _):
                if activeGroup != nil {
                    activeMembers.append(.init(sessionID: sid))
                } else {
                    // Malformed projection — stray member without header.
                    // Render as ungrouped to avoid losing the icon.
                    units.append(.init(kind: .session(id: sid)))
                }
            case .collapsedGroup(let group, let topMember):
                flushGroup()
                var members: [PickyHUDDockGroupMemberRef] = []
                if let topMember { members.append(.init(sessionID: topMember)) }
                units.append(.init(kind: .group(group: group, members: members)))
            }
        }
        flushGroup()
        return units
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

    /// Signed distance the cursor has been dragged *away* from the dock along
    /// the cross axis (perpendicular to the icon column/row). Positive means
    /// pulled out toward open screen; negative means pushed across the dock.
    private func pullOutDistance(_ translation: CGSize) -> CGFloat {
        switch dockSide {
        case .left:   return translation.width
        case .right:  return -translation.width
        case .top:    return translation.height
        case .bottom: return -translation.height
        }
    }

    /// Cross-axis travel past which a drag counts as "outside the dock". Based
    /// on the dock thickness plus a margin so the icon has visibly cleared the
    /// capsule before a destructive release arms.
    private var pullOutThreshold: CGFloat { metrics.railWidth * 0.5 + 40 }

    /// Schedule the dwell that arms session archive-on-release. Idempotent:
    /// re-arming while a timer is pending (or already armed) is a no-op, so
    /// per-frame drag callbacks don't keep rescheduling it.
    private func scheduleSessionPullOutDwell() {
        guard sessionPullOutDwellWork == nil, !sessionPullOutArmed else { return }
        let work = DispatchWorkItem {
            sessionPullOutDwellWork = nil
            guard draggingSessionID != nil else { return }
            withAnimation(.easeOut(duration: 0.16)) { sessionPullOutArmed = true }
        }
        sessionPullOutDwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelSessionPullOutDwell() {
        sessionPullOutDwellWork?.cancel()
        sessionPullOutDwellWork = nil
    }

    private func handleReorderBegin(sessionID: String) {
        guard projection.slots.contains(where: { $0.sessionID == sessionID }) else { return }
        draggingSessionID = sessionID
        pendingDropContainer = layout.container(forSessionID: sessionID)
        dragTranslation = .zero
        // Anchor the floating overlay on the measured slot center captured the
        // moment the user picked up the icon. Falling back to 0 keeps the
        // first frame safe when the GeometryReader publish hasn't landed yet.
        dragStartCenter = slotCenters[sessionID] ?? 0
        // Freeze the hit-test geometry now, while the rail still shows the
        // base (un-previewed) layout. Every subsequent drop decision is made
        // against this fixed snapshot, so the preview reflow is a pure visual
        // consequence and can never feed back into the decision.
        dragReferenceSlots = baseProjection.slots
        dragReferenceCenters = slotCenters
    }

    private func handleReorderChanged(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID else { return }
        dragTranslation = translation

        // macOS Dock-style pull-out: once the icon has clearly cleared the
        // dock on the cross axis, freeze the layout (no sibling reflow) and
        // arm archive-on-release after a short dwell. Returning early keeps
        // the dock visually still while the icon floats outside.
        if pullOutDistance(translation) > pullOutThreshold {
            pendingDropContainer = layout.container(forSessionID: sessionID)
            scheduleSessionPullOutDwell()
            return
        }
        cancelSessionPullOutDwell()
        if sessionPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { sessionPullOutArmed = false }
        }

        let translationAxis = axisDelta(translation)
        let cursorAxis = dragStartCenter + translationAxis

        // Hit-test against the FROZEN reference snapshot (captured at drag
        // start), not the live preview. Because the reference never moves
        // during the drag, the decision is a pure function of cursor position
        // and can't oscillate as the preview reflows. The resolution itself
        // (nearest center + group-edge escape) lives in the pure
        // `PickyDockDropResolver` so it can be unit-tested.
        let slotCandidates: [PickyDockDropResolver.SlotCandidate] = dragReferenceSlots.compactMap { slot in
            guard let center = dragReferenceCenters[slot.sessionID] else { return nil }
            return .init(container: slot.container, center: center)
        }
        var emptyGroupCandidates: [PickyDockDropResolver.EmptyGroupCandidate] = []
        for (centerKey, center) in dragReferenceCenters {
            guard let groupID = Self.parseEmptyGroupDropTargetID(centerKey) else { continue }
            emptyGroupCandidates.append(.init(groupID: groupID, center: center))
        }

        let nearestDestination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: sessionID,
            cursorAxis: cursorAxis,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: emptyGroupCandidates,
            layout: layout,
            slotPitch: slotPitchAlongAxis
        )

        // Record where the icon *would* land. This drives the live preview
        // projection (siblings make room at the landing spot) but is NOT
        // committed: grouping/ungrouping only happens on release, so the
        // assignment never flickers as the cursor crosses a boundary.
        if let nearestDestination, pendingDropContainer != nearestDestination {
            pendingDropContainer = nearestDestination
        }
    }

    private func handleReorderEnded(sessionID: String, translation: CGSize) {
        guard draggingSessionID == sessionID else { return }
        let didArchive = sessionPullOutArmed
        cancelSessionPullOutDwell()
        sessionPullOutArmed = false
        if didArchive {
            // Released outside the dock after the dwell: archive instead of
            // reordering. No move is committed.
            onArchiveSession(sessionID)
        } else {
            // Commit the deferred move exactly once, on release.
            let currentContainer = layout.container(forSessionID: sessionID)
            if let destination = pendingDropContainer, destination != currentContainer {
                onMoveSessionInDock(sessionID, destination)
            }
        }
        draggingSessionID = nil
        pendingDropContainer = nil
        dragTranslation = .zero
        dragReferenceSlots = []
        dragReferenceCenters = [:]
    }

    private func handleReorderCanceled() {
        guard draggingSessionID != nil else { return }
        // No commit on cancel — the Pickle simply snaps back to its slot.
        cancelSessionPullOutDwell()
        sessionPullOutArmed = false
        draggingSessionID = nil
        pendingDropContainer = nil
        dragTranslation = .zero
        dragReferenceSlots = []
        dragReferenceCenters = [:]
        activeReorderSessionID = nil
        reorderController.reset()
    }

    // MARK: - Group header drag (whole-group reorder)

    /// Visible top-level entry ids in the order the projection emitted them.
    /// `"session:<id>"` for an ungrouped slot, `"group:<id>"` for a group
    /// (either expanded or collapsed). Drives the header drag's drop
    /// hit-test along the same axis the icons live on.
    private var visibleTopEntryIDs: [String] {
        var ids: [String] = []
        for item in projection.items {
            switch item {
            case .session(let sid): ids.append("session:\(sid)")
            case .groupHeader(let g): ids.append("group:\(g.id)")
            case .collapsedGroup(let g, _): ids.append("group:\(g.id)")
            case .groupMember: break
            }
        }
        return ids
    }

    /// Translate a visible top-entry index back to its index in
    /// `dockLayout.entries`. Necessary when the visible projection is a
    /// strict subset of the persisted layout (some sessions outside the
    /// `visibleSessionLimit` cap). When the visible entry id maps to a
    /// layout entry that no longer exists, returns nil so the caller can
    /// no-op safely.
    private func layoutEntryIndex(forVisibleTopEntryID entryID: String) -> Int? {
        layout.entries.firstIndex { entry in
            switch entry {
            case .session(let id): return "session:\(id)" == entryID
            case .group(let g):    return "group:\(g.id)" == entryID
            }
        }
    }

    private func handleGroupHeaderDragBegin(groupID: String) {
        guard let layoutIdx = layout.entries.firstIndex(where: { entry in
            if case .group(let g) = entry, g.id == groupID { return true }
            return false
        }) else { return }
        // Cancel any in-flight icon drag so the two gestures never run in
        // parallel. The user typically pulls one or the other; defensive
        // here keeps state machines from getting tangled.
        if draggingSessionID != nil {
            handleReorderCanceled()
        }
        draggingGroupID = groupID
        groupDragStartLayoutIndex = layoutIdx
        groupDragCurrentLayoutIndex = layoutIdx
        groupDragOffset = .zero
        groupDragStartCenter = topEntryCenters["group:\(groupID)"] ?? 0
    }

    private func handleGroupHeaderDragChanged(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }

        // macOS Dock-style pull-out: while the group block is dragged clearly
        // outside the dock, arm removal-on-release immediately (no dwell) and
        // let the block float freely under the cursor instead of reordering.
        if pullOutDistance(translation) > pullOutThreshold {
            if !groupPullOutArmed {
                withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = true }
            }
            groupDragOffset = translation
            return
        }
        if groupPullOutArmed {
            withAnimation(.easeOut(duration: 0.16)) { groupPullOutArmed = false }
        }

        let topEntryIDs = visibleTopEntryIDs
        guard !topEntryIDs.isEmpty else { return }
        let translationAxis = axisDelta(translation)
        let cursorAxis = groupDragStartCenter + translationAxis

        // Find the visible top entry whose measured center is closest to
        // the cursor. Skip entries with no published center (= still
        // settling) so the hit-test never picks an unmeasured entry.
        var nearestVisibleIdx: Int? = nil
        var minDistance: CGFloat = .infinity
        for (i, entryID) in topEntryIDs.enumerated() {
            guard let center = topEntryCenters[entryID] else { continue }
            let distance = abs(center - cursorAxis)
            if distance < minDistance {
                minDistance = distance
                nearestVisibleIdx = i
            }
        }
        guard let nearestVisibleIdx else { return }
        let nearestEntryID = topEntryIDs[nearestVisibleIdx]
        guard let nearestLayoutIdx = layoutEntryIndex(forVisibleTopEntryID: nearestEntryID) else { return }

        if nearestLayoutIdx != groupDragCurrentLayoutIndex {
            onMoveDockGroup(groupID, nearestLayoutIdx)
            groupDragCurrentLayoutIndex = nearestLayoutIdx
        }

        // Keep the group block glued under the cursor.
        let currentHomeCenter = topEntryCenters["group:\(groupID)"] ?? groupDragStartCenter
        let shift = currentHomeCenter - groupDragStartCenter
        let offsetAxis = translationAxis - shift
        switch dockSide.orientation {
        case .horizontal:
            groupDragOffset = CGSize(width: offsetAxis, height: translation.height)
        case .vertical:
            groupDragOffset = CGSize(width: translation.width, height: offsetAxis)
        }
    }

    private func handleGroupHeaderDragEnded(groupID: String, translation: CGSize) {
        guard draggingGroupID == groupID else { return }
        let didRemove = groupPullOutArmed
        groupPullOutArmed = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            groupDragOffset = .zero
        }
        draggingGroupID = nil
        if didRemove {
            // Released outside the dock: remove the group and archive its
            // members (same outcome as the context-menu delete). A group with
            // Pickles inside confirms first; an empty group is removed at once.
            let group = layout.group(withID: groupID)
            if let group, !group.memberSessionIDs.isEmpty {
                // Defer the modal so the block first springs back into the
                // dock, then the confirmation appears over a settled layout.
                DispatchQueue.main.async {
                    PickyHUDDockGroupDeletePrompt.confirmDeleteWithArchive(
                        groupName: group.displayName
                    ) {
                        onRemoveDockGroup(groupID, false)
                    }
                }
            } else {
                onRemoveDockGroup(groupID, false)
            }
        }
    }

    private func handleGroupHeaderDragCanceled() {
        guard draggingGroupID != nil else { return }
        groupPullOutArmed = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            groupDragOffset = .zero
        }
        draggingGroupID = nil
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
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            availableSessionsForGroupCreation: sessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
    }

    /// Accent color the next group will adopt. Surfaced to the creator
    /// popover so the user sees the upcoming swatch alongside the name
    /// field instead of being surprised by the auto-rotation after
    /// pressing Create. Derived from how many group entries already live
    /// in the layout via the projection's items.
    private var nextSuggestedGroupColor: PickyDockGroupColor {
        let existingGroupCount = layout.groups.count
        return PickyDockGroupColor.nextColor(forExistingGroupCount: existingGroupCount)
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
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            availableSessionsForGroupCreation: sessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .onHover { hovering in
            let expanded = hovering || isRecentPickleFolderPickerPresented
            onAddSlotExpandedChanged(expanded)
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = expanded
            }
        }
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
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

extension View {
    func recentPickleFolderPicker(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        recentPickleCwds: [String],
        onCreatePickleInRecentFolder: @escaping (String) -> Void,
        onChooseFolder: @escaping () -> Void,
        onRemoveRecentPickleFolder: @escaping (String) -> Void,
        availableSessionsForGroupCreation: [PickySessionListViewModel.SessionCard] = [],
        suggestedGroupColor: PickyDockGroupColor = .teal,
        onCreateGroup: ((_ name: String, _ memberIDs: [String]) -> Void)? = nil
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            PickyRecentPickleFolderPickerView(
                isPresented: isPresented,
                recentPickleCwds: recentPickleCwds,
                onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
                onChooseFolder: onChooseFolder,
                onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
                availableSessionsForGroupCreation: availableSessionsForGroupCreation,
                suggestedGroupColor: suggestedGroupColor,
                onCreateGroup: onCreateGroup
            )
        }
    }
}

struct PickyRecentPickleFolderPickerView: View {
    @Binding var isPresented: Bool
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (String) -> Void
    let onChooseFolder: () -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    let availableSessionsForGroupCreation: [PickySessionListViewModel.SessionCard]
    let suggestedGroupColor: PickyDockGroupColor
    let onCreateGroup: ((_ name: String, _ memberIDs: [String]) -> Void)?

    /// Popover mode. Default flow shows the folder picker; tapping
    /// "New Group" swaps the same popover to the creator dialog so the
    /// user picks a name and initial members in one step instead of
    /// being kicked into an inline rename of an empty group.
    @State private var isShowingGroupCreator = false

    var body: some View {
        if isShowingGroupCreator, let onCreateGroup {
            PickyDockGroupCreatorView(
                availableSessions: availableSessionsForGroupCreation,
                suggestedColor: suggestedGroupColor,
                onCreate: { name, memberIDs in
                    isShowingGroupCreator = false
                    isPresented = false
                    onCreateGroup(name, memberIDs)
                },
                onCancel: {
                    isShowingGroupCreator = false
                }
            )
        } else {
            folderPickerContent
        }
    }

    private var folderPickerContent: some View {
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
                Label(L10n.t("dock.recentFolders.chooseFolder"), systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)
            .accessibilityHint(L10n.t("dock.recentFolders.chooseFolder.hint"))
            if onCreateGroup != nil {
                Button {
                    isShowingGroupCreator = true
                } label: {
                    Label(L10n.t("dock.recentFolders.newGroup"), systemImage: "folder.badge.gearshape")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 2)
                .accessibilityHint(L10n.t("dock.recentFolders.newGroup.hint"))
            }
        }
        .padding(14)
        .frame(width: 286)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("dock.recentFolders.title"))
                .pickyFont(size: 14, weight: .medium)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Text(L10n.t("dock.startPickle"))
                .pickyFont(size: 11, weight: .medium)
                .foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private var emptyState: some View {
        Text(L10n.t("dock.recentFolders.empty"))
            .pickyFont(size: 12)
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
                        .pickyFont(size: 14, weight: .medium)
                        .foregroundStyle(DS.Colors.accentText)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .pickyFont(size: 13, weight: .medium)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(compactPath)
                            .pickyFont(size: 11)
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
            .accessibilityLabel(L10n.t("dock.startPickleIn", displayName))
            .accessibilityHint(compactPath)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .pickyFont(size: 10, weight: .medium)
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
    /// Fired once when the cursor crosses the reorder threshold. The argument
    /// is the mouse-down anchor in screen space; the rail hands the drag off
    /// to its rail-level controller from here so it survives this icon's
    /// NSView being recreated mid-drag.
    var onReorderHandoff: (NSPoint) -> Void = { _ in }

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
                onReorderHandoff: onReorderHandoff
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
        PickyHUDDockCommandShortcutBadge(label: label)
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
        var canCompact = false
        var canStop = false
        var onToggleScreenContextTarget: (() -> Void)?
        var onCompact: (() -> Void)?
        var onArchivePressing: ((Bool) -> Void)?
        var onArchive: (() -> Void)?
        var onStop: (() -> Void)?
        var onReorderHandoff: ((NSPoint) -> Void)?

        func clearCallbacks() {
            onHover = nil
            onOpen = nil
            onToggleScreenContextTarget = nil
            onCompact = nil
            onArchivePressing = nil
            onArchive = nil
            onStop = nil
            onReorderHandoff = nil
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
    /// True once the drag crossed the reorder threshold and was handed off to
    /// the rail-level drag controller. From that point this view does nothing
    /// for the drag — an app-level event monitor owns it — so the drag is
    /// unaffected when SwiftUI recreates this view.
    private var handedOffReorder = false

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
