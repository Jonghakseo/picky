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

    private struct ArchiveUndoToastEntry {
        let panel: PickyHUDPanel
        var dismissTask: Task<Void, Never>?
        var toast: PickyHUDArchiveUndoToast?
    }

    private var panelsByDisplayID: [CGDirectDisplayID: PanelEntry] = [:]
    private var archiveUndoToastsByDisplayID: [CGDirectDisplayID: ArchiveUndoToastEntry] = [:]
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
            if panelsByDisplayID[displayID] == nil {
                panelsByDisplayID[displayID] = makePanelEntry(displayID: displayID)
                panelsByDisplayID[displayID]?.panel.orderFrontRegardless()
            }
            positionPanel(on: screen, displayID: displayID)
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
}

private extension NSScreen {
    /// `CGDirectDisplayID` is stable across screen reconfigurations, while
    /// `NSScreen` instance identity is not. Returns `nil` for headless or
    /// unrecognized screens so callers can skip them.
    var pickyDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
