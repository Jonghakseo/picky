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
    typealias ScreenCapture = @MainActor () async throws -> [CompanionScreenCapture]
    typealias ContextAssembler = @MainActor (_ screenCaptures: [CompanionScreenCapture], _ source: String, _ transcript: String, _ voiceFollowUpSessionID: String?) throws -> PickyContextPacket

    private let screenCapture: ScreenCapture
    private let contextAssembler: ContextAssembler

    init(
        screenCapture: @escaping ScreenCapture = { try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() },
        contextAssembler: @escaping ContextAssembler = PickyVoiceContextCaptureCoordinator.assembleContextPacket
    ) {
        self.screenCapture = screenCapture
        self.contextAssembler = contextAssembler
    }

    func captureContext(
        transcript: String,
        voiceFollowUpSessionID: String?
    ) async throws -> PickyVoiceContextCaptureResult? {
        let screenCaptures = try await screenCapture()
        guard !Task.isCancelled else { return nil }

        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        let contextPacket = try contextAssembler(screenCaptures, source, transcript, voiceFollowUpSessionID)
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
            advancedBrowserProvider: AppleScriptBrowserContextProvider(),
            selectedTextProvider: ClipboardSelectedTextProvider(),
            screenProvider: StaticPickyScreenContextProvider(captures: screenCaptures),
            defaultCwd: PickySettingsStore().load().defaultCwd
        )
        return try assembler.assemble(source: source, transcript: transcript, selectedSessionId: voiceFollowUpSessionID)
    }
}
