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
    /// Imperative session actions and full-card resolvers use this plain
    /// capability. The root observes only the dock projection below.
    let viewModel: any PickySessionCommands
    @ObservedObject var dockState: PickyHUDDockState
    var panelIdentifier: NSUserInterfaceItemIdentifier?
    var closeRequests: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    /// Display this panel renders on. Used to route notification-driven open
    /// requests to only the screen the user clicked the banner on.
    var displayID: CGDirectDisplayID?
    /// Per-panel reactive placement state. The overlay manager updates
    /// `placement.availableCardMaxHeight` whenever the dock anchor or the screen
    /// configuration changes; the conversation card binds to it so it grows or
    /// shrinks within whatever space remains below the dock's top edge.
    @ObservedObject var placement: PickyHUDPlacement = PickyHUDPlacement()
    var voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry? = nil
    var openPerformanceTracker: PickyHUDOpenPerformanceTracker? = nil
    var onSizeChange: (_ size: CGSize, _ activeSessionID: String?) -> Void = { _, _ in }
    /// Live delta callback for the dock anchor handle. Argument is the cursor's
    /// screen delta from drag start in both X and Y (`NSEvent.mouseLocation` based).
    /// The overlay manager converts the Y delta into an anchor percent and the X
    /// delta into a horizontal offset, then updates placement across every panel.
    var onDockHandleDragChanged: (CGPoint) -> Void = { _ in }
    var onDockHandleDragEnded: () -> Void = { }
    var onDockHandleDoubleClick: () -> Void = { }
    var onDockMinimize: () -> Void = { }
    var onCardMeasuredSize: (CGSize) -> Void = { _ in }
    /// Reports the visible HUD chrome frames (dock rail, conversation card) in
    /// the root's top-left SwiftUI coordinate space. The overlay manager uses
    /// them so ink capture only passes clicks through to pixels the HUD
    /// actually renders — never the transparent card-width reserve.
    var onVisibleChromeFramesChange: ([CGRect]) -> Void = { _ in }
    var onCardResizeDragChanged: (CGPoint) -> Void = { _ in }
    var onCardResizeDragEnded: () -> Void = { }
    var onCardResizeReset: () -> Void = { }
    var onArchiveUndoRequested: (_ sessionID: String, _ title: String) -> Void = { _, _ in }
    /// The overlay manager owns the display-local child panel. Folder frames
    /// are measured in this root's coordinate space before it positions it.
    var onDockGroupListToggle: (_ groupID: String) -> Void = { _ in }
    /// A regular Pickle hover has explicit pointer priority over any transient
    /// group list whose broad folder-panel corridor also covers the tile.
    var onDockSessionTileHover: () -> Void = { }
    /// Raw folder hover transition. The overlay manager owns the folder-to-panel
    /// corridor because only it knows the child panel's screen frame.
    var onDockGroupTileHover: (_ groupID: String, _ isHovering: Bool) -> Void = { _, _ in }
    /// A folder drag takes pointer ownership away from hover disclosure.
    var onDockGroupTileDragBegin: (_ groupID: String) -> Void = { _ in }
    var onDockGroupListClose: () -> Void = { }
    /// Overlay Manager owns external drag lifetime because a nonactivating
    /// child panel cannot reliably receive Escape itself.
    var onCancelExternalDockDrag: () -> Bool = { false }
    var onDockGroupListRowSelected: (_ sessionID: String) -> Void = { _ in }
    /// Display-local list state, owned by the overlay manager. The HUD root only
    /// reads it, so number keys and arrows resolve against whichever surface is
    /// frontmost without the two copies drifting.
    @ObservedObject var dockGroupListFocusStore = PickyHUDDockGroupListFocusStore()
    var onDockGroupListGeometryChange: (_ badgeFrames: [String: CGRect], _ interactionFrames: [String: CGRect], _ railFrame: CGRect, _ isCommandHintVisible: Bool, _ openedSessionID: String?) -> Void = { _, _, _, _, _ in }
    /// The rail reports base coordinates in the HUD root. Overlay Manager owns
    /// the final AppKit screen conversion and retains the latest valid input.
    var onExternalDockGeometryChange: (_ input: PickyHUDDockExternalDragRailGeometryInput, _ railFrame: CGRect) -> Void = { _, _ in }
    @State private var externalDockGeometryInput: PickyHUDDockExternalDragRailGeometryInput?
    /// One store per HUD root/display. Task 9 will let Overlay Manager update
    /// this from its coordinator without coupling the Rail to event monitors.
    @ObservedObject var externalDragPresentationStore = PickyHUDDockExternalDragRailPresentationStore()
    @State private var dockGroupBadgeFrames: [String: CGRect] = [:]
    @State private var dockGroupInteractionFrames: [String: CGRect] = [:]
    @State private var dockRailFrame: CGRect = .zero
    @StateObject private var archiveActions = PickyHUDArchiveActionController()
    @State private var heldSession: PickyHUDDockHold?
    @State private var pendingManualAutoOpenSessionID: String?
    @State private var pendingRequestedOpenSessionID: String?
    @State private var hoverPreviewSessionID: String?
    @State private var suppressedHoverSessionID: String?
    @State private var lastHandledAuthoritativeRemovalRevision: UInt64 = 0
    @State private var isHUDHovered = false
    @State private var isDockHovered = false
    @State private var closeExpansionTask: Task<Void, Never>?
    @State private var hoverPreviewCloseTask: Task<Void, Never>?
    @State private var keyDownMonitor: Any?
    @State private var modifierFlagsMonitor: Any?
    @State private var isCommandShortcutHintVisible = false
    @State private var isOptionModifierPressed = false
    @State private var composerFocusRequestID = 0
    @State private var utilityPanelOpenSessionIDs: Set<String> = []
    @State private var utilityPanelResizeStartHeight: CGFloat?
    @State private var utilityPanelHeightOverride: CGFloat?
    @AppStorage(
        PickyHUDUtilityPanelPolicy.heightStorageKey,
        store: PickyRuntimeEnvironment.userDefaults
    ) private var storedUtilityPanelHeight = PickyHUDUtilityPanelPolicy.defaultHeight
    @State private var isDockAddSlotExpanded = false
    /// One-shot relay from a child group-list panel to the matching rail tile,
    /// which owns the shared recent-folders popover anchor.
    @StateObject private var dockGroupPickerRelay = PickyHUDDockGroupPickerRelay()
    @State private var cardResizeInteraction = PickyHUDCardResizeInteractionState()
    @State private var sizeReporter = PickyHUDSizeReporter()

    private var dockSnapshot: PickyHUDDockSnapshot { dockState.snapshot }

    private var dockMetrics: PickyHUDDockMetrics {
        PickyHUDDockMetrics(preset: placement.dockSizePreset)
    }

    /// Universe of active session ids the dock renders this frame. Order
    /// matches the legacy `sessions.reversed()` convention (oldest first,
    /// newest last) so the projector's fallback branch keeps newcomers at
    /// the bottom of the dock next to the `+` slot.
    private var visibleSessionUniverse: [String] {
        Array(dockSnapshot.activeSessions.reversed().map(\.id))
    }

    /// Projection of the persisted dock layout against the current visible
    /// universe. Drives both render order (groups + ungrouped interleaved)
    /// and shortcut/drag hit-testing.
    private var dockProjection: PickyDockProjection {
        PickyDockProjector.project(
            layout: dockSnapshot.dockLayout,
            visibleSessionIDs: visibleSessionUniverse
        )
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

    /// Full active session-card universe, including members represented by
    /// folders in the rail. Its fallback order remains oldest-first.
    private var visibleSessions: [PickyHUDDockSession] {
        Array(dockSnapshot.activeSessions.reversed())
    }

    /// Cycle shortcuts follow persisted dock order, unlike the card universe
    /// above which must retain every active group member.
    private var cycleSessionIDs: [String] {
        PickyDockProjector.cycleSessionIDs(
            layout: dockSnapshot.dockLayout,
            activeSessionIDs: visibleSessionUniverse
        )
    }

    /// Active session ids remain the card universe, including members hidden
    /// behind folders. Shortcut routing intentionally uses `dockProjection`.
    private var visibleSessionIDs: [String] {
        visibleSessionUniverse
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

    private var activeSession: PickyHUDDockSession? {
        guard let activeSessionID else { return nil }
        return visibleSessions.first { $0.id == activeSessionID }
    }

    var body: some View {
        let _ = PickyPerf.event("hud_root_body")
        hudContent
            .confirmationDialog(
                Text(archiveActions.choiceSessionID.map { sessionID in
                    L10n.t("hud.asyncTasks.archiveChoice.namedTitle",
                        viewModel.sessionCard(sessionID: sessionID)?.title ?? sessionID)
                } ?? L10n.t("hud.asyncTasks.archiveChoice.title")),
                isPresented: Binding(get: { archiveActions.choiceSessionID != nil },
                                     set: { if !$0 { archiveActions.cancelChoice() } })
            ) {
                Button("hud.asyncTasks.archiveChoice.continue") {
                    archiveActions.choose(.continue)
                }
                Button("hud.asyncTasks.archiveChoice.stop") {
                    archiveActions.choose(.stopThenArchive)
                }
                Button("hud.asyncTasks.archiveChoice.cancel", role: .cancel) { archiveActions.cancelChoice() }
            } message: {
                Text("hud.asyncTasks.archiveChoice.message")
            }
            .alert(Text(L10n.t(archiveActions.errorTitleKey)), isPresented: Binding(
                get: { archiveActions.error != nil }, set: { if !$0 { archiveActions.dismissError() } }
            )) {
                Button("hud.asyncTasks.archiveChoice.cancel") { archiveActions.dismissError() }
            } message: {
                Text(archiveActions.error ?? "")
            }
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
            .coordinateSpace(name: PickyHUDVisibleChromeCoordinateSpaceName)
            .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: handleHUDSizeChange)
            .onPreferenceChange(PickyHUDCardSizePreferenceKey.self, perform: handleCardMeasuredSize)
            .onPreferenceChange(PickyHUDVisibleChromeFramePreferenceKey.self) { frames in
                onVisibleChromeFramesChange(frames)
            }
            .onPreferenceChange(PickyHUDDockGroupBadgeFramePreferenceKey.self) { frames in
                dockGroupBadgeFrames = frames
                reportDockGroupListGeometry()
            }
            .onPreferenceChange(PickyHUDDockGroupInteractionFramePreferenceKey.self) { frames in
                dockGroupInteractionFrames = frames
                reportDockGroupListGeometry()
            }
            .onPreferenceChange(PickyHUDDockRailFramePreferenceKey.self) { frame in
                guard !placement.isMinimized else { return }
                dockRailFrame = frame
                reportDockGroupListGeometry()
                reportExternalDockGeometry()
            }
            .onChange(of: isCommandShortcutHintVisible) { _, _ in
                reportDockGroupListGeometry()
            }
            .onChange(of: openedSessionID) { _, _ in
                reportDockGroupListGeometry()
            }
            .onChange(of: placement.isMinimized) { _, isMinimized in
                if isMinimized { clearMinimizedDockTransientState() }
            }
            .onChange(of: placement.dockGroupListCreateRequestGroupID) { _, groupID in
                guard let groupID else { return }
                placement.dockGroupListCreateRequestGroupID = nil
                dockGroupPickerRelay.request(groupID: groupID)
            }
            .onAppear {
                installCloseShortcutMonitor()
                consumeAuthoritativeRemovalEvent(dockSnapshot.authoritativeRemovalEvent)
                handleOpenSessionRequest(dockSnapshot.openSessionRequest)
                markFocusedActiveSessionReadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard isCurrentHUDPanel(notification.object) else { return }
                markFocusedActiveSessionReadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                let currentHUDPanelResigned = isCurrentHUDPanel(notification.object)
                isCommandShortcutHintVisible = PickyHUDCommandShortcutHintPolicy.visibility(
                    current: isCommandShortcutHintVisible,
                    after: .hudPanelDidResignKey(isCurrentHUDPanel: currentHUDPanelResigned)
                )
                if currentHUDPanelResigned {
                    isOptionModifierPressed = false
                }
            }
            .onChange(of: activeSessionID) { _, _ in
                resetCardResizeInteraction()
                markFocusedActiveSessionReadIfNeeded()
            }
            .onChange(of: dockSnapshot.unreadSessionIDs) { _, _ in
                markFocusedActiveSessionReadIfNeeded()
            }
            .onChange(of: visibleSessionIDs) { _, _ in
                openPendingManualPickleIfVisible()
                openPendingRequestedSessionIfVisible()
            }
            .onChange(of: dockSnapshot.authoritativeRemovalEvent) { _, event in
                consumeAuthoritativeRemovalEvent(event)
            }
            .onChange(of: dockSnapshot.openSessionRequest) { _, request in
                handleOpenSessionRequest(request)
            }
            .onReceive(closeRequests) {
                if !placement.isMinimized { closeHeldSession() }
            }
            .onChange(of: dockSnapshot.screenContextArmCollapseToken) { _, _ in
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
                hoverPreviewCloseTask?.cancel()
                hoverPreviewCloseTask = nil
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
                extensionUiRequestID: activeSessionID.flatMap { viewModel.sessionCard(sessionID: $0)?.pendingExtensionUiRequest?.id },
                shouldHoldHeight: shouldHoldPanelHeightDuringActiveTurn,
                onSizeChange: { size in onSizeChange(size, activeID) }
            )
        }
    }

    private func handleCardMeasuredSize(_ size: CGSize) {
        PickyPerf.event("hud_card_size_preference_changed")
        guard size.width > 0, size.height > 0 else { return }
        onCardMeasuredSize(size)
    }

    private var shouldHoldPanelHeightDuringActiveTurn: Bool {
        guard !placement.isMinimized else { return false }
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
        if !placement.isMinimized && activeSession != nil {
            conversationCard
        } else {
            Color.clear
                .frame(
                    width: placement.cardWidth,
                    height: PickyHUDDockMinimizedGeometry.horizontalPreviewReserveHeight(metrics: dockMetrics)
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var conversationCard: some View {
        if !placement.isMinimized, let activeSessionID {
            PickyHUDConversationCardResolver(viewModel: viewModel, sessionID: activeSessionID) { store, session in
                conversationCard(for: session, store: store)
            }
        }
    }

    @ViewBuilder
    private func conversationCard(
        for activeSession: PickyConversationSessionCard,
        store: PickySessionStore
    ) -> some View {
            let utilityPanelIsOpen = isUtilityPanelOpen(sessionID: activeSession.id)
                && !viewModel.isInlineTerminalMode(sessionID: activeSession.id)
            let utilityPanelHeight = resolvedUtilityPanelHeight
            let openAttemptToken = openPerformanceTracker?.activeToken(sessionID: activeSession.id)
            VStack(alignment: .leading, spacing: 0) {
                PickyConversationCardView(
                    viewModel: viewModel,
                    sessionStore: store,
                    onArchiveSession: archiveSession,
                    onClose: { closeOpenedSession(activeSession.id) },
                    maxHeight: conversationCardMaxHeight(
                        isUtilityPanelOpen: utilityPanelIsOpen,
                        utilityPanelHeight: utilityPanelHeight
                    ),
                    width: placement.cardWidth,
                    fixedHeight: placement.fixedCardHeight,
                    isPreviewMode: false,
                    focusRequestID: composerFocusRequestID,
                    isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                    isOptionModifierPressed: isOptionModifierPressed,
                    isUtilityPanelOpen: utilityPanelIsOpen,
                    onToggleUtilityPanel: { toggleUtilityPanel(sessionID: activeSession.id) },
                    onInitialContentReady: {
                        guard let openAttemptToken else { return }
                        PickyPerf.event("hud_open_interactive")
                        openPerformanceTracker?.markInteractive(token: openAttemptToken)
                    }
                )
                .background(PickyHUDCardSizeReader())
                .background {
                    if let voiceTargetHitTestRegistry {
                        PickyVoiceTargetHitRegionHost(
                            sessionID: activeSession.id,
                            isEligible: !viewModel.isInlineTerminalMode(sessionID: activeSession.id),
                            registry: voiceTargetHitTestRegistry
                        )
                    }
                }
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
                .accessibilityHint(L10n.t("hud.card.resize.help"))

                if utilityPanelIsOpen {
                    PickyHUDUtilityPanelResizeGrip(
                        onDragChanged: updateUtilityPanelHeight(for:),
                        onDragEnded: finishUtilityPanelResize
                    )
                    .frame(width: placement.cardWidth)
                    PickySessionUtilityPanelView(
                        sessionStore: store,
                        commands: viewModel,
                        height: utilityPanelHeight
                    )
                    // The panel's GeometryReader is greedy; without an explicit width it
                    // stretches past the conversation card when the host proposal is wider.
                    .frame(width: placement.cardWidth)
                    .transition(.opacity)
                }
            }
            .background(PickyHUDVisibleChromeFrameReporter())
            .environment(\.pickyHUDDetailWidth, placement.cardWidth)
            .transition(.identity)
            .onAppear {
                guard let openAttemptToken else { return }
                PickyPerf.event("hud_open_card_mounted")
                openPerformanceTracker?.markCardMounted(token: openAttemptToken)
            }
            .onDisappear(perform: resetCardResizeInteraction)
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

    private var resolvedUtilityPanelHeight: CGFloat {
        PickyHUDUtilityPanelPolicy.clampedHeight(
            utilityPanelHeightOverride ?? storedUtilityPanelHeight,
            availableCardHeight: placement.availableCardMaxHeight
        )
    }

    private func conversationCardMaxHeight(
        isUtilityPanelOpen: Bool,
        utilityPanelHeight: CGFloat
    ) -> CGFloat {
        guard isUtilityPanelOpen else { return placement.availableCardMaxHeight }
        return PickyHUDUtilityPanelPolicy.conversationCardMaxHeight(
            availableCardHeight: placement.availableCardMaxHeight,
            utilityPanelHeight: utilityPanelHeight
        )
    }

    private func updateUtilityPanelHeight(for verticalTranslation: CGFloat) {
        if utilityPanelResizeStartHeight == nil {
            utilityPanelResizeStartHeight = resolvedUtilityPanelHeight
        }
        guard let utilityPanelResizeStartHeight else { return }
        utilityPanelHeightOverride = PickyHUDUtilityPanelPolicy.clampedHeight(
            utilityPanelResizeStartHeight - verticalTranslation,
            availableCardHeight: placement.availableCardMaxHeight
        )
    }

    private func finishUtilityPanelResize() {
        if let utilityPanelHeightOverride {
            storedUtilityPanelHeight = utilityPanelHeightOverride
        }
        utilityPanelHeightOverride = nil
        utilityPanelResizeStartHeight = nil
    }

    private var dockRail: some View {
        PickyHUDDockMinimizedPresentation(
            isLoading: dockSnapshot.isLoadingInitialSessionSnapshot,
            isMinimized: placement.isMinimized,
            dockSide: placement.dockSide,
            metrics: dockMetrics,
            projection: dockProjection,
            availableRailLength: placement.availableDockRailLength,
            hasArchiveAccess: viewModel.archivedSessionAccess != nil,
            activeSessionID: activeSession?.id,
            onRestore: restoreDock
        ) {
            PickyHUDDockRailView(
                sessions: visibleSessions,
                allSessions: dockSnapshot.activeSessions,
                baseProjection: dockProjection,
                layout: dockSnapshot.dockLayout,
                groupMemberIDsByRecency: dockSnapshot.groupMemberIDsByRecency,
                activeSessionID: activeSession?.id,
                openedSessionID: openedSessionID,
                previewSessionID: hoverPreviewSessionID,
                screenContextTargetSessionID: dockSnapshot.screenContextTargetSessionID,
                screenContextTargetSticky: dockSnapshot.screenContextTargetSticky,
                dockSide: placement.dockSide,
                isCommandShortcutHintVisible: isRailShortcutHintVisible,
                pendingDoneFlashSessionIDs: dockSnapshot.pendingDoneFlashSessionIDs,
                unreadSessionIDs: dockSnapshot.unreadSessionIDs,
                metrics: dockMetrics,
                availableRailLength: placement.availableDockRailLength,
                onHoverSession: handleDockSessionTileHoverTransition,
                onOpenSession: toggleOpenSession,
                onToggleScreenContextTarget: toggleScreenContextTarget,
                onToggleStickyScreenContextTarget: toggleStickyScreenContextTarget,
                onCompactSession: compactSession,
                onArchiveSession: archiveSession,
                onStopSession: stopSession,
                onCreatePickle: { targetGroupID in
                    chooseFolderForEmptyPickle(targetGroupID: targetGroupID)
                },
                pinnedPickleCwds: visiblePinnedPickleCwds,
                recentPickleCwds: visibleRecentPickleCwds,
                onCreatePickleInRecentFolder: { cwd, targetGroupID in
                    startEmptyPickle(cwd: cwd, targetGroupID: targetGroupID)
                },
                onRemoveRecentPickleFolder: viewModel.removeRecentPickleFolder,
                onPinPickleFolder: viewModel.pinPickleFolder,
                onUnpinPickleFolder: viewModel.unpinPickleFolder,
                onReorderPinnedPickleFolders: viewModel.reorderPinnedPickleFolders,
                onCreateDockGroup: { name, memberIDs in
                    viewModel.createDockGroup(name: name, withMemberIDs: memberIDs)
                },
                onRenameDockGroup: { id, name in viewModel.renameDockGroup(id: id, to: name) },
                onSetDockGroupColor: { id, color in viewModel.setDockGroupColor(id: id, color: color) },
                onActivateDockGroup: activateDockGroupTileFromPointer,
                onActivateDockGroupFromKeyboard: activateDockGroupTileFromCommandShortcut,
                onDockGroupTileHover: handleDockGroupTileHoverTransition,
                onDockGroupTileDragBegin: onDockGroupTileDragBegin,
                pinnedDockGroupListGroupID: placement.pinnedDockGroupListGroupID,
                onRemoveDockGroup: { id, keepMembers in viewModel.removeDockGroup(id: id, keepMembers: keepMembers) },
                onMoveSessionInDock: { sessionID, container in viewModel.moveSessionInDock(sessionID: sessionID, to: container) },
                onMoveDockGroup: { id, target in viewModel.moveDockGroup(id: id, toTopLevelIndex: target) },
                pendingPickleFolderPickerRequest: dockGroupPickerRelay.request,
                onPickleFolderPickerPresentationAcknowledged: { dockGroupPickerRelay.acknowledgePresentation(requestID: $0) },
                onDockHoverChanged: handleDockHover,
                onAddSlotExpandedChanged: { isDockAddSlotExpanded = $0 },
                onDoneFlashConsumed: viewModel.markDoneFlashConsumed(sessionID:),
                onDockHandleDragChanged: onDockHandleDragChanged,
                onDockHandleDragEnded: onDockHandleDragEnded,
                onDockHandleDoubleClick: onDockHandleDoubleClick,
                onExternalDragGeometryChange: { input in
                    externalDockGeometryInput = input
                    reportExternalDockGeometry()
                },
                externalDragPresentationStore: externalDragPresentationStore,
                archiveAccess: viewModel.archivedSessionAccess,
                onMinimize: minimizeDock
            )
        }
    }

    private func minimizeDock() {
        cancelPendingClose()
        cancelHoverPreviewClose()
        hoverPreviewSessionID = nil
        isDockHovered = false
        isHUDHovered = false
        isDockAddSlotExpanded = false
        isCommandShortcutHintVisible = false
        isOptionModifierPressed = false
        archiveActions.cancelChoice()
        archiveActions.dismissError()
        onDockMinimize()
    }

    private func clearMinimizedDockTransientState() {
        cancelPendingClose()
        cancelHoverPreviewClose()
        hoverPreviewSessionID = nil
        dockRailFrame = .zero
        dockGroupBadgeFrames = [:]
        dockGroupInteractionFrames = [:]
        externalDockGeometryInput = nil
    }

    private func restoreDock() {
        placement.isMinimized = false
    }

    private func consumeAuthoritativeRemovalEvent(_ event: PickyHUDDockRemovalEvent?) {
        let state = PickyHUDSessionRemovalState(
            heldSession: heldSession,
            pendingManualAutoOpenSessionID: pendingManualAutoOpenSessionID,
            pendingRequestedOpenSessionID: pendingRequestedOpenSessionID,
            hoverPreviewSessionID: hoverPreviewSessionID,
            suppressedHoverSessionID: suppressedHoverSessionID,
            utilityPanelOpenSessionIDs: utilityPanelOpenSessionIDs
        )
        guard let result = PickyHUDSessionRemovalPolicy.applying(
            event,
            after: lastHandledAuthoritativeRemovalRevision,
            to: state
        ) else { return }
        heldSession = result.state.heldSession
        pendingManualAutoOpenSessionID = result.state.pendingManualAutoOpenSessionID
        pendingRequestedOpenSessionID = result.state.pendingRequestedOpenSessionID
        hoverPreviewSessionID = result.state.hoverPreviewSessionID
        suppressedHoverSessionID = result.state.suppressedHoverSessionID
        utilityPanelOpenSessionIDs = result.state.utilityPanelOpenSessionIDs
        lastHandledAuthoritativeRemovalRevision = result.handledRevision
    }

    private func reportExternalDockGeometry() {
        guard !placement.isMinimized, let externalDockGeometryInput, dockRailFrame != .zero else { return }
        onExternalDockGeometryChange(externalDockGeometryInput, dockRailFrame)
    }

    private func reportDockGroupListGeometry() {
        guard !placement.isMinimized else { return }
        onDockGroupListGeometryChange(
            dockGroupBadgeFrames,
            dockGroupInteractionFrames,
            dockRailFrame,
            isCommandShortcutHintVisible,
            openedSessionID
        )
    }

    private var isPointerInsideHUDSurface: Bool {
        isHUDHovered || isDockHovered
    }

    private func handleHUDHover(_ isHovering: Bool) {
        guard !placement.isMinimized else { return }
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
        guard !placement.isMinimized, isCurrentHUDPanel(NSApp.keyWindow), let activeSessionID else { return }
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
        PickyRecentPickleFolderPolicy.visiblePinnedCwds(dockSnapshot.pinnedPickleCwds, exists: Self.isExistingDirectory)
    }

    private var visibleRecentPickleCwds: [String] {
        PickyRecentPickleFolderPolicy.visibleRecentCwds(
            dockSnapshot.recentPickleCwds,
            pinned: dockSnapshot.pinnedPickleCwds,
            exists: Self.isExistingDirectory
        )
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func chooseFolderForEmptyPickle(targetGroupID: String?) {
        NSApp.activate(ignoringOtherApps: true)
        PickyHUDWorkingFolderPickerCoordinator.shared.beginSelection { url in
            startEmptyPickle(cwd: url.path, targetGroupID: targetGroupID)
        }
    }

    private func startEmptyPickle(cwd: String, targetGroupID: String?) {
        Task {
            do {
                let sessionID = try await viewModel.createEmptyPickleSession(cwd: cwd)
                await MainActor.run {
                    if let targetGroupID = PickyHUDWorkingFolderTargetPolicy.resolvedGroupID(
                        targetGroupID,
                        in: dockState.snapshot.dockLayout
                    ) {
                        viewModel.assignSessionToDockGroup(
                            sessionID: sessionID,
                            groupID: targetGroupID
                        )
                    }
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
        let effect = PickyHUDDockOpenRequestPolicy.apply(
            request, displayID: displayID, openedSessionID: openedSessionID, placement: placement
        )
        switch effect {
        case .open(let sessionID):
            pendingRequestedOpenSessionID = sessionID
            openPendingRequestedSessionIfVisible()
        case .close(let sessionID):
            toggleOpenSession(sessionID)
        case nil:
            break
        }
    }

    private func openPendingRequestedSessionIfVisible() {
        guard let next = PickyHUDDockLayout.requestedOpenResolution(
            pendingSessionID: pendingRequestedOpenSessionID,
            visibleIDs: visibleSessionIDs
        ) else { return }
        pendingRequestedOpenSessionID = nil
        openHeldSession(next)
    }

    private func handleDockSessionTileHoverTransition(_ sessionID: String, _ isHovering: Bool) {
        guard isHovering else {
            scheduleHoverPreviewClose(for: sessionID)
            return
        }
        previewDockSession(sessionID)
    }

    private func handleDockGroupTileHoverTransition(_ groupID: String, _ isHovering: Bool) {
        if isHovering {
            cancelHoverPreviewClose()
            hoverPreviewSessionID = PickyHUDDockInteractionPolicy.previewSessionIDAfterGroupHover(
                current: hoverPreviewSessionID,
                isHovering: true
            )
        }
        onDockGroupTileHover(groupID, isHovering)
    }

    private func previewDockSession(_ sessionID: String) {
        cancelHoverPreviewClose()
        onDockSessionTileHover()
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

    private func scheduleHoverPreviewClose(for sessionID: String) {
        hoverPreviewCloseTask?.cancel()
        hoverPreviewCloseTask = Task {
            do {
                try await Task.sleep(
                    nanoseconds: PickyHUDDockHoverDisclosurePolicy.closeGraceNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                hoverPreviewSessionID = PickyHUDDockInteractionPolicy.previewSessionIDAfterTileExitTimeout(
                    current: hoverPreviewSessionID,
                    exitedSessionID: sessionID
                )
                hoverPreviewCloseTask = nil
            }
        }
    }

    private func cancelHoverPreviewClose() {
        hoverPreviewCloseTask?.cancel()
        hoverPreviewCloseTask = nil
    }

    private func toggleOpenSession(_ sessionID: String) {
        pendingManualAutoOpenSessionID = nil
        cancelPendingClose()
        let nextHeldSession = PickyHUDDockLayout.heldSessionAfterClick(
            current: heldSession,
            clicked: sessionID
        )
        if nextHeldSession == nil {
            openPerformanceTracker?.cancel(sessionID: sessionID)
        } else if let session = viewModel.sessionCard(sessionID: sessionID) {
            PickyPerf.event("hud_open_click")
            openPerformanceTracker?.start(
                sessionID: sessionID,
                messageCount: session.messages.count,
                wasUnread: dockSnapshot.unreadSessionIDs.contains(sessionID)
            )
        }
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
            // Record only after the held conversation card state is open.
            viewModel.markConversationCardOpened(sessionID: sessionID)
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

    private func toggleStickyScreenContextTarget(_ sessionID: String) {
        cancelPendingClose()
        viewModel.toggleStickyScreenContextTarget(sessionID: sessionID)
    }

    private func compactSession(_ sessionID: String) {
        cancelPendingClose()
        Task { await viewModel.requestCompaction(sessionID: sessionID) }
    }

    private func archiveSession(_ sessionID: String) {
        cancelPendingClose()
        archiveActions.request(sessionID: sessionID, commands: viewModel, onConfirmed: finishArchive)
    }

    private func finishArchive(_ sessionID: String) {
        let title = visibleSessions.first(where: { $0.id == sessionID })?.title
            ?? viewModel.sessionCard(sessionID: sessionID)?.title ?? "Pickle"
        utilityPanelOpenSessionIDs.remove(sessionID)
        if heldSession?.sessionID == sessionID { heldSession = nil }
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        if suppressedHoverSessionID == sessionID { suppressedHoverSessionID = nil }
        onArchiveUndoRequested(sessionID, title)
    }

    private func stopSession(_ sessionID: String) {
        cancelPendingClose()
        Task { @MainActor in
            do { try await viewModel.abortRestoringQueuedInputs(sessionID: sessionID) } catch {
                archiveActions.presentStopError(error)
            }
        }
    }

    private func scheduleCloseIfNeeded() {
        guard !placement.isMinimized else { return }
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
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard handleKeyboardShortcut(event) else { return event }
                return nil
            }
        }

        if modifierFlagsMonitor == nil {
            modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                updateModifierKeyState(modifierFlags: event.modifierFlags)
                return event
            }
        }
    }

    private func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        updateModifierKeyState(modifierFlags: event.modifierFlags)
        guard let keyWindow = NSApp.keyWindow as? PickyHUDPanel else { return false }
        if let panelIdentifier, keyWindow.identifier != panelIdentifier { return false }
        guard !placement.isMinimized else { return false }
        keyWindow.restoreRememberedNativeInputResponderIfNeeded()
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
        let visibleIDs = cycleSessionIDs
        let activeCard = activeSessionID.flatMap { viewModel.sessionCard(sessionID: $0) }
        let isTextInputFocused = isEditableTextInputFocused(in: keyWindow)
        let returnOutcome = PickyHUDDockGroupListKeyboardPolicy.returnOutcome(
            for: PickyHUDDockGroupListReturnContext(
                isPlainReturn: PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(
                    keyCode: event.keyCode,
                    modifiers: flags
                ),
                isListOpen: dockGroupListFocus.isOpen,
                highlightedRowID: dockGroupListFocus.highlightedRowID,
                isTextInputFocused: isTextInputFocused,
                isHUDFallbackResponder: keyWindow.isFirstResponderFallback,
                hasActiveCard: activeCard != nil,
                isInlineTerminalMode: activeCard.map { viewModel.isInlineTerminalMode(sessionID: $0.id) } ?? false
            )
        )
        switch returnOutcome {
        case .selectHighlightedRow(let rowID):
            onDockGroupListRowSelected(rowID)
            return true
        case .focusComposer:
            focusActiveComposer()
            return true
        case .passThrough:
            break
        }

        if flags == .command, event.keyCode == Self.wKeyCode, heldSession != nil {
            closeHeldSession()
            return true
        }

        // Esc closes the expanded Pickle card just like Cmd+W, but only when no
        // text input is focused. The composer's own .onKeyPress(.escape) handles
        // autocomplete dismissal and stop-if-possible while the input is focused;
        // intercepting here would steal that behavior.
        // Esc closes an open group list first, even from the composer, so the
        // floating panel can never outlive the key press that dismisses it.
        if flags.isEmpty,
           event.keyCode == Self.escKeyCode,
           onCancelExternalDockDrag() {
            return true
        }

        if flags.isEmpty,
           event.keyCode == Self.escKeyCode,
           PickyHUDDockGroupListKeyboardPolicy.escapeOutcome(isListOpen: dockGroupListFocus.isOpen)
           == .closeGroupList {
            onDockGroupListClose()
            return true
        }

        if flags.isEmpty,
           event.keyCode == Self.escKeyCode,
           heldSession != nil,
           !isEditableTextInputFocused(in: keyWindow) {
            closeHeldSession()
            return true
        }

        if PickyHUDDockGroupListKeyboardPolicy.ownsListNavigationKeys(
            isListOpen: dockGroupListFocus.isOpen,
            isTextInputFocused: isTextInputFocused
        ), flags.isEmpty {
            switch event.keyCode {
            case Self.upArrowKeyCode:
                _ = dockGroupListFocusStore.moveHighlight(displayID: displayID, direction: .up)
                return true
            case Self.downArrowKeyCode:
                _ = dockGroupListFocusStore.moveHighlight(displayID: displayID, direction: .down)
                return true
            case Self.returnKeyCode, Self.keypadEnterKeyCode:
                guard let highlighted = dockGroupListFocus.highlightedRowID else { return false }
                onDockGroupListRowSelected(highlighted)
                return true
            default:
                break
            }
        }

        if PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard,
           activeCard.hasLatestAgentResponseReport {
            openLatestAgentResponseReport(sessionID: activeCard.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard,
           activeCard.piSessionFilePath != nil {
            viewModel.toggleInlineTerminalMode(sessionID: activeCard.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard,
           activeCard.piSessionFilePath != nil {
            viewModel.openTerminalOverlay(sessionID: activeCard.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard {
            toggleMacOSNotifyOnCompletion(session: activeCard)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard,
           !viewModel.isInlineTerminalMode(sessionID: activeCard.id) {
            toggleUtilityPanel(sessionID: activeCard.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard {
            viewModel.toggleThinkingBlocks(sessionID: activeCard.id)
            return true
        }

        if PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: flags
        ), let activeCard,
           !isEditableTextInputFocused(in: keyWindow) {
            toggleScreenContextTarget(activeCard.id)
            return true
        }

        // Text input owns Cmd+Delete as delete-to-line-start, and a focused
        // terminal already consumed it above as a readline control byte.
        if PickyHUDKeyboardShortcutPolicy.isArchiveSessionShortcut(
            keyCode: event.keyCode,
            modifiers: flags
        ), let activeCard,
           !isEditableTextInputFocused(in: keyWindow) {
            archiveSession(activeCard.id)
            return true
        }

        if flags == .command, let number = Self.numberShortcutValue(for: event) {
            // An open list owns the number keys; the rail only gets them back
            // once the list closes.
            if case .groupList = PickyHUDDockGroupListKeyboardPolicy.shortcutContext(
                openGroupID: dockGroupListFocus.openGroupID
            ) {
                guard let rowID = PickyHUDDockGroupListKeyboardPolicy.rowID(
                    forShortcutNumber: number,
                    rowIDs: dockGroupListFocus.rowIDs
                ) else { return true }
                onDockGroupListRowSelected(rowID)
                return true
            }
            let slots = dockProjection.slots
            guard number >= 1, number <= slots.count else { return false }
            switch slots[number - 1].target {
            case .group(let groupID):
                activateDockGroupTileFromCommandShortcut(groupID)
            case .session(let sessionID, _):
                let next = PickyHUDDockLayout.heldSessionAfterClick(
                    current: heldSession,
                    clicked: sessionID
                )
                if let next {
                    openHeldSession(next)
                } else {
                    closeHeldSession()
                }
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

    private var dockGroupActivationCoordinator: PickyHUDDockGroupActivationCoordinator {
        PickyHUDDockGroupActivationCoordinator(
            visibleMemberIDs: visibleMemberIDs(inDockGroup:),
            showFolderPicker: { dockGroupPickerRelay.request(groupID: $0) },
            openSession: toggleOpenSession,
            toggleMemberList: onDockGroupListToggle
        )
    }

    private func visibleMemberIDs(inDockGroup groupID: String) -> [String] {
        let activeSessionIDs = Set(dockSnapshot.activeSessions.map(\.id))
        return dockSnapshot.dockLayout.group(withID: groupID)?.memberSessionIDs
            .filter(activeSessionIDs.contains) ?? []
    }

    private func activateDockGroupTileFromPointer(_ groupID: String) {
        dockGroupActivationCoordinator.activateFromPointer(groupID: groupID)
    }

    private func activateDockGroupTileFromCommandShortcut(_ groupID: String) {
        dockGroupActivationCoordinator.activateFromCommandShortcut(groupID: groupID)
    }

    private func openHeldSession(_ next: PickyHUDDockHold) {
        restoreDock()
        pendingManualAutoOpenSessionID = nil
        pendingRequestedOpenSessionID = nil
        cancelPendingClose()
        heldSession = next
        hoverPreviewSessionID = nil
        suppressedHoverSessionID = nil
        viewModel.markConversationCardOpened(sessionID: next.sessionID)
    }

    private func focusActiveComposer() {
        composerFocusRequestID &+= 1
    }

    private func isUtilityPanelOpen(sessionID: String) -> Bool {
        utilityPanelOpenSessionIDs.contains(sessionID)
    }

    private func toggleUtilityPanel(sessionID: String) {
        cancelPendingClose()
        let wasOpen = utilityPanelOpenSessionIDs.contains(sessionID)
        utilityPanelOpenSessionIDs = PickyHUDUtilityPanelPolicy.openSessionIDsAfterToggling(
            sessionID: sessionID,
            openSessionIDs: utilityPanelOpenSessionIDs
        )
        if !wasOpen {
            viewModel.markSessionRead(sessionID: sessionID)
        }
    }

    private func toggleMacOSNotifyOnCompletion(session: PickyConversationSessionCard) {
        let enabled = !(session.notifyMacOSOnCompletion == true)
        Task { try? await viewModel.setNotifyMacOSOnCompletion(sessionID: session.id, enabled: enabled) }
    }

    private func openLatestAgentResponseReport(sessionID: String) {
        cancelPendingClose()
        Task { try? await viewModel.openLatestAgentResponseReport(sessionID: sessionID) }
    }

    private func isEditableTextInputFocused(in window: NSWindow) -> Bool {
        PickyHUDKeyboardShortcutPolicy.isEditableTextInputFocused(window.firstResponder)
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
        isOptionModifierPressed = false
    }

    private func updateModifierKeyState(modifierFlags: NSEvent.ModifierFlags) {
        let isCurrentPanelKey = isCurrentHUDPanel(NSApp.keyWindow)
        isCommandShortcutHintVisible = PickyHUDCommandShortcutHintPolicy.visibility(
            current: isCommandShortcutHintVisible,
            after: .modifierFlagsChanged(
                modifierFlags: modifierFlags,
                isCurrentHUDPanelKey: isCurrentPanelKey
            )
        )
        isOptionModifierPressed = PickyHUDOptionModifierPolicy.isPressed(
            modifierFlags: modifierFlags,
            isCurrentHUDPanelKey: isCurrentPanelKey
        )
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
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    private var dockGroupListFocus: PickyHUDDockGroupListFocus {
        dockGroupListFocusStore.focus(for: displayID)
    }

    /// Rail hints go quiet while a list is open, because the numbers address the
    /// list's rows instead of the rail's slots.
    private var isRailShortcutHintVisible: Bool {
        isCommandShortcutHintVisible && !dockGroupListFocus.isOpen
    }
}

/// Full-card observation is isolated to this mounted subtree. Its explicit
/// identity prevents a newly opened Pickle from retaining the previous card's
/// local SwiftUI state while dock icons continue to use lightweight snapshots.
private struct PickyHUDConversationCardResolver<Content: View>: View {
    /// The HUD root intentionally keeps this as a plain command/resolver
    /// capability. The mounted subtree observes the selected registry store,
    /// avoiding global façade-array fan-out for unrelated sessions.
    let viewModel: any PickySessionCommands
    let sessionID: String
    @ViewBuilder let content: (PickySessionStore, PickyConversationSessionCard) -> Content

    var body: some View {
        if let store = viewModel.sessionStore(sessionID: sessionID),
           let session = store.materializedSessionCard(includeAsyncDetail: false) {
            content(store, session)
                .id(sessionID)
        }
    }
}
