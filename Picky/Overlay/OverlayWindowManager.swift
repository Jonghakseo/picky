//
//  OverlayWindowManager.swift
//  Picky
//
//  Multi-display overlay window lifecycle.
//

import AppKit
import SwiftUI

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    private weak var currentCompanionManager: CompanionManager?
    private var screenParametersObserver: NSObjectProtocol?
    private var isSuppressedForSystemCapture = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        currentCompanionManager = companionManager
        startScreenParametersObserverIfNeeded()
        rebuildOverlayWindows(onScreens: screens, companionManager: companionManager)
    }

    func hideOverlay() {
        stopScreenParametersObserver()
        currentCompanionManager = nil
        removeOverlayWindows()
    }

    func setSuppressedForSystemCapture(_ suppressed: Bool) {
        guard isSuppressedForSystemCapture != suppressed else { return }
        isSuppressedForSystemCapture = suppressed

        if suppressed {
            for window in overlayWindows {
                window.orderOut(nil)
            }
            return
        }

        guard currentCompanionManager != nil else { return }
        for window in overlayWindows {
            window.orderFrontRegardless()
        }
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        stopScreenParametersObserver()
        currentCompanionManager = nil

        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }

    private func rebuildOverlayWindows(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        removeOverlayWindows()

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: LocalizedHostingRoot { contentView })
            hostingView.frame = PickyOverlayGeometry.overlayContentFrame(for: screen.frame)
            window.contentView = hostingView

            overlayWindows.append(window)
            if !isSuppressedForSystemCapture {
                window.orderFrontRegardless()
            }
        }
    }

    private func removeOverlayWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    private func startScreenParametersObserverIfNeeded() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let companionManager = self.currentCompanionManager else { return }
                self.rebuildOverlayWindows(onScreens: NSScreen.screens, companionManager: companionManager)
            }
        }
    }

    private func stopScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
    }
}
