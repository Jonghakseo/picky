//
//  PickyMainCancelPillPanelManager.swift
//  Picky
//
//  Hosts the interactive cancellation control separately from the click-through
//  cursor overlay so normal desktop input remains untouched.
//

import AppKit
import Combine
import SwiftUI

private final class PickyMainCancelPillPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PickyMainCancelPillViewModel: ObservableObject {
    @Published var state: PickyMainCancelPillState = .rest
}

@MainActor
final class PickyMainCancelPillPanelManager {
    private static let panelSize = CGSize(width: 260, height: 82)
    private static let topInset: CGFloat = 64

    private let viewModel = PickyMainCancelPillViewModel()
    private var panel: PickyMainCancelPillPanel?
    private var escapeResetTask: Task<Void, Never>?
    private var cancelledDismissTask: Task<Void, Never>?

    var onCancel: () -> Void = {}

    deinit {
        escapeResetTask?.cancel()
        cancelledDismissTask?.cancel()
    }

    func update(isMainTurnInFlight: Bool, isPickyPanelKeyWindow: Bool) {
        guard PickyMainCancelPillPolicy.shouldPresent(
            isMainTurnInFlight: isMainTurnInFlight,
            isPickyPanelKeyWindow: isPickyPanelKeyWindow
        ) else {
            if viewModel.state != .cancelled {
                dismiss()
            }
            return
        }
        present()
    }

    func handleEscape() {
        guard panel?.isVisible == true, viewModel.state != .cancelled else { return }
        let nextState = PickyMainCancelPillPolicy.stateAfterEscape(currentState: viewModel.state)
        viewModel.state = nextState
        if nextState == .cancelled {
            cancel()
        } else {
            scheduleEscapeReset()
        }
    }

    func dismiss() {
        escapeResetTask?.cancel()
        escapeResetTask = nil
        cancelledDismissTask?.cancel()
        cancelledDismissTask = nil
        viewModel.state = .rest
        panel?.orderOut(nil)
    }

    private func present() {
        if panel == nil { createPanel() }
        positionPanelOnCursorScreen()
        panel?.orderFrontRegardless()
    }

    private func createPanel() {
        let view = PickyMainCancelPillView(
            viewModel: viewModel,
            onHoverChanged: { [weak self] isHovering in
                guard let self else { return }
                self.viewModel.state = PickyMainCancelPillPolicy.stateAfterHover(
                    isHovering,
                    currentState: self.viewModel.state
                )
            },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = NSHostingView(rootView: LocalizedHostingRoot { view })
        host.frame = NSRect(origin: .zero, size: Self.panelSize)

        let panel = PickyMainCancelPillPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .pickyCursorOverlay
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = .none
        panel.contentView = host
        self.panel = panel
    }

    private func positionPanelOnCursorScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.maxY - Self.topInset - Self.panelSize.height
        )
        panel.setFrame(CGRect(origin: origin, size: Self.panelSize), display: true)
    }

    private func scheduleEscapeReset() {
        escapeResetTask?.cancel()
        escapeResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PickyMainCancelPillPolicy.escapeConfirmationWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.viewModel.state == .escapeArmed else { return }
                self?.viewModel.state = .rest
            }
        }
    }

    private func cancel() {
        guard viewModel.state != .cancelled else { return }
        escapeResetTask?.cancel()
        escapeResetTask = nil
        viewModel.state = .cancelled
        onCancel()
        cancelledDismissTask?.cancel()
        cancelledDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PickyMainCancelPillPolicy.cancellationConfirmationDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }
}
