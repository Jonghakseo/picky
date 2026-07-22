//
//  PickySecureSurfaceWindowCoordinator.swift
//  Picky
//
//  Keeps Picky-owned windows out of macOS secure authorization surfaces.
//

import AppKit

/// Secure authorization sheets, including App Store download and update
/// confirmation, may be suppressed when another app's window overlaps them.
/// Keep this policy intentionally narrow: it is a system-UI compatibility
/// safeguard, not a general foreground-window policy.
enum PickySecureSurfaceOverlayPolicy {
    static let suppressedBundleIDs: Set<String> = ["com.apple.AppStore"]

    static func shouldSuppressOverlay(frontmostBundleID: String?) -> Bool {
        guard let frontmostBundleID else { return false }
        return suppressedBundleIDs.contains(frontmostBundleID)
    }
}

/// Minimal window boundary for the coordinator. Production uses `NSWindow`;
/// tests use a deterministic fake without creating real AppKit windows.
protocol PickySecureSurfaceManagedWindow: AnyObject {
    var isVisible: Bool { get }
    var isSecureSurfaceSuppressionCandidate: Bool { get }
    var secureSurfaceVisibilityRevision: UInt64 { get }
    func orderOutForSecureSurfaceSuppression()
    func orderFrontRegardless()
}

/// Common base for Picky's elevated panels. Owner-driven `orderOut` calls
/// advance a revision, while coordinator-driven suppression does not. This
/// lets restoration distinguish "temporarily hidden" from "dismissed while
/// hidden" even though both states have `isVisible == false`.
class PickySecureSurfacePanel: NSPanel, PickySecureSurfaceManagedWindow {
    private(set) var secureSurfaceVisibilityRevision: UInt64 = 0

    var isSecureSurfaceSuppressionCandidate: Bool {
        level.rawValue > NSWindow.Level.normal.rawValue
    }

    override func orderOut(_ sender: Any?) {
        secureSurfaceVisibilityRevision &+= 1
        super.orderOut(sender)
    }

    func orderOutForSecureSurfaceSuppression() {
        super.orderOut(nil)
    }
}

/// Orders every currently visible, always-on-top Picky window out while a
/// secure-surface app is frontmost, then restores only those windows when it
/// resigns. The AppKit update cycle also closes the race where a global
/// shortcut opens Quick Input after the App Store is already active.
@MainActor
final class PickySecureSurfaceWindowCoordinator {
    private let frontmostBundleIDProvider: @MainActor () -> String?
    private let windowsProvider: @MainActor () -> [PickySecureSurfaceManagedWindow]
    private var activationObserver: NSObjectProtocol?
    private var applicationUpdateObserver: NSObjectProtocol?
    private var windowClosedObserver: NSObjectProtocol?
    private struct SuppressedWindow {
        let window: PickySecureSurfaceManagedWindow
        let visibilityRevision: UInt64
    }

    private var suppressedWindows: [ObjectIdentifier: SuppressedWindow] = [:]
    private(set) var isSuppressed = false

    init(
        frontmostBundleIDProvider: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        windowsProvider: @escaping @MainActor () -> [PickySecureSurfaceManagedWindow] = {
            NSApp.windows.compactMap { $0 as? PickySecureSurfaceManagedWindow }
        }
    ) {
        self.frontmostBundleIDProvider = frontmostBundleIDProvider
        self.windowsProvider = windowsProvider
    }

    func start() {
        guard activationObserver == nil else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.apply(frontmostBundleID: bundleID)
            }
        }
        applicationUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suppressVisibleWindowsIfNeeded()
            }
        }
        windowClosedObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? PickySecureSurfaceManagedWindow else { return }
            Task { @MainActor [weak self] in
                self?.handleWindowClosed(window)
            }
        }
        apply(frontmostBundleID: frontmostBundleIDProvider())
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let applicationUpdateObserver {
            NotificationCenter.default.removeObserver(applicationUpdateObserver)
        }
        if let windowClosedObserver {
            NotificationCenter.default.removeObserver(windowClosedObserver)
        }
        activationObserver = nil
        applicationUpdateObserver = nil
        windowClosedObserver = nil
        restoreSuppressedWindows()
        isSuppressed = false
    }

    /// Internal for deterministic unit tests; runtime callers should use
    /// workspace activation notifications through `start()`.
    func apply(frontmostBundleID: String?) {
        let shouldSuppress = PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(
            frontmostBundleID: frontmostBundleID
        )
        guard shouldSuppress != isSuppressed else {
            suppressVisibleWindowsIfNeeded()
            return
        }

        isSuppressed = shouldSuppress
        if shouldSuppress {
            suppressVisibleWindowsIfNeeded()
        } else {
            restoreSuppressedWindows()
        }
    }

    private func handleWindowClosed(_ window: PickySecureSurfaceManagedWindow) {
        suppressedWindows.removeValue(forKey: ObjectIdentifier(window))
    }

    private func suppressVisibleWindowsIfNeeded() {
        guard isSuppressed else { return }
        for window in windowsProvider() where window.isVisible && window.isSecureSurfaceSuppressionCandidate {
            suppress(window)
        }
    }

    private func suppress(_ window: PickySecureSurfaceManagedWindow) {
        suppressedWindows[ObjectIdentifier(window)] = SuppressedWindow(
            window: window,
            visibilityRevision: window.secureSurfaceVisibilityRevision
        )
        window.orderOutForSecureSurfaceSuppression()
    }

    private func restoreSuppressedWindows() {
        let windowsToRestore = suppressedWindows.values
        suppressedWindows.removeAll()
        for suppressedWindow in windowsToRestore
        where suppressedWindow.window.secureSurfaceVisibilityRevision == suppressedWindow.visibilityRevision {
            suppressedWindow.window.orderFrontRegardless()
        }
    }
}
