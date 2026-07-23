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
    private var cancellationAttemptID: UUID?

    var onCancel: () async -> Bool = { false }

    deinit {
        escapeResetTask?.cancel()
        cancelledDismissTask?.cancel()
    }

    func update(isMainTurnInFlight: Bool, isPickyPanelKeyWindow: Bool) {
        guard PickyMainCancelPillPolicy.shouldPresent(
            isMainTurnInFlight: isMainTurnInFlight,
            isPickyPanelKeyWindow: isPickyPanelKeyWindow
        ) else {
            // A successful abort clears the in-flight projection before this
            // panel receives its confirmation result. Keep it visible while
            // awaiting that result so success can still show “Stopped”; a
            // failure restores .rest without dropping the usable control.
            if viewModel.state != .cancelled, cancellationAttemptID == nil {
                dismiss()
            }
            return
        }
        present()
    }

    func handleEscape() {
        guard panel?.isVisible == true, viewModel.state != .cancelled, cancellationAttemptID == nil else { return }
        let nextState = PickyMainCancelPillPolicy.stateAfterEscape(currentState: viewModel.state)
        if nextState == .cancelled {
            // Keep the armed state while the abort is in flight. Only a
            // confirmed daemon abort is allowed to show the cancelled label.
            cancel()
        } else {
            viewModel.state = nextState
            scheduleEscapeReset()
        }
    }

    func dismiss() {
        escapeResetTask?.cancel()
        escapeResetTask = nil
        cancelledDismissTask?.cancel()
        cancelledDismissTask = nil
        cancellationAttemptID = nil
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
        let screenFrame = screen.frame
        let origin = CGPoint(
            x: screenFrame.midX - Self.panelSize.width / 2,
            y: screenFrame.maxY - Self.topInset - Self.panelSize.height
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
        guard viewModel.state != .cancelled, cancellationAttemptID == nil else { return }
        escapeResetTask?.cancel()
        escapeResetTask = nil
        let attemptID = UUID()
        cancellationAttemptID = attemptID

        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.onCancel()
            guard self.cancellationAttemptID == attemptID else { return }
            self.cancellationAttemptID = nil
            self.viewModel.state = PickyMainCancelPillPolicy.stateAfterCancellationAttempt(succeeded: succeeded)
            guard succeeded else { return }
            self.scheduleCancelledDismissal()
        }
    }

    private func scheduleCancelledDismissal() {
        cancelledDismissTask?.cancel()
        cancelledDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PickyMainCancelPillPolicy.cancellationConfirmationDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }
}
