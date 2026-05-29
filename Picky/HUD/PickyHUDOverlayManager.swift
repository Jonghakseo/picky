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
import SwiftUI

final class PickyHUDPanel: NSPanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
            if !clickHitsFocusedControl(event) {
                resignFocusedControl()
            }
        }
        super.sendEvent(event)
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
        guard firstResponder != nil else { return false }
        return makeFirstResponder(nil)
    }
}

@MainActor
final class PickyHUDOverlayManager {
    private let viewModel: PickySessionListViewModel
    private let appearanceStore: PickyAppearanceStore
    private let fontScaleStore: PickyAppFontScaleStore
    private let settingsStore: PickySettingsStore
    private let onOpenFullscreenSession: (String?) -> Void
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
    }

    private struct ArchiveUndoToastEntry {
        let panel: PickyHUDPanel
        var dismissTask: Task<Void, Never>?
        var toast: PickyHUDArchiveUndoToast?
    }

    private var panelsByDisplayID: [CGDirectDisplayID: PanelEntry] = [:]
    private var archiveUndoToastsByDisplayID: [CGDirectDisplayID: ArchiveUndoToastEntry] = [:]
    private var isHiddenForFullscreen = false
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
    /// Per-display dock group collapse overrides keyed by display ID, then
    /// group ID. Each monitor manages its collapsed groups independently.
    private var dockGroupCollapseByDisplayID: [String: [String: Bool]]

    init(
        viewModel: PickySessionListViewModel,
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        settingsStore: PickySettingsStore,
        onOpenFullscreenSession: @escaping (String?) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
        self.settingsStore = settingsStore
        self.onOpenFullscreenSession = onOpenFullscreenSession
        let settings = settingsStore.load()
        self.currentPositionsByDisplayID = settings.hudDockPositions
        self.currentDockSizePreset = settings.hudDockSizePreset
        self.currentCardSizesByDisplayID = settings.hudCardSizes
        self.dockGroupCollapseByDisplayID = settings.hudDockGroupCollapse
    }

    private func dockGroupCollapse(for displayID: CGDirectDisplayID) -> [String: Bool] {
        dockGroupCollapseByDisplayID[String(displayID)] ?? [:]
    }

    /// Store this display's collapse overrides and persist to Settings so the
    /// per-monitor collapse state survives relaunch.
    private func handleDockGroupCollapseChanged(displayID: CGDirectDisplayID, overrides: [String: Bool]) {
        dockGroupCollapseByDisplayID[String(displayID)] = overrides
        var settings = settingsStore.load()
        settings.hudDockGroupCollapse = dockGroupCollapseByDisplayID
        try? settingsStore.save(settings)
    }

    /// Get the live position for a display. Returns defaults for unknown displays.
    private func position(for displayID: CGDirectDisplayID) -> PickyHUDDockPosition {
        PickyHUDDockPosition.resolved(
            in: currentPositionsByDisplayID,
            displayKey: String(displayID)
        )
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
        return PickyHUDDockLayout.panelWidth(
            cardWidth: cardWidth(for: displayID),
            dockSide: side,
            sessionCount: visibleSessionCount(),
            isAddSlotExpanded: false,
            metrics: PickyHUDDockMetrics(preset: currentDockSizePreset)
        )
    }

    /// Number of session tiles currently rendered in the dock rail. Caps at
    /// `visibleSessionLimit` to match `PickyHUDView.visibleSessions` so the
    /// dock-length math used for horizontal X clamping matches what's on
    /// screen.
    private func visibleSessionCount() -> Int {
        min(viewModel.sessions.count, PickyHUDDockLayout.visibleSessionLimit)
    }

    func start() {
        viewModel.start()
        syncPanelsForCurrentScreens()
        startScreenParametersObserver()
        startSettingsObserver()
    }

    /// Opens the given session in the HUD dock. Used when the user taps a macOS
    /// notification banner; selection alone is not enough because each HUD view keeps
    /// its open card in local `heldSession` state.
    func focusSession(id: String) {
        viewModel.requestOpenSession(sessionID: id)
        for (_, entry) in panelsByDisplayID {
            entry.panel.orderFrontRegardless()
        }
    }

    func stop() {
        stopScreenParametersObserver()
        stopSettingsObserver()
        viewModel.stop()
        tearDownPanels()
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
        panelsByDisplayID.removeAll()
        archiveUndoToastsByDisplayID.removeAll()
    }

    // MARK: - Panel sync

    private func syncPanelsForCurrentScreens() {
        guard !isHiddenForFullscreen else {
            tearDownPanels()
            return
        }

        let screens = NSScreen.screens
        let liveDisplayIDs = Set(screens.compactMap(\.pickyDisplayID))

        // Tear down panels for displays that disappeared.
        for displayID in panelsByDisplayID.keys where !liveDisplayIDs.contains(displayID) {
            if let entry = panelsByDisplayID.removeValue(forKey: displayID) {
                entry.pendingShrinkTask?.cancel()
                entry.panel.orderOut(nil)
            }
        }
        for displayID in archiveUndoToastsByDisplayID.keys where !liveDisplayIDs.contains(displayID) {
            if let entry = archiveUndoToastsByDisplayID.removeValue(forKey: displayID) {
                entry.dismissTask?.cancel()
                entry.panel.orderOut(nil)
            }
        }

        // Create or reposition for every connected display.
        for screen in screens {
            guard let displayID = screen.pickyDisplayID else { continue }
            let shouldOrderFront = panelsByDisplayID[displayID] == nil
            if shouldOrderFront {
                panelsByDisplayID[displayID] = makePanelEntry(displayID: displayID)
            }
            positionPanel(on: screen, displayID: displayID)
            if shouldOrderFront {
                panelsByDisplayID[displayID]?.panel.orderFrontRegardless()
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

        let placement = PickyHUDPlacement(
            dockSide: position(for: displayID).side,
            dockSizePreset: currentDockSizePreset,
            cardSize: cardSize(for: displayID),
            panelWidth: initialPanelWidth,
            collapsedGroupOverrides: dockGroupCollapse(for: displayID)
        )
        let hudRoot = PickyHUDView(
            viewModel: viewModel,
            panelIdentifier: panelIdentifier,
            placement: placement,
            onSizeChange: { [weak self] size in
                // SwiftUI animates the card reveal itself. Grow the transparent NSPanel
                // immediately, but defer shrinking it until the collapse animation has
                // finished so shadows/content aren't clipped by the outer container.
                self?.resizePanel(displayID: displayID, toContentSize: size, deferShrink: true)
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
            onOpenFullscreenSession: { [weak self] sessionID in
                self?.onOpenFullscreenSession(sessionID)
            },
            onDockGroupCollapseChanged: { [weak self] overrides in
                self?.handleDockGroupCollapseChanged(displayID: displayID, overrides: overrides)
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
            entry.placement.availableCardMaxHeight = next
        }
        if entry.placement.dockSide != pos.side {
            entry.placement.dockSide = pos.side
        }
        let nextCardSize = cardSize(for: displayID)
        if entry.placement.cardSize != nextCardSize {
            entry.placement.cardSize = nextCardSize
        }
        let nextPanelWidth = panelWidth(for: displayID, dockSide: pos.side)
        if abs(entry.placement.panelWidth - nextPanelWidth) > 0.5 {
            entry.placement.panelWidth = nextPanelWidth
        }
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

    private func resizePanel(displayID: CGDirectDisplayID, toContentSize contentSize: CGSize, deferShrink: Bool) {
        guard var entry = panelsByDisplayID[displayID] else { return }
        guard let screen = screen(for: displayID) else { return }
        guard let targetFrame = targetFrame(for: screen, displayID: displayID, contentSize: contentSize) else { return }

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
                self.resizePanel(displayID: displayID, toContentSize: contentSize, deferShrink: false)
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
            entry.panel.setFrame(targetFrame, display: true)
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
            let horizontalDockLength = PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: visibleSessionCount(),
                isAddSlotExpanded: false,
                metrics: dockMetrics,
                includesFullscreenControl: PickyFullscreenFeatureFlags.isEnabled
            )
            safeXOffset = PickyHUDDockLayout.clampedHorizontalXOffset(
                pos.xOffset,
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                dockRailLength: horizontalDockLength
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
                xOffset: safeXOffset
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

    // MARK: - Archive undo toast

    private func showArchiveUndoToast(displayID: CGDirectDisplayID, sessionID: String, title: String) {
        guard screen(for: displayID) != nil else { return }
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

        var settings = settingsStore.load()
        settings.hudDockPositions = currentPositionsByDisplayID
        try? settingsStore.save(settings)
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
        let startPanelWidth = panelWidth(for: displayID, dockSide: startPos.side)
        if startPos.side.orientation == .horizontal {
            let horizontalDockLength = PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: visibleSessionCount(),
                isAddSlotExpanded: false,
                metrics: dockMetrics,
                includesFullscreenControl: PickyFullscreenFeatureFlags.isEnabled
            )
            // -- X axis: along-axis position from screen center --
            pos.xOffset = PickyHUDDockLayout.clampedHorizontalXOffset(
                startPos.xOffset + delta.x,
                visibleFrame: visibleFrame,
                panelWidth: startPanelWidth,
                dockRailLength: horizontalDockLength
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
            pos.anchorPercent = PickySettings.clampedDockTopAnchorPercent(
                startPos.anchorPercent + dPct
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
        var settings = settingsStore.load()
        settings.hudDockPositions = currentPositionsByDisplayID
        try? settingsStore.save(settings)
    }

    private func handleCardMeasuredSize(displayID: CGDirectDisplayID, size: CGSize) {
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
        var settings = settingsStore.load()
        settings.hudCardSizes = currentCardSizesByDisplayID
        try? settingsStore.save(settings)
    }

    private func handleCardResizeReset(displayID: CGDirectDisplayID) {
        resizeStartCardSizesByDisplayID = nil
        currentCardSizesByDisplayID.removeValue(forKey: String(displayID))
        if let entry = panelsByDisplayID[displayID] {
            entry.placement.cardSize = nil
            entry.placement.panelWidth = panelWidth(for: displayID)
        }
        repositionAllPanels()
        var settings = settingsStore.load()
        settings.hudCardSizes = currentCardSizesByDisplayID
        try? settingsStore.save(settings)
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
        for displayID in panelsByDisplayID.keys {
            panelsByDisplayID[displayID]?.placement.dockSizePreset = preset
            panelsByDisplayID[displayID]?.placement.panelWidth = panelWidth(for: displayID)
        }
        syncPanelsForCurrentScreens()
    }
}

private extension NSScreen {
    /// `CGDirectDisplayID` is stable across screen reconfigurations, while
    /// `NSScreen` instance identity is not. Returns `nil` for headless or
    /// unrecognized screens so callers can skip them.
    var pickyDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Fullscreen HUD visibility

extension PickyHUDOverlayManager: PickyHUDVisibilityControlling {
    var isHUDVisibleForFullscreen: Bool {
        !isHiddenForFullscreen
    }

    func hideForFullscreen() {
        guard !isHiddenForFullscreen else { return }
        isHiddenForFullscreen = true
        tearDownPanels()
    }

    func restoreAfterFullscreen() {
        guard isHiddenForFullscreen else { return }
        isHiddenForFullscreen = false
        syncPanelsForCurrentScreens()
    }
}
