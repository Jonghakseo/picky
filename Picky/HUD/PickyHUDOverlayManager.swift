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

    init(viewModel: PickySessionListViewModel, appearanceStore: PickyAppearanceStore) {
        self.viewModel = viewModel
        self.appearanceStore = appearanceStore
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

        let hudRoot = PickyHUDView(viewModel: viewModel) { [weak self] size in
            // SwiftUI animates the card reveal itself. Grow the transparent NSPanel
            // immediately, but defer shrinking it until the collapse animation has
            // finished so shadows/content aren't clipped by the outer container.
            self?.resizePanel(displayID: displayID, toContentSize: size, deferShrink: true)
        }
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
        let targetHeight = min(max(contentSize.height, minimumHeight), visibleFrame.height - 160)
        return NSRect(
            x: visibleFrame.maxX - width - PickyHUDDockLayout.dockRightEdgeMargin,
            y: PickyHUDDockLayout.centeredPanelY(visibleFrame: visibleFrame, targetHeight: targetHeight),
            width: width,
            height: targetHeight
        )
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
