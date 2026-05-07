//
//  PickyHUDOverlayManager.swift
//  Picky
//
//  Right-side HUD panel lifecycle and placement. One panel per attached
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
        var pendingShrinkTask: Task<Void, Never>?
        var lastContentSize: CGSize
    }

    private var panelsByDisplayID: [CGDirectDisplayID: PanelEntry] = [:]
    private var screenParametersObserver: NSObjectProtocol?

    /// Live anchor percent (5–40% from the visible frame top to the dock's TOP edge).
    /// Hydrated from settings on init, updated in real time during a handle drag, and
    /// persisted back to settings when the drag ends. All connected displays read this
    /// same value so the dock sits at the same relative position on every monitor.
    private var currentAnchorPercent: Double
    private var dragStartAnchorPercent: Double?

    init(
        viewModel: PickySessionListViewModel,
        appearanceStore: PickyAppearanceStore,
        settingsStore: PickySettingsStore
    ) {
        self.viewModel = viewModel
        self.appearanceStore = appearanceStore
        self.settingsStore = settingsStore
        self.currentAnchorPercent = PickySettings.clampedDockTopAnchorPercent(
            settingsStore.load().hudDockTopAnchorPercent
        )
    }

    func start() {
        viewModel.start()
        syncPanelsForCurrentScreens()
        startScreenParametersObserver()
    }

    func stop() {
        stopScreenParametersObserver()
        viewModel.stop()
        for (_, entry) in panelsByDisplayID {
            entry.pendingShrinkTask?.cancel()
            entry.panel.orderOut(nil)
        }
        panelsByDisplayID.removeAll()
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

        // Create or reposition for every connected display.
        for screen in screens {
            guard let displayID = screen.pickyDisplayID else { continue }
            if panelsByDisplayID[displayID] == nil {
                panelsByDisplayID[displayID] = makePanelEntry(displayID: displayID)
                panelsByDisplayID[displayID]?.panel.orderFrontRegardless()
            }
            positionPanel(on: screen, displayID: displayID)
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

        let hudRoot = PickyHUDView(
            viewModel: viewModel,
            onSizeChange: { [weak self] size in
                // SwiftUI animates the card reveal itself. Grow the transparent NSPanel
                // immediately, but defer shrinking it until the collapse animation has
                // finished so shadows/content aren't clipped by the outer container.
                self?.resizePanel(displayID: displayID, toContentSize: size, deferShrink: true)
            },
            onDockHandleDragChanged: { [weak self] screenDeltaY in
                self?.handleDockDragChanged(displayID: displayID, screenDeltaY: screenDeltaY)
            },
            onDockHandleDragEnded: { [weak self] in
                self?.handleDockDragEnded()
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
            pendingShrinkTask: nil,
            lastContentSize: CGSize(width: width, height: collapsedHeight)
        )
    }

    private func positionPanel(on screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let entry = panelsByDisplayID[displayID] else { return }
        let contentSize = entry.panel.contentView?.fittingSize ?? entry.lastContentSize
        resizePanel(displayID: displayID, toContentSize: contentSize, deferShrink: false)
    }

    // MARK: - Resizing / placement

    private func resizePanel(displayID: CGDirectDisplayID, toContentSize contentSize: CGSize, deferShrink: Bool) {
        guard var entry = panelsByDisplayID[displayID] else { return }
        guard let screen = screen(for: displayID) else { return }
        guard let targetFrame = targetFrame(for: screen, contentSize: contentSize) else { return }

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

    private func targetFrame(for screen: NSScreen, contentSize: CGSize) -> NSRect? {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        let topPadding = PickyHUDExpansion.dockShadowVerticalPadding
        // Cap the panel height so dockTopAnchoredPanelY never has to clamp at the
        // visible-frame floor (which would push the dock top up and break the anchor
        // guarantee). The conversation list scrolls internally for anything taller.
        let dockAnchoredCap = PickyHUDDockLayout.dockTopAnchoredMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: currentAnchorPercent
        )
        let visibleHeightCap = visibleFrame.height - 160
        let cap = min(visibleHeightCap, dockAnchoredCap)
        let targetHeight = max(min(contentSize.height, cap), minimumHeight)
        let originY = PickyHUDDockLayout.dockTopAnchoredPanelY(
            visibleFrame: visibleFrame,
            targetHeight: targetHeight,
            topPaddingFromContentTop: topPadding,
            anchorPercent: currentAnchorPercent
        )
        return NSRect(
            x: visibleFrame.maxX - width - PickyHUDDockLayout.dockRightEdgeMargin,
            y: originY,
            width: width,
            height: targetHeight
        )
    }

    // MARK: - Dock handle drag

    private func handleDockDragChanged(displayID: CGDirectDisplayID, screenDeltaY: CGFloat) {
        guard let screen = screen(for: displayID) else { return }
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.height > 0 else { return }
        if dragStartAnchorPercent == nil {
            dragStartAnchorPercent = currentAnchorPercent
        }
        // `screenDeltaY` is the cursor's bottom-up screen delta from drag start.
        // Moving the cursor DOWN (screen Y decreasing) should INCREASE anchor%, since
        // anchor% measures the dock's top edge as a fraction below the visible-frame
        // top. Negate to get a top-down delta percentage and add to the start value.
        let dPct = -(Double(screenDeltaY) / Double(visibleFrame.height)) * 100.0
        let next = PickySettings.clampedDockTopAnchorPercent((dragStartAnchorPercent ?? currentAnchorPercent) + dPct)
        guard next != currentAnchorPercent else { return }
        currentAnchorPercent = next
        repositionAllPanels()
    }

    private func handleDockDragEnded() {
        dragStartAnchorPercent = nil
        var settings = settingsStore.load()
        let clamped = PickySettings.clampedDockTopAnchorPercent(currentAnchorPercent)
        guard settings.hudDockTopAnchorPercent != clamped else { return }
        settings.hudDockTopAnchorPercent = clamped
        // Settings save throws on directory validation failure (defaultCwd / worktreeParent).
        // Failing to persist the anchor shouldn't tear down the live drag UX, so swallow the
        // error here — next launch falls back to the previously saved anchor percent.
        try? settingsStore.save(settings)
    }

    private func repositionAllPanels() {
        for screen in NSScreen.screens {
            guard let displayID = screen.pickyDisplayID else { continue }
            guard panelsByDisplayID[displayID] != nil else { continue }
            positionPanel(on: screen, displayID: displayID)
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
}

private extension NSScreen {
    /// `CGDirectDisplayID` is stable across screen reconfigurations, while
    /// `NSScreen` instance identity is not. Returns `nil` for headless or
    /// unrecognized screens so callers can skip them.
    var pickyDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
