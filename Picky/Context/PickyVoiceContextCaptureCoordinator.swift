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
    func captureContext(
        transcript: String,
        voiceFollowUpSessionID: String?
    ) async throws -> PickyVoiceContextCaptureResult {
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

        let assembler = PickyContextPacketAssembler(
            appProvider: WorkspacePickyApplicationContextProvider(),
            windowProvider: CGWindowPickyWindowContextProvider(),
            advancedBrowserProvider: AppleScriptBrowserContextProvider(),
            selectedTextProvider: ClipboardSelectedTextProvider(),
            screenProvider: StaticPickyScreenContextProvider(captures: screenCaptures),
            defaultCwd: PickySettingsStore().load().defaultCwd
        )
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        let contextPacket = try assembler.assemble(source: source, transcript: transcript, selectedSessionId: voiceFollowUpSessionID)
        return PickyVoiceContextCaptureResult(contextPacket: contextPacket, source: source)
    }
}
