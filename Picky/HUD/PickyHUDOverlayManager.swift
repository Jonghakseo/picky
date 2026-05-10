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

final class PickyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
            resignFocusedControl()
        }
        super.sendEvent(event)
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
    private let settingsStore: PickySettingsStore
    private let width: CGFloat = PickyHUDDockLayout.panelWidth
    private let collapsedHeight: CGFloat = 180
    private let minimumHeight: CGFloat = 48

    /// Stable, per-display state. Keyed by `CGDirectDisplayID` because AppKit
    /// hands us new `NSScreen` instances whenever the screen configuration
    /// changes; the display ID survives those rebuilds as long as the physical
    /// monitor stays connected.
    private struct PanelEntry {
        let panel: PickyHUDPanel
        let placement: PickyHUDPlacement
        let displayState: PickyHUDDisplayState
        var pendingShrinkTask: Task<Void, Never>?
        var lastContentSize: CGSize
    }

    private struct ArchiveUndoToastEntry {
        let panel: PickyHUDPanel
        var dismissTask: Task<Void, Never>?
        var toast: PickyHUDArchiveUndoToast?
    }

    private var panelsByDisplayID: [CGDirectDisplayID: PanelEntry] = [:]
    private var archiveUndoToastsByDisplayID: [CGDirectDisplayID: ArchiveUndoToastEntry] = [:]
    private var screenParametersObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var currentDockSizePreset: PickyHUDDockSizePreset

    /// Per-display dock position state. Each display remembers its own side,
    /// anchor percent, and horizontal offset so users can place the dock
    /// independently on each monitor. Keyed by display ID string.
    private var currentPositionsByDisplayID: [String: PickyHUDDockPosition]
    /// Snapshot of all positions at drag start so deltas accumulate from the
    /// original anchor rather than the previous frame's clamped value.
    private var dragStartPositionsByDisplayID: [String: PickyHUDDockPosition]?

    init(
        viewModel: PickySessionListViewModel,
        appearanceStore: PickyAppearanceStore,
        settingsStore: PickySettingsStore
    ) {
        self.viewModel = viewModel
        self.appearanceStore = appearanceStore
        self.settingsStore = settingsStore
        let settings = settingsStore.load()
        self.currentPositionsByDisplayID = settings.hudDockPositions
        self.currentDockSizePreset = settings.hudDockSizePreset
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

    func start() {
        viewModel.start()
        syncPanelsForCurrentScreens()
        startScreenParametersObserver()
        startSettingsObserver()
    }

    func stop() {
        stopScreenParametersObserver()
        stopSettingsObserver()
        viewModel.stop()
        for (_, entry) in panelsByDisplayID {
            entry.pendingShrinkTask?.cancel()
            entry.panel.orderOut(nil)
        }
        for (_, entry) in archiveUndoToastsByDisplayID {
            entry.dismissTask?.cancel()
            entry.panel.orderOut(nil)
        }
        panelsByDisplayID.removeAll()
        archiveUndoToastsByDisplayID.removeAll()
    }

    // MARK: - Panel sync

    private func syncPanelsForCurrentScreens() {
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
        let hudPanel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hudPanel.level = .statusBar
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
            dockSizePreset: currentDockSizePreset
        )
        let displayState = PickyHUDDisplayState()
        let hudRoot = PickyHUDView(
            viewModel: viewModel,
            panelIdentifier: panelIdentifier,
            placement: placement,
            displayState: displayState,
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
            onArchiveUndoRequested: { [weak self] sessionID, title in
                self?.showArchiveUndoToast(displayID: displayID, sessionID: sessionID, title: title)
            }
        )
            .frame(width: width)
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let hostingView = NSHostingView(rootView: hudRoot)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: collapsedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hudPanel.contentView = hostingView

        return PanelEntry(
            panel: hudPanel,
            placement: placement,
            displayState: displayState,
            pendingShrinkTask: nil,
            lastContentSize: CGSize(width: width, height: collapsedHeight)
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
        let next = computeAvailableCardMaxHeight(for: screen, anchorPercent: pos.anchorPercent)
        // Avoid spamming SwiftUI re-renders with identical values; @Published
        // publishes on every assignment regardless of equality.
        if abs(entry.placement.availableCardMaxHeight - next) > 0.5 {
            entry.placement.availableCardMaxHeight = next
        }
        if entry.placement.dockSide != pos.side {
            entry.placement.dockSide = pos.side
        }
    }

    /// Largest height the conversation card may take on the given screen, derived
    /// from the live anchor percent and the visible frame. Card content beyond this
    /// scrolls inside `PickyConversationListView` rather than overflowing the panel.
    private func computeAvailableCardMaxHeight(for screen: NSScreen, anchorPercent: Double) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.height > 0 else {
            return PickyHUDPlacement.defaultAvailableCardMaxHeight
        }
        let topPadding = PickyHUDExpansion.dockBodyTopOffsetFromContentTop
        let dockAnchoredCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchorPercent
        )
        let visibleHeightCap = (visibleFrame.height - 160).rounded(.down)
        let panelCap = min(dockAnchoredCap, visibleHeightCap)
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
        let dockAnchoredCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: pos.anchorPercent
        )
        let visibleHeightCap = (visibleFrame.height - 160).rounded(.down)
        let cap = max(minimumHeight, min(visibleHeightCap, dockAnchoredCap).rounded(.down))
        let clampedHeight = min(max(contentSize.height, minimumHeight), cap)
        let targetHeight = clampedHeight.rounded(.up)
        let originY = PickyHUDDockLayout.dockTopAnchoredPointAlignedPanelY(
            visibleFrame: visibleFrame,
            targetHeight: targetHeight,
            topPaddingFromContentTop: topPadding,
            anchorPercent: pos.anchorPercent
        )
        let dockMetrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let safeXOffset = PickyHUDDockLayout.clampedXOffset(
            pos.xOffset,
            visibleFrame: visibleFrame,
            panelWidth: width,
            dockSide: pos.side,
            dockRailWidth: dockMetrics.railWidth
        )
        if safeXOffset != pos.xOffset {
            var normalizedPosition = pos
            normalizedPosition.xOffset = safeXOffset
            setPosition(normalizedPosition, for: displayID)
        }

        return NSRect(
            x: PickyHUDDockLayout.panelX(
                visibleFrame: visibleFrame,
                panelWidth: width,
                dockSide: pos.side,
                xOffset: safeXOffset
            ),
            y: originY,
            width: width,
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
        let root = PickyHUDArchiveUndoToastPanelRoot(
            toast: toast,
            onUndo: { [weak self] in
                self?.undoArchiveFromToast(displayID: displayID, toast: toast)
            }
        )
        .environmentObject(appearanceStore)
        .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let hostingView = NSHostingView(rootView: root)
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
        let pos = PickyHUDDockPosition.defaults()
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

        // -- Y axis: anchor percent --
        if dragStartPositionsByDisplayID == nil {
            dragStartPositionsByDisplayID = currentPositionsByDisplayID
        }
        let startPositions = dragStartPositionsByDisplayID ?? currentPositionsByDisplayID
        let startPos = PickyHUDDockPosition.resolved(
            in: startPositions,
            displayKey: String(displayID)
        )
        let dPct = -(Double(delta.y) / Double(visibleFrame.height)) * 100.0
        pos.anchorPercent = PickySettings.clampedDockTopAnchorPercent(
            startPos.anchorPercent + dPct
        )

        // -- X axis: horizontal offset and side --
        let dockMetrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let draggedDockCenterX = PickyHUDDockLayout.dockRailCenterX(
            visibleFrame: visibleFrame,
            panelWidth: width,
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
            panelWidth: width,
            dockSide: pos.side,
            dockRailWidth: dockMetrics.railWidth
        )

        setPosition(pos, for: displayID)
        repositionAllPanels()
    }

    private func handleDockDragEnded() {
        dragStartPositionsByDisplayID = nil
        var settings = settingsStore.load()
        settings.hudDockPositions = currentPositionsByDisplayID
        try? settingsStore.save(settings)
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
