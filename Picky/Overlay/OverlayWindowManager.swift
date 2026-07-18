//
//  OverlayWindowManager.swift
//  Picky
//
//  Multi-display overlay window lifecycle.
//

import AppKit
import Combine
import SwiftUI

/// macOS suppresses secure confirmation UI (App Store purchase sheets,
/// payment authorization) whenever another app's window overlaps the sheet —
/// regardless of window level, sharing type, or click-through. Because the
/// cursor overlay covers the whole screen, it must be ordered out entirely
/// while such an app is frontmost. Verified experimentally against the
/// App Store on macOS 26.5.2 (see the 0.4.42 purchase-sheet bug report).
enum PickySecureSurfaceOverlayPolicy {
    static let suppressedBundleIDs: Set<String> = ["com.apple.AppStore"]

    static func shouldSuppressOverlay(frontmostBundleID: String?) -> Bool {
        guard let frontmostBundleID else { return false }
        return suppressedBundleIDs.contains(frontmostBundleID)
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private struct AnnotationDismissPresentation: Equatable {
        let annotations: [PickyAgentAnnotation]
        let isPresented: Bool
    }

    private var overlayWindows: [OverlayWindow] = []
    private weak var currentCompanionManager: CompanionManager?
    private var screenParametersObserver: NSObjectProtocol?
    private var frontmostAppObserver: NSObjectProtocol?
    private var annotationDismissObservation: AnyCancellable?
    private let annotationDismissPanelController = PickyAnnotationDismissPanelController()
    private var isSuppressedForSecureSurface = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Rebinding can happen after display reconstruction; discard any panel whose
        // button closure still references the previous manager before observing again.
        annotationDismissPanelController.dismiss()
        currentCompanionManager = companionManager
        startScreenParametersObserverIfNeeded()
        startFrontmostAppObserverIfNeeded()
        isSuppressedForSecureSurface = PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        annotationDismissPanelController.setSuppressed(isSuppressedForSecureSurface)
        rebuildOverlayWindows(onScreens: screens, companionManager: companionManager)
        startAnnotationDismissObservation(companionManager)
    }

    func hideOverlay() {
        stopScreenParametersObserver()
        stopFrontmostAppObserver()
        stopAnnotationDismissObservation()
        annotationDismissPanelController.dismiss()
        currentCompanionManager = nil
        removeOverlayWindows()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        stopScreenParametersObserver()
        stopFrontmostAppObserver()
        stopAnnotationDismissObservation()
        annotationDismissPanelController.dismiss()
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
            if !isSuppressedForSecureSurface {
                window.orderFrontRegardless()
            }
        }
    }

    /// Orders overlay windows out while a secure-surface app is frontmost and
    /// back in when it resigns. Windows are kept alive (not rebuilt) so the
    /// suppression round-trip is cheap.
    private func applySecureSurfaceSuppression(_ suppressed: Bool) {
        guard suppressed != isSuppressedForSecureSurface else { return }
        isSuppressedForSecureSurface = suppressed
        for window in overlayWindows {
            if suppressed {
                window.orderOut(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
        annotationDismissPanelController.setSuppressed(suppressed)
    }

    private func startFrontmostAppObserverIfNeeded() {
        guard frontmostAppObserver == nil else { return }
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let activatedBundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.applySecureSurfaceSuppression(
                    PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(frontmostBundleID: activatedBundleID)
                )
            }
        }
    }

    private func stopFrontmostAppObserver() {
        if let frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
        }
        frontmostAppObserver = nil
    }

    private func removeOverlayWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    private func startAnnotationDismissObservation(_ companionManager: CompanionManager) {
        stopAnnotationDismissObservation()
        annotationDismissObservation = companionManager.$agentAnnotations
            .combineLatest(companionManager.$showsAgentAnnotationDismissControl)
            .map { annotations, isPresented in
                AnnotationDismissPresentation(annotations: annotations, isPresented: isPresented)
            }
            .removeDuplicates()
            .sink { [weak self, weak companionManager] presentation in
                guard let self, let companionManager else { return }
                self.annotationDismissPanelController.update(
                    annotations: presentation.annotations,
                    isPresented: presentation.isPresented,
                    screens: NSScreen.screens,
                    onDismiss: { [weak companionManager] in
                        companionManager?.dismissAgentAnnotations()
                    }
                )
            }
    }

    private func refreshAnnotationDismissPanels(for companionManager: CompanionManager) {
        annotationDismissPanelController.update(
            annotations: companionManager.agentAnnotations,
            isPresented: companionManager.showsAgentAnnotationDismissControl,
            screens: NSScreen.screens,
            onDismiss: { [weak companionManager] in
                companionManager?.dismissAgentAnnotations()
            }
        )
    }

    private func stopAnnotationDismissObservation() {
        annotationDismissObservation?.cancel()
        annotationDismissObservation = nil
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
                self.refreshAnnotationDismissPanels(for: companionManager)
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
