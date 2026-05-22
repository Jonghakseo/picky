//
//  PickySystemCaptureMonitor.swift
//  Picky
//
//  Watches for macOS' built-in Screenshot UI so Picky can temporarily hide
//  always-on chrome that would otherwise become the selected "window" during
//  system window capture.
//

import AppKit
import CoreGraphics

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

enum PickySystemCaptureShortcutMatcher {
    /// US ANSI key codes for 3, 4, 5, 6. These are the macOS screenshot shortcuts:
    /// ⌘⇧3/4/5 and the Touch Bar capture variant ⌘⇧6.
    private static let screenshotKeyCodes: Set<UInt16> = [20, 21, 22, 23]
    private static let escapeKeyCode: UInt16 = 53

    static func isScreenshotShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            && flags.contains(.maskShift)
            && screenshotKeyCodes.contains(keyCode)
    }

    static func isEscape(keyCode: UInt16) -> Bool {
        keyCode == escapeKeyCode
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
    private let shortcutFallbackNanoseconds: UInt64
    private let shortcutCompletionDelayNanoseconds: UInt64
    private let shortcutCancelDelayNanoseconds: UInt64
    private let pollingInterval: TimeInterval
    private let installsEventTap: Bool

    private var observers: [NSObjectProtocol] = []
    private var processRestoreTask: Task<Void, Never>?
    private var shortcutReleaseTask: Task<Void, Never>?
    private var pollingTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var isStarted = false
    private var isProcessCaptureActive = false
    private var isShortcutCaptureActive = false
    private(set) var isSystemCaptureActive = false

    init(
        workspace: NSWorkspace = .shared,
        restoreDelayNanoseconds: UInt64 = 800_000_000,
        shortcutFallbackNanoseconds: UInt64 = 45_000_000_000,
        shortcutCompletionDelayNanoseconds: UInt64 = 2_000_000_000,
        shortcutCancelDelayNanoseconds: UInt64 = 200_000_000,
        pollingInterval: TimeInterval = 0.25,
        suppressionHandler: @escaping SuppressionHandler
    ) {
        self.workspaceNotificationCenter = workspace.notificationCenter
        self.runningApplicationsProvider = {
            workspace.runningApplications.map(PickyRunningApplicationSnapshot.init(application:))
        }
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
        self.shortcutFallbackNanoseconds = shortcutFallbackNanoseconds
        self.shortcutCompletionDelayNanoseconds = shortcutCompletionDelayNanoseconds
        self.shortcutCancelDelayNanoseconds = shortcutCancelDelayNanoseconds
        self.pollingInterval = pollingInterval
        self.installsEventTap = true
        self.suppressionHandler = suppressionHandler
    }

    init(
        notificationCenter: NotificationCenter,
        runningApplicationsProvider: @escaping RunningApplicationsProvider,
        restoreDelayNanoseconds: UInt64 = 800_000_000,
        shortcutFallbackNanoseconds: UInt64 = 45_000_000_000,
        shortcutCompletionDelayNanoseconds: UInt64 = 2_000_000_000,
        shortcutCancelDelayNanoseconds: UInt64 = 200_000_000,
        pollingInterval: TimeInterval = 0.25,
        installsEventTap: Bool = false,
        suppressionHandler: @escaping SuppressionHandler
    ) {
        self.workspaceNotificationCenter = notificationCenter
        self.runningApplicationsProvider = runningApplicationsProvider
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
        self.shortcutFallbackNanoseconds = shortcutFallbackNanoseconds
        self.shortcutCompletionDelayNanoseconds = shortcutCompletionDelayNanoseconds
        self.shortcutCancelDelayNanoseconds = shortcutCancelDelayNanoseconds
        self.pollingInterval = pollingInterval
        self.installsEventTap = installsEventTap
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

        startPolling()
        if installsEventTap {
            startEventTap()
        }
        evaluateRunningApplications()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        processRestoreTask?.cancel()
        processRestoreTask = nil
        shortcutReleaseTask?.cancel()
        shortcutReleaseTask = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        stopEventTap()
        for observer in observers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        isProcessCaptureActive = false
        isShortcutCaptureActive = false
        updateSystemCaptureActive()
    }

    func evaluateRunningApplications() {
        let isActive = runningApplicationsProvider().contains {
            PickySystemCaptureApplicationMatcher.isSystemCaptureApplication($0)
        }

        if isActive {
            processRestoreTask?.cancel()
            processRestoreTask = nil
            setProcessCaptureActive(true)
            return
        }

        processRestoreTask?.cancel()
        processRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.setProcessCaptureActive(false)
        }
    }

    func noteScreenshotShortcutStartedForTesting() {
        beginShortcutCaptureSuppression()
    }

    func noteCaptureInteractionCompletedForTesting() {
        scheduleShortcutSuppressionRelease(after: shortcutCompletionDelayNanoseconds)
    }

    private func startPolling() {
        guard pollingTimer == nil, pollingInterval > 0 else { return }
        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateRunningApplications()
            }
        }
        pollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startEventTap() {
        guard eventTap == nil else { return }
        let eventTypes: [CGEventType] = [.keyDown, .leftMouseUp, .rightMouseUp]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.handleEventTap,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Picky screenshot monitor: couldn't create CGEvent tap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            print("⚠️ Picky screenshot monitor: couldn't create event tap run loop source")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private static let handleEventTap: CGEventTapCallBack = { _, eventType, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<PickySystemCaptureMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        Task { @MainActor in
            monitor.handleEventTap(eventType: eventType, keyCode: keyCode, flags: flags)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleEventTap(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        switch eventType {
        case .keyDown:
            if PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: keyCode, flags: flags) {
                beginShortcutCaptureSuppression()
            } else if isShortcutCaptureActive, PickySystemCaptureShortcutMatcher.isEscape(keyCode: keyCode) {
                scheduleShortcutSuppressionRelease(after: shortcutCancelDelayNanoseconds)
            }
        case .leftMouseUp, .rightMouseUp:
            guard isShortcutCaptureActive, !isProcessCaptureActive else { return }
            scheduleShortcutSuppressionRelease(after: shortcutCompletionDelayNanoseconds)
        default:
            break
        }
    }

    private func beginShortcutCaptureSuppression() {
        shortcutReleaseTask?.cancel()
        setShortcutCaptureActive(true)
        scheduleShortcutSuppressionRelease(after: shortcutFallbackNanoseconds)
    }

    private func scheduleShortcutSuppressionRelease(after delay: UInt64) {
        shortcutReleaseTask?.cancel()
        shortcutReleaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self.setShortcutCaptureActive(false)
        }
    }

    private func setProcessCaptureActive(_ isActive: Bool) {
        guard isProcessCaptureActive != isActive else { return }
        isProcessCaptureActive = isActive
        updateSystemCaptureActive()
    }

    private func setShortcutCaptureActive(_ isActive: Bool) {
        guard isShortcutCaptureActive != isActive else { return }
        isShortcutCaptureActive = isActive
        updateSystemCaptureActive()
    }

    private func updateSystemCaptureActive() {
        let next = isProcessCaptureActive || isShortcutCaptureActive
        guard isSystemCaptureActive != next else { return }
        isSystemCaptureActive = next
        suppressionHandler(next)
    }
}
