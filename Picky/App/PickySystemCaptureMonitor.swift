//
//  PickySystemCaptureMonitor.swift
//  Picky
//
//  Watches for macOS' built-in Screenshot UI so Picky can temporarily hide
//  always-on chrome that would otherwise become the selected "window" during
//  system window capture.
//

import AppKit

struct PickyRunningApplicationSnapshot: Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURLLastPathComponent: String?

    init(bundleIdentifier: String?, localizedName: String?, bundleURLLastPathComponent: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.bundleURLLastPathComponent = bundleURLLastPathComponent
    }

    init(application: NSRunningApplication) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            bundleURLLastPathComponent: application.bundleURL?.lastPathComponent
        )
    }
}

enum PickySystemCaptureApplicationMatcher {
    private static let knownBundleIdentifiers: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher"
    ]

    private static let knownNames: Set<String> = [
        "screencaptureui",
        "screencaptureui.app",
        "Screenshot",
        "Screenshot.app"
    ]

    static func isSystemCaptureApplication(_ application: PickyRunningApplicationSnapshot) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier,
           knownBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        if let localizedName = application.localizedName,
           knownNames.contains(localizedName) {
            return true
        }

        if let bundleURLLastPathComponent = application.bundleURLLastPathComponent,
           knownNames.contains(bundleURLLastPathComponent) {
            return true
        }

        return false
    }
}

@MainActor
final class PickySystemCaptureMonitor {
    typealias RunningApplicationsProvider = () -> [PickyRunningApplicationSnapshot]
    typealias SuppressionHandler = (Bool) -> Void

    private let workspaceNotificationCenter: NotificationCenter
    private let runningApplicationsProvider: RunningApplicationsProvider
    private let suppressionHandler: SuppressionHandler
    private let restoreDelayNanoseconds: UInt64

    private var observers: [NSObjectProtocol] = []
    private var restoreTask: Task<Void, Never>?
    private var isStarted = false
    private(set) var isSystemCaptureActive = false

    init(
        workspace: NSWorkspace = .shared,
        restoreDelayNanoseconds: UInt64 = 800_000_000,
        suppressionHandler: @escaping SuppressionHandler
    ) {
        self.workspaceNotificationCenter = workspace.notificationCenter
        self.runningApplicationsProvider = {
            workspace.runningApplications.map(PickyRunningApplicationSnapshot.init(application:))
        }
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
        self.suppressionHandler = suppressionHandler
    }

    init(
        notificationCenter: NotificationCenter,
        runningApplicationsProvider: @escaping RunningApplicationsProvider,
        restoreDelayNanoseconds: UInt64 = 800_000_000,
        suppressionHandler: @escaping SuppressionHandler
    ) {
        self.workspaceNotificationCenter = notificationCenter
        self.runningApplicationsProvider = runningApplicationsProvider
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
        self.suppressionHandler = suppressionHandler
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        observers = names.map { name in
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateRunningApplications()
                }
            }
        }

        evaluateRunningApplications()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        restoreTask?.cancel()
        restoreTask = nil
        for observer in observers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        setSystemCaptureActive(false)
    }

    func evaluateRunningApplications() {
        let isActive = runningApplicationsProvider().contains {
            PickySystemCaptureApplicationMatcher.isSystemCaptureApplication($0)
        }

        if isActive {
            restoreTask?.cancel()
            restoreTask = nil
            setSystemCaptureActive(true)
            return
        }

        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.setSystemCaptureActive(false)
        }
    }

    private func setSystemCaptureActive(_ isActive: Bool) {
        guard isSystemCaptureActive != isActive else { return }
        isSystemCaptureActive = isActive
        suppressionHandler(isActive)
    }
}
