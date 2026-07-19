//
//  PickySystemPermissionGateway.swift
//  Picky
//

import AVFoundation
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Speech

enum PickySystemPermissionCapability: String, Equatable {
    case accessibility
    case microphone
    case screenContent
    case screenRecording
    case speechRecognition
}

enum PickySystemPermissionAccessError: LocalizedError, Equatable {
    case unavailableInUnitTests(PickySystemPermissionCapability)

    var errorDescription: String? {
        switch self {
        case .unavailableInUnitTests(let capability):
            "\(capability.rawValue) permission requests are unavailable while running unit tests"
        }
    }
}

/// The only production boundary permitted to trigger macOS privacy prompts.
/// Unit tests must receive a typed failure before a system API is invoked.
@MainActor
struct PickySystemPermissionGateway {
    typealias ScreenShareableContentProvider = @MainActor () async throws -> SCShareableContent
    typealias ScreenshotCapturer = @MainActor (SCContentFilter, SCStreamConfiguration) async throws -> CGImage
    typealias MicrophoneAccessRequester = @MainActor () async -> Bool
    typealias SpeechAuthorizationRequester = @MainActor () async -> SFSpeechRecognizerAuthorizationStatus
    typealias ScreenRecordingAccessRequester = @MainActor () -> Bool
    typealias AccessibilityAccessRequester = @MainActor () -> Bool

    static let shared = PickySystemPermissionGateway()

    private let isRunningUnitTests: () -> Bool
    private let screenShareableContentProvider: ScreenShareableContentProvider
    private let screenshotCapturer: ScreenshotCapturer
    private let microphoneAccessRequester: MicrophoneAccessRequester
    private let speechAuthorizationRequester: SpeechAuthorizationRequester
    private let screenRecordingAccessRequester: ScreenRecordingAccessRequester
    private let accessibilityAccessRequester: AccessibilityAccessRequester

    init(
        isRunningUnitTests: @escaping () -> Bool = { PickyRuntimeEnvironment.isRunningUnitTests },
        screenShareableContentProvider: @escaping ScreenShareableContentProvider = {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        },
        screenshotCapturer: @escaping ScreenshotCapturer = { filter, configuration in
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        },
        microphoneAccessRequester: @escaping MicrophoneAccessRequester = {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        },
        speechAuthorizationRequester: @escaping SpeechAuthorizationRequester = {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        },
        screenRecordingAccessRequester: @escaping ScreenRecordingAccessRequester = {
            CGRequestScreenCaptureAccess()
        },
        accessibilityAccessRequester: @escaping AccessibilityAccessRequester = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    ) {
        self.isRunningUnitTests = isRunningUnitTests
        self.screenShareableContentProvider = screenShareableContentProvider
        self.screenshotCapturer = screenshotCapturer
        self.microphoneAccessRequester = microphoneAccessRequester
        self.speechAuthorizationRequester = speechAuthorizationRequester
        self.screenRecordingAccessRequester = screenRecordingAccessRequester
        self.accessibilityAccessRequester = accessibilityAccessRequester
    }

    func screenShareableContent() async throws -> SCShareableContent {
        try rejectInUnitTests(capability: .screenContent)
        return try await screenShareableContentProvider()
    }

    func captureScreenshot(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try rejectInUnitTests(capability: .screenContent)
        return try await screenshotCapturer(contentFilter, configuration)
    }

    func requestMicrophoneAccess() async throws -> Bool {
        try rejectInUnitTests(capability: .microphone)
        return await microphoneAccessRequester()
    }

    func requestSpeechRecognitionAuthorization() async throws -> SFSpeechRecognizerAuthorizationStatus {
        try rejectInUnitTests(capability: .speechRecognition)
        return await speechAuthorizationRequester()
    }

    func requestScreenRecordingAccess() throws -> Bool {
        try rejectInUnitTests(capability: .screenRecording)
        return screenRecordingAccessRequester()
    }

    func requestAccessibilityAccess() throws -> Bool {
        try rejectInUnitTests(capability: .accessibility)
        return accessibilityAccessRequester()
    }

    private func rejectInUnitTests(capability: PickySystemPermissionCapability) throws {
        guard isRunningUnitTests() else { return }
        PickyLog.notice(
            .permission,
            prefix: "🔐 Picky permission —",
            message: "capability=\(capability.rawValue) skippedForUnitTests=true"
        )
        throw PickySystemPermissionAccessError.unavailableInUnitTests(capability)
    }
}
