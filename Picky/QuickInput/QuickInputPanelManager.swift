//
//  QuickInputPanelManager.swift
//  Picky
//
//  Owns the floating Quick Input pill — a non-activating NSPanel that appears
//  near the cursor when the user double-taps Control. Mirrors the panel
//  patterns used by MenuBarPanelManager (KeyablePanel) and
//  CompanionResponseOverlay (cursor-relative positioning + screen clamping).
//

import AppKit
import Combine
import SwiftUI

/// NSPanel subclass that can take key window status while still using the
/// `.nonactivatingPanel` style so the host app does not lose foreground focus.
private final class QuickInputKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickInputPanelManager {
    /// Horizontal offset from the cursor to the leading edge of the visible pill.
    private let cursorOffsetX: CGFloat = 18
    /// Vertical gap below the cursor before the visible pill is placed.
    private let cursorOffsetY: CGFloat = 12
    /// Transparent breathing room so the capsule shadow is not clipped into a rectangle.
    private let shadowOutset: CGFloat = QuickInputPanelLayout.shadowOutset
    /// Estimated rendered height; used for first-frame placement before
    /// SwiftUI reports its actual fitting size.
    private let estimatedPanelHeight: CGFloat = QuickInputPanelLayout.estimatedPanelHeight
    private let panelWidth: CGFloat = QuickInputPanelLayout.panelWidth

    private let viewModel = QuickInputPanelViewModel()
    private var panel: QuickInputKeyablePanel?

    /// Called when the user submits a non-empty message. The host (typically
    /// CompanionManager) is responsible for performing the actual delivery and
    /// for calling `panelDidFinishSending(success:errorMessage:)` afterwards.
    var onSubmit: (String) -> Void = { _ in }
    var onVisibilityChange: (Bool) -> Void = { _ in }

    var isPanelVisible: Bool { panel?.isVisible == true }

    func containsInteractiveGlobalPoint(_ point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame
            .insetBy(dx: shadowOutset, dy: shadowOutset)
            .insetBy(dx: -8, dy: -8)
            .contains(point)
    }

    init() {
        viewModel.onSubmit = { [weak self] text in
            self?.handleSubmit(text)
        }
        viewModel.onClose = { [weak self] in
            self?.dismiss()
        }
    }

    /// Opens the pill anchored near `cursorLocation` (global AppKit screen
    /// coordinates). If the panel is already visible, it is repositioned and
    /// the field is re-focused.
    func presentPanel(near cursorLocation: CGPoint) {
        if panel == nil {
            createPanel()
        }
        viewModel.errorMessage = nil
        positionPanelNearCursor(cursorLocation)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        onVisibilityChange(true)
    }

    /// Hides the pill and clears any draft text.
    func dismiss() {
        viewModel.draftText = ""
        viewModel.errorMessage = nil
        viewModel.isSending = false
        panel?.orderOut(nil)
        onVisibilityChange(false)
    }

    /// Called by the host after the submission task finishes. On success the
    /// panel auto-closes; on failure the error stays visible inside the pill
    /// and the input is preserved so the user can retry.
    func panelDidFinishSending(success: Bool, errorMessage: String?) {
        viewModel.isSending = false
        if success {
            dismiss()
        } else {
            viewModel.errorMessage = errorMessage ?? "메시지를 보내지 못했어요."
        }
    }

    // MARK: - Private

    private func handleSubmit(_ text: String) {
        viewModel.isSending = true
        viewModel.errorMessage = nil
        onSubmit(text)
    }

    private func createPanel() {
        let hostingView = NSHostingView(
            rootView: QuickInputPanelView(viewModel: viewModel)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: estimatedPanelHeight)

        let quickInputPanel = QuickInputKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: estimatedPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        quickInputPanel.isFloatingPanel = true
        quickInputPanel.level = .statusBar
        quickInputPanel.isOpaque = false
        quickInputPanel.backgroundColor = .clear
        quickInputPanel.hasShadow = false
        quickInputPanel.hidesOnDeactivate = false
        quickInputPanel.isExcludedFromWindowsMenu = true
        quickInputPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        quickInputPanel.isMovableByWindowBackground = false
        quickInputPanel.titleVisibility = .hidden
        quickInputPanel.titlebarAppearsTransparent = true
        quickInputPanel.contentView = hostingView

        panel = quickInputPanel
    }

    /// Positions the pill so its top-leading corner sits just below and to the
    /// right of the cursor, then clamps to the visible frame of the screen
    /// containing the cursor so the pill never goes off-screen.
    private func positionPanelNearCursor(_ cursorLocation: CGPoint) {
        guard let panel else { return }

        // Resize first so the fitting height is up-to-date for placement.
        let fittingSize = panel.contentView?.fittingSize
            ?? CGSize(width: panelWidth, height: estimatedPanelHeight)
        let panelSize = CGSize(
            width: panelWidth,
            height: max(fittingSize.height, estimatedPanelHeight)
        )

        // AppKit screen coordinates: y grows upward. Place the pill *below*
        // the cursor so the user can keep glancing at the cursor while typing.
        var originX = cursorLocation.x + cursorOffsetX - shadowOutset
        var originY = cursorLocation.y - cursorOffsetY - (panelSize.height - shadowOutset)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorLocation) })
            ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame

            if originX + panelSize.width > visibleFrame.maxX {
                originX = cursorLocation.x - cursorOffsetX - panelSize.width + shadowOutset
            }
            if originY < visibleFrame.minY {
                originY = cursorLocation.y + cursorOffsetY - shadowOutset
            }
            originX = max(visibleFrame.minX, min(originX, visibleFrame.maxX - panelSize.width))
            originY = max(visibleFrame.minY, min(originY, visibleFrame.maxY - panelSize.height))
        }

        panel.setFrame(NSRect(origin: CGPoint(x: originX, y: originY), size: panelSize), display: true)
    }
}
