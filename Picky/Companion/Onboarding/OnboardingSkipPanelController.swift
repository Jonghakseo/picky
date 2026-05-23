//
//  OnboardingSkipPanelController.swift
//  Picky
//
//  Small floating panel that pins a "Skip onboarding" button to the top-right
//  of every connected screen for the entire onboarding flow. One panel per
//  screen so a user with multiple displays always has the affordance in their
//  line of sight; click or ESC long-press fires the same skip handler.
//
//  ESC is intentionally NOT a SwiftUI keyboardShortcut on the button itself —
//  the controller installs a global+local NSEvent monitor and only triggers
//  skip after ESC has been held for `skipHoldDuration` (default 2s). The
//  visible capsule fills left → right while the key is held, giving immediate
//  feedback so users learn the "hold to confirm" gesture without extra copy.
//

import AppKit
import Combine
import SwiftUI

private final class OnboardingSkipPanel: NSPanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
}

/// Shared observable state driving the hold-to-skip progress fill on every
/// skip panel. The controller (or its parent flow) calls `start(duration:)`
/// when ESC is first pressed and `cancel()` when ESC is released or the
/// onboarding tears down. All panels listen to the same instance so the
/// animation stays in lockstep across displays.
@MainActor
final class OnboardingSkipHoldModel: ObservableObject {
    /// 0...1 fill progress. SwiftUI animates between updates.
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var isHolding: Bool = false

    private var tickTask: Task<Void, Never>?

    func start(duration: TimeInterval) {
        cancelTask()
        isHolding = true
        progress = 0
        let started = Date()
        tickTask = Task { @MainActor [weak self] in
            // ~60fps tick. We don't try to derive progress from the timer
            // task's sleep precision because macOS coalesces short sleeps and
            // we want the fill to feel smooth even under load.
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)
                let p = min(1.0, CGFloat(elapsed / duration))
                self.progress = p
                if p >= 1.0 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// Soft cancel: animates the fill back to 0 so a quick ESC tap doesn't
    /// leave a stub of progress glued to the capsule. Use `reset()` for hard
    /// teardown (panel dismissal) where animation doesn't matter.
    func cancel() {
        cancelTask()
        withAnimation(.easeOut(duration: 0.18)) {
            self.progress = 0
            self.isHolding = false
        }
    }

    func reset() {
        cancelTask()
        progress = 0
        isHolding = false
    }

    private func cancelTask() {
        tickTask?.cancel()
        tickTask = nil
    }
}

@MainActor
final class OnboardingSkipPanelController {
    private var panels: [OnboardingSkipPanel] = []
    private let onSkip: () -> Void
    let holdModel = OnboardingSkipHoldModel()

    init(onSkip: @escaping () -> Void) {
        self.onSkip = onSkip
    }

    func present() {
        if !panels.isEmpty { return }
        // One panel per connected screen so the button is always reachable
        // regardless of which display the user is currently looking at.
        // Screen hot-plug during onboarding is uncommon enough that we don't
        // observe `NSApplication.didChangeScreenParametersNotification` here;
        // the user can always click any visible panel.
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let panel = makePanel(on: screen)
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
    }

    func dismiss() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        holdModel.reset()
    }

    /// Called by the flow controller when ESC is first pressed.
    func startHoldFeedback(duration: TimeInterval) {
        holdModel.start(duration: duration)
    }

    /// Called when ESC is released before the hold completes.
    func cancelHoldFeedback() {
        holdModel.cancel()
    }

    private func makePanel(on screen: NSScreen) -> OnboardingSkipPanel {
        let size = NSSize(width: 180, height: 44)
        let frame = computeTopRightFrame(of: screen, size: size)

        let panel = OnboardingSkipPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let skipHandler = onSkip
        let model = holdModel
        let host = NSHostingController(rootView: LocalizedHostingRoot {
            OnboardingSkipButtonView(onSkip: skipHandler, holdModel: model)
        })
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.autoresizingMask = [.width, .height]
        panel.contentViewController = host
        panel.setFrame(frame, display: true)
        return panel
    }

    private func computeTopRightFrame(of screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let margin: CGFloat = 18
        let originX = visible.maxX - size.width - margin
        let originY = visible.maxY - size.height - margin
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }
}

private struct OnboardingSkipButtonView: View {
    let onSkip: () -> Void
    @ObservedObject var holdModel: OnboardingSkipHoldModel

    var body: some View {
        Button(action: onSkip) {
            HStack(spacing: 6) {
                Text("onboarding.skip.button")
                    .pickyFont(size: 12.5, weight: .semibold)
                Text("onboarding.skip.shortcut")
                    .pickyFont(size: 10, weight: .semibold, design: .rounded)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                    )
                    .foregroundColor(.white.opacity(0.85))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.72))
                    // Left-to-right progress fill mirrors the ESC hold
                    // duration so the user learns the gesture from the
                    // animation alone, no extra copy required.
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: geo.size.width * holdModel.progress)
                            .animation(.linear(duration: 0.05), value: holdModel.progress)
                    }
                    .clipShape(Capsule())
                }
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(holdModel.isHolding ? 0.55 : 0.32), lineWidth: 1)
                )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("onboarding.skip.button"))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
