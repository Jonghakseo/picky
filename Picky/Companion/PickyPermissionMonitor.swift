//
//  PickyPermissionMonitor.swift
//  Picky
//
//  Single owner of the macOS permission flags the setup surface renders.
//  Probes system state, polls for live updates, persists the one-time screen
//  content grant, and publishes transitions so effect owners (PTT monitor,
//  cursor overlay) can react without owning the flags themselves.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class PickyPermissionMonitor: ObservableObject {
    struct Probes {
        var accessibility: @MainActor () -> Bool = { WindowPositionManager.hasAccessibilityPermission() }
        var screenRecording: @MainActor () -> Bool = { WindowPositionManager.hasScreenRecordingPermission() }
        var microphone: @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        var persistedScreenContent: @MainActor () -> Bool = { PickyRuntimeEnvironment.userDefaults.bool(forKey: screenContentDefaultsKey) }
        var persistScreenContent: @MainActor () -> Void = { PickyRuntimeEnvironment.userDefaults.set(true, forKey: screenContentDefaultsKey) }
    }

    static let screenContentDefaultsKey = "hasScreenContentPermission"
    static let pollingInterval: TimeInterval = 1.5

    @Published private(set) var hasAccessibility = false
    @Published private(set) var hasScreenRecording = false
    @Published private(set) var hasMicrophone = false
    @Published private(set) var hasScreenContent = false
    @Published private(set) var isRequestingScreenContent = false

    /// Emits after every refresh with the current accessibility state, so the
    /// global event-tap owners can start or stop on each probe.
    let accessibilityProbed = PassthroughSubject<Bool, Never>()
    /// Emits once per false → true transition of `allGranted`.
    let becameAllGranted = PassthroughSubject<Void, Never>()

    var allGranted: Bool {
        hasAccessibility && hasScreenRecording && hasMicrophone && hasScreenContent
    }

    private let probes: Probes
    /// `PICKY_FORCE_PERMISSIONS_MISSING=1` reports every flag as false after the
    /// real probe so the panel renders the full setup surface without revoking
    /// real grants. Side effects still follow real macOS state.
    private let forceMissing: Bool
    private var pollingTimer: Timer?

    init(
        probes: Probes = Probes(),
        forceMissing: Bool = ProcessInfo.processInfo.environment["PICKY_FORCE_PERMISSIONS_MISSING"] == "1"
    ) {
        self.probes = probes
        self.forceMissing = forceMissing
    }

    func refresh() {
        let previouslyHadAccessibility = hasAccessibility
        let previouslyHadScreenRecording = hasScreenRecording
        let previouslyHadMicrophone = hasMicrophone
        let previouslyHadAll = allGranted

        hasAccessibility = probes.accessibility()
        accessibilityProbed.send(hasAccessibility)
        hasScreenRecording = probes.screenRecording()
        hasMicrophone = probes.microphone()

        if previouslyHadAccessibility != hasAccessibility
            || previouslyHadScreenRecording != hasScreenRecording
            || previouslyHadMicrophone != hasMicrophone {
            print("🔑 Permissions — accessibility: \(hasAccessibility), screen: \(hasScreenRecording), mic: \(hasMicrophone), screenContent: \(hasScreenContent)")
        }

        if !previouslyHadAccessibility && hasAccessibility {
            PickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecording {
            PickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophone {
            PickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // The SCShareableContent picker grant is persisted; never re-probe it.
        if !hasScreenContent {
            hasScreenContent = probes.persistedScreenContent()
        }

        if forceMissing {
            hasAccessibility = false
            hasScreenRecording = false
            hasMicrophone = false
            hasScreenContent = false
        }

        if !previouslyHadAll && allGranted {
            PickyAnalytics.trackAllPermissionsGranted()
            becameAllGranted.send()
        }
    }

    /// Screen Recording is the exception to live polling: macOS requires an app
    /// restart for that grant to take effect.
    func startPolling() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Triggers the macOS screen content picker by performing a dummy capture.
    /// A non-empty image means the user approved; the grant is then persisted.
    func requestScreenContent() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await PickySystemPermissionGateway.shared.screenShareableContent()
                guard let display = content.displays.first else {
                    isRequestingScreenContent = false
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await PickySystemPermissionGateway.shared.captureScreenshot(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                isRequestingScreenContent = false
                guard didCapture else { return }
                markScreenContentGranted()
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                isRequestingScreenContent = false
            }
        }
    }

    func markScreenContentGranted() {
        let previouslyHadAll = allGranted
        hasScreenContent = true
        probes.persistScreenContent()
        PickyAnalytics.trackPermissionGranted(permission: "screen_content")
        if !previouslyHadAll && allGranted {
            becameAllGranted.send()
        }
    }
}
