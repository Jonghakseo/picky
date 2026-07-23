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

/// Keeps the panel click-through except where SwiftUI renders the pill or its
/// visible caption. A borderless NSPanel otherwise receives mouse events across
/// its transparent 260×82 backing frame.
private final class PickyMainCancelPillHostingView: NSHostingView<LocalizedHostingRoot<PickyMainCancelPillView>> {
    private let hitRegion: () -> CGRect

    required init(rootView: LocalizedHostingRoot<PickyMainCancelPillView>) {
        self.hitRegion = { .null }
        super.init(rootView: rootView)
    }

    init(rootView: LocalizedHostingRoot<PickyMainCancelPillView>, hitRegion: @escaping () -> CGRect) {
        self.hitRegion = hitRegion
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let region = hitRegion()
        guard !region.isNull else { return super.hitTest(point) }
        let appKitRegion = NSRect(
            x: region.minX,
            y: bounds.height - region.maxY,
            width: region.width,
            height: region.height
        )
        guard appKitRegion.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class PickyMainCancelPillViewModel: ObservableObject {
    @Published var state: PickyMainCancelPillState = .rest
    /// SwiftUI reports its rendered pill/caption geometry in the hosting view's
    /// coordinate space so transparent panel margins remain click-through.
    @Published var visibleContentFrame = CGRect.null
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
    /// Invalidates an in-flight fade-out when the pill is re-presented before
    /// the animation completes, so the completion handler cannot hide a panel
    /// that should be visible again.
    private var dismissGeneration = 0

    var onCancel: () async -> Bool = { false }
    /// Called after either a successful or failed cancellation attempt has
    /// restored its visual state, so the panel converges against current
    /// in-flight and key-window state rather than a stale pre-attempt snapshot.
    var onCancellationAttemptResolved: () -> Void = {}

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
        dismissGeneration += 1
        let generation = dismissGeneration
        guard let panel, panel.isVisible else {
            viewModel.state = .rest
            panel?.orderOut(nil)
            return
        }
        // Fade out (keeps the current label — e.g. “Stopped” — visible during
        // the transition), then reset for the next presentation. Reduce Motion
        // keeps the same state change without an opacity animation.
        let completeDismissal: () -> Void = { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, self.dismissGeneration == generation else { return }
                panel?.orderOut(nil)
                panel?.alphaValue = 1
                self.viewModel.state = .rest
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            completeDismissal()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: completeDismissal)
        }
    }

    private func present() {
        // A new turn supersedes a completed cancellation confirmation. Cancel
        // its delayed dismissal and restore an enabled control before showing
        // the panel again; the generation invalidates any fade completion.
        if cancellationAttemptID == nil, viewModel.state == .cancelled {
            cancelledDismissTask?.cancel()
            cancelledDismissTask = nil
            viewModel.state = .rest
        }
        dismissGeneration += 1
        if panel == nil { createPanel() }
        positionPanelOnCursorScreen()
        panel?.alphaValue = 1
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
        let host = PickyMainCancelPillHostingView(
            rootView: LocalizedHostingRoot { view },
            hitRegion: { [weak viewModel] in viewModel?.visibleContentFrame ?? .null }
        )
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
            self.onCancellationAttemptResolved()
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
