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
    typealias ScreenCapture = @MainActor (_ scope: PickyScreenContextScope) async throws -> [CompanionScreenCapture]
    typealias SettingsProvider = @MainActor () -> PickySettings
    typealias ContextAssembler = @MainActor (_ screenCaptures: [CompanionScreenCapture], _ source: String, _ transcript: String, _ voiceFollowUpSessionID: String?) throws -> PickyContextPacket

    private let screenCapture: ScreenCapture
    private let settingsProvider: SettingsProvider
    private let contextAssembler: ContextAssembler

    init(
        screenCapture: @escaping ScreenCapture = { scope in try await CompanionScreenCaptureUtility.captureScreensAsJPEG(scope: scope) },
        settingsProvider: @escaping SettingsProvider = { PickySettingsStore().load() },
        contextAssembler: @escaping ContextAssembler = PickyVoiceContextCaptureCoordinator.assembleContextPacket
    ) {
        self.screenCapture = screenCapture
        self.settingsProvider = settingsProvider
        self.contextAssembler = contextAssembler
    }

    func captureContext(
        transcript: String,
        voiceFollowUpSessionID: String?
    ) async throws -> PickyVoiceContextCaptureResult? {
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        return try await captureContext(
            transcript: transcript,
            source: source,
            selectedSessionID: voiceFollowUpSessionID
        )
    }

    func captureContext(
        transcript: String,
        source: String,
        selectedSessionID: String? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        let settings = settingsProvider()
        let screenCaptures = try await screenCapture(settings.screenContextScope)
        guard !Task.isCancelled else { return nil }

        let contextPacket = try contextAssembler(screenCaptures, source, transcript, selectedSessionID)
        return PickyVoiceContextCaptureResult(contextPacket: contextPacket, source: source)
    }

    private static func assembleContextPacket(
        screenCaptures: [CompanionScreenCapture],
        source: String,
        transcript: String,
        voiceFollowUpSessionID: String?
    ) throws -> PickyContextPacket {
        let assembler = PickyContextPacketAssembler(
            appProvider: WorkspacePickyApplicationContextProvider(),
            windowProvider: CGWindowPickyWindowContextProvider(),
            advancedBrowserProvider: ChainedBrowserContextProvider(providers: [
                AppleScriptBrowserContextProvider(),
                AccessibilityBrowserContextProvider()
            ]),
            selectedTextProvider: ClipboardSelectedTextProvider(),
            screenProvider: StaticPickyScreenContextProvider(captures: screenCaptures),
            defaultCwd: PickySettingsStore().load().defaultCwd
        )
        return try assembler.assemble(source: source, transcript: transcript, selectedSessionId: voiceFollowUpSessionID)
    }
}
