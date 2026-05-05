//
//  PickyHUDOverlayManager.swift
//  Picky
//
//  Right-side HUD panel lifecycle, placement, and resizing.
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
    private let settingsStore: PickySettingsStore
    private let appearanceStore: PickyAppearanceStore
    private var panel: NSPanel?
    private var pendingPanelShrinkTask: Task<Void, Never>?
    private var pendingScreenSwitchTask: Task<Void, Never>?
    private var currentScreen: NSScreen?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private let width: CGFloat = PickyHUDDockLayout.panelWidth
    private let collapsedHeight: CGFloat = 180
    private let minimumHeight: CGFloat = 48
    private let screenSwitchDebounce: TimeInterval = 0.2

    init(viewModel: PickySessionListViewModel, appearanceStore: PickyAppearanceStore, settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.viewModel = viewModel
        self.settingsStore = settingsStore
        self.appearanceStore = appearanceStore
    }

    func start() {
        viewModel.start()
        createPanelIfNeeded()
        currentScreen = focusedScreen() ?? NSScreen.main ?? NSScreen.screens.first
        positionRightMiddle()
        panel?.orderFrontRegardless()
        startFocusTracking()
    }

    func stop() {
        pendingPanelShrinkTask?.cancel()
        pendingPanelShrinkTask = nil
        pendingScreenSwitchTask?.cancel()
        pendingScreenSwitchTask = nil
        stopFocusTracking()
        viewModel.stop()
        panel?.orderOut(nil)
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }
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
            self?.resizePanel(toContentSize: size, deferShrink: true)
        }
            .frame(width: width)
            .environmentObject(appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        let hostingView = NSHostingView(rootView: hudRoot)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: collapsedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hudPanel.contentView = hostingView
        panel = hudPanel
    }

    private func positionRightMiddle() {
        resizePanel(toContentSize: panel?.contentView?.fittingSize ?? CGSize(width: width, height: collapsedHeight), deferShrink: false)
    }

    private func resizePanel(toContentSize contentSize: CGSize, deferShrink: Bool) {
        guard let panel else { return }
        guard let targetFrame = targetFrame(forContentSize: contentSize) else { return }
        let shouldDeferShrink = PickyHUDExpansion.shouldDeferPanelShrink(
            currentHeight: panel.frame.height,
            targetHeight: targetFrame.height,
            deferShrink: deferShrink
        )

        if shouldDeferShrink {
            pendingPanelShrinkTask?.cancel()
            pendingPanelShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(PickyHUDExpansion.panelShrinkDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.pendingPanelShrinkTask = nil
                self.resizePanel(toContentSize: contentSize, deferShrink: false)
            }
            return
        }

        pendingPanelShrinkTask?.cancel()
        pendingPanelShrinkTask = nil
        applyPanelFrame(targetFrame)
    }

    private func targetFrame(forContentSize contentSize: CGSize) -> NSRect? {
        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return nil }
        let targetHeight = min(max(contentSize.height, minimumHeight), visibleFrame.height - (PickyHUDDockLayout.screenMargin * 2))
        return NSRect(
            x: visibleFrame.maxX - width - PickyHUDDockLayout.dockRightEdgeMargin,
            y: PickyHUDDockLayout.centeredPanelY(visibleFrame: visibleFrame, targetHeight: targetHeight),
            width: width,
            height: targetHeight
        )
    }

    private func applyPanelFrame(_ targetFrame: NSRect) {
        guard let panel, panel.frame.integral != targetFrame.integral else { return }
        panel.setFrame(targetFrame, display: true)
    }

    // MARK: - Focused-screen tracking

    private func startFocusTracking() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensChanged() }
        }

        // mouseMoved fires often, but our handler short-circuits unless the cursor
        // crossed onto a different screen, so the steady-state cost is just a
        // rectangle-contains check per event.
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.handleCursorMoved() }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        }
    }

    private func stopFocusTracking() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        globalMouseMonitor = nil
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        localMouseMonitor = nil
    }

    private func handleCursorMoved() {
        guard settingsStore.load().followsFocusedScreen else { return }
        guard NSScreen.screens.count > 1 else { return }
        guard let target = focusedScreen() else { return }
        guard target != currentScreen else { return }
        guard !shouldDeferScreenSwitch() else { return }
        scheduleScreenSwitch(to: target)
    }

    private func handleScreensChanged() {
        let screens = NSScreen.screens
        // Current screen may have been disconnected. Re-anchor to the focused
        // screen if available, otherwise fall back to the system primary.
        if let current = currentScreen, !screens.contains(current) {
            currentScreen = focusedScreen() ?? NSScreen.main ?? screens.first
            positionRightMiddle()
            return
        }
        if settingsStore.load().followsFocusedScreen,
           let target = focusedScreen(),
           target != currentScreen {
            currentScreen = target
            positionRightMiddle()
        }
    }

    private func scheduleScreenSwitch(to screen: NSScreen) {
        pendingScreenSwitchTask?.cancel()
        pendingScreenSwitchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.screenSwitchDebounce ?? 0.2) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingScreenSwitchTask = nil
            // Re-validate after debounce: cursor may have moved back, settings
            // may have flipped, or the panel may now be hovered/keyboard-busy.
            guard self.settingsStore.load().followsFocusedScreen else { return }
            guard let latest = self.focusedScreen(), latest == screen else { return }
            guard latest != self.currentScreen else { return }
            guard !self.shouldDeferScreenSwitch() else { return }
            self.currentScreen = latest
            self.positionRightMiddle()
        }
    }

    private func shouldDeferScreenSwitch() -> Bool {
        guard let panel else { return false }
        // Don't yank the panel out from under the user's pointer.
        if panel.frame.contains(NSEvent.mouseLocation) { return true }
        // Don't disrupt typing into Steer / extension UI inputs.
        if panel.firstResponder is NSText { return true }
        if let firstResponder = panel.firstResponder as? NSView, firstResponder !== panel.contentView { return true }
        return false
    }

    private func focusedScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}
