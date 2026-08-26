//
//  PickyHUDOverlayManager.swift
//  Picky
//
//  Screen-edge HUD panel lifecycle and placement. One panel per attached
//  display so the dock is always visible on every monitor; per-screen UI
//  state (hover, pin, preview) lives inside each PickyHUDView's @State while
//  the shared session model drives every panel in lockstep.
//

import AppKit
import Combine
import SwiftUI

final class PickyHUDPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Input intent is scoped to one panel. SwiftUI may briefly leave a panel
    /// as its own responder while preserving the mounted native input view;
    /// restore only this responder on the next key event, never when the panel
    /// becomes key, so a click can still choose a different control first.
    private weak var lastNativeInputResponder: NSView?

    /// Records native input only after AppKit accepted it as this panel's
    /// first responder. This also captures terminal focus because SwiftTerm's
    /// responder override is not open for subclassing.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result,
           let responder = responder as? NSView,
           responder.window === self,
           responder is PickyIMENSTextView || responder is PickySwiftTermView {
            lastNativeInputResponder = responder
        }
        return result
    }

    /// Restores the panel's remembered native input only from an unintentional
    /// panel/window fallback. Any real current responder is user intent and
    /// must remain untouched.
    @discardableResult
    func restoreRememberedNativeInputResponderIfNeeded() -> Bool {
        guard isFirstResponderFallback else { return false }
        guard let responder = lastNativeInputResponder else { return false }
        guard responder.window === self, responder.acceptsFirstResponder else {
            if responder.window !== self {
                lastNativeInputResponder = nil
            }
            return false
        }
        return makeFirstResponder(responder)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
            if !clickHitsFocusedControl(event) {
                resignFocusedControl()
            }
        }
        if event.type == .keyDown {
            restoreRememberedNativeInputResponderIfNeeded()
            if let terminal = focusedTerminalView,
               terminal.handleMacLineEditingShortcut(event) {
                return
            }
        }
        super.sendEvent(event)
    }

    var isFirstResponderFallback: Bool {
        PickyHUDKeyboardShortcutPolicy.isPanelFirstResponderFallback(firstResponder, panel: self)
    }

    private var focusedTerminalView: PickySwiftTermView? {
        var currentView = firstResponder as? NSView
        while let view = currentView {
            if let terminal = view as? PickySwiftTermView { return terminal }
            currentView = view.superview
        }
        return nil
    }

    /// Re-clicking the already-focused control (e.g. the composer NSTextView)
    /// must not pre-emptively resign first responder. Doing so races with the
    /// composer's async SwiftUI focus binding: the resign queues an
    /// `isFocused = false` update, AppKit then re-focuses the text view via
    /// the click's natural hit-test, but the coordinator's guard suppresses
    /// the corrective `isFocused = true` dispatch (state still reads true),
    /// leaving the stale `false` to win and flip focus off on the second
    /// click. Outside-focused-control clicks still resign so the
    /// "clear focus before collapse" contract holds.
    func clickHitsFocusedControl(_ event: NSEvent) -> Bool {
        guard let focused = firstResponder as? NSView, focused.window === self else {
            return false
        }
        let pointInFocused = focused.convert(event.locationInWindow, from: nil)
        return focused.bounds.contains(pointInFocused)
    }

    @discardableResult
    func resignFocusedControl() -> Bool {
        guard firstResponder != nil else {
            lastNativeInputResponder = nil
            return false
        }
        let didResign = makeFirstResponder(nil)
        if didResign {
            lastNativeInputResponder = nil
        }
        return didResign
    }

    /// The overlay manager owns the observable projection; this panel only
    /// reports AppKit's post-ordering visibility so secure-surface suppression
    /// and restoration follow the real `NSPanel` state.
    var onActualVisibilityChanged: ((Bool) -> Void)?

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        reportActualVisibility()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        reportActualVisibility()
    }

    override func orderOutForSecureSurfaceSuppression() {
        super.orderOutForSecureSurfaceSuppression()
        reportActualVisibility()
    }

    private func reportActualVisibility() {
        onActualVisibilityChanged?(isVisible)
    }
}

private final class PickyHUDDockGroupListPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PickyHUDOverlayManager {
    private let viewModel: any PickyHUDSessionLifecycle
    private let appearanceStore: PickyAppearanceStore
    private let fontScaleStore: PickyAppFontScaleStore
    private let visibilityStore: PickyHUDVisibilityStore
    private let actualPanelVisibilityStore: PickyHUDActualPanelVisibilityStore
    private let dockGroupListFocusStore = PickyHUDDockGroupListFocusStore()
    private let settingsStore: PickySettingsStore
    private let settingsPersistence: PickySettingsPersistenceCoordinator
    private let voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry
    private var visibilityCancellable: AnyCancellable?
    private var dockStateCancellable: AnyCancellable?
    private var fontScaleCancellable: AnyCancellable?
    private let collapsedHeight: CGFloat = 180
    private let minimumHeight: CGFloat = 48

    /// Stable, per-display state. Keyed by `CGDirectDisplayID` because AppKit
    /// hands us new `NSScreen` instances whenever the screen configuration
    /// changes; the display ID survives those rebuilds as long as the physical
    /// monitor stays connected.
    private struct PanelEntry {
        let panel: PickyHUDPanel
        let placement: PickyHUDPlacement
        var pendingShrinkTask: Task<Void, Never>?
        var lastContentSize: CGSize
        var lastCardMeasuredSize: CGSize?
        /// Visible chrome frames (dock rail, conversation card) reported by
        /// SwiftUI in the HUD root's top-left coordinate space. Consulted by
        /// ink capture so only rendered pixels pass clicks through.
        var visibleChromeFrames: [CGRect] = []
    }

    private struct ArchiveUndoToastEntry {
        let panel: PickyHUDPanel
        var dismissTask: Task<Void, Never>?
        var toast: PickyHUDArchiveUndoToast?
    }

    private struct DockGroupListGeometry {
        var badgeFrames: [String: CGRect] = [:]
        var railFrame: CGRect = .zero
        var openedSessionID: String?
    }

    private struct DockGroupListChildEntry {
        let panel: PickyHUDDockGroupListPanel
        /// Folder tap retained until SwiftUI publishes a usable anchor frame.
        var pendingGroupID: String?
        var openGroupID: String?
        var badgeFrames: [String: CGRect] = [:]
        var railFrame: CGRect = .zero
        var openedSessionID: String?
        var localMouseDownMonitor: Any?
        var globalMouseDownMonitor: Any?
    }

    private var panelsByDisplayID: [CGDirectDisplayID: PanelEntry] = [:]
    private var archiveUndoToastsByDisplayID: [CGDirectDisplayID: ArchiveUndoToastEntry] = [:]
    private var dockGroupListChildrenByDisplayID: [CGDirectDisplayID: DockGroupListChildEntry] = [:]
    private var dockGroupListGeometryByDisplayID: [CGDirectDisplayID: DockGroupListGeometry] = [:]
    private var screenParametersObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var currentDockSizePreset: PickyHUDDockSizePreset
    private var currentCardSizesByDisplayID: [String: PickyHUDCardSize]

    /// Per-display dock position state. Each display remembers its own side,
    /// anchor percent, and horizontal offset so users can place the dock
    /// independently on each monitor. Keyed by display ID string.
    private var currentPositionsByDisplayID: [String: PickyHUDDockPosition]
    /// Snapshot of all positions at drag start so deltas accumulate from the
    /// original anchor rather than the previous frame's clamped value.
    private var dragStartPositionsByDisplayID: [String: PickyHUDDockPosition]?
    private var resizeStartCardSizesByDisplayID: [String: PickyHUDCardSize]?


    init(
        viewModel: any PickyHUDSessionLifecycle,
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        visibilityStore: PickyHUDVisibilityStore,
        actualPanelVisibilityStore: PickyHUDActualPanelVisibilityStore? = nil,
        settingsStore: PickySettingsStore,
        voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry
    ) {
        self.viewModel = viewModel
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
        self.visibilityStore = visibilityStore
        self.actualPanelVisibilityStore = actualPanelVisibilityStore ?? PickyHUDActualPanelVisibilityStore()
        self.settingsStore = settingsStore
        self.settingsPersistence = .shared(for: settingsStore)
        self.voiceTargetHitTestRegistry = voiceTargetHitTestRegistry
        let settings = settingsStore.load()
        self.currentPositionsByDisplayID = settings.hudDockPositions
        self.currentDockSizePreset = settings.hudDockSizePreset
        self.currentCardSizesByDisplayID = settings.hudCardSizes
        self.dockStateCancellable = viewModel.dockState.$snapshot
            .sink { [weak self] _ in self?.syncDockGroupListChildrenWithSnapshot() }
        self.fontScaleCancellable = fontScaleStore.$scale
            .dropFirst()
            .sink { [weak self] _ in self?.syncDockGroupListChildrenWithSnapshot() }
    }

    /// Get the live position for a display. Returns defaults for unknown displays.
    private func position(for displayID: CGDirectDisplayID) -> PickyHUDDockPosition {
        var position = PickyHUDDockPosition.resolved(
            in: currentPositionsByDisplayID,
            displayKey: String(displayID)
        )
        guard position.side.orientation == .vertical,
              let visibleHeight = screen(for: displayID)?.visibleFrame.height else {
            return position
        }
        let keepVisible = PickyHUDDockMetrics(preset: currentDockSizePreset).railWidth
        let maxAnchorPercent = PickyHUDDockLayout.maxDockTopAnchorPercent(
            visibleHeight: visibleHeight,
            keepVisible: keepVisible
        )
        position.anchorPercent = min(max(position.anchorPercent, PickySettings.dockTopAnchorPercentRange.lowerBound), maxAnchorPercent)
        return position
    }

    /// Update position for a display after drag/double-click.
    private func setPosition(_ position: PickyHUDDockPosition, for displayID: CGDirectDisplayID) {
        currentPositionsByDisplayID[String(displayID)] = position
    }

    private func cardSize(for displayID: CGDirectDisplayID) -> PickyHUDCardSize? {
        currentCardSizesByDisplayID[String(displayID)]
    }

    private func cardWidth(for displayID: CGDirectDisplayID) -> CGFloat {
        cardSize(for: displayID)?.width ?? PickyHUDCardSize.defaultWidth
    }

    private func panelWidth(for displayID: CGDirectDisplayID, dockSide: PickyHUDDockSide? = nil) -> CGFloat {
        let side = dockSide ?? position(for: displayID).side
        let intrinsicWidth = PickyHUDDockLayout.panelWidth(
            cardWidth: cardWidth(for: displayID),
            dockSide: side,
            sessionCount: projectedDockSessionCount(for: displayID),
            isAddSlotExpanded: false,
            metrics: PickyHUDDockMetrics(preset: currentDockSizePreset)
        )
        guard side.orientation == .horizontal,
              let screen = screen(for: displayID) else {
            return intrinsicWidth
        }
        // A horizontal rail now scrolls its sessions rather than widening the
        // transparent panel offscreen. Keep the entire panel inside the same
        // visible-frame margins used by the other horizontal placement math.
        let screenWidth = max(0, screen.visibleFrame.width - (PickyHUDDockLayout.screenMargin * 2))
        return min(intrinsicWidth, screenWidth)
    }

    /// Number of session tiles currently projected for this display's dock
    /// rail. Uses every active session so panel sizing/clamping follows the
    /// actual dock projection without a count cap.
    private func projectedDockSessionCount(for displayID: CGDirectDisplayID) -> Int {
        PickyDockProjector.project(
            layout: viewModel.dockState.snapshot.dockLayout,
            visibleSessionIDs: Array(viewModel.dockState.snapshot.activeSessions.reversed().map(\.id))
        ).slots.count
    }

    private func horizontalDockRailLength(
        for screen: NSScreen,
        displayID: CGDirectDisplayID,
        dockSide: PickyHUDDockSide,
        isAddSlotExpanded: Bool = false
    ) -> CGFloat {
        let metrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let contentLength = PickyHUDDockLayout.horizontalDockRailLength(
            sessionCount: projectedDockSessionCount(for: displayID),
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        )
        return PickyHUDDockOverflowPolicy.layout(
            contentLength: contentLength,
            availableLength: computeAvailableDockRailLength(
                for: screen,
                dockSide: dockSide,
                anchorPercent: position(for: displayID).anchorPercent
            ),
            fixedChromeLength: 0
        ).railLength
    }

    func start() {
        viewModel.start()
        visibilityCancellable = visibilityStore.$snapshot
            .sink { [weak self] visibility in
                // Apply the EMITTED snapshot. `@Published` emits during `willSet`,
                // so re-reading the store here would observe the pre-change state
                // and permanently lag every dock toggle by one mutation.
                self?.applyDockVisibility(visibility)
            }
        startScreenParametersObserver()
        startSettingsObserver()
    }

    /// Opens the given session in the HUD dock. Used when the user taps a macOS
    /// notification banner; selection alone is not enough because each HUD view keeps
    /// its open card in local `heldSession` state.
    func focusSession(id: String) {
        // Clicking a session notification is an explicit request to reveal its
        // conversation, so restore the dock on the target display before routing
        // the open without unexpectedly revealing other user-hidden displays.
        // macOS notifications don't tell us which display they were shown on,
        // so use the screen under the cursor at click time as the target.
        let targetDisplayID = displayIDUnderCursor()
        if let targetDisplayID {
            visibilityStore.setVisible(true, for: targetDisplayID)
        } else {
            visibilityStore.setAllVisible(true)
        }
        viewModel.requestOpenSession(sessionID: id, targetDisplayID: targetDisplayID)
        if let targetDisplayID, let entry = panelsByDisplayID[targetDisplayID] {
            entry.panel.orderFrontRegardless()
        } else {
            for (_, entry) in panelsByDisplayID {
                entry.panel.orderFrontRegardless()
            }
        }
    }

    private func displayIDUnderCursor() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        return screen?.pickyDisplayID
    }

    func stop() {
        visibilityCancellable = nil
        dockStateCancellable = nil
        stopScreenParametersObserver()
        stopSettingsObserver()
        viewModel.stop()
        tearDownPanels()
    }

    private func applyDockVisibility(_ visibility: PickyHUDDockVisibilitySnapshot) {
        syncPanelsForCurrentScreens(visibility: visibility)
        for (displayID, entry) in archiveUndoToastsByDisplayID {
            guard entry.toast != nil else { continue }
            if visibility.isVisible(for: displayID) {
                entry.panel.orderFrontRegardless()
            } else {
                entry.panel.orderOut(nil)
            }
        }
    }

    private func tearDownPanels() {
        for (_, entry) in panelsByDisplayID {
            entry.pendingShrinkTask?.cancel()
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
        }
        for (_, entry) in archiveUndoToastsByDisplayID {
            entry.dismissTask?.cancel()
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
        }
        for displayID in dockGroupListChildrenByDisplayID.keys {
            hideDockGroupListChild(displayID: displayID)
        }
        panelsByDisplayID.removeAll()
        actualPanelVisibilityStore.removeAllPanels()
        archiveUndoToastsByDisplayID.removeAll()
        dockGroupListChildrenByDisplayID.removeAll()
        dockGroupListGeometryByDisplayID.removeAll()
    }

    // MARK: - Panel sync

    /// `visibility` carries the just-published snapshot when the sync runs from
    /// the store's change emission; other callers omit it to read the current
    /// settled state.
    private func syncPanelsForCurrentScreens(visibility: PickyHUDDockVisibilitySnapshot? = nil) {
        let visibility = visibility ?? visibilityStore.snapshot
        let screens = NSScreen.screens
        let liveDisplayIDs = Set(screens.compactMap(\.pickyDisplayID))

        // Tear down panels for displays that disappeared.
        for displayID in panelsByDisplayID.keys where !liveDisplayIDs.contains(displayID) {
            if let entry = panelsByDisplayID.removeValue(forKey: displayID) {
                entry.pendingShrinkTask?.cancel()
                entry.panel.orderOut(nil)
                actualPanelVisibilityStore.removePanel(for: displayID)
            }
        }
        for displayID in archiveUndoToastsByDisplayID.keys where !liveDisplayIDs.contains(displayID) {
            if let entry = archiveUndoToastsByDisplayID.removeValue(forKey: displayID) {
                entry.dismissTask?.cancel()
                entry.panel.orderOut(nil)
            }
        }
        for displayID in dockGroupListChildrenByDisplayID.keys where !liveDisplayIDs.contains(displayID) {
            hideDockGroupListChild(displayID: displayID)
        }

        // Create or reposition for every connected display, then independently
        // order each panel in or out according to that display's visibility.
        for screen in screens {
            guard let displayID = screen.pickyDisplayID else { continue }
            if panelsByDisplayID[displayID] == nil {
                panelsByDisplayID[displayID] = makePanelEntry(displayID: displayID)
            }
            positionPanel(on: screen, displayID: displayID)
            if visibility.isVisible(for: displayID) {
                panelsByDisplayID[displayID]?.panel.orderFrontRegardless()
            } else {
                panelsByDisplayID[displayID]?.panel.orderOut(nil)
                hideDockGroupListChild(displayID: displayID)
            }
        }
        for displayID in archiveUndoToastsByDisplayID.keys {
            positionArchiveUndoToast(displayID: displayID)
        }
    }

    private func makePanelEntry(displayID: CGDirectDisplayID) -> PanelEntry {
        let initialPanelWidth = panelWidth(for: displayID)
        let hudPanel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialPanelWidth, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Sit below the menu bar (24) and the macOS Dock (`kCGDockWindowLevel` = 20)
        // so the system chrome can cover the HUD when they overlap, while remaining
        // above normal app windows / `.floating` panels.
        hudPanel.level = NSWindow.Level(rawValue: 19)
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = false
        hudPanel.hidesOnDeactivate = false
        hudPanel.isExcludedFromWindowsMenu = true
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let panelIdentifier = NSUserInterfaceItemIdentifier("picky-hud-\(displayID)")
        hudPanel.identifier = panelIdentifier
        actualPanelVisibilityStore.track(hudPanel, for: displayID)
        hudPanel.onActualVisibilityChanged = { [weak self] isVisible in
            guard !isVisible else { return }
            Task { @MainActor in self?.hideDockGroupListChild(displayID: displayID) }
        }

        let initialPosition = position(for: displayID)
        let placement = PickyHUDPlacement(
            dockSide: initialPosition.side,
            dockSizePreset: currentDockSizePreset,
            cardSize: cardSize(for: displayID),
            panelWidth: initialPanelWidth,
            availableDockRailLength: initialAvailableDockRailLength(
                displayID: displayID,
                dockSide: initialPosition.side,
                anchorPercent: initialPosition.anchorPercent
            )
        )
        let openPerformanceTracker = PickyHUDOpenPerformanceTracker()
        let hudRoot = PickyHUDView(
            viewModel: viewModel,
            dockState: viewModel.dockState,
            panelIdentifier: panelIdentifier,
            displayID: displayID,
            placement: placement,
            visibilityStore: visibilityStore,
            actualPanelVisibilityStore: actualPanelVisibilityStore,
            voiceTargetHitTestRegistry: voiceTargetHitTestRegistry,
            openPerformanceTracker: openPerformanceTracker,
            onSizeChange: { [weak self] size, activeSessionID in
                // SwiftUI animates the card reveal itself. Grow the transparent NSPanel
                // immediately, but defer shrinking it until the collapse animation has
                // finished so shadows/content aren't clipped by the outer container.
                guard let self else { return }
                if let activeSessionID,
                   let attemptToken = openPerformanceTracker.activeToken(sessionID: activeSessionID) {
                    self.resizePanel(
                        displayID: displayID,
                        toContentSize: size,
                        deferShrink: true
                    ) { resizeMilliseconds in
                        PickyPerf.event("hud_open_panel_settled")
                        openPerformanceTracker.markPanelSettled(
                            token: attemptToken,
                            panelResizeMilliseconds: resizeMilliseconds
                        )
                    }
                } else {
                    self.resizePanel(displayID: displayID, toContentSize: size, deferShrink: true)
                }
            },
            onDockHandleDragChanged: { [weak self] delta in
                self?.handleDockDragChanged(displayID: displayID, delta: delta)
            },
            onDockHandleDragEnded: { [weak self] in
                self?.handleDockDragEnded()
            },
            onDockHandleDoubleClick: { [weak self] in
                self?.handleDockHandleDoubleClick(displayID: displayID)
            },
            onCardMeasuredSize: { [weak self] size in
                self?.handleCardMeasuredSize(displayID: displayID, size: size)
            },
            onVisibleChromeFramesChange: { [weak self] frames in
                self?.handleVisibleChromeFramesChange(displayID: displayID, frames: frames)
            },
            onCardResizeDragChanged: { [weak self] delta in
                self?.handleCardResizeChanged(displayID: displayID, delta: delta)
            },
            onCardResizeDragEnded: { [weak self] in
                self?.handleCardResizeEnded()
            },
            onCardResizeReset: { [weak self] in
                self?.handleCardResizeReset(displayID: displayID)
            },
            onArchiveUndoRequested: { [weak self] sessionID, title in
                self?.showArchiveUndoToast(displayID: displayID, sessionID: sessionID, title: title)
            },
            onDockGroupListToggle: { [weak self] groupID in
                self?.toggleDockGroupListChild(displayID: displayID, groupID: groupID)
            },
            onDockGroupListClose: { [weak self] in
                self?.hideDockGroupListChild(displayID: displayID)
            },
            onDockGroupListRowSelected: { [weak self] sessionID in
                self?.selectDockGroupListRow(displayID: displayID, sessionID: sessionID)
            },
            dockGroupListFocusStore: dockGroupListFocusStore,
            onDockGroupListGeometryChange: { [weak self] badgeFrames, railFrame, isCommandHintVisible, openedSessionID in
                self?.handleDockGroupListGeometryChange(
                    displayID: displayID,
                    badgeFrames: badgeFrames,
                    railFrame: railFrame,
                    isCommandShortcutHintVisible: isCommandHintVisible,
                    openedSessionID: openedSessionID
                )
            }
        )
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let scaledHudRoot = PickyAppFontScaleRoot(store: fontScaleStore) { hudRoot }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { scaledHudRoot })
        hostingView.frame = NSRect(x: 0, y: 0, width: initialPanelWidth, height: collapsedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hudPanel.contentView = hostingView

        return PanelEntry(
            panel: hudPanel,
            placement: placement,
            pendingShrinkTask: nil,
            lastContentSize: CGSize(width: initialPanelWidth, height: collapsedHeight),
            lastCardMeasuredSize: nil
        )
    }

    private func positionPanel(on screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let entry = panelsByDisplayID[displayID] else { return }
        // Refresh the per-panel placement before sizing so the SwiftUI card uses the
        // latest available height when it computes its natural size. Otherwise the
        // card might keep the stale 1080 cap on the first frame after a screen
        // configuration change or an anchor drag.
        updatePlacement(for: screen, displayID: displayID)
        let contentSize = entry.panel.contentView?.fittingSize ?? entry.lastContentSize
        resizePanel(displayID: displayID, toContentSize: contentSize, deferShrink: false)
    }

    private func updatePlacement(for screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let entry = panelsByDisplayID[displayID] else { return }
        let pos = position(for: displayID)
        let next = computeAvailableCardMaxHeight(
            for: screen,
            dockSide: pos.side,
            anchorPercent: pos.anchorPercent
        )
        // Avoid spamming SwiftUI re-renders with identical values; @Published
        // publishes on every assignment regardless of equality.
        if abs(entry.placement.availableCardMaxHeight - next) > 0.5 {
            PickyPerf.event("placement_publish_available_height")
            entry.placement.availableCardMaxHeight = next
        }
        if entry.placement.dockSide != pos.side {
            PickyPerf.event("placement_publish_dock_side")
            if PickyHUDDockGroupListInteractionPolicy.openGroupIDAfterDockSideChanged() == nil {
                hideDockGroupListChild(displayID: displayID)
            }
            entry.placement.dockSide = pos.side
        }
        let nextDockRailLength = computeAvailableDockRailLength(
            for: screen,
            dockSide: pos.side,
            anchorPercent: pos.anchorPercent
        )
        if abs(entry.placement.availableDockRailLength - nextDockRailLength) > 0.5 {
            entry.placement.availableDockRailLength = nextDockRailLength
        }
        let nextCardSize = cardSize(for: displayID)
        if entry.placement.cardSize != nextCardSize {
            PickyPerf.event("placement_publish_card_size")
            entry.placement.cardSize = nextCardSize
        }
        let nextPanelWidth = panelWidth(for: displayID, dockSide: pos.side)
        if abs(entry.placement.panelWidth - nextPanelWidth) > 0.5 {
            PickyPerf.event("placement_publish_panel_width")
            entry.placement.panelWidth = nextPanelWidth
        }
    }

    /// Largest primary-axis length the dock rail may occupy without extending
    /// beyond the display's visible frame. The rail itself reserves persistent
    /// chrome and scrolls sessions/groups when its content exceeds this budget.
    private func computeAvailableDockRailLength(
        for screen: NSScreen,
        dockSide: PickyHUDDockSide,
        anchorPercent: Double
    ) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return PickyHUDPlacement.defaultAvailableCardMaxHeight
        }
        switch dockSide.orientation {
        case .vertical:
            let dockAnchoredCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
                visibleFrame: visibleFrame,
                topPaddingFromContentTop: PickyHUDExpansion.dockBodyTopOffsetFromContentTop,
                anchorPercent: anchorPercent
            )
            let panelCap = min((visibleFrame.height - 160).rounded(.down), dockAnchoredCap)
            return max(0, panelCap - PickyHUDExpansion.dockShadowVerticalPadding)
        case .horizontal:
            let metrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
            let horizontalChrome = (PickyHUDDockLayout.screenMargin * 2)
                + (PickyHUDExpansion.dockShadowHorizontalPadding * 2)
                + (PickyHUDDockLayout.miniPreviewHorizontalReserve(metrics: metrics) * 2)
            return max(0, visibleFrame.width - horizontalChrome)
        }
    }

    private func initialAvailableDockRailLength(
        displayID: CGDirectDisplayID,
        dockSide: PickyHUDDockSide,
        anchorPercent: Double
    ) -> CGFloat {
        guard let screen = screen(for: displayID) else {
            return PickyHUDPlacement.defaultAvailableCardMaxHeight
        }
        return computeAvailableDockRailLength(
            for: screen,
            dockSide: dockSide,
            anchorPercent: anchorPercent
        )
    }

    /// Largest height the conversation card may take on the given screen, derived
    /// from the live anchor percent and the visible frame. Card content beyond this
    /// scrolls inside `PickyConversationListView` rather than overflowing the panel.
    private func computeAvailableCardMaxHeight(
        for screen: NSScreen,
        dockSide: PickyHUDDockSide,
        anchorPercent: Double
    ) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.height > 0 else {
            return PickyHUDPlacement.defaultAvailableCardMaxHeight
        }
        let topPadding = PickyHUDExpansion.dockBodyTopOffsetFromContentTop
        let visibleHeightCap = (visibleFrame.height - 160).rounded(.down)
        let panelCap: CGFloat
        switch dockSide.orientation {
        case .horizontal:
            // Horizontal mode stacks the dock and card vertically inside the
            // panel. The card's max height has to leave room for the dock
            // rail's cross-axis thickness and the gap between the two so the
            // measured panel height never exceeds `visibleHeightCap` (which
            // `targetFrame` uses as the panel cap in horizontal mode).
            let dockMetrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
            panelCap = max(0, visibleHeightCap - dockMetrics.railWidth - PickyHUDDockLayout.panelGap)
        case .vertical:
            let dockAnchoredCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
                visibleFrame: visibleFrame,
                topPaddingFromContentTop: topPadding,
                anchorPercent: anchorPercent
            )
            panelCap = min(dockAnchoredCap, visibleHeightCap)
        }
        // Subtract the outer vertical padding (top + bottom). The card sits at HStack
        // top alongside the dock-stack VStack, so the card's max usable height is the
        // panel content height minus the outer vertical padding only — the handle
        // area only takes vertical space inside the dock-stack column.
        //
        // Then leave an extra `cardBreathingRoom` pixels of slack so the conversation
        // card never sits right at the cap. Without that buffer, sub-pixel layout
        // measurement drift while the agent streams (composer auto-grow, status pill
        // text length changes, thinking preview rewrites) can cross the cap by
        // fractions of a point and trigger a re-clip mid-frame, which the user sees
        // as a faint twitch on the visible HUD.
        return max(0, panelCap - PickyHUDExpansion.dockShadowVerticalPadding - PickyHUDExpansion.cardBreathingRoom)
    }

    // MARK: - Resizing / placement

    private func handleVisibleChromeFramesChange(displayID: CGDirectDisplayID, frames: [CGRect]) {
        guard var entry = panelsByDisplayID[displayID] else { return }
        entry.visibleChromeFrames = frames
        panelsByDisplayID[displayID] = entry
    }

    /// True when `screenPoint` sits over visibly rendered HUD chrome (dock
    /// rail, conversation card, or an archive-undo toast) on any display.
    /// Used by ink capture: only these points may pass a gesture through.
    func containsInkPassThroughPoint(_ screenPoint: CGPoint) -> Bool {
        for entry in panelsByDisplayID.values where entry.panel.isVisible {
            if PickyHUDInkPassThroughPolicy.contains(
                screenPoint,
                swiftUIFrames: entry.visibleChromeFrames,
                panelFrame: entry.panel.frame
            ) {
                return true
            }
        }
        // Toast and group-list panels are tightly sized around their visible
        // chrome, so the window frame is already an accurate content bound.
        if dockGroupListChildrenByDisplayID.values.contains(where: {
            $0.panel.isVisible && $0.panel.frame.contains(screenPoint)
        }) {
            return true
        }
        return archiveUndoToastsByDisplayID.values.contains {
            $0.panel.isVisible && $0.panel.frame.contains(screenPoint)
        }
    }

    private func resizePanel(
        displayID: CGDirectDisplayID,
        toContentSize contentSize: CGSize,
        deferShrink: Bool,
        completion: ((_ frameUpdateMilliseconds: Int) -> Void)? = nil
    ) {
        PickyPerf.event("panel_resize_requested")
        guard var entry = panelsByDisplayID[displayID] else { return }
        guard let screen = screen(for: displayID) else { return }
        let nextPanelWidth = panelWidth(for: displayID)
        if abs(entry.placement.panelWidth - nextPanelWidth) > 0.5 {
            entry.placement.panelWidth = nextPanelWidth
        }
        let resolvedTargetFrame = PickyPerf.interval("panel_resize_target_frame") {
            self.targetFrame(for: screen, displayID: displayID, contentSize: contentSize)
        }
        guard let targetFrame = resolvedTargetFrame else { return }

        let shouldDeferShrink = PickyHUDExpansion.shouldDeferPanelShrink(
            currentHeight: entry.panel.frame.height,
            targetHeight: targetFrame.height,
            deferShrink: deferShrink
        )

        if shouldDeferShrink {
            entry.pendingShrinkTask?.cancel()
            entry.pendingShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(PickyHUDExpansion.panelShrinkDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if var current = self.panelsByDisplayID[displayID] {
                    current.pendingShrinkTask = nil
                    self.panelsByDisplayID[displayID] = current
                }
                self.resizePanel(
                    displayID: displayID,
                    toContentSize: contentSize,
                    deferShrink: false,
                    completion: completion
                )
            }
            entry.lastContentSize = contentSize
            panelsByDisplayID[displayID] = entry
            return
        }

        entry.pendingShrinkTask?.cancel()
        entry.pendingShrinkTask = nil
        entry.lastContentSize = contentSize
        panelsByDisplayID[displayID] = entry

        if entry.panel.frame.integral != targetFrame.integral {
            if let completion {
                let frameUpdateStartedAt = ProcessInfo.processInfo.systemUptime
                PickyPerf.interval("panel_resize_set_frame") {
                    entry.panel.setFrame(targetFrame, display: true)
                }
                let frameUpdateMilliseconds = max(
                    0,
                    Int(((ProcessInfo.processInfo.systemUptime - frameUpdateStartedAt) * 1_000).rounded())
                )
                completion(frameUpdateMilliseconds)
            } else {
                PickyPerf.interval("panel_resize_set_frame") {
                    entry.panel.setFrame(targetFrame, display: true)
                }
            }
        } else {
            completion?(0)
        }
    }

    private func targetFrame(for screen: NSScreen, displayID: CGDirectDisplayID, contentSize: CGSize) -> NSRect? {
        let pos = position(for: displayID)
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        // Use the dock CAPSULE's top offset so the anchor percent lines up with the
        // visible dock capsule, not just the transparent NSPanel's top edge.
        let topPadding = PickyHUDExpansion.dockBodyTopOffsetFromContentTop
        // Cap and align the panel height to the whole-point frame AppKit will keep.
        // Without this, fractional anchor math can land in `origin.y` for short HUDs
        // but in `height` for capped HUDs; NSPanel then floors one and ceils the other,
        // making the dock jump by 1pt while hovering between sessions.
        let dockMetrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let keepVisible = dockMetrics.railWidth
        let panelWidth = panelWidth(for: displayID, dockSide: pos.side)
        let visibleHeightCap = (visibleFrame.height - 160).rounded(.down)
        let cap: CGFloat
        if pos.side.orientation == .horizontal {
            cap = max(minimumHeight, visibleHeightCap)
        } else {
            let dockAnchoredCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
                visibleFrame: visibleFrame,
                topPaddingFromContentTop: topPadding,
                anchorPercent: pos.anchorPercent
            )
            cap = max(minimumHeight, min(visibleHeightCap, dockAnchoredCap).rounded(.down))
        }
        let clampedHeight = min(max(contentSize.height, minimumHeight), cap)
        let targetHeight = clampedHeight.rounded(.up)

        let safeXOffset: CGFloat
        let safeYOffset: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        if pos.side.orientation == .horizontal {
            let horizontalDockLength = horizontalDockRailLength(
                for: screen,
                displayID: displayID,
                dockSide: pos.side
            )
            safeXOffset = PickyHUDDockLayout.clampedHorizontalXOffset(
                pos.xOffset,
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                dockRailLength: horizontalDockLength,
                keepVisible: keepVisible
            )
            safeYOffset = PickyHUDDockLayout.clampedHorizontalYOffset(
                pos.yOffset,
                visibleFrame: visibleFrame,
                panelHeight: targetHeight,
                dockSide: pos.side,
                dockRailHeight: dockMetrics.railWidth
            )
            originX = PickyHUDDockLayout.horizontalPanelX(
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                xOffset: safeXOffset,
                dockRailLength: horizontalDockLength,
                keepVisible: keepVisible
            )
            originY = PickyHUDDockLayout.horizontalPanelY(
                visibleFrame: visibleFrame,
                targetHeight: targetHeight,
                dockSide: pos.side,
                yOffset: safeYOffset
            )
        } else {
            safeXOffset = PickyHUDDockLayout.clampedXOffset(
                pos.xOffset,
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                dockSide: pos.side,
                dockRailWidth: dockMetrics.railWidth
            )
            safeYOffset = 0
            originX = PickyHUDDockLayout.panelX(
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                dockSide: pos.side,
                xOffset: safeXOffset
            )
            originY = PickyHUDDockLayout.dockTopAnchoredPointAlignedPanelY(
                visibleFrame: visibleFrame,
                targetHeight: targetHeight,
                topPaddingFromContentTop: topPadding,
                anchorPercent: pos.anchorPercent
            )
        }
        if safeXOffset != pos.xOffset || safeYOffset != pos.yOffset {
            var normalizedPosition = pos
            normalizedPosition.xOffset = safeXOffset
            normalizedPosition.yOffset = safeYOffset
            setPosition(normalizedPosition, for: displayID)
        }

        return NSRect(
            x: originX,
            y: originY,
            width: panelWidth,
            height: targetHeight
        )
    }

    // MARK: - Dock group list child panel

    private func handleDockGroupListGeometryChange(
        displayID: CGDirectDisplayID,
        badgeFrames: [String: CGRect],
        railFrame: CGRect,
        isCommandShortcutHintVisible _: Bool,
        openedSessionID: String?
    ) {
        let geometry = DockGroupListGeometry(
            badgeFrames: badgeFrames,
            railFrame: railFrame,
            openedSessionID: openedSessionID
        )
        dockGroupListGeometryByDisplayID[displayID] = geometry
        guard var entry = dockGroupListChildrenByDisplayID[displayID] else { return }
        let needsContentSync = entry.badgeFrames != geometry.badgeFrames
            || entry.railFrame != geometry.railFrame
            || entry.openedSessionID != geometry.openedSessionID
        entry.badgeFrames = geometry.badgeFrames
        entry.railFrame = geometry.railFrame
        entry.openedSessionID = geometry.openedSessionID
        dockGroupListChildrenByDisplayID[displayID] = entry
        if let pendingGroupID = PickyHUDDockGroupListOpenPolicy.pendingGroupIDReadyToOpen(
            entry.pendingGroupID,
            anchoredGroupIDs: Set(entry.badgeFrames.keys),
            hasRailFrame: entry.railFrame != .zero
        ) {
            showDockGroupListChild(displayID: displayID, groupID: pendingGroupID)
        } else if entry.openGroupID != nil, needsContentSync {
            syncDockGroupListChild(displayID: displayID)
        }
    }

    private func toggleDockGroupListChild(displayID: CGDirectDisplayID, groupID: String) {
        let entry = dockGroupListChildrenByDisplayID[displayID]
        let openGroupID = entry?.openGroupID ?? entry?.pendingGroupID
        let nextGroupID = PickyHUDDockGroupListOpenPolicy.toggled(
            openGroupID: openGroupID,
            tappedGroupID: groupID
        )
        guard let nextGroupID else {
            hideDockGroupListChild(displayID: displayID)
            return
        }
        showDockGroupListChild(displayID: displayID, groupID: nextGroupID)
    }

    private func showDockGroupListChild(displayID: CGDirectDisplayID, groupID: String) {
        guard visibilityStore.isVisible(for: displayID),
              let group = viewModel.dockState.snapshot.dockLayout.group(withID: groupID),
              let screen = screen(for: displayID),
              let hudEntry = panelsByDisplayID[displayID]
        else { return }

        var entry = dockGroupListChildrenByDisplayID[displayID]
            ?? DockGroupListChildEntry(panel: makeDockGroupListChildPanel())
        if let geometry = dockGroupListGeometryByDisplayID[displayID] {
            entry.badgeFrames = geometry.badgeFrames
            entry.railFrame = geometry.railFrame
            entry.openedSessionID = geometry.openedSessionID
        }
        if entry.openGroupID != nil {
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
        }
        entry.pendingGroupID = PickyHUDDockGroupListOpenPolicy.pendingGroupID(afterRequestFor: groupID)
        entry.openGroupID = nil
        dockGroupListChildrenByDisplayID[displayID] = entry
        guard let folderFrame = entry.badgeFrames[groupID],
              entry.railFrame != .zero
        else {
            pickySessionLog("dock group list open deferred group=\(groupID) display=\(displayID) reason=missing-anchor-geometry")
            return
        }

        entry.pendingGroupID = nil
        entry.openGroupID = groupID
        dockGroupListFocusStore.open(
            displayID: displayID,
            groupID: groupID,
            rowIDs: dockGroupListRowIDs(group: group),
            openedSessionID: entry.openedSessionID
        )
        entry.panel.contentView = makeDockGroupListChildHostingView(
            displayID: displayID,
            group: group,
            entry: entry
        )
        dockGroupListChildrenByDisplayID[displayID] = entry
        positionDockGroupListChild(
            displayID: displayID,
            screen: screen,
            hudPanelFrame: hudEntry.panel.frame,
            folderFrame: folderFrame
        )
        entry.panel.alphaValue = 0
        entry.panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            entry.panel.animator().alphaValue = 1
        }
        installDockGroupListMouseMonitors(displayID: displayID)
    }

    private func syncDockGroupListChild(displayID: CGDirectDisplayID) {
        guard var entry = dockGroupListChildrenByDisplayID[displayID] else { return }
        let existingGroupIDs = Set(viewModel.dockState.snapshot.dockLayout.groups.map(\.id))
        entry.pendingGroupID = PickyHUDDockGroupListOpenPolicy.reconciledPendingGroupID(
            entry.pendingGroupID,
            existingGroupIDs: existingGroupIDs
        )
        dockGroupListChildrenByDisplayID[displayID] = entry
        if let pendingGroupID = entry.pendingGroupID {
            showDockGroupListChild(displayID: displayID, groupID: pendingGroupID)
            return
        }
        guard let groupID = entry.openGroupID else { return }
        guard let group = viewModel.dockState.snapshot.dockLayout.group(withID: groupID),
              let folderFrame = entry.badgeFrames[groupID],
              entry.railFrame != .zero,
              let screen = screen(for: displayID),
              let hudEntry = panelsByDisplayID[displayID]
        else {
            let nextGroupID = PickyHUDDockGroupListOpenPolicy.afterGroupRemoved(
                openGroupID: groupID,
                removedGroupID: groupID
            )
            if nextGroupID == nil { hideDockGroupListChild(displayID: displayID) }
            return
        }
        dockGroupListFocusStore.updateRows(displayID: displayID, rowIDs: dockGroupListRowIDs(group: group))
        entry.panel.contentView = makeDockGroupListChildHostingView(
            displayID: displayID,
            group: group,
            entry: entry
        )
        positionDockGroupListChild(
            displayID: displayID,
            screen: screen,
            hudPanelFrame: hudEntry.panel.frame,
            folderFrame: folderFrame
        )
    }

    /// Visible rows only: archived members stay in the group but never render,
    /// so they must not be reachable by number or arrow keys either.
    private func dockGroupListRowIDs(group: PickyDockGroup) -> [String] {
        let activeIDs = Set(viewModel.dockState.snapshot.activeSessions.map(\.id))
        return group.memberSessionIDs.filter { activeIDs.contains($0) }
    }

    private func makeDockGroupListChildPanel() -> PickyHUDDockGroupListPanel {
        let panel = PickyHUDDockGroupListPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: 19)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func makeDockGroupListChildHostingView(
        displayID: CGDirectDisplayID,
        group: PickyDockGroup,
        entry: DockGroupListChildEntry
    ) -> NSView {
        let snapshot = viewModel.dockState.snapshot
        let sessionsByID = Dictionary(snapshot.activeSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = PickyHUDDockGroupListRowProjection.rows(
            memberSessionIDs: group.memberSessionIDs,
            activeSessionsByID: sessionsByID,
            updatedAt: { [weak self] sessionID in self?.viewModel.sessionCard(sessionID: sessionID)?.updatedAt },
            makeRow: { session, updatedAt in
                PickyHUDDockGroupListRowModel(session: session, updatedAt: updatedAt)
            }
        )
        let metrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let root = PickyAppFontScaleRoot(store: self.fontScaleStore) { [self] in
            PickyHUDDockGroupListPanelRoot(
                group: group,
                rows: rows,
                unreadSessionIDs: snapshot.unreadSessionIDs,
                openedSessionID: entry.openedSessionID,
                displayID: displayID,
                focusStore: dockGroupListFocusStore,
                metrics: metrics,
                onSelectSession: { [weak self] sessionID in
                    self?.selectDockGroupListRow(displayID: displayID, sessionID: sessionID)
                },
                onCreatePickle: { [weak self] in
                    self?.requestDockGroupListPickleCreation(displayID: displayID, groupID: group.id)
                },
                moveTargetGroups: snapshot.dockLayout.groups.filter { $0.id != group.id },
                screenContextTargetSessionID: snapshot.screenContextTargetSessionID,
                screenContextTargetSticky: snapshot.screenContextTargetSticky,
                onToggleScreenContextTarget: { [weak self] sessionID in
                    self?.viewModel.toggleScreenContextTarget(sessionID: sessionID)
                },
                onToggleStickyScreenContextTarget: { [weak self] sessionID in
                    self?.viewModel.toggleStickyScreenContextTarget(sessionID: sessionID)
                },
                onCompactSession: { [weak self] sessionID in
                    Task { await self?.viewModel.requestCompaction(sessionID: sessionID) }
                },
                onArchiveSession: { [weak self] sessionID in
                    self?.archiveDockGroupListSession(displayID: displayID, sessionID: sessionID)
                },
                onStopSession: { [weak self] sessionID in
                    Task { try? await self?.viewModel.abortRestoringQueuedInputs(sessionID: sessionID) }
                },
                onMoveSessionToGroup: { [weak self] sessionID, groupID in
                    guard let self,
                          let target = self.viewModel.dockState.snapshot.dockLayout.group(withID: groupID)
                    else { return }
                    self.viewModel.moveSessionInDock(
                        sessionID: sessionID,
                        to: .group(id: groupID, memberIndex: target.memberSessionIDs.count)
                    )
                },
                onUngroupSession: { [weak self] sessionID in
                    self?.ungroupDockGroupListSession(sessionID: sessionID)
                },
                onReorderSession: { [weak self] sessionID, visibleIndex in
                    self?.reorderDockGroupListSession(
                        groupID: group.id,
                        sessionID: sessionID,
                        visibleIndex: visibleIndex
                    )
                },
                convertScreenPointToPanel: { [weak panel = entry.panel] screenPoint in
                    guard let panel else { return .zero }
                    return PickyHUDDockGroupListScreenLayout.panelLocalPoint(
                        screenPoint: screenPoint,
                        panelFrame: panel.frame
                    )
                }
            )
            .environmentObject(self.appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: self.appearanceStore))
        }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { root })
        let panelSize = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: max(1, rows.count),
            metrics: metrics,
            fontScale: fontScaleStore.cgValue
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        return hostingView
    }

    private func positionDockGroupListChild(
        displayID: CGDirectDisplayID,
        screen: NSScreen,
        hudPanelFrame: CGRect,
        folderFrame: CGRect
    ) {
        guard let entry = dockGroupListChildrenByDisplayID[displayID],
              let groupID = entry.openGroupID,
              let group = viewModel.dockState.snapshot.dockLayout.group(withID: groupID)
        else { return }
        let memberCount = max(1, group.memberSessionIDs.filter { sessionID in
            viewModel.dockState.snapshot.activeSessions.contains(where: { $0.id == sessionID })
        }.count)
        let metrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let panelSize = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: memberCount,
            metrics: metrics,
            fontScale: fontScaleStore.cgValue
        )
        let side = position(for: displayID).side
        let anchoredOrigin = PickyHUDDockGroupListPolicy.anchoredOrigin(
            folderFrame: folderFrame,
            railFrame: entry.railFrame,
            panelSize: panelSize,
            dockSide: side,
            panelGap: PickyHUDDockLayout.panelGap
        )
        let origin = PickyHUDDockGroupListPolicy.clampedOrigin(
            anchoredOrigin,
            panelSize: panelSize,
            bounds: PickyHUDDockGroupListScreenLayout.hudRootBounds(
                visibleFrame: screen.visibleFrame,
                hudPanelFrame: hudPanelFrame
            ),
            dockSide: side,
            margin: PickyHUDDockLayout.screenMargin
        )
        let frame = PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudPanelFrame,
            swiftUIOrigin: origin,
            panelSize: panelSize
        )
        if entry.panel.frame.integral != frame.integral {
            entry.panel.setFrame(frame, display: true)
        }
    }

    private func selectDockGroupListRow(displayID: CGDirectDisplayID, sessionID: String) {
        let result = PickyHUDDockGroupListInteractionPolicy.selectionResult(
            sessionID: sessionID,
            openGroupID: dockGroupListChildrenByDisplayID[displayID]?.openGroupID
        )
        viewModel.requestOpenSession(sessionID: result.openedSessionID, targetDisplayID: displayID)
        hideDockGroupListChild(displayID: displayID)
    }

    private func archiveDockGroupListSession(displayID: CGDirectDisplayID, sessionID: String) {
        let snapshot = viewModel.dockState.snapshot
        let title = snapshot.activeSessions.first(where: { $0.id == sessionID })?.title
            ?? viewModel.sessionCard(sessionID: sessionID)?.title
            ?? L10n.t("group.list.fallbackTitle")
        viewModel.archive(sessionID: sessionID)
        showArchiveUndoToast(displayID: displayID, sessionID: sessionID, title: title)
    }

    /// A drop position among the rendered rows is not a stored member index:
    /// archived members stay in `memberSessionIDs` without rendering, so the
    /// visible index has to be translated before the move is emitted.
    private func reorderDockGroupListSession(groupID: String, sessionID: String, visibleIndex: Int) {
        let snapshot = viewModel.dockState.snapshot
        guard let group = snapshot.dockLayout.group(withID: groupID) else { return }
        let memberIndex = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: visibleIndex,
            memberSessionIDs: group.memberSessionIDs,
            activeSessionIDs: Set(snapshot.activeSessions.map(\.id))
        )
        viewModel.moveSessionInDock(
            sessionID: sessionID,
            to: .group(id: groupID, memberIndex: memberIndex)
        )
    }

    private func ungroupDockGroupListSession(sessionID: String) {
        let layout = viewModel.dockState.snapshot.dockLayout
        guard let source = layout.container(forSessionID: sessionID),
              case .group(let groupID, _) = source,
              let groupIndex = layout.entries.firstIndex(where: { entry in
                  if case .group(let group) = entry { return group.id == groupID }
                  return false
              })
        else { return }
        viewModel.moveSessionInDock(sessionID: sessionID, to: .topLevel(index: groupIndex + 1))
    }

    private func requestDockGroupListPickleCreation(displayID: CGDirectDisplayID, groupID: String) {
        guard let entry = panelsByDisplayID[displayID] else { return }
        hideDockGroupListChild(displayID: displayID)
        entry.placement.dockGroupListCreateRequestGroupID = groupID
    }

    private func installDockGroupListMouseMonitors(displayID: CGDirectDisplayID) {
        guard var entry = dockGroupListChildrenByDisplayID[displayID], entry.localMouseDownMonitor == nil else { return }
        entry.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.dismissDockGroupListForOutsideMouseDown(displayID: displayID, event: event) }
            return event
        }
        entry.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.dismissDockGroupListForOutsideMouseDown(displayID: displayID, event: event) }
        }
        dockGroupListChildrenByDisplayID[displayID] = entry
    }

    private func dismissDockGroupListForOutsideMouseDown(displayID: CGDirectDisplayID, event: NSEvent) {
        guard let entry = dockGroupListChildrenByDisplayID[displayID], entry.openGroupID != nil else { return }
        let screenPoint: CGPoint
        if let window = event.window {
            screenPoint = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        guard !entry.panel.frame.contains(screenPoint) else { return }
        if let hudEntry = panelsByDisplayID[displayID] {
            let railFrame = PickyHUDDockGroupListScreenLayout.screenFrame(
                hudPanelFrame: hudEntry.panel.frame,
                swiftUIOrigin: entry.railFrame.origin,
                panelSize: entry.railFrame.size
            )
            guard !railFrame.contains(screenPoint) else { return }
        }
        hideDockGroupListChild(displayID: displayID)
    }

    private func hideDockGroupListChild(displayID: CGDirectDisplayID) {
        dockGroupListFocusStore.close(displayID: displayID)
        guard let entry = dockGroupListChildrenByDisplayID.removeValue(forKey: displayID) else { return }
        if let localMouseDownMonitor = entry.localMouseDownMonitor { NSEvent.removeMonitor(localMouseDownMonitor) }
        if let globalMouseDownMonitor = entry.globalMouseDownMonitor { NSEvent.removeMonitor(globalMouseDownMonitor) }
        entry.panel.orderOut(nil)
        entry.panel.contentView = nil
    }

    private func syncDockGroupListChildrenWithSnapshot() {
        for displayID in dockGroupListChildrenByDisplayID.keys {
            syncDockGroupListChild(displayID: displayID)
        }
    }

    // MARK: - Archive undo toast

    private func showArchiveUndoToast(displayID: CGDirectDisplayID, sessionID: String, title: String) {
        guard visibilityStore.isVisible(for: displayID), screen(for: displayID) != nil else { return }
        let toast = PickyHUDArchiveUndoToast(sessionID: sessionID, title: title)
        var entry = archiveUndoToastsByDisplayID[displayID] ?? makeArchiveUndoToastEntry()
        entry.dismissTask?.cancel()
        entry.toast = toast
        entry.panel.contentView = makeArchiveUndoToastHostingView(displayID: displayID, toast: toast)
        entry.panel.alphaValue = 0
        archiveUndoToastsByDisplayID[displayID] = entry
        positionArchiveUndoToast(displayID: displayID)
        entry.panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PickyHUDExpansion.duration
            entry.panel.animator().alphaValue = 1
        }
        entry.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: PickyHUDArchiveUndoToastPolicy.durationNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.archiveUndoToastsByDisplayID[displayID]?.toast?.id == toast.id else { return }
            self.hideArchiveUndoToast(displayID: displayID, expectedToastID: toast.id)
        }
        archiveUndoToastsByDisplayID[displayID] = entry
    }

    private func makeArchiveUndoToastEntry() -> ArchiveUndoToastEntry {
        let panel = PickyHUDPanel(
            contentRect: NSRect(origin: .zero, size: PickyHUDArchiveUndoToastPolicy.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return ArchiveUndoToastEntry(panel: panel, dismissTask: nil, toast: nil)
    }

    private func makeArchiveUndoToastHostingView(displayID: CGDirectDisplayID, toast: PickyHUDArchiveUndoToast) -> NSView {
        let root = PickyAppFontScaleRoot(store: fontScaleStore) {
            PickyHUDArchiveUndoToastPanelRoot(
                toast: toast,
                onUndo: { [weak self] in
                    self?.undoArchiveFromToast(displayID: displayID, toast: toast)
                }
            )
            .environmentObject(self.appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: self.appearanceStore))
        }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { root })
        hostingView.frame = NSRect(origin: .zero, size: PickyHUDArchiveUndoToastPolicy.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        return hostingView
    }

    private func positionArchiveUndoToast(displayID: CGDirectDisplayID) {
        guard let screen = screen(for: displayID), let entry = archiveUndoToastsByDisplayID[displayID] else { return }
        let frame = PickyHUDArchiveUndoToastLayout.panelFrame(visibleFrame: screen.visibleFrame)
        if entry.panel.frame.integral != frame.integral {
            entry.panel.setFrame(frame, display: true)
        }
    }

    private func undoArchiveFromToast(displayID: CGDirectDisplayID, toast: PickyHUDArchiveUndoToast) {
        guard archiveUndoToastsByDisplayID[displayID]?.toast?.id == toast.id else { return }
        viewModel.unarchive(sessionID: toast.sessionID)
        hideArchiveUndoToast(displayID: displayID, expectedToastID: toast.id)
    }

    private func hideArchiveUndoToast(displayID: CGDirectDisplayID, expectedToastID: UUID? = nil) {
        guard var entry = archiveUndoToastsByDisplayID[displayID] else { return }
        if let expectedToastID, entry.toast?.id != expectedToastID { return }
        entry.dismissTask?.cancel()
        entry.dismissTask = nil
        entry.toast = nil
        archiveUndoToastsByDisplayID[displayID] = entry
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PickyHUDExpansion.duration
            entry.panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel = entry.panel] in
            Task { @MainActor in
                guard let current = self?.archiveUndoToastsByDisplayID[displayID], current.toast == nil else { return }
                panel?.orderOut(nil)
                self?.archiveUndoToastsByDisplayID.removeValue(forKey: displayID)
            }
        }
    }

    // MARK: - Dock handle drag / reset

    private func handleDockHandleDoubleClick(displayID: CGDirectDisplayID) {
        dragStartPositionsByDisplayID = nil
        var pos = position(for: displayID)
        pos.side = pos.side.orientationToggled(anchorPercent: pos.anchorPercent)
        pos.xOffset = 0
        pos.yOffset = 0
        setPosition(pos, for: displayID)
        // Only update the placement for this display so other monitors stay put.
        if let entry = panelsByDisplayID[displayID] {
            entry.placement.dockSide = pos.side
        }
        repositionAllPanels()

        let positionsByDisplayID = currentPositionsByDisplayID
        settingsPersistence.enqueue { $0.hudDockPositions = positionsByDisplayID }
    }

    private func handleDockDragChanged(displayID: CGDirectDisplayID, delta: CGPoint) {
        guard let screen = screen(for: displayID) else { return }
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return }

        var pos = position(for: displayID)

        if dragStartPositionsByDisplayID == nil {
            dragStartPositionsByDisplayID = currentPositionsByDisplayID
        }
        let startPositions = dragStartPositionsByDisplayID ?? currentPositionsByDisplayID
        let startPos = PickyHUDDockPosition.resolved(
            in: startPositions,
            displayKey: String(displayID)
        )

        let dockMetrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let keepVisible = dockMetrics.railWidth
        let startPanelWidth = panelWidth(for: displayID, dockSide: startPos.side)
        if startPos.side.orientation == .horizontal {
            let horizontalDockLength = horizontalDockRailLength(
                for: screen,
                displayID: displayID,
                dockSide: startPos.side
            )
            // -- X axis: along-axis position from screen center --
            pos.xOffset = PickyHUDDockLayout.clampedHorizontalXOffset(
                startPos.xOffset + delta.x,
                visibleFrame: visibleFrame,
                panelWidth: startPanelWidth,
                dockRailLength: horizontalDockLength,
                keepVisible: keepVisible
            )
            // -- Y axis: cross-axis nudge from anchored edge + top/bottom snap --
            let nextYOffsetRaw = startPos.yOffset + delta.y
            // Panel height is unknown during the drag, but for snap purposes we
            // only care about the dock CENTER's screen Y. Approximate using the
            // rail thickness — that's what `horizontalPanelY` derives from too.
            let railThickness = dockMetrics.railWidth
            let startDockCenterY: CGFloat = startPos.side == .top
                ? visibleFrame.maxY - PickyHUDDockLayout.dockEdgeMargin - (railThickness / 2)
                : visibleFrame.minY + PickyHUDDockLayout.dockEdgeMargin + (railThickness / 2)
            let draggedDockCenterY = startDockCenterY + delta.y
            pos.side = PickyHUDDockLayout.horizontalDockSide(
                forDockRailCenterY: draggedDockCenterY,
                visibleFrame: visibleFrame,
                currentSide: pos.side
            )
            // Reset cross-axis offset when the snap flips edges so the dock
            // lands cleanly on the new edge instead of carrying over a stale
            // overshoot from the dragged-from edge.
            if pos.side != startPos.side {
                pos.yOffset = 0
            } else {
                let panelHeight = panelsByDisplayID[displayID]?.panel.frame.height ?? railThickness
                pos.yOffset = PickyHUDDockLayout.clampedHorizontalYOffset(
                    nextYOffsetRaw,
                    visibleFrame: visibleFrame,
                    panelHeight: panelHeight,
                    dockSide: pos.side,
                    dockRailHeight: railThickness
                )
            }
        } else {
            // -- Y axis: anchor percent --
            let dPct = -(Double(delta.y) / Double(visibleFrame.height)) * 100.0
            let maxAnchorPercent = PickyHUDDockLayout.maxDockTopAnchorPercent(
                visibleHeight: visibleFrame.height,
                keepVisible: keepVisible
            )
            pos.anchorPercent = min(
                PickySettings.clampedDockTopAnchorPercent(startPos.anchorPercent + dPct),
                maxAnchorPercent
            )

            // -- X axis: horizontal offset and side --
            let draggedDockCenterX = PickyHUDDockLayout.dockRailCenterX(
                visibleFrame: visibleFrame,
                panelWidth: startPanelWidth,
                dockSide: startPos.side,
                xOffset: startPos.xOffset,
                dockRailWidth: dockMetrics.railWidth
            ) + delta.x
            pos.side = PickyHUDDockLayout.dockSide(
                forDockRailCenterX: draggedDockCenterX,
                visibleFrame: visibleFrame,
                currentSide: pos.side
            )
            pos.xOffset = PickyHUDDockLayout.xOffset(
                forDockRailCenterX: draggedDockCenterX,
                visibleFrame: visibleFrame,
                panelWidth: panelWidth(for: displayID, dockSide: pos.side),
                dockSide: pos.side,
                dockRailWidth: dockMetrics.railWidth
            )
        }

        setPosition(pos, for: displayID)
        repositionAllPanels()
    }

    private func handleDockDragEnded() {
        dragStartPositionsByDisplayID = nil
        let positionsByDisplayID = currentPositionsByDisplayID
        settingsPersistence.enqueue { $0.hudDockPositions = positionsByDisplayID }
    }

    private func handleCardMeasuredSize(displayID: CGDirectDisplayID, size: CGSize) {
        PickyPerf.event("overlay_card_measured_size")
        guard size.width > 0, size.height > 0, var entry = panelsByDisplayID[displayID] else { return }
        if let last = entry.lastCardMeasuredSize,
           abs(last.width - size.width) <= 0.5,
           abs(last.height - size.height) <= 0.5 {
            return
        }
        entry.lastCardMeasuredSize = size
        panelsByDisplayID[displayID] = entry
    }

    private func handleCardResizeChanged(displayID: CGDirectDisplayID, delta: CGPoint) {
        guard let screen = screen(for: displayID), let entry = panelsByDisplayID[displayID] else { return }
        let displayKey = String(displayID)
        if resizeStartCardSizesByDisplayID == nil {
            resizeStartCardSizesByDisplayID = PickyHUDDockLayout.resizeStartCardSizes(
                storedSizes: currentCardSizesByDisplayID,
                displayKey: displayKey,
                measuredSize: entry.lastCardMeasuredSize,
                maxHeight: entry.placement.availableCardMaxHeight
            )
        }
        let startSizes = resizeStartCardSizesByDisplayID ?? currentCardSizesByDisplayID
        guard let startSize = startSizes[displayKey] else { return }
        let pos = position(for: displayID)
        let next = PickyHUDDockLayout.resizedCardSize(
            from: startSize,
            delta: delta,
            dockSide: pos.side,
            maxWidth: computeAvailableCardMaxWidth(for: screen, dockSide: pos.side),
            maxHeight: computeAvailableCardMaxHeight(for: screen, dockSide: pos.side, anchorPercent: pos.anchorPercent)
        )
        currentCardSizesByDisplayID[String(displayID)] = next
        entry.placement.cardSize = next
        entry.placement.panelWidth = panelWidth(for: displayID, dockSide: pos.side)
        repositionAllPanels()
    }

    private func handleCardResizeEnded() {
        resizeStartCardSizesByDisplayID = nil
        let cardSizesByDisplayID = currentCardSizesByDisplayID
        settingsPersistence.enqueue { $0.hudCardSizes = cardSizesByDisplayID }
    }

    private func handleCardResizeReset(displayID: CGDirectDisplayID) {
        resizeStartCardSizesByDisplayID = nil
        currentCardSizesByDisplayID.removeValue(forKey: String(displayID))
        if let entry = panelsByDisplayID[displayID] {
            entry.placement.cardSize = nil
            entry.placement.panelWidth = panelWidth(for: displayID)
        }
        repositionAllPanels()
        let cardSizesByDisplayID = currentCardSizesByDisplayID
        settingsPersistence.enqueue { $0.hudCardSizes = cardSizesByDisplayID }
    }

    private func computeAvailableCardMaxWidth(for screen: NSScreen, dockSide: PickyHUDDockSide) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0 else { return PickyHUDCardSize.widthRange.upperBound }
        let dockMetrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let sideReserve: CGFloat
        switch dockSide.orientation {
        case .vertical:
            sideReserve = dockMetrics.railWidth + PickyHUDDockLayout.panelGap + (PickyHUDExpansion.dockShadowHorizontalPadding * 2) + (PickyHUDDockLayout.screenMargin * 2)
        case .horizontal:
            sideReserve = (PickyHUDExpansion.dockShadowHorizontalPadding * 2) + (PickyHUDDockLayout.screenMargin * 2)
        }
        return max(PickyHUDCardSize.widthRange.lowerBound, visibleFrame.width - sideReserve)
    }

    private func repositionAllPanels() {
        for screen in NSScreen.screens {
            guard let displayID = screen.pickyDisplayID else { continue }
            guard panelsByDisplayID[displayID] != nil else { continue }
            positionPanel(on: screen, displayID: displayID)
        }
        for displayID in archiveUndoToastsByDisplayID.keys {
            positionArchiveUndoToast(displayID: displayID)
        }
        for displayID in dockGroupListChildrenByDisplayID.keys {
            syncDockGroupListChild(displayID: displayID)
        }
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.pickyDisplayID == displayID }
    }

    // MARK: - Screen reconfiguration

    private func startScreenParametersObserver() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncPanelsForCurrentScreens() }
        }
    }

    private func stopScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
    }

    private func startSettingsObserver() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .pickySettingsDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let settings = self.settingsStore.load()
                self.currentCardSizesByDisplayID = settings.hudCardSizes
                self.applyDockSizePreset(settings.hudDockSizePreset)
            }
        }
    }

    private func stopSettingsObserver() {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        settingsObserver = nil
    }

    private func applyDockSizePreset(_ preset: PickyHUDDockSizePreset) {
        guard preset != currentDockSizePreset else { return }
        currentDockSizePreset = preset
        for displayID in dockGroupListChildrenByDisplayID.keys {
            hideDockGroupListChild(displayID: displayID)
        }
        for displayID in panelsByDisplayID.keys {
            panelsByDisplayID[displayID]?.placement.dockSizePreset = preset
            panelsByDisplayID[displayID]?.placement.panelWidth = panelWidth(for: displayID)
        }
        syncPanelsForCurrentScreens()
    }
}

extension NSScreen {
    /// `CGDirectDisplayID` is stable across screen reconfigurations, while
    /// `NSScreen` instance identity is not. Returns `nil` for headless or
    /// unrecognized screens so callers can skip them.
    var pickyDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

