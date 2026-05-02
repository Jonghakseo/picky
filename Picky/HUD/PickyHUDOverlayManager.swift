//
//  PickyHUDOverlayManager.swift
//  Picky
//
//  Top-right HUD panel lifecycle, placement, and resizing.
//

import AppKit
import SwiftUI

final class PickyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

@MainActor
final class PickyHUDOverlayManager {
    private let viewModel: PickySessionListViewModel
    private var panel: NSPanel?
    private var pendingPanelShrinkTask: Task<Void, Never>?
    private let width: CGFloat = 320
    private let collapsedHeight: CGFloat = 180
    private let minimumHeight: CGFloat = 48

    init(viewModel: PickySessionListViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        viewModel.start()
        createPanelIfNeeded()
        positionTopRight()
        panel?.orderFrontRegardless()
    }

    func stop() {
        pendingPanelShrinkTask?.cancel()
        pendingPanelShrinkTask = nil
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

        let hostingView = NSHostingView(rootView: PickyHUDView(viewModel: viewModel) { [weak self] size in
            // SwiftUI animates the card reveal itself. Grow the transparent NSPanel
            // immediately, but defer shrinking it until the collapse animation has
            // finished so shadows/content aren't clipped by the outer container.
            self?.resizePanel(toContentSize: size, deferShrink: true)
        }.frame(width: width))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: collapsedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hudPanel.contentView = hostingView
        panel = hudPanel
    }

    private func positionTopRight() {
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
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return nil }
        let targetHeight = min(max(contentSize.height, minimumHeight), visibleFrame.height - 32)
        return NSRect(
            x: visibleFrame.maxX - width - 16,
            y: visibleFrame.maxY - targetHeight - 16,
            width: width,
            height: targetHeight
        )
    }

    private func applyPanelFrame(_ targetFrame: NSRect) {
        guard let panel, panel.frame.integral != targetFrame.integral else { return }
        panel.setFrame(targetFrame, display: true)
    }
}
