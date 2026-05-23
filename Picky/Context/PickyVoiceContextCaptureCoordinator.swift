//
//  PickyVoiceContextCaptureCoordinator.swift
//  Picky
//

import Foundation

struct PickyVoiceContextCaptureResult {
    let contextPacket: PickyContextPacket
    let source: String
}

@MainActor
struct PickyVoiceContextCaptureCoordinator {
    typealias ScreenCapture = @MainActor (_ scope: PickyScreenContextScope, _ maximumDimension: Int) async throws -> [CompanionScreenCapture]
    typealias SettingsProvider = @MainActor () -> PickySettings
    typealias ContextAssembler = @MainActor (_ screenCaptures: [CompanionScreenCapture], _ source: String, _ transcript: String, _ inkCapture: PickyInkCapture?) throws -> PickyContextPacket

    private let screenCapture: ScreenCapture
    private let settingsProvider: SettingsProvider
    private let contextAssembler: ContextAssembler

    init(
        screenCapture: @escaping ScreenCapture = { scope, maximumDimension in
            try await CompanionScreenCaptureUtility.captureScreensAsJPEG(
                scope: scope,
                maximumDimension: maximumDimension
            )
        },
        settingsProvider: @escaping SettingsProvider = { PickySettingsStore().load() },
        contextAssembler: @escaping ContextAssembler = PickyVoiceContextCaptureCoordinator.assembleContextPacket
    ) {
        self.screenCapture = screenCapture
        self.settingsProvider = settingsProvider
        self.contextAssembler = contextAssembler
    }

    func captureContext(
        transcript: String,
        voiceFollowUpSessionID: String?,
        inkCapture: PickyInkCapture? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        return try await captureContext(
            transcript: transcript,
            source: source,
            inkCapture: inkCapture
        )
    }

    func captureContext(
        transcript: String,
        source: String,
        inkCapture: PickyInkCapture? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        let settings = settingsProvider()
        let screenCaptures = try await screenCapture(
            settings.screenContextScope,
            settings.screenshotQuality.maximumDimension
        )
        guard !Task.isCancelled else { return nil }

        let assembled = try contextAssembler(screenCaptures, source, transcript, inkCapture)
        let gated = Self.applyInkOnlyAttachmentGate(assembled, settings: settings)
        return PickyVoiceContextCaptureResult(contextPacket: gated, source: source)
    }

    /// Honors `PickySettings.attachScreenshotsOnlyWhenInked` by stripping
    /// screenshots/ink from the model-bound packet when the user did not draw
    /// during this turn. Screen capture and on-disk persistence have already
    /// happened by this point — only the model payload is gated.
    static func applyInkOnlyAttachmentGate(
        _ packet: PickyContextPacket,
        settings: PickySettings
    ) -> PickyContextPacket {
        guard settings.attachScreenshotsOnlyWhenInked else { return packet }
        guard packet.inkMarks.isEmpty else { return packet }
        return packet.withScreenshotsCleared()
    }

    private static func assembleContextPacket(
        screenCaptures: [CompanionScreenCapture],
        source: String,
        transcript: String,
        inkCapture: PickyInkCapture?
    ) throws -> PickyContextPacket {
        let assembler = PickyContextPacketAssembler(
            appProvider: WorkspacePickyApplicationContextProvider(),
            windowProvider: CGWindowPickyWindowContextProvider(),
            advancedBrowserProvider: ChainedBrowserContextProvider(providers: [
                AppleScriptBrowserContextProvider(),
                AccessibilityBrowserContextProvider()
            ]),
            selectedTextProvider: ChainedSelectedTextProvider(providers: [
                AccessibilitySelectedTextProvider(),
                ClipboardSelectedTextProvider()
            ]),
            screenProvider: StaticPickyScreenContextProvider(captures: screenCaptures, inkCapture: inkCapture),
            defaultCwd: PickySettingsStore().load().mainAgentCwd
        )
        return try assembler.assemble(source: source, transcript: transcript)
    }
}
